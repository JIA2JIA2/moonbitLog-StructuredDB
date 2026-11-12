# moonbitLog-StructuredDB

用 [MoonBit](https://www.moonbitlang.com/) 从零构建的 **Append-Only Event Log** 日志数据库：只追加、offset 单调、可持久化、可重放；删除以 tombstone 表达而非原地改写。

内存后端（`backend_mem`）可在 wasm/js 运行，native 文件后端（`backend_native`，C stub FFI）提供真实持久化；同一套 `log`/`segment` 逻辑通过 `io` 抽象运行在两种后端之上。

## 特性

### 存储引擎

- **只追加多段日志**：记录写入后不再修改，逻辑 offset 全局单调递增；`Log` 按 `roll_size` 滚动切段，已 roll 段不可变。
- **稀疏索引**：每段内嵌按间隔采样的稀疏索引（间隔随 `roll_size` 自适应），点查与范围扫描先定位再顺序前进。
- **崩溃恢复**：顺序解码，遇到 torn/CRC 失败的尾部即截断到最后一个完好边界并重建索引与计数；`recover_log_dir` 可恢复整个目录。
- **Tombstone 与保留策略**：`Log::delete` 追加删除标记；`drop_before`/`retain_last`/`retain_max_bytes`/`retain_before` 以整段回收旧数据。
- **持久化策略**：`SyncPolicy` 支持 `Never`/`Always`/`Batch`；单条命令默认 `Always`（返回即已 fsync），批量入口（put-batch/ingest/http）每批一次 fsync；`MOONLOG_SYNC` 可覆盖。
- **消费游标**：`ConsumerCursor` 保存已提交读位置，按批 `poll`、可续读，支持持久化到 `CURSOR`/`CURSOR.<name>`。
- **KV 逻辑视图与 compaction**：`KeyIndex` 增量维护 key→最新值，`Log::snapshot` 折叠 live 记录，`compact` 重写目录。
- **并发安全**：native 后端基于 `flock` 目录锁（写者独占 / 读者共享），CLI 写入与 `compact`/`prune` 互斥，读者总是看到一致的 offset 快照。
- **流式遍历**：`for_each`/`for_each_while`/`for_each_time_range` 零物化遍历，大结果集不占内存。

### 采集与接入（1.x）

- **`ingest` 采集**：`lines`/`kv`/`json`/`template` 四种解析，字段可提升为记录键；位点持久化为命名游标，支持断点续采与截断/轮转自动重采。
- **多源接入**：本地 agent（`ingest --follow`）、离线批量（`--once`）、HTTP 推送（`http` 网关：`/`、`/push`、`/health`、`/stats`）、消息队列（`ingest --fifo`）。
- **缓冲与背压**：HTTP 入站有界队列，入队返回 202、满返回 429 + Retry-After；积压告警 `WARN/RESOLVED`（阈值随队列容量缩放）；SIGTERM 退出前全量 drain。
- **吞吐**：`append_batch` + `SyncPolicy::Batch` + `--batch` 分批；`bench-write` 两阶段校验无丢失，QPS 只计写入路径、最终 flush 单列。
- **幂等与重放**：`--idempotent` 内容等值去重；`--dedup-id`/`--dedup-field` 显式唯一 ID；`X-Batch-Id`/`--batch-id` 整批去重。状态存于 `DEDUP`/`BATCHES`，随备份迁移，删除 sidecar 可从 `__uid=` 内嵌重建。
- **源头采样**：`--min-level`、`--sample-rate`（FNV-1a 确定性）、`--include`/`--exclude`；采样在入站执行一次，`/stats` 的 `sampling` 块可对账。

### 解析与规范化（2.x）

- **结构化解析**：`--format json` 递归展平嵌套对象为点号字段；`--template` 为受限 Grok 子集（零依赖、无回溯）；`parse-check` 离线校验并输出准确率。
- **统一 Schema**：`--schema` 将字段归一到时间戳/级别/服务名/主机/trace_id/消息六类，服务名提升为记录键，字段名做大小写与分隔符归一。
- **时间规范化**：数字按位数识别精度，ISO-8601 支持日期、`T`/空格、可选秒、`.`/`,` 小数秒、`Z`/`±HH:MM`/`±HHMM`/`UTC` 等时区；`--clock-skew`/`--clock-skew-field` 补偿采集端漂移；`query --sort-by-time` 按事件时间排序。
- **脱敏与富化**：`--mask` 在写入前掩码敏感字段名与已知令牌（`sk-`/`AKIA`/`ghp_`/`xox?-`）、Bearer/JWT、手机号、证件号、卡号、长 hex；`--meta` 追加部署元数据。

### 存储治理（3.x）

- **时间分区**：`--partition day|hour|off` 按时间桶自动滚动建段；`partition-policy` 持久化到 `<dir>/PARTITION`，写命令自动沿用。
- **倒排 + 字段列索引**：段级 `.inv` sidecar（懒构建、原子落盘、CRC 校验），支持词级倒排、字段等值/范围 posting、中文 unigram；sidecar v5 使用 front coding + delta varint 压缩。
- **段数据压缩**：`compress` 对已 roll 段做 LZSS/RLE，`stats` 报告实际磁盘占用（跟随冷层链接）。
- **生命周期 TTL**：`<dir>/TTL` 支持 `default`/`service`/`level`/`prefix` 规则；`ttl-expire` 整段回收并写 `TTL_AUDIT`（含链式完整性校验）。
- **副本与高可用**：`replicate --follow` 增量镜像；`HA_STATE` 记录角色，`ha-failover`/`ha-watch`/`ha-rebalance` 支持受监督的自动切换；拒绝以 primary 为目标的正向同步，防 failover 后误删副本写入。
- **热温冷分层与归档**：`tier` 将段原地 LZSS（温）或迁入独立冷目录并以 symlink 占位（冷）；`tier-policy` 持久化，`maintain` 自动降冷；`archive` 打包 MLAR 单文件（含审计），可 `--list`/`--extract`。

### 检索（4.x）

- **`scan` 族**：offset 区间、key 前缀、key 半开区间、时间区间。
- **`search`**：key/value 子串、`--wildcard`（`*`/`?`）、`--ignore-case`、`--inverted` 词级倒排；短语与 CJK 查询自适应走精确线性路径以避免假阳性。
- **`query`**：`--level`/`--service`/`--host`/`--trace-id`/`--contains`/`--where` AND 组合 + 时间窗 + `--limit`/`--json`；`--level-min`/`--level-max` 范围过滤；时间界经段级 `min_ts`/`max_ts` 下推，`--indexed` 将全部等值/范围条件下推并取最短 posting，`--explain` 可审计下推。
- **强制时间窗**：`query`/`search`/`scan` 族/`export-jsonl` 无 `--since` 时降级为最近 24h（`MOONLOG_QUERY_WINDOW_MS` 可调），`--require-time` 时拒绝，`--since 0` 显式全表。
- **`context`**：按 `--trace-id`/`--thread-id`（均支持 `auto`）/`--service` 关联同请求上下文，支持 `--sort-by-time`。
- **`follow`**：live tail（200ms 轮询可调），支持游标续读、`--commit`、`--json`、`--match`/`--level-min`/`--service` 过滤，SIGTERM 输出终态统计。
- **查询保护**：`QueryGuard` 四重防线——执行超时、扫描预算、结果上限、快照读 + `QLOCK` 并发槽；扫描不阻塞写入。

### 分析与告警（5.x）

- **`aggregate`**：key/value/kind/时间/键前缀/字段多维聚合 + `--quantile`（p50/p95/p99）。
- **`trend`/`dashboard`**：UTC 分桶直方图；值班面板含错误率、延迟分位数、维度切换（service/level/host/key）、峰值标注与可直接复制的 `--since/--until` 下钻。
- **`cluster`**：数字/十六进制/引号串/`key=value` 归一为模板后聚类，跨语言堆栈归并，JSON message/level 感知，`--min-count` 过滤长尾。
- **`anomalies`**：零规则自动检测 VOLUME_SPIKE / NEW_PATTERN / SEASONAL_DEVIATION / PATTERN_SPIKE（时长归一）。
- **`alert`/`baseline`/`watch`**：阈值告警、z-score 基线、滑动窗口持续监控（firing/resolved 去抖、`--metric-stat avg|max|p95`、`--buffer-max`）。
- **通知分发**：stdout / `--notify-file` / `--webhook` / `--dingtalk` / `--wecom` / `--email`+`--smtp-url`；`--snooze-until` 抑制、`--escalate-sec` 升级、`--re-alert-sec` 持续重提醒；curl `-f` 真实判定 HTTP 失败，`--notify-dry-run` 零真实投递。

### 运维与治理（6.x）

- **RBAC 与多租户**：`<dir>/RBAC`（`role`/`token`/`allow`/`scope`）控制命令级与数据级访问；scope 覆盖写、单键读、范围查询与分析过滤，整库/维护操作要求 unscoped；HTTP 按 Bearer scope 逐 key 预检（越权 403）。无 RBAC 文件时保持开放。
- **配额**：`<dir>/QUOTA` 四维（write-bytes/storage-bytes/query-concurrent/retain-days），租户=RBAC 角色，写入量滚动窗口持久化不因重启重置，超限显式拒绝或 429。
- **操作审计**：`AUDIT` JSONL 留痕（ts/actor/action/decision/target）四类命令执行前记录，越权/配额拒绝记 deny；`audit` 支持查询、`--verify`、`--rotate`；每行 `prev` CRC32 链式完整性，删行/改行可被抓出；达到阈值自动轮转。
- **自监控**：`selfmon` 独立巡检磁盘水位、写入积压、采集延迟、采集停滞、查询失败率，输出 `STATUS=ok|warn|crit`、`--exit-code 0|1|2`、`--json` 全字段；阈值可用 `SELFMON/thresholds` 持久化。
- **备份与恢复**：`backup`/`restore` 全量携带段、sidecar、MANIFEST、RBAC/TTL/QUOTA/PARTITION、`SELFMON/thresholds` 与审计文件，支持增量；`restore` 有完整性门禁；`drill` 一键演练（data/index/config/audit/idempotency 全对账）。
- **归档导出与合规删除**：`export-jsonl` 支持结构化过滤导出（`text|base64`，`--json` 机读报告）；`purge` 先导出留存副本 → tombstone → compact → 验证 0 残留，全库空前缀需 `--all`。
- **维护工具**：`fsck`（fast 段级 CRC / 全量解码，`--fix` 隔离 `.corrupt` 并截断 torn tail）、`maintain`、`serve`、`merge`/`prune-*`/`compact*`/`recover`、`stats`/`partitions`、`tier-policy`/`schema-policy`。
- **工程化**：property/fuzz 随机截断与损坏恢复测试、`moon bench` 基准、GitHub Actions CI（工具链、`fmt --check`、`.mbti` 快照、bench 阈值四重门禁）。

## 包结构

| 包 | 职责 |
| --- | --- |
| `src/core` | 记录编解码（含 CRC32）、`Record` / `RecordKind`、解析/规范化/采样/脱敏 |
| `src/io` | 存储抽象：`LogWriter` / `LogReader` / `LogTruncate` 与 `IoError` |
| `src/segment` | 单段 append、稀疏索引、范围扫描、恢复、倒排索引 |
| `src/log` | 多段管理、tombstone、保留策略、消费游标、KV 视图、compaction |
| `src/backend_mem` | 内存后端（wasm/js 可用） |
| `src/backend_native` | native 文件后端（C stub FFI、flock、备份/恢复/修复） |
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

> 仓库禁用 `derive`，且裸 `moon build` 只构建 wasm（`preferred_target = "wasm"`）；改 CLI 后需 `moon build --target native`。

## CLI 用法

构建后可执行位于 `_build/native/debug/build/src/cli/cli.exe`。所有命令的第一个参数为日志目录，无参运行打印完整帮助：

```
moonlog <command> <dir> [args...]
moonlog version | --version
```

**写入与读取**

```
put <dir> <key> <value> [--ts ms] [--idempotent] [--dedup-id id] [--partition day|hour]
put-if <dir> <key> <expected|-> <value>
put-batch <dir> [--batch-id id] <k> <v>...
delete <dir> <key>
get <dir> <offset>            getkey <dir> <key>         getkey-live <dir> <key>
has-key <dir> <key>           get-many <dir> <key>...
scan <dir> [from] [to]        scan-prefix <dir> <prefix>
scan-range <dir> <lo> [hi]    scan-time <dir> <lo> <hi>
```

**采集与接入**

```
ingest <dir> <file> [--format lines|kv|json|template] [--follow|--once|--fifo]
       [--template ...] [--schema] [--min-level ...] [--sample-rate 0-100]
       [--include ...] [--exclude ...] [--mask] [--meta ...] [--dedup-field ...]
http <dir> [--port N] [--batch N] [--queue N] [--queue-bytes N] [--backlog-alert N]
parse-check <file> [--format ...] [--template ...] [--schema] [--json]
bench-write <dir> <count> [--batch N] [--sync never|always|batch] [--warmup N]
```

**检索与分析**

```
search <dir> <text> [--inverted] [--wildcard] [--ignore-case] [--field key|value|both]
       [--since ts] [--until ts] [--limit N] [--json]
query <dir> [--level ...] [--level-min ...] [--level-max ...] [--service ...] [--host ...]
      [--trace-id ...] [--contains ...] [--where name=value] [--indexed] [--explain]
      [--since ts] [--until ts] [--require-time] [--sort-by-time] [--limit N] [--json]
context <dir> <offset> <before> <after> [--trace-id ...|auto] [--thread-id ...|auto]
        [--service ...] [--sort-by-time]
tail <dir> <n> [--json]            follow <dir> [start|-|tail] [--once] [--commit] ...
aggregate <dir> [--by key|value|kind|time|prefix] [--kv-field ...] [--quantile ...]
          [--top N] [--json]
trend <dir> [--unit minute|hour|day] [--json]
cluster <dir> [--stacks] [--min-count N] [--json]
dashboard <dir> [--last sec|--since ts --until ts] [--by service|level|host|key]
anomalies <dir> [--since ts --until ts] [--service ...] [--json]
alert <dir> ...        baseline <dir> ...        watch <dir> <match-text> [--threshold N] ...
```

**治理与运维**

```
rbac <dir> init <token> | add <name> <token> <allow> [scope=<prefix>]
          | list | remove <name> | check <command> [key]
quota <dir> [--json] [--recalc]
audit <dir> [--actor ...] [--action ...] [--verify] [--rotate --keep N] [--json]
ttl-expire <dir> [--dry-run] [--json]
ttl-audit <dir> [--since ts] [--until ts] [--limit N] [--json] [--verify]
selfmon <dir> [--json] [--exit-code]             fsck <dir> [fast] [--fix]
maintain <dir> <max-segments> [ttl]              serve <dir> ...
merge <dir> <max-segments>                       compact <dir>
prune <dir> <keep-segments>                      prune-bytes <dir> <bytes>
prune-before <dir> <ts>                          prune-expired <dir> <ttl>
prune-superseded <dir>                           recover <dir>
compress <dir>                                   stats <dir> [--json]
partitions <dir> [--unit day|hour] [--json]
partition-policy <dir> [day|hour|off]            schema-policy <dir> [on|off] [--json]
tier <dir> <cold-dir> [--warm N] [--dry-run]     tier-policy <dir> [--warm N]
archive <dir> <file> [--list] [--extract --into <dir>]
backup <src> <dst>                               restore <src> <dst>
drill <dir> [--keep]                             replicate <src> <dst> [--follow]
ha-failover <primary> <replica> [--active <link>]
ha-status <primary> [replica] [--json]           ha-rebalance <old> <new> [--json]
ha-watch <primary> <replica> --active <link> ...
export <dir> <file>                              export-jsonl <dir> <file> [--prefix ...] [--json]
import <dir> <file>                              purge <dir> <prefix> [--into <file>] [--all] [--json]
cursor <dir> <start|-> <limit>                   cursor-commit <dir> <position>
cursor-lag <dir>                                 cursor-save <dir> <name> <pos>
cursor-load <dir> <name>                         cursor-list <dir>
cursor-drop <dir> <name>
```

**示例**

```bash
D=./data
moonlog put $D user:1 alice
moonlog put $D user:2 bob --idempotent
moonlog scan $D
moonlog query $D --level error --since 0 --json
moonlog follow $D tail --level-min warn
moonlog aggregate $D --by key
moonlog dashboard $D --last 3600
moonlog backup $D ./bak && moonlog drill $D
```

## API 概览

| 类型 / 函数 | 包 | 用途 |
| --- | --- | --- |
| `Log::new` / `Log::recover` | `log` | 建立多段日志 / 从已有段恢复 |
| `Log::append` / `append_batch` / `append_batch_atomic` / `Log::delete` | `log` | 追加单条 / 批量 / 原子批量 / tombstone |
| `Log::get` / `scan` / `scan_range` / `scan_reverse` / `scan_time_range` / `tail` / `for_each` | `log` | 点查 / 全扫 / offset 与时间区间 / 最近 N 条 / 流式遍历 |
| `Log::retain_last` / `retain_max_bytes` / `retain_before` / `drop_before` | `log` | 段级保留策略 |
| `Log::build_key_index` / `get_latest` / `get_latest_at` / `get_latest_bloom` / `get_many` / `scan_prefix` / `scan_key_range` / `snapshot` / `compact` | `log` | KV 逻辑视图与 compaction |
| `Log::export_bytes` / `import_bytes` | `log` | 记录流导出 / 回放 |
| `ConsumerCursor::new` / `poll` / `seek` | `log` | 按批消费、提交与回退读位置 |
| `SyncPolicy` / `Log::flush` | `log` | `Never` / `Always` / `Batch` 与显式 fsync |
| `Log::verify` / `VerifyReport` / `Log::segment_summaries` | `log` | 全日志校验 / 逐段统计 |
| `Segment` / `SparseIndex` | `segment` | 单段读写、稀疏索引、崩溃恢复 |
| `MemLog` | `backend_mem` | 内存后端（wasm / js 可用） |
| `NativeFileLog` / `open_log_dir` / `DirLock` | `backend_native` | 文件后端、打开快路径、目录锁 |
| `backup_log_dir` / `restore_log_dir` / `repair_log_dir` | `backend_native` | 物理备份与增量 / 恢复 / 修复 |
| `rle_compress` / `rle_decompress` / `crc32` / `Record` | `core` | 压缩、校验与记录编解码 |
| `LogWriter` / `LogReader` / `LogTruncate` / `IoError` | `io` | 存储抽象 |

## 在 wasm / JS 中使用

内存后端不依赖 native FFI，可直接在 wasm/js 目标构建运行（`moon test` 即在该目标下执行）：

```moonbit
let store = @backend_mem.MemLog::new()
let log : @log.Log[@backend_mem.MemLog, @backend_mem.MemLog] = @log.Log::new(
  1_048_576,
  base => @segment.Segment::new(store, store, base),
)
ignore(log.append(b"user:1", b"alice", 0))
let recs = log.scan()
```

需要真实文件持久化时改用 `backend_native`（仅 native 目标），接口一致，业务代码无需改动。

## 可运行示例

```bash
moon run examples/mem_demo --target native      # 追加、tombstone、live 视图、消费游标
moon run examples/mem_demo --target wasm        # 同一示例跑在 wasm
moon run examples/native_demo --target native   # 真实文件：打开目录、追加/删除、key 区间、段统计
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

`io` 抽象让同一份 `log`/`segment` 逻辑同时运行在内存（wasm/js）与文件（native）后端之上；`segment` 负责单段 append、稀疏索引、范围扫描与崩溃恢复，`log` 在其上实现多段管理、全局 offset、保留策略、消费游标、KV 视图与 compaction。

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

段文件名零填充以保证字典序与数值序一致，例如 `0000000000000007.log`。

段与目录的持久化元数据：

- `<name>.log.index`：段计数、稀疏索引快照、key Bloom 过滤器、时间跨度、已 roll 段的 data CRC32/压缩标志/原始大小；格式 v1→v7 递增演进，高版本含 `ts_sorted` 与压缩算法字段。
- `<name>.log.keys`：段内 key → 最新 offset（含 tombstone 标志），含 CRC32，缺失或损坏时回退重建。
- `MANIFEST`：`roll_size`、`next_offset` 与段清单（`base_offset`、`byte_size`），打开时校验段文件真实大小。
- `.inv`：倒排/字段列 sidecar；缺失、损坏或版本不符时自动删除并懒重建。
- `LOCK`：`flock` 目录锁载体；`CURSOR`/`CURSOR.<name>`：`u32 magic("MLCU") + u64 position + u32 crc32`。
- 元数据以原子替换落盘（tmp → fsync → rename → fsync 目录），任意时刻崩溃只会留下旧版或新版。

## 运维要点

- **fd 上限**：每个打开段占 1 个 fd，段数接近 `ulimit -n` 时打开/写入会失败；用 `merge`/`maintain` 合并段，或持久化 `SELFMON/thresholds` 做预警。
- **维护周期**：定期 `maintain <dir> <max-segments> [ttl]`——合并段控制读放大与 fd 占用，回收冗余与过期数据，压缩已 roll 段并构建索引 sidecar。
- **游标语义**：`prune-*` 自动跳过仍含未消费记录的段；`compact`/`compact-expired`/`import` 会重排 offset，执行后需用 `cursor-commit 0` 重置游标；`merge` 保留 offset，游标继续有效。
- **fsck 两档**：日常用 `fsck <dir> fast`（段级 CRC，不解码记录体），事故用 `fsck <dir>`（全量解码，定位记录级损坏），`--fix` 隔离/截断并重建元数据。
- **异地同步**：段文件不可变，是天然增量复制单元——`backup <dir> primary-bak` 后 `rsync -a --delete primary-bak/ 远端:`，备机结构与主目录一致，可直接读或 failover 接管。

开发里程碑与逐轮复核记录见 `git log`（M0–M216）。

## 许可

Apache-2.0