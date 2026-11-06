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
- **物理备份/恢复**：`backup` / `restore` 以独占锁 + 全量 flush 生成一致快照并原样拷贝段文件与元数据，offset 语义保留，恢复后的副本可无缝续写与续读；对已有备份目录重复执行 `backup` 为**增量**拷贝——备份副本比源端段文件新（源端自上次备份未被修改）即跳过，源端已删除的段自动清理，大目录备份成本降为 O(变更)。
- **日志采集**：`ingest` 从外部日志文件采集——批量导入或持续跟踪追加（`--follow`），`lines`/`kv`/`json`/`template` 四种解析（字段提取：指定字段提升为记录键、其余字段重组为值），位点经命名游标持久化可断点续采，截断/轮转自动从头重采。
- **多源接入**（1.1）：四类来源均可入库——**Agent 采集**（`ingest --follow` 本地文件 agent，断点续采/轮转）、**离线批量导入**（`ingest --once`）、**HTTP 推送**（`http` 服务：`POST /`/`/push` 逐行入库 + `/health`/`/stats`；SDK 直接调用 `Log::append`）、**消息队列订阅**（`ingest --fifo` 订阅命名管道，写者推送批次、跨写者持续采集；也兼容 `curl`/`kcat` 等外部桥接写入）。
- **高吞吐写入**（1.2）：append-only 批量写入（`Log::append_batch` 每条自带 timestamp），峰值流量靠 `SyncPolicy::Batch`（批末一次 fsync）与 `--batch N` 分批提交；架构不做逐条随机更新（更新=追加新版本，tombstone 删除）。`bench-write` 现场压测并**两阶段校验无丢失**（写入进程关闭后重开：精确条数 + offset 连续 + verify_fast）：本地参考 1000 条/批约 **8–9 万 records/s**、5000 条/批约 9 万、逐批 fsync 约 600/s；内核批量基准 1000 条/批 **4.3ms（≈23 万 records/s）**，单条路径约 135µs（批量快约 31 倍）。
- **缓冲与背压**（1.3）：下游过载时**缓冲而非丢弃**——HTTP 推送端点用有界入站队列（`--queue` 行数上限）：入队成功返回 **202**（含 pending），队列满返回 **429 + Retry-After** 明确反压（客户端重试，无静默丢数据）；后台按 `--batch` 行分批落库，积压超 `--backlog-alert` 打印 `WARN backlog` 并经 `/stats` 暴露 `pending`/`backlog_alerts`；**SIGTERM/SIGINT 优雅关闭**（新增信号 stub + 200ms 超时 accept 轮询）在退出前清空队列，实测并发超限场景 429 重试后 **1200/1200 条零丢失**。FIFO 订阅侧由内核管道满自动反压写者。
- **幂等与重放**（1.4）：`--idempotent`（`put`/`ingest`/`http`）开启写入侧幂等——待写记录的 (key, value) 与该键最新 live 记录完全一致时**识别为重复投递并跳过**（返回既有 offset），否则正常追加；检查骑乘增量维护的 key 索引（O(1) 热路径）。重放文件（`ingest --from 0`）、HTTP 429 重试、批次重投全部幂等：实测重放 2 行 `2 duplicates skipped` 零新增，非幂等对照翻倍至 4。断点续传（采集位点命名游标）与此互补：位点内不重读、位点外的重复投递靠幂等兜底。
- **源头采样限流**（1.5）：`ingest`/`http` 的采样管线（core `SamplingConfig` + `sampling_allows`，单测覆盖）——**按级别** `--min-level debug|info|warn|error|fatal`（kv `--level-field` 字段的严重度阈值，未知级别不参与过滤）、**按比例** `--sample-rate 0-100`（FNV-1a 确定性哈希，同内容判定恒定、与幂等重放一致）、**按规则** `--include`/`--exclude`（原始行子串，ASCII 忽略大小写）。采样在源头（入队/写入前）执行，`ingest` 输出 `(N sampled out)`、HTTP 202 响应含 `sampled_out`——实测 `--min-level warn` 丢 debug/info、`--sample-rate 50` 采样 99/200、`--sample-rate 0` 全丢。
- **统一 Schema**（2.2）：`ingest`/`http` 的 `--schema` 将解析出的字段归一到**六大基础字段**——时间戳（`ts`/`@timestamp`/`timestamp`/`time`）、级别（`level`/`severity`）、服务名（`service`/`service_name`/`app`/`application`）、主机（`host`/`hostname`）、trace_id（`trace_id`/`traceId`/`trace`）、消息（`message`/`msg`；core `canonical_field` 别名映射，单测覆盖）：**服务名提升为记录键**、标准字段按固定顺序重组为 value（`level=… host=… trace_id=… message=…`）、时间戳取自解析值——不同服务的字段命名习惯入库后口径一致；**联合过滤查询** `query`（`--level`/`--service`/`--host`/`--trace-id`/`--contains` AND 组合 + `--since`/`--until` 时间窗 + `--limit`/`--json`；core `schema_matches` 单测覆盖）——如 `query --trace-id t9` 一次关联多个服务的同一链路；非 schema 记录仍可按 key/contains 过滤，混合目录可查。
- **时间规范化**（2.3）：采集端时间值经 core `normalize_ts` 归一到 epoch 毫秒——纯数字按位数识别精度（秒 <1e11 / 毫秒 <1e14 / 微秒 <1e17 / 纳秒），其余按 ISO-8601 解析（`Z`/`±HH:MM`/`±HHMM` 时区、`T` 或空格分隔、小数秒截断到毫秒；core `parse_iso8601_ms` 正向 days-from-civil 与 `format_utc` 互逆，单测覆盖）——**跨时区（`+08:00`/`Z`/`-05:00`）同事件归一到同一时间戳**；`ingest`/`http` 增加 `--clock-skew <ms>` 补偿采集端时钟偏移；append-only 保留到达序，`query --sort-by-time` 按**事件时间**排序输出（tie 保持 offset 序）——实测三时区乱序到达后输出正确事件序，秒/毫秒/ISO 三种写法归一为同一值。展示层统一 UTC。
- **脱敏与字段富化**（2.4）：`ingest`/`http` 的 `--mask` 在**写入前**对每条 value 做单遍扫描掩码（core `mask_sensitive`，无正则引擎、未命中字节逐个保真）——敏感字段名（`token`/`password`/`secret`/`api_key`/`authorization`/`session`/`cookie` 等内置词表 + `--mask-fields` 自定义，ASCII 忽略大小写）值段整体 `[REDACTED]`；`Bearer <token>`（≥8 字符）与 JWT（`eyJ` 前缀双点）→ `[REDACTED]`；11 位手机号（1[3-9]）保留 3+4（`138****5678`）；15 位/17 位+X 证件号保留前 3 后 4；≥20 位连续 hex（md5/sha1/sha256）→ `[REDACTED]`（UUID 段、纳秒时间戳不误伤）；`--meta env=prod,region=cn-north,version=x` 在写入前为每条记录追加部署元数据（环境/版本/地域富化）。掩码作用于幂等去重之前，重复投递判定一致。实测：手机号/证件号/令牌/长 hex 掩码后 `search` 零明文残留（kv、schema、lines、HTTP 四条路径）。
- **热温冷分层存储**：`tier` 将已 roll 段原地压缩（温层），把更旧的段迁入独立目录并以 symlink 原子占位（冷层）——活跃段恒为热层；读、校验、修复、备份经链接透明工作，段被回收时冷副本联动删除（依赖 POSIX symlink）。
- **按时间分区**（3.1）：`put`/`ingest`/`http` 的 `--partition day|hour` 开启时间分区——append 路径在记录的时间桶（core `time_bucket`，epoch 对齐）与活跃段桶不同时**自动滚动创建新段**，同桶数据聚成段运行（迟到数据开自己的段）；单段大小仍受 `roll_size` 控制，分区+段两层大小可控；`partitions` 命令按 `--unit day|hour` 展示分区视图（每分区段数/记录数/字节/UTC span，可选 JSON）；过期清理沿用整段回收（`prune-before`/`prune-expired`）——分区对齐时即整分区淘汰，清理只触碰被回收的段文件，读者（共享锁）永不被阻塞。实测：put/ingest 跨天自动切段、schema+partition 组合按归一后事件时间分桶、prune 与并发读者互不阻塞。
- **倒排 + 列式索引**（3.2）：段级 `InvIndex`（segment 包）双 posting 列表——**词倒排**（key/value 的 ASCII 词 token，小写折叠，`tokenize` 词法；单 token ≤32 字节、每记录 token 数有上限）与**字段列**（`name=value` 精确对 + `__key__=<key>`），lazy 构建（首次索引查询触发）并持久化为 `<base>.log.inv` sidecar（CRC 校验；`maintain`/`serve` 管线顺带全量构建，sidecar 缺失/损坏时自动重建）；`search --inverted` 词级全文匹配（**词命中语义，不同于线性子串**）、`query --indexed` 用第一个等值过滤（level/service/host/trace_id）经字段列预筛后全条件 AND 精滤（service 经记录 key 并集）。基准对比（2000 条、10% 命中）：线性全扫 2.69ms vs 列索引查询 167ns——关键词与字段组合查询均秒级返回；线性扫描始终为回退路径（未启用/索引缺失零影响）。
- **列式数据压缩**（3.3）：`.inv` sidecar 的 postings 列做 **delta + varint（LEB128）编码**（sidecar v2）——posting 是严格递增的 record index，delta 后多为一字节（vs 定长 4 字节）；500 条密集列实测 sidecar 约 7.6KB（v1 固定布局约 30KB，**约 75% 缩减**），600 条混合负载（稀疏列 delta 大）实测 28.7KB（v1 估算约 41KB，约 30% 缩减）；加载时一次性解码回内存 postings——**查询路径零变化**，索引查询基准 173ns（3.2 基线 167ns，噪声范围内，未明显变慢）；旧 v1 sidecar 被精确版本检查拒绝后 lazy 重建，升级安全；行式数据压缩（段级 RLE/LZSS，压缩比见 `stats`/`compress`）此前已覆盖。
- **生命周期 TTL**（3.4）：`<dir>/TTL` 策略文件——`default <days>` / `service <name> <days>` / `level <level> <days>`（`#` 注释、畸形行**整文件拒绝**）：对每条记录，service 匹配记录键（项目）、level 匹配解析的 level 字段，双命中取更严、无命中用 default（default 缺省且无命中 = 永不过期，days=0 即刻过期）；`ttl-expire [--dry-run]` 评估并**整段回收记录全部到期的段**（段级粒度——混合段等全部到期后回收，配 `--partition day` 让同日/同服务数据聚段；dry-run 只打印计划零副作用），应用运行将清理动作追加 `<dir>/TTL_AUDIT.log` JSONL 审计（ts/segments_dropped/records_expired/policy 原文）；`maintain`/`serve` 管线在策略文件存在时**自动执行**并逐轮审计。实测：service/level/default 三维差异化清理（到期段删除、混合段保留且过期计数入审计）、dry-run 零副作用、畸形策略拒绝、maintain 自动审计追加。
- **副本与高可用**（3.5）：`replicate <src> <dst> [--follow]` 把源日志**增量镜像**为完整副本目录（同 `backup` 引擎：mtime 增量 skip、源端删除传播、sidecar/manifest 恒重拷；副本 offset/游标语义完整保留，可直接读写）——`--follow` 按周期（默认 200ms，`MOONLOG_REPLICATE_INTERVAL`）持续同步；**源目录消失时该轮明确失败而不重建空源**（防 follow 误清副本上的 failover 数据）。高可用语义（**单写者模型**，无自动仲裁）：failover = 客户端把读写切到副本目录（主不可达期间副本 scan/put/search 全部正常），并停掉指向旧主的 replicate 进程；rebalance = 原主恢复后反向 `replicate` 增量追赶（以新主为准，双向收敛）。实测：单轮全量同步、follow 增量追赶、主目录移除后副本读/写/检索正常、反向追赶后主副本逐记录一致。定位：目录级副本 + 手动/脚本化切换，不构成分布式共识（无 leader 选举/自动故障检测）。
- **全文检索：通配符与中文**（4.1）：`search --wildcard`——`*` 匹配任意字节序列、`?` 精确匹配单字节（字节级：中文一字 3 个 UTF-8 字节，可用 `查询??????错误` 类模式或 `*` 跨汉字）、其余字符字面匹配（`--ignore-case` 折叠 ASCII）；**子串语义**（模式包裹 `*` 后做 greedy 回溯匹配，无正则引擎）；与 `--inverted` 互斥（词级倒排 vs 通配子串）。**中文关键词**由线性子串路径天然命中（UTF-8 字节级精确匹配，无需分词——"数据库"精确命中含该词的记录，短语同理），倒排索引面向 ASCII 词（CJK 不产 token，既有定位）。实测：中文关键词（`数据库`/`连接失败`）与英文关键词（线性+倒排回归）均命中；通配符 `data*se`/`*TIMEOUT`（+ignore-case）/`查询*错误`/`查询??????错误` 全语义正确；`--wildcard --inverted` 明确报错。
- **结构化过滤：范围与下推**（4.2）：`query` 新增 `--level-min`/`--level-max`——按严重度有序范围过滤（core `level_rank` 五级 debug<info<warn<error<fatal，与 `--level` 精确可 AND 组合；**范围过滤要求已知 level，未知级别被排除**——与字段列下推语义一致）；**条件下推到存储层**：①时间界 `--since`/`--until` 经段级 `min_ts`/`max_ts` **跳过不相交段**（不解码段数据，线性与 indexed 路径均生效）；②`--indexed` 的下推从单等值扩展为**值列表**——level 范围展开为五级枚举中满足区间的值的字段列 postings 并集（矛盾区间得空候选集即零结果），service/host/trace_id 等值同样走列表形态。实测：`--level-min warn` linear/indexed 一致（3 条）、`--level-min warn --level-max error` 一致（2 条，fatal 排除）、`--level-min warn --service payments --since/--until` 多维组合一致（2 条）、时间窗只覆盖单桶时另一桶被跳过、`--level bogus` 报错。
- **强制时间范围**（4.3）：`query` **禁止无边界全表扫描**——无显式 `--since` 时自动**降级**到默认时间窗（最近 24h，`MOONLOG_QUERY_WINDOW_MS` 可调）并输出 INFO 提示行；`--require-time` 时无 `--since` 的查询被**拒绝**（报错并指引）；`--since 0` 是显式全表（不受降级/拒绝影响）。默认窗经 4.2 的段级时间下推只扫窗口内段（窗外段不解码）——遗忘时间界的查询天然受限。范围决策：聚焦结构化查询主入口 `query`；`search` 的全文线性扫描已有 `--limit`/`--from/--to` 兜底（README 定位）。实测：默认窗命中新记录且旧桶被下推跳过（linear/indexed 一致）、`--since 0` 显式全表 5 条、`--require-time` 拒绝、`MOONLOG_QUERY_WINDOW_MS=3600000` 1h 窗排除 1 天前数据。
- **热温冷分层与归档**（3.6）：分层本体由 `tier` 承载（热=活跃段、温=已 roll 段 LZSS 压缩、冷=旧段迁独立 cold-dir + symlink 原子替换，M105）——cold-dir 可指向任意更廉价存储路径/设备，**跨层查询对用户完全透明**（scan/search/query/aggregate/fsck/backup/prune 经链接无感）；新增 `archive <dir> <file> [--list] [--extract --into <dir>]`——把目录数据文件（MANIFEST + 段 + sidecar）打包为**单一自包含归档文件**（`MLAR` 容器：file 表 + 内容 + 尾部 CRC32），单文件 PUT 即可上传任意对象存储（S3/OSS/OBS），`--extract` 解包到空目录后即可直接打开查询（跨层数据完整）；归档应针对**主目录**（symlink 穿透读取冷段数据），cold-dir 只含段本体不可独立恢复。实测：三桶 90 条 → tier 后热层少 2 段（温层 compressed=true、1 段迁冷）且 scan/aggregate/query 对冷段数据全部正常（透明）；归档 10 文件 9085B → 解包恢复副本 scan 90 条、冷段数据可查；CRC 破坏拒绝。
- **日志检索**：结构化键查询（`get_many`/`get_latest`/`scan_prefix`/`scan_key_range`）；**全文检索** `search`（线性扫描 key/value 子串，支持字段选择、ASCII 忽略大小写、limit、offset 区间）；**上下文关联检索** `context`（按 offset 取前后 N 条，自动 clamp 并跨段）。
- **日志分析**：**多维聚合统计** `aggregate`（key/value/kind/UTC 时间/键前缀/`--kv-field` 字段维度，top-N，可选 JSON）；**错误自动聚类** `cluster`（数字/十六进制/引号串归一化为模板后按形态计数，变量内容自动折叠）；**趋势可视化** `trend`（UTC 分钟/小时/天分桶 + 文本直方图）。
- **告警监控**：**阈值告警** `alert`（按 UTC 窗口计数对比阈值）；**异常基线检测** `baseline`（窗口计数的均值/标准差 z-score，超 sigma 标记异常）；**多渠道通知分发**（stdout / `--notify-file` JSONL 追加 / `--webhook` 经 curl POST 且失败降级不中断）。
- **运维管理与 RBAC**：`rbac` 以 `<dir>/RBAC` 规则文件（`role=<name> token=<token> allow=<cmds|*>`）控制命令访问——文件存在时除 `rbac init`/`rbac check` 外均需 `MOONLOG_TOKEN` 且角色允许该命令，拒绝事件写入 `AUDIT.log`；无 RBAC 文件时保持开放（向后兼容）。定位说明：本地 CLI 的**防误操作与审计**手段，进程可绕过文件，不构成多租户强隔离。
- **修复模式**：`fsck --fix`（`repair_log_dir`）隔离整段校验失败的段（改名 `.corrupt` 保留证据）、截断损坏尾部、重建缺失/损坏的 MANIFEST 与段 sidecar。
- **尾随读**：`follow` 持续打印新追加的记录（`tail -f` 语义），支持从持久化游标续读并 `--commit` 自动提交。
- **自动维护**：`serve` 周期性执行 maintain 管线（段合并 + 冗余回收 + 可选过期折叠）。
- **KV 逻辑视图与 compaction**：`KeyIndex` 提供 key→最新值查询（tombstone 生效），缓存索引随 `append` **增量维护**（put 刷新、tombstone 移除，段集合结构变化才整体失效），写密集点查不再触发全量重建；`Log::snapshot` 生成折叠后的 live 记录，`compact` 命令重写目录。
- **并发安全**：native 后端基于 `flock` 对目录加建议锁（写者独占 / 读者共享），CLI 写入与 `compact`/`prune` 互斥，读者总是观察到一致的偏移快照。
- **工程化**：property/fuzz 随机截断与损坏恢复测试、`moon bench` 基准、GitHub Actions CI（工具链固定 + `fmt --check`/`.mbti` 快照/bench 阈值四重门禁）。
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

  put <dir> <key> <value> [--ts <ms>] [--idempotent] [--partition day|hour]
                                追加一条 key/value 记录（`--partition` 开启
                                按天/小时时间分区，跨桶自动滚动新段）
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
  ttl-expire <dir> [--dry-run]  按 <dir>/TTL 策略做差异化过期清理
                                （default/service/level 规则，天数）；
                                应用运行的清理动作追加到 TTL_AUDIT.log
  merge <dir> <max-segments>    将连续的已 roll 段合并至不超过 N 段
  maintain <dir> <max-segments> [ttl]
                                一键维护：合并 + 冗余回收 + 过期折叠 + 压缩
                                已 roll 段 + 构建倒排/字段列 sidecar
                                （3.2）+ fsck
  cursor <dir> <start|-> <limit>  按批读取消费游标（`-` 从持久化位置续读）
  cursor-commit <dir> <position> 持久化消费游标位置
  cursor-lag <dir>              报告每个消费游标的滞后量（next_offset -
                                position），便于发现停滞的消费者
  cursor-save <dir> <name> <pos> 持久化命名消费游标位置
  cursor-load <dir> <name>      读取命名消费游标位置
  cursor-list <dir>             列出全部命名消费游标位置
  cursor-drop <dir> <name>      删除命名消费游标位置
  follow <dir> [start|-|tail] [--once] [--commit] [--json] [--name <cursor>]
                                持续打印新追加的记录（`-` 从持久化游标续读，
                                `tail` 从当前末尾开始；`--commit` 每批后提交
                                游标，`--name` 指定命名游标以支持多消费者各
                                自 follow/提交；`--json` 以单行 JSON 输出
                                （UTF-8 文本，与 export-jsonl 同构）；`--once`
                                拉取一轮即退出；轮询间隔可用
                                `MOONLOG_FOLLOW_INTERVAL` 调整，默认 200ms）
  ingest <dir> <file> [--follow] [--once] [--fifo]
                    [--format lines|kv|json|template] [--template <tpl>]
                    [--key <name>] [--key-field <name>] [--value-field <name>]
                    [--ts-field <name>] [--from <bytes>] [--batch N]
                    [--interval ms] [--idempotent] [--min-level <level>]
                    [--level-field <name>] [--sample-rate 0-100]
                    [--include <text>] [--exclude <text>] [--schema]
                    [--clock-skew <ms>] [--mask] [--mask-fields <csv>]
                    [--meta <csv>] [--partition day|hour]
                                采集外部日志文件：每行按格式解析为字段并写入
                                （`lines` 默认整行为 value；`kv` 解析空格分
                                隔 name=value 对；`json` 解析顶层 JSON 对象
                                字段；`template` 按 `--template "<a> <b>"`
                                的字面+`<name>` 占位符提取——轻量 Grok 等
                                价，不含正则）；`--key-field` 字段提升为记
                                录键、`--value-field` 字段作为 value（缺省
                                整行）、`--ts-field` 从字段取时间戳；`--idem
                                 potent` 幂等去重；`--min-level`/`--sample-ra
                                 te`/`--include`/`--exclude` 源头采样限流；
                                 `--schema` 统一六字段（服务名提升为键、标
                                 准字段重组 value、别名归一，详见下 `query`）；
                                 `--clock-skew <ms>` 为全部记录时间戳加固定
                                 偏移（校正采集端时钟慢/快）；时间值自动识别
                                 秒/毫秒/微秒/纳秒与 ISO-8601 时区（2.3）；
                                 `--mask` 写入前脱敏（敏感字段名/Bearer/JWT
                                 →[REDACTED]，手机号/证件号保留前 3 后 4，
                                 长 hex→[REDACTED]；`--mask-fields` 追加敏
                                 感字段名）；`--meta k=v,k2=v2` 为每条记录
                                 追加部署元数据（环境/版本/地域富化，2.4）；
                                 `--partition day|hour` 按时间分区（跨桶自
                                 动滚动新段，旧分区可经 prune-before 整段
                                 淘汰，3.1）；
                                `--once` 导入到当前末尾即退出，`--follow` 持
                                续跟踪追加（半行留待下轮、截断/轮转自动从零
                                重采）；`--fifo` 改为订阅命名管道（写者推送
                                批次，跨写者持续采集）；采集位点以命名游标
                                `ingest-<basename>` 持久化，重跑自动续采
                                （`--from` 可覆盖），`--batch` 控制每批写入
                                条数（默认 256）
  http <dir> [--port N] [--queue N] [--batch N] [--backlog-alert N]
            [--format lines|kv] [--key <name>] [--key-field <name>]
            [--ts-field <name>] [--schema] [--clock-skew <ms>]
            [--mask] [--mask-fields <csv>] [--meta <csv>]
            [--partition day|hour]
                                在 127.0.0.1 上提供 HTTP 推送端点：`POST /`
                                或 `/push` 先进入**有界队列**（`--queue` 行
                                数上限，默认 10000）并返回 202；队列满时返回
                                **429 + Retry-After**（明确反压，客户端重试
                                即可，不静默丢数据）；后台按 `--batch` 行
                                分批落库，积压超 `--backlog-alert`（默认
                                5000）时打印 `WARN backlog` 并经 `/stats`
                                的 `pending`/`backlog_alerts` 暴露；SIGTERM/
                                SIGINT 优雅关闭前会清空队列；另有 `GET
                                /health`、`GET /stats`；SDK 直接调用库 API
                                `Log::append`
  serve <dir> <max-segments> [ttl] [--every ms] [--fsck-every N] [--once]
                                周期性执行维护（合并 + 冗余回收 + 可选过期折
                                叠 + 压缩 + flush 元数据）；`--every` 或
                                `MOONLOG_SERVE_INTERVAL` 设置周期，默认
                                60000ms；`--fsck-every N` 每 N 轮跑一次快
                                速 fsck 并输出报告；`--once` 执行一轮即退出
  backup <dir> <dst>            将目录的一致快照拷贝到空目录 dst（独占锁内
                                flush 数据与元数据后原样拷贝段文件、sidecar
                                与 MANIFEST；不拷贝 LOCK 与游标文件）
  restore <src> <dst>           将 backup 产物还原到空目录 dst（offset 原样
                                保留，恢复后可无缝续写、游标仍有效；完成后
                                自动 verify_fast 校验并输出报告）
  replicate <src> <dst> [--follow]
                                增量镜像 src 为完整副本目录（同 backup 引
                                擎，offset/游标保留，副本可直接读写）；
                                `--follow` 周期持续同步（`MOONLOG_REPLICA
                                TE_INTERVAL` 默认 200ms），源目录消失仅
                                WARN 重试不重建；failover 切目录到副本、
                                反向 replicate 再平衡（3.5）
  archive <dir> <file> [--list] [--extract --into <dir>]
                                把目录数据文件（MANIFEST + 段 + sidecar）
                                打包为单一自包含归档文件（`MLAR` 容器，
                                CRC32 完整性校验）——单文件 PUT 上传任意
                                对象存储；`--list` 列内容、`--extract`
                                解包到目录后可直接打开查询（分层归档用
                                主目录，symlink 穿透冷段数据）（3.6）
  getkey <dir> <key>            查询 key 的最新值（tombstone 生效）
  getkey-live <dir> <key> <ttl> 查询 key 的最新值，过期则视为不存在
  has-key <dir> <key>           用段级 Bloom 过滤判断 key 是否存在
  export <dir> <file>           导出全部记录（含 tombstone）到可移植文件
  export-jsonl <dir> <file> [base64]
                                导出全部记录为 JSON Lines（每行一个 JSON 对
                                象：offset/timestamp/kind/key/value；默认文
                                本模式假定 UTF-8 文本、控制字符转义，`base64`
                                模式对任意字节无损）
  import <dir> <file>           从可移植文件回放记录
  compact <dir>                 折叠为 live 记录并重写目录
  compact-expired <dir> <ttl>   折叠 live 记录并剔除已过期记录（offset 重排）
  fsck <dir> [fast] [--fix] [--dry-run]
                                校验完整性（fast 跳过记录解码，段级 CRC）；
                                `--fix` 先执行修复：隔离整段校验失败的段
                                （改名 `<name>.corrupt` 保留证据）、截断损坏
                                尾部、重建 MANIFEST 与全部段 sidecar，随后
                                再校验一次并输出报告；`--dry-run` 只打印修
                                复计划（将截断/隔离/删除什么），不改盘
