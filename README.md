# moonbitLog-StructuredDB

用 [MoonBit](https://www.moonbitlang.com/) 从零构建的 **Append-Only Event Log** 日志数据库：只追加、offset 单调、可持久化、可重放；删除以 tombstone 表达而非原地改写。

## 特性

- **只追加日志**：记录一旦写入不再修改，逻辑 offset 全局单调递增。
- **双后端**：内存后端（`backend_mem`，可在 wasm/js 运行）+ native 文件后端（`backend_native`，基于 C stub FFI 的真实文件持久化），通过 `io` 抽象隔离核心引擎。
- **多段管理**：`Log` 按 `roll_size` 滚动切段，段一旦 roll 不再修改。
- **稀疏索引**：每段内嵌按固定间隔采样的稀疏索引，`get(offset)` 与范围扫描先定位再顺序前进，避免全段扫描。
- **范围扫描**：`Segment::scan_range` / `Log::scan_range` 支持半开区间 `[from, to)`。
- **崩溃恢复**：`Segment::recover` 顺序解码、遇 torn/CRC 失败的尾部即截断到最后一个完好边界并重建索引与计数；native 侧 `recover_log_dir` 打开目录恢复全部 `*.log` 段。
- **Tombstone**：`Log::delete` 追加删除标记记录，历史不被改写。
- **保留策略**：`Log::drop_before` / `Log::retain_last` / `Log::retain_max_bytes`（按 offset / 段数 / 总字节）以整段删除方式回收旧数据。
- **可配置持久化**：`SyncPolicy::Always` 让每次 append 后 `fsync`；CLI 用 `MOONLOG_SYNC=1` 开启。
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
```

## CLI 用法

构建后可执行位于 `_build/native/debug/build/src/cli/cli.exe`：

```
moonlog <command> <dir> [args...]

  put <dir> <key> <value>       追加一条 key/value 记录
  delete <dir> <key>            追加 key 的 tombstone
  get <dir> <offset>            按 offset 读取记录
  scan <dir> [from] [to]        列出 [from, to) 区间记录
  recover <dir>                 打开并恢复，报告计数
  prune <dir> <keep-segments>   只保留最新 N 个段
  prune-bytes <dir> <bytes>     回收最旧段直到总字节 <= bytes
  cursor <dir> <start|-> <limit>  按批读取消费游标（`-` 从持久化位置续读）
  cursor-commit <dir> <position> 持久化消费游标位置
  getkey <dir> <key>            查询 key 的最新值（tombstone 生效）
  compact <dir>                 折叠为 live 记录并重写目录
  stats <dir>                   打印记录/段计数
```

示例：

```bash
EXE=_build/native/debug/build/src/cli/cli.exe
$EXE put /tmp/log user:1 alice
$EXE put /tmp/log user:2 bob
$EXE delete /tmp/log user:2
$EXE scan /tmp/log
```

## API 概览

| 类型 / 函数 | 包 | 用途 |
| --- | --- | --- |
| `Log::new` / `Log::recover` | `log` | 建立多段日志 / 从已有段恢复 |
| `Log::append` / `Log::delete` | `log` | 追加记录 / tombstone，返回全局 offset |
| `Log::get` / `scan` / `scan_range` / `for_each` | `log` | 点查 / 全扫 / 区间扫描 / 流式遍历 |
| `Log::retain_last` / `retain_max_bytes` / `drop_before` | `log` | 段级保留策略 |
| `Log::build_key_index` / `get_latest` / `snapshot` | `log` | KV 逻辑视图 / 折叠为 live 记录 |
| `ConsumerCursor::new` / `poll` / `seek` | `log` | 按批消费、提交与回退读位置 |
| `SyncPolicy` | `log` | `Never` / `Always` 持久化策略 |
| `Manifest::encode` / `decode_manifest` | `log` | 目录级元数据编解码 |
| `Segment` / `SparseIndex` | `segment` | 单段读写、稀疏索引、崩溃恢复 |
| `MemLog` | `backend_mem` | 内存后端（wasm / js 可用） |
| `NativeFileLog` / `open_log_dir` / `flush_meta` / `DirLock` | `backend_native` | 文件后端、打开快路径、目录锁 |
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

- 每个段旁挂 `<name>.log.index`：保存该段计数与稀疏索引快照（含 CRC32），重开时可直接恢复，无需扫描数据。
- 目录级 `MANIFEST`：记录 `roll_size`、`next_offset` 与段清单（含 CRC32）。
- `open_log_dir` 优先使用上述元数据（快速路径）；缺失或校验失败时回退到 `recover_log_dir` 全量恢复。

### 目录锁与游标文件（M12）

- `LOCK`：`flock` 建议锁的载体。写者取独占锁，读者取共享锁，均以非阻塞方式获取，冲突即快速失败而非死等；`compact` 会保留该文件。
- `CURSOR`：CLI 持久化的消费游标位置。编码为 `u32 magic("MLCU") + u64 position + u32 crc32`，损坏或缺失时回退为 `0`。

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

## 许可

Apache-2.0