# moonbitLog-StructuredDB

用 [MoonBit](https://www.moonbitlang.com/) 从零构建的 **Append-Only Event Log** 日志数据库：只追加、offset 单调、可持久化、可重放；删除以 tombstone 表达而非原地改写。

## 特性

- **只追加日志**：记录一旦写入不再修改，逻辑 offset 全局单调递增。
- **双后端**：内存后端（`backend_mem`，可在 wasm/js 运行）+ native 文件后端（`backend_native`，基于 C stub FFI 的真实文件持久化），通过 `io` 抽象隔离核心引擎。
- **多段管理**：`Log` 按 `roll_size` 滚动切段，段一旦 roll 不再修改。
- **稀疏索引**：每段内嵌按间隔采样的稀疏索引（间隔随 `roll_size` 自适应，使每段索引条目数接近固定），`get(offset)` 与范围扫描先定位再顺序前进，避免全段扫描。
- **范围扫描**：`Segment::scan_range` / `Log::scan_range` 支持半开区间 `[from, to)`。
- **崩溃恢复**：`Segment::recover` 顺序解码、遇 torn/CRC 失败的尾部即截断到最后一个完好边界并重建索引与计数；native 侧 `recover_log_dir` 打开目录恢复全部 `*.log` 段。
- **Tombstone**：`Log::delete` 追加删除标记记录，历史不被改写。
- **保留策略**：`Log::drop_before` / `Log::retain_last` / `Log::retain_max_bytes` / `Log::retain_before`（按 offset / 段数 / 总字节 / 时间戳）以整段删除方式回收旧数据。
- **可配置持久化**：`SyncPolicy` 支持 `Never` / `Always` / `Batch`；CLI **默认 `Always`**（命令返回即已 fsync），可用 `MOONLOG_SYNC=batch|never` 调整。
- **消费游标**：`ConsumerCursor` 保存已提交读位置，按批 `poll`，可续读；位置可持久化到目录下的 `CURSOR` 文件。
- **KV 逻辑视图与 compaction**：`KeyIndex` 提供 key→最新值查询（tombstone 生效），`Log::snapshot` 生成折叠后的 live 记录，`compact` 命令重写目录。
- **并发安全**：native 后端基于 `flock` 对目录加建议锁（写者独占 / 读者共享），CLI 写入与 `compact`/`prune` 互斥，读者总是观察到一致的偏移快照。
- **工程化**：property/fuzz 随机截断与损坏恢复测试、`moon bench` 基准、GitHub Actions CI。
- **CLI**：native 命令行工具覆盖上述能力。

## 包结构

| 包 | 职责 |
| --- | --- |
| `src/core` | 记录编码/解码（含 CRC32）、`Record` / `RecordKind` |
| `src/io` | 存储抽象：`LogWriter` / `LogReader` / `LogTruncate` 与 `IoError` |
| `src/segment` | 单段 append、稀疏索引、范围扫描、恢复 |
| `src/log` | 多段管理器、tombstone、保留策略、消费游标 |
| `src/backend_mem` | 内存后端（wasm/js 可用） |
| `src/backend_native` | native 文件后端（C stub FFI） |
| `src/cli` | 命令行前端（native 可执行） |

## 构建与测试

```bash
moon build --target native   # 构建（含 CLI）
moon test                    # wasm 目标测试
moon test --target native    # native 目标测试
moon bench --target native   # 基准：追加 / 点查 / 范围扫描 / 恢复
moon test --enable-coverage --target native   # native 覆盖率采集
moon coverage report -f summary               # 覆盖率摘要
```

## CLI 用法

构建后可执行位于 `_build/native/debug/build/src/cli/cli.exe`：

```
moonlog <command> <dir> [args...]

  put <dir> <key> <value>       追加一条 key/value 记录
  put-if <dir> <key> <expected|-> <value>
                                仅当 live 值等于 expected（`-` 要求不存在）才追加
  put-batch <dir> <k> <v> ...   一次追加多组 key/value 记录
  delete <dir> <key>            追加 key 的 tombstone
  get <dir> <offset>            按 offset 读取记录
  scan <dir> [from] [to]        列出 [from, to) 区间记录
  scan-prefix <dir> <prefix>    按 key 前缀列出（结果按 key 排序）
  scan-range <dir> <lo> [hi]    按 key 半开区间 [lo, hi) 列出（hi 省略表示无上界）
  scan-time <dir> <lo> <hi>     列出 timestamp 落在 [lo, hi) 的记录
  recover <dir>                 打开并恢复，报告计数
  prune <dir> <keep-segments>   只保留最新 N 个段
  prune-bytes <dir> <bytes>     回收最旧段直到总字节 <= bytes
  prune-before <dir> <timestamp> 回收末条记录早于 timestamp 的段
  prune-expired <dir> <ttl>     回收末条记录早于 now-ttl 的段
  prune-superseded <dir>        回收所有记录均被后续覆盖的段
  merge <dir> <max-segments>    将连续的已 roll 段合并至不超过 N 段
  maintain <dir> <max-segments> [ttl]
                                一键维护：合并 + 冗余回收 + 过期折叠 + fsck
  cursor <dir> <start|-> <limit>  按批读取消费游标（`-` 从持久化位置续读）
  cursor-commit <dir> <position> 持久化消费游标位置
  cursor-save <dir> <name> <pos> 持久化命名消费游标位置
  cursor-load <dir> <name>      读取命名消费游标位置
  cursor-list <dir>             列出全部命名消费游标位置
  cursor-drop <dir> <name>      删除命名消费游标位置
  getkey <dir> <key>            查询 key 的最新值（tombstone 生效）
  getkey-live <dir> <key> <ttl> 查询 key 的最新值，过期则视为不存在
  has-key <dir> <key>           用段级 Bloom 过滤判断 key 是否存在
  export <dir> <file>           导出全部记录（含 tombstone）到可移植文件
  import <dir> <file>           从可移植文件回放记录
  compact <dir>                 折叠为 live 记录并重写目录
  compact-expired <dir> <ttl>   折叠 live 记录并剔除已过期记录（offset 重排）
  fsck <dir>                    校验记录/offset 完整性
stats <dir> [json]            打印逐段统计（可选 JSON）
```

持久性与 `MOONLOG_SYNC`：CLI 写入默认 `Always`，即命令返回时数据已 fsync 落盘；设 `MOONLOG_SYNC=batch` 改为批量 / 导入时一次 fsync，设 `MOONLOG_SYNC=never`（或 `0`）关闭显式 fsync（仅依赖 OS 回写）。

`import` 会用目标日志的 `append` **重新分配 offset**（offset 是每个日志本地的连续编号）；导出文件保留 key/value/timestamp/kind，不含目标 offset 语义。

## API 概览

| 类型 / 函数 | 包 | 用途 |
| --- | --- | --- |
| `Log::new` / `Log::recover` | `log` | 建立多段日志 / 从已有段恢复 |
| `Log::append` / `append_batch` / `append_batch_atomic` / `Log::delete` | `log` | 追加单条 / 批量 / 原子批量（失败回滚）/ tombstone |
| `Log::get` / `scan` / `scan_range` / `scan_reverse` / `scan_time_range` / `tail` / `for_each` | `log` | 点查 / 全扫 / offset 区间 / 逆序区间 / 时间区间 / 最近 N 条 / 流式遍历 |
| `Log::retain_last` / `retain_max_bytes` / `retain_before` / `drop_before` | `log` | 段级保留策略（段数 / 字节 / 时间戳 / offset） |
| `Log::build_key_index` / `index_build_count` / `get_latest` / `get_latest_at` / `get_latest_bloom` / `get_many` / `scan_live` / `scan_prefix` / `scan_key_range` / `snapshot` / `compact` / `compact_expired` / `merge_segments` / `prune_superseded` | `log` | KV 逻辑视图（带缓存）/ TTL 读取 / Bloom 快查 / 批量点查 / 前缀与区间扫描 / 折叠 live / 过期折叠 / 原地重写 / 段合并 / 冗余段回收 |
| `Log::export_bytes` / `import_bytes` | `log` | 记录流导出 / 回放（可移植交换） |
| `ConsumerCursor::new` / `poll` / `seek` | `log` | 按批消费、提交与回退读位置 |
| `SyncPolicy` / `Log::flush` | `log` | `Never` / `Always` / `Batch` 持久化策略与显式 fsync |
| `Manifest::encode` / `decode_manifest` | `log` | 目录级元数据编解码 |
| `Log::verify` / `VerifyReport` | `log` | 全日志顺序与段校验和完整性校验 |
| `Log::segment_summaries` / `SegmentSummary` | `log` | 逐段计数 / 大小 / 压缩标志 / 时间跨度统计 |
| `rle_compress` / `rle_decompress` | `core` | 纯 MoonBit RLE 段数据压缩 / 解压（wasm 可用） |
| `Segment` / `SparseIndex` | `segment` | 单段读写、稀疏索引、崩溃恢复 |
| `MemLog` | `backend_mem` | 内存后端（wasm / js 可用） |
| `NativeFileLog` / `open_log_dir` / `index_interval_for` / `flush_meta` / `compress_log_dir` / `count_compressible_segments` / `DirLock` | `backend_native` | 文件后端、打开快路径、索引间隔、段压缩与计数、目录锁（含超时重试） |
| `save_named_cursor` / `load_named_cursor` / `list_named_cursors` / `remove_named_cursor` | `backend_native` | 命名消费游标持久化与管理 |
| `Record` / `crc32` | `core` | 记录编解码 |
| `LogWriter` / `LogReader` / `LogTruncate` / `IoError` | `io` | 存储抽象 |

## 在 wasm / JS 中使用

内存后端 `backend_mem` 不依赖 native FFI，可直接在 wasm / js 目标构建运行（`moon test` 即在该目标下执行）。构造一个内存日志：

```moonbit
let store = @backend_mem.MemLog::new()
let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
  1_048_576,
  base => @segment.Segment::new(store, store, base),
)
ignore(log.append(b"user:1", b"alice", 0))
let recs = log.scan()
```

需要真实文件持久化时改用 `backend_native`（仅 native 目标），二者接口一致，业务代码无需改动。

## 可运行示例

`examples/mem_demo/` 是一个最小可运行程序，用内存后端演示追加、tombstone、live 视图与消费游标，可在三种目标运行：

```bash
moon run examples/mem_demo --target native
moon run examples/mem_demo --target wasm
```

`examples/native_demo/` 用真实文件后端（native）演示打开目录、追加/删除、live 视图、key 区间扫描与逐段统计：

```bash
moon run examples/native_demo --target native
```

## 架构

```
          ┌──────────────┐
          │  cli（CLI）  │  put / scan / compact / export / fsck …
          └──────┬───────┘
                 │
          ┌──────▼───────┐
          │     log      │  Log[W,R]：多段、offset、保留、游标、KV 视图
          └───┬──────┬───┘
              │      │
    ┌─────────▼─┐  ┌─▼──────────┐
    │  segment  │  │    core    │  记录编解码 / CRC32
    └─────┬─────┘  └────────────┘
          │
   ┌──────▼───────────────────┐
   │ io：LogWriter/Reader/    │
   │     LogTruncate/IoError  │
   └───┬──────────────────┬───┘
       │                  │
┌──────▼──────┐    ┌──────▼────────┐
│ backend_mem │    │ backend_native│  flock / C stub FFI
└─────────────┘    └───────────────┘
```

- 存储抽象（`io`）让同一份 `log`/`segment` 逻辑同时运行在内存（wasm/js）与文件（native）后端之上。
- `segment` 负责单段的 append、稀疏索引、范围扫描与崩溃恢复；`log` 在其上实现多段管理、全局 offset、保留策略、消费游标、KV 视图与 compaction。

## 磁盘格式

每条记录（小端）：

```
u32 body_len
body:
  u8  flags        (0 = Put, 1 = Delete)
  u64 offset
  i64 timestamp
  u32 key_len
  u32 value_len
  key[key_len]
  value[value_len]
u32 crc32          (仅覆盖 body)
```

段文件名零填充，保证字典序与数值序一致，例如 `0000000000000007.log`。

### 持久化元数据（M8）

- 每个段旁挂 `<name>.log.index`：保存该段计数、稀疏索引快照、该段 key 的 Bloom 过滤器、时间跨度（min/max timestamp），以及已 roll 段的整段数据 CRC32 与压缩标志 + 原始大小（整体含 CRC32），重开时可直接恢复，无需扫描数据。采用版本化布局，打开时按版本解析（向后兼容读取 v1–v7）：
  - v1：header + 稀疏索引条目；v2：+ Bloom 过滤器；v3：+ 时间跨度（`min_ts`/`max_ts`/`time_known`）
  - v4：+ 整段数据 CRC32（`data_crc`/`crc_known`，仅已 roll 段）；v5：+ 压缩标志与原始大小（`compressed`/`raw_size`）
  - v6：+ 时间有序标志（`ts_sorted`）；v7：+ 压缩算法（`comp_algo`：0 无 / 1 RLE / 2 LZSS）
- 每个段旁挂 `<name>.log.keys`：保存该段 key → 最新 offset（含 tombstone 标志）索引（含 CRC32），重开时直接加载；缺失或损坏则回退重建扫描。
- 目录级 `MANIFEST`：记录 `roll_size`、`next_offset` 与段清单（每段的 `base_offset` 与 `byte_size`，整体附 CRC32）。打开时据此校验每个段文件的真实大小，不符则回退全量恢复。
- `open_log_dir` 优先使用上述元数据（快速路径）；缺失或校验失败时回退到 `recover_log_dir` 全量恢复。
- 元数据（`MANIFEST` 与每段 `.index`）以**原子替换**落盘：写入 `<name>.tmp` → fsync → `rename` 覆盖 → fsync 目录。进程在任意时刻崩溃只会留下旧版或新版，不会出现半写文件。

### 目录锁与游标文件（M12）

- `LOCK`：`flock` 建议锁的载体。写者取独占锁，读者取共享锁；`DirLock::acquire_timeout` 在有限时间内重试忙锁（CLI 默认 5s，可用 `MOONLOG_LOCK_TIMEOUT` 调整），使多写者排队而非立即失败；`compact` 会保留该文件。
- `CURSOR` / `CURSOR.<name>`：CLI 持久化的（命名）消费游标位置。编码为 `u32 magic("MLCU") + u64 position + u32 crc32`，损坏或缺失时回退为 `0`；写入采用原子替换。

### 游标与段回收语义（M72）

- `prune-superseded` / `prune-bytes` / `prune-before` / `prune-expired` / `maintain` 会自动枚举目录下全部游标（`CURSOR` 与 `CURSOR.*`），**跳过仍含未消费记录的段**（段尾 offset 大于最小游标位置），消费者不会因回收而丢失未读数据；游标文件损坏时按位置 0 保守处理（保护全部段）。
- `compact` / `compact-expired` / `import` 会**重排 offset**：执行后所有游标位置失效，命令会输出警告——请用 `cursor-commit 0`（或 `cursor-save <name> 0`）重置游标后重新消费。
- `merge` 不删除任何记录（offset 保留），游标位置在合并后依然有效。

## 里程碑

- M0/M1 脚手架、记录编码与内存后端、单段 append
- M2 多段 `Log` 与 native 文件后端
- M3 稀疏索引与范围扫描
- M4 崩溃恢复（torn-tail 截断）
- M5 tombstone、保留策略、消费游标
- M6 CLI 与文档
- M7 边界测试与显式 CLI 参数校验
- M8 段索引与目录 manifest 持久化（打开免全量扫描）
- M9 流式段读取与 `for_each`（收敛 IO）
- M10 key 索引、快照与 `compact`
- M11 可配置 durability（`SyncPolicy`）与按字节保留
- M12 `flock` 目录锁、读快照与 CLI 游标持久化
- M13 property/fuzz 恢复测试、`moon bench`、CI 与 API/CHANGELOG 文档
- M14 compaction 提升为 `Log::compact` 库方法
- M15 按时间戳保留（`Log::retain_before` 与 `prune-before`）
- M16 manifest 记录段字节大小并在打开时校验
- M17 `examples/mem_demo` 可运行示例（wasm/js/native）
- M18 批量写入 `Log::append_batch` 与 CLI `put-batch`
- M19 完整性校验 `Log::verify` 与 CLI `fsck`
- M20 命名消费者游标（`cursor-save` / `cursor-load`）
- M21 元数据原子写（tmp + fsync + rename + fsync 目录）
- M22 组提交：`SyncPolicy::Batch` 与 `Log::flush`（批量写只 fsync 一次）
- M23 创建/删除加固：新建段与删除段后 fsync 目录，游标原子写
- M26 记录级 TTL：`Log::get_latest_at` / `Log::scan_live` 与 CLI `getkey-live` / `prune-expired`
- M27 命名游标管理：`list_named_cursors` / `remove_named_cursor` 与 CLI `cursor-list` / `cursor-drop`
- M28 导出/导入：`Log::export_bytes` / `Log::import_bytes` 与 CLI `export` / `import`
- M24 自适应稀疏索引间隔：`index_interval_for` 按 `roll_size` 估算
- M25 读取路径：实测读缓存比直接 pread 慢约 3.7×，故保留直接 `pread`；新增 native 顺序扫描基准
- M29 CI 增强：native 覆盖率摘要 + bench 结果归档
- M30 架构文档与发布工作流（release 触发 `moon publish`）
- M31 审阅修复：`Log::flush` 刷所有段、`import_bytes` 批量落盘、CLI 支持 `MOONLOG_SYNC=batch`
- M32 审阅修复：CLI 默认 `MOONLOG_SYNC=always`（命令返回即落盘），并明确 `import` 的 offset 语义
- M33 key 前缀扫描：`Log::scan_prefix` 与 CLI `scan-prefix`（结果按 key 排序）
- M34 段级 Bloom 过滤：`BloomFilter` 持久化进 `.index`（meta v2），`Log::get_latest_bloom` 跳过不可能含 key 的段；CLI `has-key`
- M35 时间范围查询：段级 min/max timestamp 持久化进 `.index`（meta v3），`Log::scan_time_range` 跳过无重叠段；CLI `scan-time`
- M36 key 区间扫描：`Log::scan_key_range` 按 `[lo, hi)` 返回每个 live key 的最新记录（按 key 排序，空 `hi` 表示无上界）；CLI `scan-range`
- M37 二进制安全 key 索引：`KeyIndex` 改以 key 原始字节为键（此前用有损 `utf8.decode_lossy`，非法 UTF-8 的不同 key 会塌缩冲突），`scan_prefix` 改按原始字节匹配；新增回归测试
- M38 段数据校验和：已 roll 段在 `.index` 记录整段数据 CRC32（meta v4，旧版本读为未校验）；`Log::verify` 报告首个校验和不符的段（`VerifyReport::first_bad_checksum`）
- M39 有序 key 索引：`KeyIndex` 维护按字节排序的 live key 列表，`scan_prefix` / `scan_key_range` 改为二分定位 + 点查（不再全量扫段 + 排序）
- M40 多键批量点查：`Log::get_many` 一次返回多个 key 的最新 live 记录（共享一次索引扫描）；CLI `get-many`
- M41 逆序扫描与 tail：`Log::scan_reverse` 按 offset 降序返回区间记录，`Log::tail` 返回最近 n 条（按 append 顺序）；CLI `tail`
- M42 缓冲写合并：`NativeFileLog` 把小追加合并成更少的 `pwrite`；读取 / flush / truncate / close 与写元数据前先 drain，写命令返回时文件大小与逻辑大小一致
- M43 段压缩：纯 MoonBit RLE（`core.rle_compress` / `core.rle_decompress`）；CLI `compress` 原地压缩所有已 roll 段（meta v5 记录压缩标志与原始大小），打开时透明解压为只读视图，旧版本 meta 读为未压缩
- M44 原子批量写入：`Log::append_batch_atomic` 失败时整体回滚（删除批中新建段、截断并重建原活跃段、恢复 offset 空间）
- M45 可观测性：`Log::segment_summaries` 暴露每段计数 / 大小 / 压缩标志 / 时间跨度；CLI `stats` 打印逐段信息并支持 `stats <dir> json`
- M47 持久化 key 索引：每段内存维护 key→最新 offset（含 tombstone 标志），`flush_meta` 写入 `.keys` sidecar；重开直接加载（缺失/损坏回退重建扫描），`build_key_index` 不再全量扫段
- M48 表驱动 CRC32：`crc32` 改为加载时构建 256 项查表，替代逐位计算
- M49 段内时间索引：段记录 timestamp 是否非递减（meta v6 持久化）；`scan_time_range` 对有序段二分定位 `[lo, hi)` 的 offset 窗口，无序段回退线性过滤
- M50 段压缩增强：新增纯 MoonBit LZSS（`core.lz_compress` / `lz_decompress`，4 KiB 窗口）与 RLE 并存；CLI `compress <dir> [rle|lzss]` 可选算法（默认 lzss），meta v7 记录算法以正确解压
- M51 冗余段回收：`Log::prune_superseded` 删除所有记录均被后续覆盖（同 key 更新 / tombstone）的已 roll 段，回收空间且不重排 offset；CLI `prune-superseded`
- M52 并发写锁超时：`DirLock::acquire_timeout` 在超时前重试忙锁（新增 `nanosleep` stub），多写者排队而非立即失败；CLI 等待上限由 `MOONLOG_LOCK_TIMEOUT` 控制（默认 5000ms）
- M53 CLI dry-run 与批量 key：`compress` / `prune-superseded` 支持 `dry-run`（经 `count_compressible_segments` / `Log::count_superseded` 只读报告）；`get-many` 支持 `--keys <file>` 按行读取 key
- M54 复杂度回归保护：`CountReader` 测试断言 `build_key_index` 不读记录体（锁定 M47 带来的 O(keys) 开销）
- M55 文档与 native 示例：新增 `examples/native_demo`（文件后端端到端演示）；README 补齐本轮（M47–M54）能力说明
- M56 旧格式兼容性测试：构造 v1–v7 各历史版本的段元数据字节，断言当前解码器均可正确读取（锁定向后兼容）
- M57 崩溃一致性测试：损坏 `.index`、删除 `MANIFEST` / `.index` / `.keys` 后，断言 `open_log_dir` 仍能从段数据恢复记录并重建 key 索引
- M58 段合并：`Log::merge_segments` 将 offset 连续的已 roll 段合并为更少的段（保留逻辑 offset）；CLI `merge <dir> <max-segments>`
- M59 key 索引缓存：`Log::build_key_index` 记忆化结果并在任意变更（append/delete/保留/回收/合并/compact）后失效，同进程重复 KV 查询每次变更后最多重建一次；`Log::index_build_count` 暴露实际构建次数
- M60 复杂度基线扩展：断言 `scan_range` 只读请求窗口、`scan_time_range` 跳过无重叠段（补充 M54 的 key 索引基线）
- M62 property 测试：固定 seed 的随机 append/delete/读校验序列对照内存模型（强制跨段滚动），结尾全量 `verify`
- M63 TTL 空间回收闭环：`Log::compact_expired(now, ttl)` 在折叠 live 时同时丢弃已过期记录与对应 tombstone（offset 重排，同 compact）；CLI `compact-expired <dir> <ttl>`
- M64 条件写入 CAS：`Log::compare_and_swap(key, expected, value, ts)` 仅当 live 值匹配期望（或要求 key 不存在）才追加；CLI `put-if`
- M65 sidecar 写放大优化：段级 `meta_dirty` 标志，`flush_meta` 只重写有变更段（新 roll / checksum / 压缩）的 `.index`/`.keys`，干净已 roll 段跳过
- M66 发布 0.5.0：property 测试、TTL 折叠、CAS、sidecar 写放大优化随包发布
- M67 native property 测试：文件后端随机操作 + 周期性注入 torn tail（fsync 后截断最后段数据文件），模型按存活记录数重建
- M68 live 折叠点查化：`snapshot` / `scan_live` 经 key 索引逐 key 点查（按 offset 排序保持输出顺序），替代二次全量扫描
- M69 段内 ts 采样索引：`Segment` 维护与稀疏索引同步的内存 ts 采样（append/rebuild 填充），`lower_bound_ts` 先对采样二分（零 I/O）再至多走一个采样区间；无采样的新打开段回退点探二分
- M70 一键维护：CLI `maintain <dir> <max-segments> [ttl]` 聚合段合并 + 冗余段回收 + 过期折叠（可选）+ fsck 报告
- M71 发布 0.6.0：native property 测试（含 torn tail 注入）、live 折叠点查化、ts 采样索引、maintain 命令随包发布

## 许可

Apache-2.0