compress <dir> [rle|lzss]     原地压缩所有已 roll 段
  tier <dir> <cold-dir> [--warm N] [--dry-run]
                                热温冷分层：已 roll 段原地压缩（温），比最
                                新 `--warm` 个已 roll 段更旧的段迁入
                                cold-dir 并以 symlink 占位（冷），读/校验/
                                备份路径全部透明；`--dry-run` 只打印计划
stats <dir> [json]            打印逐段统计（含每段逻辑字节 disk 磁盘字节与
                              压缩汇总；可选 JSON）
partitions <dir> [--unit day|hour] [--json]
                              时间分区视图：按段首记录的时间桶分组展示每
                              分区的段数/记录数/字节与 UTC span；分区写
                              入（--partition）后旧分区可经 prune-before/
                              prune-expired 整段淘汰，清理只触碰被回收
                              的段文件，读者（共享锁）不被阻塞
search <dir> <text> [--field key|value|both] [--ignore-case] [--limit N]
                    [--from off] [--to off] [--inverted] [--wildcard]
                              全文检索：默认线性扫描 key/value 子串（无倒
                              排索引依赖）；`--wildcard` 切换为通配符语
                              义——`*` 匹配任意字节序列、`?` 精确匹配单
                              字节（字节级：中文一字 3 个 UTF-8 字节），
                              其余字符字面匹配（`--ignore-case` 折叠
                              ASCII），子串命中（与 `--inverted` 互斥）；
                              `--inverted` 改走段级词倒排索
                              引（<base>.log.inv sidecar，lazy 构建或
                              maintain 预建）——查询词按 ASCII 词法分词
                              折叠小写后做**完整词命中**（词级语义，与子
                              串不同；CJK 文本请用线性路径），`--field`/
                              `--ignore-case` 在该模式下忽略；`--limit`
                              提前停止，`--from`/`--to` 限定 offset 区间
query <dir> [--level <lv>] [--service <svc>] [--host <h>]
              [--trace-id <id>] [--level-min <lv>] [--level-max <lv>]
              [--contains <text>] [--since <ts>] [--until <ts>]
              [--limit N] [--indexed] [--sort-by-time] [--json]
              [--require-time]
                              统一 Schema 联合过滤：全部给定条件按 AND 匹配
                              （`--service` 匹配记录键或解析的服务字段；
                              `--level-min`/`--level-max` 按严重度排序过
                              滤（debug<info<warn<error<fatal，双界取区
                              间；范围过滤要求已知 level——未知级别被排
                              除）；`--contains` 大小写不敏感子串匹配 value；
                              `--since`/`--until` 限定记录时间戳区间，
                              epoch ms 含端点；`--limit` 提前停止）；
                              **条件下推**（4.2）：时间界经段级 `min_ts`/
                              `max_ts` 跳过不相交段（不解码），`--indexed`
                              把等值或级别范围（展开为五级枚举并集）经字
                              段列索引预筛（sidecar lazy 构建，maintain
                              预建）再全条件精滤，无条件退回线性；
                              `--sort-by-time` 按事件时间排序输出（同刻
                              保持 offset 序）；`--json` 以单行 JSONL
                              输出；无 schema 的旧记录仍可按 key/
                              contains 过滤
context <dir> <offset> [--before N] [--after N]
                              上下文检索：打印目标 offset 前后各 N 条（默认
                              3/3，自动 clamp 到日志边界并跨段）
aggregate <dir> [--by key|value|kind|hour|prefix:N] [--kv-field <name>]
                 [--match <text>] [--top N] [--json]
                              多维聚合统计：按 key/value/kind/UTC 小时/键前
                              缀 N 字节计数，`--kv-field` 按 value 内的
                              name=value 字段聚合，`--match` 过滤记录，
                              输出前 N 桶（`--json` 结构化）
cluster <dir> [--match <text>] [--top N]
                              错误自动聚类：把匹配行归一化为模板（数字/
                              十六进制/引号串替换为占位符）后按模板计数，
                              变量内容折叠为消息形态（默认匹配 "error"）
trend <dir> [--bucket minute|hour|day] [--match <text>] [--width N]
                              趋势可视化：按 UTC 时间桶计数并以文本直方图
                              输出（按时间序，`--width` 控制最长条宽）
alert <dir> <match> --threshold N [--window minute|hour|day]
                [--notify-file <path>] [--webhook <url>] [--json]
                              阈值告警：按 UTC 窗口统计匹配记录数，超过阈值
                              的窗口告警（`--json` 输出事件；`--notify-file`
                              追加 JSONL 通知；`--webhook` 经 curl POST，
                              失败仅告警不中断）
baseline <dir> [--match <text>] [--window minute|hour|day] [--sigma N]
               [--min-windows N] [--notify-file <path>] [--webhook <url>]
                              异常基线检测：按窗口计数计算均值/标准差，
                              |z-score| > sigma（默认 3）且窗口数达标即标记
                              异常，可走文件/webhook 通知
rbac <dir> init <token> | add <name> <token> <allow> | list
         | remove <name> | check <command>
                              管理目录 RBAC 规则（`<dir>/RBAC`）；文件一旦存
                              在，除 `rbac init` 与 `rbac check`（诊断）外所
                              有命令需提供 MOONLOG_TOKEN 且角色 allow 列表
                              含该命令（或 `*`），拒绝事件追加到 `AUDIT.log`
version                       打印 moonlog 版本号（与 moon.mod 同步）
```

持久性与 `MOONLOG_SYNC`：CLI 写入默认 `Always`，即命令返回时数据已 fsync 落盘；设 `MOONLOG_SYNC=batch` 改为批量 / 导入时一次 fsync，设 `MOONLOG_SYNC=never`（或 `0`）关闭显式 fsync（仅依赖 OS 回写）。

`import` 会用目标日志的 `append` **重新分配 offset**（offset 是每个日志本地的连续编号）；导出文件保留 key/value/timestamp/kind，不含目标 offset 语义。

## API 概览

| 类型 / 函数 | 包 | 用途 |
| --- | --- | --- |
| `Log::new` / `Log::recover` | `log` | 建立多段日志 / 从已有段恢复 |
| `Log::append` / `append_batch` / `append_batch_atomic` / `Log::delete` | `log` | 追加单条 / 批量 / 原子批量（失败回滚）/ tombstone |
| `Log::get` / `scan` / `scan_range` / `scan_reverse` / `scan_time_range` / `tail` / `for_each` | `log` | 点查 / 全扫 / offset 区间 / 逆序区间 / 时间区间 / 最近 N 条 / 流式遍历 |
| `Log::for_each_while` / `Log::for_each_time_range` | `log` | 流式遍历（`f` 返回 `false` 提前终止、跨段传播）/ 时间区间流式遍历，大结果集零物化 |
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
| `backup_log_dir` / `restore_log_dir` | `backend_native` | 目录级物理备份（对既有备份目录增量拷贝）/ 恢复，offset 保留 |
| `repair_log_dir` / `RepairReport` | `backend_native` | 修复：坏段隔离（`.corrupt`）、torn-tail 截断、MANIFEST/sidecar 重建 |
| `compress_rolled_segments` / `compress_log_dir` / `count_compressible_segments` | `backend_native` | 对已打开日志 / 目录执行已 roll 段压缩与计数 |
| `file_size` / `sleep_ms` / `rename_file` | `backend_native` | 文件尺寸 / 轮询休眠 / 文件改名（增量备份、follow/serve/repair 支撑） |
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

### 运维指南（M75）

- **fd 上限**：每个打开的段占用 1 个文件描述符（另有 `LOCK` 等少量 fd）。段数接近 `ulimit -n` 时，`open_log_dir` / 写命令会以 `Syscall` 错误失败——用 `merge <dir> <max-segments>` 或 `maintain` 减少段数，或调高 `ulimit -n`。
- **维护周期**：建议定期执行 `maintain <dir> <max-segments> [ttl]`：段合并控制读放大与 fd 占用，`prune-superseded` 回收冗余空间，`compact-expired <ttl>` 回收过期数据。
- **游标语义**：`prune-*` 系列自动保护未消费段；`compact` / `compact-expired` / `import` 重排 offset 后需重置游标——详见「游标与段回收语义（M72）」。
- **fsck 两档**：日常巡检用 `fsck <dir> fast`（不解码记录体，段级 CRC）；事故排查用 `fsck <dir>`（全量解码，能定位记录级损坏）。
- **异地同步/复制（M92）**：段文件 immutable，是天然的增量复制单元，无需专用协议即可搭建主→备同步：

  ```bash
  # 主机（生产者）：定时增量推送（backup 幂等，重复执行只传变更段）
  moonlog backup /data/moonlog primary-bak
  rsync -a --delete primary-bak/ backup-host:/data/moonlog-replica/

  # 备机（消费者）：首次落地 + 周期刷新
  moonlog backup /data/moonlog primary-bak   # 增量
  rsync -a primary-bak/ replica/
  ```

  备机目录结构与主目录字节一致（MANIFEST/段/sidecar），offset 与游标语义原样保留——备机可直接 `scan` / `getkey` / `follow -` 消费，故障切换时把备机目录交给写者即可（游标文件不随 backup 拷贝，如需保留消费进度先 `cp CURSOR*` 或在备机 `cursor-commit`）。注意：只做单向复制，双主互写不受支持。

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
- M73 选择性 fsync：段级 `fsync_dirty`，`Log::flush` / `SyncPolicy::Always` 只 fsync 有新数据的段；**行为变化**：`flush()` 幂等化（无新追加时为 no-op）
- M74 快速校验：`Log::verify_fast` / CLI `fsck <dir> fast` 不解码记录体，只校验段连续性、计数一致性与段级 CRC32（fast 不能发现记录级损坏，full 仍是彻底校验）
- M68 live 折叠点查化：`snapshot` / `scan_live` 经 key 索引逐 key 点查（按 offset 排序保持输出顺序），替代二次全量扫描
- M69 段内 ts 采样索引：`Segment` 维护与稀疏索引同步的内存 ts 采样（append/rebuild 填充），`lower_bound_ts` 先对采样二分（零 I/O）再至多走一个采样区间；无采样的新打开段回退点探二分
- M70 一键维护：CLI `maintain <dir> <max-segments> [ttl]` 聚合段合并 + 冗余段回收 + 过期折叠（可选）+ fsck 报告
- M71 发布 0.6.0：native property 测试（含 torn tail 注入）、live 折叠点查化、ts 采样索引、maintain 命令随包发布
- M76 发布 0.7.0：游标感知回收、选择性 fsync（flush 幂等化）、fsck fast、运维指南随包发布
- M77 维护/游标 property 测试 + 修复：随机维护（merge/prune-superseded/compact）与游标推进的 property 测试；**修复** `prune_superseded` 不再删除含 tombstone 的段（防旧 put 复活）
- M78 ts 采样持久化（meta v8）：稀疏索引条目附 timestamp（兼容读 v1–v7），打开的段加载即恢复内存 ts 采样，`scan_time_range` 立即使用采样二分
- M79 `get_many` 段分组点查：批量点查按 offset 排序后单次顺序遍历段，替代逐 key 重复定位
- M80 发布 0.8.0：维护/游标 property 测试、tombstone 安全修剪修复、ts 采样持久化、get_many 段分组随包发布
- M81 物理备份/恢复：`backup_log_dir` / `restore_log_dir` 与 CLI `backup` / `restore`（独占锁内 flush 后原样拷贝，空目录强制、MANIFEST 校验，offset 保留）
- M82 修复模式：`repair_log_dir` 与 CLI `fsck --fix`（整段 CRC 失败隔离为 `.corrupt`、torn-tail 截断、空段清理、MANIFEST 与段 sidecar 原子重建）
- M83 尾随读：CLI `follow`（轮询新记录持续输出，`-`/`tail`/offset 起点、`--commit` 自动提交游标、`--once` 单轮、`MOONLOG_FOLLOW_INTERVAL` 间隔）
- M84 自动维护：CLI `serve`（周期性维护管线，`--every`/`MOONLOG_SERVE_INTERVAL` 周期、`--once` 单轮；`maintain` 核心重构为共享的 `run_maintenance`）
- M85 增量备份：`backup_log_dir` 对既有备份目录增量执行——备份副本比源端段文件新（源端自上次备份未被修改）即跳过、源端已删段自动清理、MANIFEST 与 sidecar 始终重拷（原地重写），大目录备份降为 O(变更)。M98 发现并修复了原"同名同尺寸跳过"启发式的缺陷：compact/merge 会以同名重写段文件，尺寸可能不变而内容已变——现改用纳秒级 mtime 判断（`file_mtime_ns`，新增 stub）
- M86 维护管线集成压缩：`compress_rolled_segments` 从 `compress_log_dir` 抽出为库 API，`maintain` / `serve` 管线自动压缩全部已 roll 段（LZSS）并输出 `compressed N`
- M87 消费滞后监控：CLI `cursor-lag` 报告默认与命名游标的 position/lag 与 `next_offset`
- M88 修复鲁棒性 property 测试：固定 seed 随机注入截断/翻转字节/删 MANIFEST/删 sidecar/追加 torn 尾（1–3 类/轮，40 轮），断言 repair 后存活记录与原始一致、verify 通过、可续写
- M89 流式遍历：`Segment::for_each_while` / `Log::for_each_while`（`f` 返回 `false` 提前终止，跨段传播）与 `Log::for_each_time_range`；CLI `scan`/`scan-time`/`tail` 改流式输出，大结果集不再物化 Array
- M90 批量读快路径：`scan`/`rebuild_index`/`recover` 改为单次读全段后内存顺序解码（`decode_in`），消除逐记录 pread——native bench 段恢复 86.9ms→5.2ms（16.7×）、全量顺序扫描 2.77ms→0.86ms（3.2×），点查/写入持平
- M91 观测与导出：`SegmentSummary` 增加逻辑字节与 `disk_bytes`，`stats` 输出每段与总体的压缩尺寸（文本/JSON）；CLI `export-jsonl` 以 JSON Lines 导出（text/base64 双模式，内置 RFC 4648 base64 编码器）
- M92 复制方案文档化：运维指南新增「异地同步/复制」——增量 backup + rsync 搭建主→备只读副本（offset/游标语义保留），并明确单写多读边界
- M93 恢复即校验：`restore` 完成后自动对恢复副本执行 `verify_fast` 并输出报告，静默损坏的备份在投入使用前即被拦截
- M94 修复预览：`repair_log_dir` 增加 `dry_run` 模式（只读探测 `probe_records`），CLI `fsck --dry-run` 打印修复计划——将截断/隔离/删除什么，不改盘；dry-run 计划与实际修复结果一致（测试断言）
- M95 KeyIndex 增量维护：`append` 将新记录增量折叠进缓存的 key 索引（`KeyIndex::update`——新 offset 恒更大，put 刷新 latest、tombstone 移除键），`sorted_keys` 视图惰性重算；仅段集合结构变化（保留/合并/压缩/导入重放）才整体失效，写密集点查消除 O(全部 key) 的全量重建
- M96 Bloom 快查 O(1) 化：`latest_key_in_segment` 直接查段的内存 key 映射（append/rebuild/`.keys` sidecar 加载恒就绪）取 latest offset 后单点读取，`get_latest_bloom` 从 O(段大小解码) 降为 O(1)，不再全段扫描
- M97 前缀/区间扫描段分组读取：`scan_prefix` / `scan_key_range` 按 offset 顺序单遍读取（复用 get_many 的段分组模式 M79）后按 key 序重排，消除逐 key 跨段定位的读放大
- M98 增量备份 property 测试：固定 seed 随机写序列（put/delete 交错、每三轮 compact）× 8 轮增量 backup → restore，断言与源端逐记录等价；该测试暴露并驱动修复了"同名同尺寸跳过"启发式在 compact 重写同名段时的 stale 数据缺陷（改用纳秒级 mtime 判断）
- M99 follow 程序化消费：`--json` 以单行 JSON 输出记录（UTF-8 文本、控制字符转义，与 export-jsonl 同构）；`--name <cursor>` 支持命名游标的读取与提交，多消费者可各自 follow 互不干扰
- M100 serve 周期巡检：`--fsck-every N` 每 N 轮维护后对日志执行 `verify_fast` 并输出报告，常驻守护自带完整性巡检
- M101 CLI `version` 命令：输出 moonlog 版本号（与 `moon.mod` 同步维护）
- M102 CI 性能门禁：ms 级 native 基准（顺序扫描/区间扫描/段恢复）与保守阈值（本地 pinned 工具链值的 5–6 倍余量）比较，仅拦截数量级回退，规避共享 runner 的 µs 级噪声
- M103 export/import roundtrip property 测试：固定 seed 随机 put/delete 序列 × 6 轮，导出记录流重放进全新目录，断言逐记录等价（offset 连续、timestamp/kind/payload 保留）
- M104 日志采集：CLI `ingest` 从外部日志文件批量导入（`--once`）或持续跟踪（`--follow`，半行留待下轮、截断/轮转自动重采）；`lines`/`kv` 两种解析（字段提取与格式化：`--key-field` 提升为记录键、其余字段重组为值，`--key` 常量标签）；采集位点以命名游标 `ingest-<basename>` 持久化实现断点续采；核心解析器 `parse_kv_pairs` 随 core 包提供并有单测
- M105 热温冷分层存储：`tier_log_dir` 与 CLI `tier`——已 roll 段先原地压缩（温层），较旧的段复制进 cold 目录并以 symlink **原子替换**主路径（冷层），活跃段恒热；新增 symlink/lstat/readlink stub，`remove_segment_files` 联动清理冷副本；读/校验/备份/修复经链接透明，命令幂等并支持 `--dry-run` 计划
- M106 日志检索：全文检索 CLI `search`（流式线性扫描 key/value 子串，`--field`/`--ignore-case`/`--limit`/`--from`/`--to`，无倒排索引、成本 O(records)，文档注明定位）与上下文关联检索 `context`（按 offset 打印前后 N 条，自动 clamp 边界并跨段）；新增 core 子串匹配器 `bytes_contains`/`bytes_contains_ci` 并有单测
- M107 日志分析：`aggregate` 多维聚合（`--by key|value|kind|hour|prefix:N`、`--kv-field` 字段维度、`--match` 过滤、`--top`、`--json`）；`cluster` 错误聚类（core `normalize_log_template` 将数字/hex/引号串折叠为占位符后按模板计数）；`trend` 趋势直方图（core `format_utc` 的 UTC 分钟/小时/天标签 + 文本条）；顺带修复 `ensure_dir` 不支持父目录的缺陷（改为逐级递归创建，此前冒烟均手工 `mkdir -p` 而未暴露）
- M108 告警监控：`alert` 阈值告警（UTC 窗口计数 vs `--threshold`，`--json` 事件）与 `baseline` 异常基线检测（窗口计数均值/标准差 z-score，`--sigma`/`--min-windows`）；多渠道通知分发（stdout + `--notify-file` JSONL 追加 + `--webhook` 经 `curl` POST，`shell_quote` 防注入、投递失败降级告警不中断，新增 `moonlog_run_command` stub）；配套为告警提供真实时间维度：`put --ts` 与 `ingest --ts-field`（kv 采集时从日志字段提取 timestamp）
- M109 运维管理 RBAC：core 新增 `RbacRole`/`parse_rbac_line`/`rbac_allows`/`rbac_find`（Bytes 模型 + 单测），CLI 以 `<dir>/RBAC` 规则文件（`role=.. token=.. allow=cmds|*`）控制访问——文件存在时除 `rbac init`/`rbac check` 外所有命令需 `MOONLOG_TOKEN` 且角色允许，拒绝事件追加 `AUDIT.log`；`rbac init/add/list/remove/check` 管理命令（`list` 隐藏 token 尾部）；无 RBAC 文件保持开放向后兼容。TTL 清理（prune/compact-expired/retain_before/`--ttl`）与导出归档（export/export-jsonl/import/backup）此前已覆盖
- M110 多源接入（1.1）：补齐四类采集来源——**HTTP 推送端点** `http`（127.0.0.1 监听，`POST /`/`/push` 按 `lines|kv` 格式逐行入库、`GET /health`、`GET /stats`；新增 TCP（listen/accept/read/write）C stub 与 core `parse_http_request` 及单测）；**消息队列订阅** `ingest --fifo`（命名管道订阅，写者推送批次、跨写者持续采集、半行跨 chunk 保留；新增 mkfifo/阻塞读 C stub）；Agent 采集（`ingest --follow`）与离线批量导入（`ingest --once`）此前已覆盖；SDK 接入即库 API `Log::append`。`ingest` 的入库流水线抽取为共享 `ingest_lines`/`ingest_timestamp`（HTTP 与 FIFO 复用）
- M111 高吞吐写入（1.2）：append-only 批量链路此前已覆盖（`append_batch` 每条自带 timestamp、`append_batch_atomic`、`put-batch`、`SyncPolicy::Batch`、`ingest --batch`），补齐**可执行压测**——CLI `bench-write <dir> <count> [--batch N] [--sync always|batch|never]`：分批批量写入并报告 records/s，随后**重新打开目录做两阶段无丢失校验**（精确条数 + offset 连续 + `verify_fast` 干净）；新增 native `bench append batch bulk write` 基准（1000 条/批 4.30ms ≈ 23.2 万 records/s，对比单条 append 135µs，批量快约 31 倍）。实测：1000 条/批 Batch 模式 ≈ 79.7k/s、5000 条/批 ≈ 89.1k/s、`--sync never` ≈ 89.7k/s、`--sync always`（逐批 fsync）≈ 605/s——全部 verify `ok (no loss)`
- M112 缓冲与背压（1.3）：HTTP 端点改为**有界入站队列**（`--queue` 行数上限）——`POST` 入队成功返回 **202**（含 pending），队列满返回 **429 + Retry-After**（明确反压、无静默丢弃），后台按 `--batch` 行分批落库；积压超 `--backlog-alert` 打印 `WARN backlog` 并在 `/stats` 暴露 `pending`/`backlog_alerts`；新增 `poll` 超时 accept（空闲时持续消化队列）与 SIGTERM/SIGINT 信号 stub——**优雅关闭前清空队列**（冒烟实测并发超限 429 重试后 1200/1200 零丢失、积压告警触发、退出提示 backlog drained）。首版冒烟曾发现"kill 时队列 200 行未落盘"的静默丢失，由此补上优雅关闭
- M113 幂等与重放（1.4）：core 新增 `Log::append_idempotent`——待写 (key, value) 与该键最新 live 记录一致时跳过并返回既有 offset（检查骑乘增量 key 索引，O(1)），否则正常追加；CLI `put`/`ingest`/`http` 增加 `--idempotent`（重放文件、HTTP 429 重试、批次重投全部幂等：实测重放 2 行 `2 duplicates skipped` 零新增，非幂等对照翻倍至 4）；`ingest` 输出补充重复跳过计数；与采集位点断点续传互补（位点内不重读，位点外重复投递靠幂等兜底）。新增 2 个幂等单测（基本语义 + 跨段）
- M114 源头采样限流（1.5）：core 新增 `SamplingConfig` + `sampling_allows`（**按级别** `level_rank` 五级映射、**按比例** `fnv1a_hash` 确定性采样——同内容判定恒定与幂等重放一致、**按规则** include/exclude 子串）+ 5 个单测；`ingest`/`http` 增加 `--min-level`/`--level-field`/`--sample-rate`/`--include`/`--exclude`，采样在源头（HTTP 入队前 / ingest 写入前）执行，`ingest` 输出 `(N sampled out)`、HTTP 202 响应含 `sampled_out`。实测：`--min-level warn` 丢 debug/info、`--sample-rate 0` 全丢、`--sample-rate 50` 采样 99/200、`--exclude healthcheck` 精确过滤
- M115 结构化解析（2.1）：`--format json`（core `json_object_fields` 复用 `moonbitlang/core/json`，顶层对象字段展平、ParseError 由入库管线捕获）与 `--template "<ip> - <user>"`（core `parse_by_template`——字面 + `<name>` 占位符的**轻量 Grok 等价**，贪婪捕获到下一字面首现，不含正则引擎）；`--value-field` 指定字段作为 value（缺省整行）；`ingest_timestamp` 统一从解析字段提取时间戳（json/template/kv 三格式共用）。实测：JSON 行 key/value 字段提取、模板四字段提取、`--min-level warn` 组合采样全部准确
- M116 统一 Schema（2.2）：core 新增 `canonical_field`/`SchemaFields`/`schema_from_fields`/`schema_value`/`schema_matches`（六槽位别名映射 + 4 个单测）；`ingest`/`http` 增加 `--schema`——解析字段按六大基础字段（时间戳/级别/服务名/主机/trace_id/消息，接受常用别名 `@timestamp`/`severity`/`service_name`/`app`/`hostname`/`traceId`/`msg` 等）归一，**服务名提升为记录键**、标准字段按固定顺序重组 value、时间戳取自解析值，异构服务入库口径一致（实测 `severity=… service_name=… traceId=… @timestamp=…` 与 `level=… service=… trace_id=… timestamp=…` 两种命名习惯归一为同一 shape）；新增 `query` 联合过滤命令（`--level`/`--service`/`--host`/`--trace-id`/`--contains` AND + `--since`/`--until` 时间窗 + `--limit`/`--json`，流式线性扫描），跨服务联查实测 `--trace-id t9` 命中 orders 与 inventory 两条异构来源记录；HTTP 推送经队列异步落库同样按 schema 归一（curl POST `severity=fatal service=gateway …` → `query --service gateway` 可查）。开发注记：初版 `SchemaFields` 以 mut 字段 + 循环赋值实现触发 native SIGABRT，重构为六个独立 first-match 查找后消除；定位中确认测试内 panic 断言在 native 以 SIGABRT 呈现（此前所谓工具链深坑，实为断言失败路径的表象）
- M117 时间规范化（2.3）：core 新增 `normalize_ts`/`parse_iso8601_ms`（+3 单测）——纯数字按位数缩放（秒 <1e11 / 毫秒 <1e14 / 微秒 <1e17 / 纳秒），ISO-8601 解析 `Z`/`±HH:MM`/`±HHMM` 时区、`T`/空格分隔、小数秒截断毫秒（正向 days-from-civil 与 `format_utc` 的 days-to-civil 互逆，无日历库）；`ingest_timestamp` 与 schema 六字段的 ts 提取改走 `normalize_ts`（此前只认纯数字毫秒：秒级值错 1000 倍、ISO8601 直接回退到达序）；`ingest`/`http` 增加 `--clock-skew <ms>`（固定偏移补偿采集端时钟慢/快，作用于全部记录时间戳含到达序回退值）；`query` 增加 `--sort-by-time`（物化命中后按事件时间排序、tie 保 offset 序，处理乱序到达）。实测：`2026-11-06T20:00:00+08:00`/`12:00:00Z` 同事件归一为同一 1793966400000；四条三时区乱序到达 `--sort-by-time` 输出正确事件序；秒/毫秒/ISO 三写法同值；`--clock-skew 5000` 精确 +5s；trend 的 UTC 小时桶往返正确。开发注记：MoonBit 链式算术表达式中的裸数字字面量会被定型为 Int 向左传播（如 `(153 * mp + 2) / 5 + d - 1` 整条变 Int），days-from-civil 需对字面量逐个 `(: Int64)` 标注
- M118 脱敏与字段富化（2.4）：core 新增 `mask_sensitive`（+3 单测）——单遍扫描逐字节保真、无正则引擎：敏感字段名值段（内置词表 password/passwd/pwd/secret/secret_key/token/api_key/apikey/access_key/authorization/auth/credential(s)/session/session_id/sessionid/cookie/private_key + `--mask-fields` 自定义，ASCII 忽略大小写、词边界判定）→ `name=[REDACTED]`；`Bearer <token>`（≥8 字符）与 JWT（`eyJ` 前缀 + 双点 token run）→ `[REDACTED]`；11 位手机号（1[3-9] 开头、数字边界）保留 3+4（`138****5678`）；15 位/17 位+X 证件号保留前 3 后 4；≥20 位连续 hex（md5/sha1/sha256）→ `[REDACTED]`，UUID 分段与 19 位纳秒时间戳不误伤；CLI `ingest`/`http` 增加 `--mask`/`--mask-fields <csv>`/`--meta <csv>`（`--meta k=v,k2=v2` 写入前为每条 value 追加部署元数据，k 缺 `=` 报错），掩码与富化在 schema 转换之后、幂等去重之前执行（重复投递判定一致；schema 模式下非规范敏感字段天然不落盘 + message 内模式掩码双保险）。实测：kv/schema/lines/HTTP 四条路径——`phone=138****5678`、`idcard=110***********777X`、`token=[REDACTED]`、`sha=[REDACTED]`、lines 整行 `139****5678 … Bearer [REDACTED]`，四项明文 `search` 全部 0 matches；`env=prod region=cn-north version=2.1.0` 富化落盘
- M119 按时间分区（3.1）：core `Log` 增加 `partition_ms`/`active_bucket` 与 pub `time_bucket`——`put`/`ingest`/`http` 的 `--partition day|hour` 使 append 在记录时间桶与活跃段桶不同时自动滚动新段（`append_batch` 逐条复用同一路径；`Log::recover` 从活跃段首记录恢复桶，重开后同桶续写不切段），桶按 epoch 对齐（负 ts clamp 0、非法 unit 报错）；单段大小仍受 roll_size 控制（分区+段两层大小可控），+2 单测（跨桶滚动/迟到数据开新段/recover 恢复桶）；CLI 新增 `partitions` 视图（按段首记录桶分组：段数/记录数/字节/UTC span，`--unit day|hour` + `--json`）；过期清理沿用整段回收语义——分区对齐即整分区淘汰，prune 只触碰被回收段、读者共享锁不阻塞（并发冒烟验证）。实测：put 三条跨两天 → 2 段、partitions day/hour 两视图正确、ingest `--ts-field` 归一后按事件时间分桶、schema+partition 组合正常、prune-before 精确淘汰旧分区（dropped 1）。开发注记：`Log::recover` 因读段首记录需补 `R : @io.LogReader` 约束；MoonBit 可选默认参数（`partition_ms~ = 0`）保证全部既有调用点零改动
- M120 倒排 + 列式索引（3.2）：segment 新增 `InvIndex`（词倒排 terms + 字段列 fields 双 posting 表，pub `tokenize` ASCII 词法小写折叠、`build_inv_index`/`ensure_inv_index` lazy 全段构建、`inv_term_postings`/`inv_field_postings` 查询、`encode`/`decode_inv_index` sidecar 序列化 + CRC，+3 单测含 roundtrip 与 CRC 破坏拒绝）；`<base>.log.inv` sidecar 随 `load_segment_keys` 加载、`flush_meta` 幂等写出、`maintain`/`serve` 管线顺带全量构建；CLI `search --inverted`（词级全文，候选经倒排预筛按 offset 序输出，`(inverted)` 后缀标注）与 `query --indexed`（首个等值过滤经字段列预筛（service 经 `__key__` 并集）后 schema_matches 全条件精滤，`(indexed)` 后缀），linear/inverted/indexed 冒烟结果一致；native_bench 新增对比基准——2000 条 10% 命中下线性全扫 2.69ms vs 列索引查询 167ns（约 1.6 万倍），验收"关键词与字段组合查询均秒级返回"达成。开发注记：encode/decode 的 entry 布局曾不一致（[klen,key,n,...] vs [klen,n,key,...]）导致 decode 读到垃圾 n 触发 Truncated——调试打印定位后对齐；另有 Edit 凭记忆写 oldString 误改 `meta_dirty/fsync_dirty` 初始值破坏既有 dirty 测试（git diff 揪出，恢复 true）——教训：编辑构造体时 oldString 必须取自重读原文
- M121 列式压缩（3.3）：`.inv` sidecar postings 由定长 u32 改为 **delta + varint（LEB128）**编码（`inv_write_varint`/`inv_read_varint`，>5 字节与越界防恶意截断；INV_VERSION 1→2 且 decode 收紧为精确版本检查——旧 v1 拒绝后 lazy 重建而非静默错读），+1 单测（500 条密集列：v1 布局约 30KB → varint 实测 <15KB、解码语义逐列相等）。实测：600 条混合负载 `.inv` 28724B（v1 估算约 41KB，约 30% 缩减；密集列约 75% 缩减）；索引查询 warm 读基准 **173ns ± 0.47ns**（3.2 基线 167ns ± 3ns——查询路径未变，decode 仅发生在 sidecar 加载，"查询未明显变慢"达成）；linear/indexed/inverted 与 v1 sidecar 篡改重建冒烟全部回归一致；行式段级 RLE/LZSS 压缩此前已覆盖（第 2 域验收）。开发注记：`UInt32.to_int()` 已被工具链标记弃用（改用 `reinterpret_as_int`）；sh 算术 `$(( ))` 不支持 printf 的 `%%` 写法
- M122 生命周期 TTL（3.4）：core 新增 `ttlpolicy.mbt`（`TtlPolicy` + `parse_ttl_policy` + `ttl_days_of` + `ttl_record_level`，+2 单测：三维命中取严/default 兜底/畸形行整文件拒绝/default 缺省不过期/days=0 即刻过期）与 `Log::expire_by_policy`（逐记录按差异化 TTL 判定、段内全部到期整段回收——keep 重建 + 游标保护 + 索引失效；`apply=false` 供 dry-run 只统计）；CLI 新增 `ttl-expire <dir> [--dry-run]`（读 `<dir>/TTL`：`default/service/level` 行式规则，畸形策略报错拒绝）与 `append_ttl_audit`（`TTL_AUDIT.log` JSONL：ts/event/segments_dropped/records_expired/policy 原文转义）；`run_maintenance` 接入（策略文件存在时每轮 maintain/serve 自动执行并审计）。实测：五笔 put 跨三天桶（--partition day 自然分段）——service payments 3 天段与 level error 1 天段被整段删除、混合段（过期 payments+error 与存活 orders 同段）按段级粒度保留且过期计数入审计、dry-run "would drop 2 segments, 3 records" 零副作用、审计 JSONL 正确、maintain 自动追加审计轮次、无策略/畸形策略两场景友好处理。开发注记：core 包内调本包函数（parse_kv_pairs/slice）不能带 `@core.` 前缀（自引用报错，M120 同坑）；`is None` 模式后不能加 `?`；未使用的 trait bound（LogWriter）会被 lint 拦下
- M123 副本与高可用（3.5）：CLI 新增 `replicate <src> <dst> [--follow]`（`replicate_pass` = flush 源 + `backup_log_dir` 增量镜像——副本目录始终是 offset/游标语义完整的可用日志；`--follow` 周期同步（`MOONLOG_REPLICATE_INTERVAL` 默认 200ms），**源目录消失时该轮明确失败（`source unavailable`）而不经 ensure_dir 重建空源**——该缺陷若不修，follow 轮会在主短暂消失后把副本裁剪到空态摧毁 failover 数据；源锁被占/不可达仅 WARN 重试、状态翻转才输出）；单写者高可用语义（failover = 切目录到副本 + 停旧 replicate 进程；rebalance = 反向 replicate 增量追赶）。实测：单轮全量 50 条、follow 增量 70 条、主目录移除后副本 scan/put/search 全部正常（down_k offset 50）、反向 replicate 后主 51 条且 `get 50` 正确、正向再同步双向收敛 51=51。开发注记：MoonBit 不支持 `let f = fn() -> T raise E { }` 类型化匿名 fn 表达式（Parse error ×13）——用顶层命名函数替代；沙箱 root 下 chmod 000 模拟宕机无效（root 绕过 DAC），须用 mv 目录模拟；SIGTERM kill 丢 stdout 缓冲导致 follow 的 WARN 无法从重定向文件观测（功能正常，观测局限）；backup_log_dir 的"dst 中源端不存在的段删除"清理在源短暂消失时是数据安全风险——replicate_pass 的存在性检查是防线
- M124 热温冷分层与归档（3.6）：分层本体由 `tier` 承载（M105 已验收），本子项补**对象存储归档**等价物——CLI 新增 `archive <dir> <file> [--list] [--extract --into <dir>]`（`archive_pack`/`archive_entries`：`MLAR` 容器 magic+version+file 表+内容+尾部 CRC32，纯 CLI 文件操作零依赖，不集成对象存储 SDK——单文件 PUT 即可上传 S3/OSS/OBS）；归档应针对**主目录**（symlink 穿透读取冷段数据、MANIFEST+sidecar 齐全、解包后可直接打开），cold-dir 只含段本体不可独立恢复（README 注明）。实测：三桶 90 条 → `tier --warm 1` 后热层少 2 段（温层 compressed=true、1 段迁 cold-dir）且 **scan 90/aggregate 90/query 冷段数据全部正常（跨层透明复测）**；`archive` 打包 10 文件 9085B → `--list` 列出 → `--extract` 解包恢复副本 scan 90 条、`query --contains seq=61` 冷段命中；CRC 破坏（dd 改字节）→ `crc mismatch` 拒绝。开发注记：MoonBit 无 `Int.reinterpret_as_uint64`（用 `to_uint64()`）；UInt64 无 `to_int`——归档内容长度用 u32（现实段文件远小于 2GB）；**同轮并行编辑同一文件互相踩踏**（第一处落盘刷新 mtime 后其余被守卫拦截，FSM 却报成功——M118 守卫问题的新变体），同文件多处修改应串行或用 sed；`archive_entries` 的 raise 统一为 CLI 层 `IoError::Invalid`（MetaError 是 segment/core 包类型，跨包错误类型不兼容）
- M125 全文检索通配符与中文验证（4.1）：core 新增 `wildcard_contains`（子串语义通配匹配——`*` 任意序列/`?` 单字节/字面字符 ASCII 折叠，greedy 双指针带回溯的经典算法、模式包裹 `*` 实现子串语义，无正则引擎；UTF-8 字节级参与故中文模式字面可用，+2 单测含中文模式）与 `search --wildcard`（线性路径的匹配器替换，按 `--field` 选择 key/value/both；与 `--inverted` 互斥报错）。验收"中文与英文关键词均可命中"：中文由线性子串路径天然精确命中（冒烟 `数据库`/`连接失败`），英文线性+倒排双路径回归；通配符冒烟 `data*se`/`*TIMEOUT`+ignore-case/`查询*错误`/`查询??????错误`（字节级 `?` 的中文演示）与互斥报错全部正确。开发注记：wc_match 初版循环未先判 pattern 耗尽导致 pattern.at(p) 越界 abort（经典通配算法的 pattern-exhausted 分支须走 `*` 回溯）；子串包裹下 `?` 的精确单字节不可用 contains 否定（尾星兜底吸收）——精确性用 `err??r` 类模式断言；**python 多替换脚本对同文件原子应用**是规避并行 edit 踩踏的可靠手段（fmt 重排过的锚文本须先 cat 实际行再写替换对）
- M126 结构化过滤范围与下推（4.2）：`query` 新增 `--level-min`/`--level-max`（core 既有 `level_rank` 五级有序；范围过滤激活时要求已知 level——未知级别被排除，与字段列下推语义一致，冒烟曾暴露 linear 保留/indexed 排除的不一致后统一）；**条件下推到存储层**——①时间界下推：`query` 两条路径（线性重构为段循环、indexed 段循环）先按 `seg.min_ts`/`seg.max_ts` 判与 [since, until] 不相交则整段跳过（不解码）；②等值/范围下推：`idx_sel` 从单 `(field, value)` 扩展为 `(field, values[], also_key)`——level 范围展开为五级枚举区间内值的字段列 postings **并集**（矛盾区间空集即零结果），service/host/trace_id 等值转列表形态，全条件 AND 精滤不变。实测：`--level-min warn` linear/indexed 一致 3 条、`--level-min warn --level-max error` 一致 2 条（fatal 排除）、多维组合（level-min+service+time 窗口）一致 2 条、时间窗只覆盖单桶时另一桶数据不出现（下推跳段）、`--level bogus` 报错、宽窗口回归（修正冒烟脚本的时钟偏移——两次运行的 NOW-3d 不同导致窗口错位，非代码问题）。开发注记：`--indexed` 的 level 范围下推在数据含未知 level（verbose）时与线性路径语义不一致曾暴露（展开枚举不含未知值），统一为"范围过滤要求已知 level"；冒烟时间窗口要用宽界或数据实际 ts（时钟随运行推进）
- M127 强制时间范围（4.3）：`query` 新增**禁止无边界全表扫描**语义——无显式 `--since` 时自动降级到默认时间窗（`query_window_ms`：最近 24h，env `MOONLOG_QUERY_WINDOW_MS` 可调）并输出 `INFO query scoped to the last ...s` 提示行；`--require-time` 时无 `--since` 直接报错（附 `--since 0` 指引）；`--since 0` 是显式值不受两者影响（拒绝的是*无*时间范围的查询）。默认窗经 M126 的段级 `min_ts/max_ts` 时间下推只扫窗口内段——降级窗与下推闭环即"避免无边界全表扫描"的实意。范围决策：聚焦 `query`（结构化查询主入口）；`search` 保持线性定位（`--limit`/`--from/--to` 兜底）。实测：默认窗命中新记录且 D1/D3 旧桶被下推跳过（linear/indexed 一致 1 条）、`--since 0` 全表 5 条、`--require-time` 拒绝（含指引）、`--require-time --since 0` 正常、1h 窗排除 1 天前数据。开发注记：`query_window_ms` 返回 Int64 以与 `now_ms()` 运算（follow_interval_ms 的 Int32 是为 sleep_ms 服务）；冒烟数据超出默认窗导致 0 matches 是正确行为（建库时刻 + 1d 距今超 24h）——用"现在"写入的记录验证窗内命中

## 许可

Apache-2.0