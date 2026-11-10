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
- **多源接入**（1.1）：四类来源均可入库——**Agent 采集**（`ingest --follow` 本地文件 agent，断点续采/轮转）、**离线批量导入**（`ingest --once`）、**HTTP 推送**（`http` 服务：`POST /`/`/push` 逐行入库 + `/health`/`/stats`；SDK 直接调用 `Log::append`）、**消息队列订阅**（`ingest --fifo` 订阅命名管道，写者推送批次、跨写者持续采集；也兼容 `curl`/`kcat` 等外部桥接写入）。接入链路健壮性：HTTP 连接有**每读超时 + 10s 请求总期限**（慢/滴漏客户端不会永久占住串行 accept）、短 body 直接 400 不入库、响应半关闭后再 close 防止 RST 截断；`/stats` 暴露 `accepted`/`written`/`sampled_out` 端到端计数；FIFO 订阅收到 SIGTERM/SIGINT 时协作式退出（flush 已接收行后打印终态，不再被信号直接杀死）。
- **高吞吐写入**（1.2）：append-only 批量写入（`Log::append_batch` 每条自带 timestamp），峰值流量靠 `SyncPolicy::Batch`（批末一次 fsync）与 `--batch N` 分批提交；架构不做逐条随机更新（更新=追加新版本，tombstone 删除）。`bench-write` 现场压测并**两阶段校验无丢失**（写入进程关闭后重开：精确条数 + offset 连续 + verify_fast）。压测口径：**QPS 只计写入路径，最终持久化 flush（全量 fsync + 元数据）单列**——旧口径把这次 flush 也计入窗口，导致数值随预热/段数波动并偏低；`--warmup N` 可选预热。优化后本地参考：1000 条/批 **约 14.7 万 records/s**（final flush ≈0.86s）、5000 条/批 **约 19.3 万/s**、`--sync never` **约 28.4 万/s**、逐批 fsync（`always`）约 585/s；写入缓冲改为定长数组原地追加（消除每条记录复制 64KB 缓冲的 O(n²)），`Record::encode` 固定字段原地编码（每条少两次缓冲分配/复制）。
- **缓冲与背压**（1.3）：下游过载时**缓冲而非丢弃**——HTTP 推送端点用有界入站队列（`--queue` 行数上限 + 可选 `--queue-bytes` 字节预算）：入队成功返回 **202**（含 pending），队列或字节预算满返回 **429 + Retry-After**（客户端重试，无静默丢数据）；后台按 `--batch` 行分批落库，**有积压时全速连续 drain**（消除每批等 200ms accept 的节拍；drain 用 Batch 持久化，每 `--batch` 一次 fsync），积压超 `--backlog-alert` **进入时打印一次 `WARN backlog`、排空后打印一次 `RESOLVED`**（含持续 ms 与峰值，避免按批刷屏）；`/stats` 暴露 `pending`/`pending_peak`/`pending_bytes`/`backlog_alerts`/`rejected_requests`/`rejected_lines` 与 `accepted`/`written`/`sampled_out`，关闭时打印同口径终态。**SIGTERM/SIGINT 优雅关闭**在退出前清空队列；慢客户端由每读 5s 超时 + 10s 请求总期限兜底。实测：3000 行积压 **109ms 排空**（旧实现 4s+）、一次积压仅 1 条 WARN + 1 条 RESOLVED、字节预算 429 后拆小重试 **1000/1000 条零丢失**、SIGTERM 立即关闭仍全量 drain 3000 条。FIFO 订阅侧由内核管道满自动反压写者。
- **幂等与重放**（1.4）：两种去重语义共存——①**内容幂等** `--idempotent`（`put`/`ingest`/`http`）：待写记录的 (key, value) 与该键最新 live 记录完全一致时**识别为重复投递并跳过**（O(1) 骑乘增量 key 索引）；②**显式唯一 ID 去重** `--dedup-field <name>`（`ingest`/`http` 从解析字段取 ID）与 `--dedup-id <id>`（`put`）：已见 ID 一律跳过，**即使同一 ID 的 payload/value 已变化**，修复内容幂等对"同 key 同内容的不同事件"的误去重。已见 ID 持久化在 `<dir>/DEDUP`（`<offset>\t<id>`），每条去重记录把 `__uid=<id>` 内嵌进 value，**DEDUP 只是缓存**：启动时读 sidecar 并扫描其未覆盖的日志尾部补齐，删除/截断 DEDUP 后仍能重建（实测删掉 sidecar 后重放仍 0 新增）。重放文件（`ingest --from 0`）、HTTP 429 重试、批次重投均不产生重复日志：实测 2 行重放 `2 duplicates skipped` 零新增；同 key 交替重放 e1/e2 也 0 新增（不依赖 latest-wins 单条窗口）；对照：同 key 同 value、不同 ID 的两条事件在内容幂等下被误去重为 1 条，唯一 ID 下正确写入 2 条。断点续传（采集位点命名游标）与此互补：位点内不重读、位点外的重复投递靠 ID 兜底。
- **源头采样限流**（1.5）：`ingest`/`http` 的采样管线（core `SamplingConfig` + `sampling_allows`，单测覆盖）——**按级别** `--min-level debug|info|warn|error|fatal`：`kv`/`json`/`template` 取 `--level-field` 字段，**纯文本 `lines` 也从原始行识别** `level=warn` / `level:"warn"` / `"level":"warn"`（未知级别不参与过滤），**按比例** `--sample-rate 0-100`（FNV-1a 确定性哈希，同内容判定恒定、与幂等重放一致；小样本存在哈希偏差属预期），**按规则** `--include`/`--exclude`（原始行子串，ASCII 忽略大小写）。采样在源头执行：`ingest` 输出 `(N sampled out)`，HTTP 在入站按规则过滤一次（202 响应含 `sampled_out`），**drain 不再重复采样**（`skip_sampling`），因此 `accepted == written` 可与 `sampled_out` 直接对账。实测：lines 400 行（debug/info/warn/error 各 100）`--min-level warn` → **200 写入 / 200 sampled**；`--sample-rate 0/50/100` → 0/215/400 且两个独立目录的 50% 结果完全一致；HTTP 入站 min-level warn → accepted=written=200、sampled_out=200；kv 与 FIFO 路径回归一致；非法 `--sample-rate 101` 显式报错。
- **结构化解析**（2.1）：`ingest`/`http` 支持 `--format json|kv|template`，另加只读校验工具 `parse-check`——JSON **递归展平嵌套对象**为点号字段（`request.user_id`），数字/布尔/null 转文本、数组紧凑序列化；`--template` 为**受限 Grok 子集**（零依赖、无回溯引擎）：`<name>` 保持"捕获到下一字面"的兼容语义，`<name:pattern>` 支持单个字符类 + 量词（`\d+`/`\w+`/`\s+`/`\S+`/`.`/`[^...]`/`[a-z]`，`?`/`*`/`+` 及 `+?` 非贪婪），贪婪模式回溯到下一个字面；`parse-check <file>` 逐行报告提取字段并汇总准确率（`parsed/lines`、空字段数，`--json` 可机读）。实测：nginx combined 2/2 行、8/8 字段 **100%**；JSON 嵌套 `request.user_id`/`request.path` 正确展平；畸形 JSON 计入 failed（准确率 66%）；`--json` 输出可被 `json.loads` 解析；`ingest` 用同一模板入库字段与 parse-check 一致。
- **统一 Schema**（2.2）：`ingest`/`http` 的 `--schema` 将解析出的字段归一到**六大基础字段**——时间戳（`ts`/`@timestamp`/`timestamp`/`time`）、级别（`level`/`severity`/`severity_text`/`lvl`）、服务名（`service`/`service.name`/`serviceName`/`service-name`/`app`/`application`/`svc`）、主机（`host`/`host.name`/`hostname`/`node`）、trace_id（`trace_id`/`trace.id`/`traceId`/`trace`）、消息（`message`/`msg`/`log`/`body`；core `canonical_field` 先对字段名做**大小写与 `.`/`-`/`_`/`@` 分隔符归一**再匹配，单测覆盖）：**服务名提升为记录键**、标准字段按固定顺序重组为 value（`level=… host=… trace_id=… message=…`）、时间戳取自解析值——不同服务的字段命名习惯（含 OTel 嵌套 `service.name`/`trace.id`/`host.name`）入库后口径一致；**联合过滤查询** `query`（`--level`/`--service`/`--host`/`--trace-id`/`--contains` AND 组合 + `--since`/`--until` 时间窗 + `--limit`/`--json`；core `schema_matches` 单测覆盖）的**值比较大小写不敏感**，level 还识别 warn/warning 同义——`--service ORDERS --level ERROR` 可命中 `orders`/`error` 记录，`query --trace-id t9` 一次关联多个服务的同一链路；非 schema 记录仍可按 key/contains 过滤，混合目录可查。`parse-check --schema` 可先离线校验归一结果（输出 `schema N fields`）。
- **时间规范化**（2.3）：采集端时间值经 core `normalize_ts` 归一到 epoch 毫秒——纯数字按位数识别精度（秒 <1e11 / 毫秒 <1e14 / 微秒 <1e17 / 纳秒），其余按 **ISO-8601 扩展形态**解析：`YYYY-MM-DD` 或 `YYYY/MM/DD`、`T`/空格分隔、**秒可选**（`HH:MM`）、小数秒 `.` 或 **`,`**（Java/log4j）截断到毫秒、时区支持 `Z`/`z`、`±HH:MM`、`±HHMM`、`±HH` 与 ` UTC`/` GMT`（大小写不敏感）——**跨时区同事件归一到同一时间戳**；`ingest`/`http` 的 `--clock-skew <ms>` 补偿采集端固定漂移，新增 `--clock-skew-field <name>` 从每条记录的字段读取**每源偏移**并与全局偏移叠加（多 agent 不同漂移场景）；append-only 保留到达序，`query --sort-by-time` 按**事件时间**排序输出（tie 保持 offset 序）——实测乱序到达 `e4 e2 e5 e1 e3` 排序为 `e1 e2 e3 e4 e5`，跨 `+08:00`/`-05:00`/`Z` 一致；展示层统一 UTC。
- **脱敏与字段富化**（2.4）：`ingest`/`http` 的 `--mask` 在**写入前**对每条 value 做单遍扫描掩码（core `mask_sensitive`，无正则引擎、未命中字节逐个保真）——敏感字段名（`token`/`password`/`secret`/`api_key`/`authorization`/`session`/`cookie` 等内置词表 + `--mask-fields` 自定义，ASCII 忽略大小写）值段整体 `[REDACTED]`，**同时识别 `name=value` 与 JSON 的 `"name":"value"`/`"name": "value"`**（引号值截到闭合引号，含空格也完整掩码）；已知令牌前缀 `sk-…`（OpenAI/Anthropic）、`AKIA…`（AWS access key）、`ghp_…`/`github_pat_…`（GitHub）、`xox?-…`（Slack）整段 `[REDACTED]`；`Bearer <token>`（≥8 字符）与 JWT（`eyJ` 前缀双点）→ `[REDACTED]`；11 位手机号（1[3-9]）保留 3+4（`138****5678`）；15 位/17 位+X 证件号保留前 3 后 4；≥20 位连续 hex（md5/sha1/sha256）→ `[REDACTED]`（UUID 段、纳秒时间戳不误伤）；`--meta env=prod,region=cn-north,version=x` 在写入前为每条记录追加部署元数据（环境/版本/地域富化）。掩码作用于幂等去重之前，重复投递判定一致。实测：JSON 推送与 `--format json` 的 `token/password` 明文 `search` 均 0；`sk-`/`AKIA`/`ghp_`/`xoxb-` 独立出现均被掩而 `disk-usage-report-2026` 保留；schema 模式下 token/phone 字段被六字段丢弃（双保险），message 内嵌的令牌/手机号仍被掩；kv/lines/HTTP 四条路径零明文。
- **热温冷分层存储**：`tier` 将已 roll 段原地压缩（温层），把更旧的段迁入独立目录并以 symlink 原子占位（冷层）——活跃段恒为热层；读、校验、修复、备份经链接透明工作，段被回收时冷副本联动删除（依赖 POSIX symlink）。
- **按时间分区**（3.1）：`put`/`ingest`/`http` 的 `--partition day|hour|off` 开启时间分区——append 路径在记录的时间桶（core `time_bucket`，epoch 对齐）与活跃段桶不同时**自动滚动创建新段**，同桶数据聚成段运行（迟到数据开自己的段）；单段大小仍受 `roll_size` 控制，分区+段两层大小可控。**目录级策略持久化**：`partition-policy <dir> [day|hour|off]` 写入 `<dir>/PARTITION`，写命令不带 `--partition` 时自动沿用（显式 `--partition` 仍覆盖，`off` 可临时关闭）；漏带参数不再静默退化为纯字节滚动（旧行为会把跨天数据混进一个段、分区视图与过期淘汰都失真）。`partitions` 视图按 `--unit day|hour` 展示每分区段数/记录数/字节/UTC span 并显示当前 policy（可选 JSON）；过期清理沿用整段回收（`prune-before`/`prune-expired`）——分区对齐时即整分区淘汰，清理只触碰被回收的段文件，读者（共享锁）永不被阻塞。实测：策略 day 后不带 `--partition` 的 ingest 跨天 → **2 桶**（旧 1 桶混合）；显式 `off` → 1 桶、显式 `hour` 覆盖 day → 2 小时桶；`prune-before` 删旧日段（dropped 2）后仅剩 day2 且 scan 正确；`partition-policy ... off` 关闭策略。
- **倒排 + 列式索引**（3.2）：段级 `InvIndex`（segment 包）双 posting 列表——**词倒排**（key/value 的 ASCII 词 token，小写折叠，`tokenize` 词法；单 token ≤32 字节、每记录 token 数有上限）与**字段列**（`name=value` 精确对 + `__key__=<key>`），lazy 构建并持久化为 `<base>.log.inv` sidecar（CRC 校验）。**查询进程构建后立即原子落盘**（M153）：首次 indexed 查询在共享读锁下构建并 `save_segment_inv`（tmp+fsync+rename，不暴露半写文件），后续进程直接加载 sidecar——4 万条实测首次 **0.96s**、跨进程 **0.45s**（旧行为每次重建 ~0.8s、甚至慢于线性 0.76s）；`maintain`/`serve` 仍可预建；sidecar 缺失/损坏/段内容变化时自动重建。`search --inverted` 词级全文匹配（**词命中语义，不同于线性子串**）、`query --indexed` 用第一个等值过滤（level/service/host/trace_id）经字段列预筛后全条件 AND 精滤（service 经记录 key 并集）。**sidecar 生命周期**：删段（purge/compact/merge）删除 `.inv`、`quarantine_segment` 将其改名为 `.inv.corrupt`、repair 截断段后删除陈旧 `.inv`——避免幽灵命中与每次重建。基准（2000 条、10% 命中）线性 2.69ms vs 列索引 167ns；4 万条 indexed 与线性输出逐字节一致（37 命中）。
- **列式数据压缩**（3.3）：`.inv` sidecar 双压缩（sidecar v3）——①postings 列 **delta + varint（LEB128）**：严格递增 record index 的差多为一字节（vs 定长 4 字节）；②**front coding 前缀压缩**：terms/fields 的 key 按字典序排序，每条只存"与上一条的共享前缀长度 + 剩余后缀"（`trace_id=t12345` 系列、`evt-123`/`t123` 系列共享长前缀），不再重复完整 key。**实测 4 万条 schema 数据**：`.inv` 总大小 **3,758,004B → 1,452,624B（−61.3%，约 2.6x）**；加载时解码回内存 map，索引查询跨进程 **0.43s**（v2 0.45s、线性 0.76s，未变慢且略快；首次构建 1.1s 一次性）；indexed 与线性输出逐字节一致（37 命中）。旧 v2/v1 sidecar 被精确版本检查拒绝后**删除并 lazy 重建为 v3**（升级自动自愈，不再每次重建；CRC 失败同样处理）；500 条密集列单测仍 <15KB；行式段级 RLE/LZSS（`stats`/`compress`）此前已覆盖。
- **生命周期 TTL**（3.4）：`<dir>/TTL` 策略文件——`default <days>` / `service <name> <days>` / `level <level> <days>` / `prefix <p> <days>`（`#` 注释、畸形行**整文件拒绝**）：对每条记录，service 匹配记录键（项目）、level 匹配解析的 level 字段，**service/level 与 `Level=` 字段名均按 ASCII 大小写不敏感匹配**（`service Orders 1` 命中 key `orders`、`level ERROR 2` 命中 `error`；prefix 保持字节精确），双命中取更严、无命中用 default（default 缺省且无命中 = 永不过期，days=0 即刻过期）；`ttl-expire [--dry-run] [--json]` 评估并**整段回收记录全部到期的段**（段级粒度——混合段等全部到期后回收，配 `--partition day` 让同日/同服务数据聚段；dry-run 只打印计划零副作用且不审计；`--json` 输出 `segments_dropped`/`records_expired`/`audited` 便于自动化），应用运行将清理动作追加 `<dir>/TTL_AUDIT` JSONL 审计（ts/event/**trigger=cli|maintain**/segments_dropped/records_expired/policy 原文）；`maintain`/`serve` 管线在策略文件存在时**自动执行**并逐轮审计。实测：`service Orders` 命中小写 `orders` 记录（删 1 段）、`level ERROR` 命中 `error`（删 1 段）、default/未命中保留；dry-run `--json` 不删不审计；CLI 与 maintain 审计分别记录 `trigger=cli`/`maintain`。
- **副本与高可用**（3.5）：`replicate <src> <dst> [--follow]` 把源日志**增量镜像**为完整副本目录（同 `backup` 引擎：mtime 增量 skip、源端删除传播、sidecar/manifest 恒重拷；副本 offset/游标语义完整保留，可直接读写）——`--follow` 按周期（默认 200ms，`MOONLOG_REPLICATE_INTERVAL`）持续同步；**源目录消失时该轮明确失败而不重建空源**（防 follow 误清副本上的 failover 数据）。**角色与自动切换**：`<dir>/HA_STATE`（`role=primary|standby` + switched_at/from）标记目录角色；`ha-failover <primary> <replica> [--active <link>]` 把副本提升为 primary、把可达旧主标为 standby，并用 `--active` **原子重指稳定 symlink**（tmp+rename，客户端只需一个固定路径）；`ha-watch <primary> <replica> --active <link> [--interval] [--fail-threshold]` 连续 N 次探测不到主目录即自动执行 failover 后退出（交给 supervisor 重启）；`ha-status --json` 查看角色/可达性/切换时间；`ha-rebalance <old> <new>` 反向镜像（以新主为准）并把旧主标为 standby。**防误删**：`replicate` 检测到目标是 `role=primary` 时拒绝正向同步——主恢复后旧 follow 的一轮不会再把副本上宕机期间的新写段裁掉（实测旧行为 12→10 丢失 2 条，修复后保持 12）。实测：镜像 10 → 宕机期副本写入 12 → failover 后旧同步被拒（12 保持）→ 通过 active symlink 写入 13 → rebalance 旧主追平 13 → `replicate R→P` 允许、`P→R` 拒绝 → ha-watch 主存活不切、主消失 3 轮后自动切并更新 active。定位：目录级副本 + 单写者语义（无 leader 选举/共识），自动切换为受监督的进程/脚本，不构成分布式一致性。
- **全文检索：关键词/短语/通配符/中文**（4.1）：`search` 线性路径对 key/value 做**子串语义**匹配（`--field both|key|value`、`--ignore-case` 折叠 ASCII；短语即连续子串，天然精确）——`--wildcard` 支持 `*`/`?`（字节级，见 M125 说明）；`--inverted` 走 ASCII 词级倒排（token AND）。**短语与中文自适应路由（M158）**：查询含空格（短语）或非 ASCII（CJK）时改走精确线性子串路径——倒排 posting 无位置信息、无法校验相邻/顺序，直接 AND 会假阳性（`user login` 曾命中 `login failed for user bob`，2 条 vs 线性 1 条）；英文单 token 仍走倒排词级。**中文分词（零依赖）**：`tokenize` 对非 ASCII 文本按 UTF-8 **字符 unigram** 入索引（`INV_VERSION` v4，无需词典/jieba），旧 sidecar 自动重建；中文查询精确命中（`数据库`/`数据库连接`），非相邻词不误报（`数据失败` 0）。实测：4 万条中文 `--inverted 数据库连接` 20000 命中、**0.244s**（与线性一致；倒排候选+精滤版 0.444s，故路由线性更优），`login` 词级倒排 2 命中不变。
- **结构化过滤：范围与下推**（4.2）：`query` 的 `--level-min`/`--level-max`——按严重度有序范围过滤（core `level_rank` 五级 debug<info<warn<error<fatal，与 `--level` 精确可 AND 组合；**范围过滤要求已知 level，未知级别被排除**，与字段列下推语义一致）；**组合条件下推到存储层**（M159 强化）：①时间界 `--since`/`--until` 经段级 `min_ts`/`max_ts` **跳过不相交段**（不解码，线性与 indexed 均生效）；②`--indexed` 下**每个等值/范围条件都下推**——各条件展开为段内字段列 postings 并集（level 范围枚举区间值；service 同时匹配记录 key），**任一条件在段内无 posting 则整段跳过**，多个 posting 中取**最短**作为候选集再做全条件 AND 精滤；③`--explain` 输出 `(pushed level,service,host; candidates N; segments_skipped M)`，可直接审计下推是否在存储层执行。实测 4 万条：`--level error --service svc3 --host h7` → pushed `level,service,host`、候选 **2087**（旧只按 level 预筛 8021）、42 命中与线性一致；`--level-min warn --level-max error --service svc3` → 4082 候选/1625 命中；`--until 1` → segments_skipped 4、0 候选；不存在的 trace_id 组合 → 0 候选（任一 posting 空即整段跳过）。
- **强制时间范围**（4.3）：**`query` 与 `search` 均禁止无边界全表扫描**——无显式 `--since` 时自动**降级**到默认时间窗（最近 24h，`MOONLOG_QUERY_WINDOW_MS` 可调）并输出 INFO 提示；`--require-time` 时无 `--since` 被**拒绝**（报错并指引）；`--since 0` 是显式全表（不受降级/拒绝影响）。`search` 新增 `--since/--until` 时间界（`--from/--to` 仍是 offset，两者可组合），**线性与倒排两条路径都按记录事件时间过滤**；`query --json` 时默认窗 INFO 被抑制，输出保持纯 JSON（修复此前 INFO 行污染管道）。默认窗经 4.2 的段级时间下推只扫窗口内段（窗外段不解码）。范围决策：`aggregate/trend/dashboard` 等分析命令有各自 `--last`/时间窗下推，不再叠加默认窗。实测：`search` 默认窗只命中新记录（2 天前旧数据排除）、`--require-time` 拒绝、`--since 0` 全表 3 条、`--since 0 --until <new_ts>` 精确取旧 2 条、`--inverted` 同样受窗约束（1 条 vs `--since 0` 3 条）、`MOONLOG_QUERY_WINDOW_MS=1` 0 条；`query --json` 首行为 JSON；4.1 关键词/短语/中文/通配回归不变。
- **上下文检索：同请求/同线程关联**（4.4）：`context` 的 `--trace-id <id|auto>`、`--thread-id <id|auto>` 与 `--service <svc>` 关联过滤——上下文只取与锚点**同 trace / 同 thread（`auto` 从锚点提取）/ 同服务**的记录，**不匹配的交错记录跳过且不占名额**（offset 序连续可读），多关联键之间为 AND；**`auto` 提取支持 KV 与 JSON/OTel 字段名**（`trace_id`/`traceId`/`trace.id`、`thread_id`/`threadId`、`service` 按大小写与分隔符归一，2.1 展平），不再因 JSON 记录静默退化为物理窗口；`--sort-by-time` 在收集窗口后按**事件时间**排序（tie 保 offset 序），乱序到达时也能还原正确现场；无关联选项时保持 M106 的物理前后 N 条语义。service/trace/thread 值比较按 ASCII 大小写不敏感。实测：A/B 交错锚定 A → A 完整 4 条；**JSON 记录 `{"trace_id":"tJ"}` 锚点 → 2 条**（旧混入 A）；`--thread-id auto` → 4 条；**`--sort-by-time` 输出事件时间序 0→4→2→5**（默认 offset 序 0→2→4→5）；越界报错；无关联 M106 回归 5 条窗口。
- **热温冷分层与归档**（3.6）：分层本体由 `tier <dir> <cold-dir> [--warm N] [--dry-run] [--json]` 承载——温层 LZSS 原地压缩、冷层旧段复制到 cold-dir 后 symlink 原子替换主路径，读/查/校验/归档经链接透明；**cold-dir 必须绝对路径**（相对路径会让链接相对主目录解析成悬空、段不可读——修复前实测 40000 条只读到 16477，现在 CLI 与 backend 双重拒绝）。**LZSS 匹配改为 3 字节哈希链**：旧实现只线性回扫最近 64 个位置，日志行间距 ~89B 匹配不到、压缩后反而膨胀 2.6%；修复后 20k 条文本 2.52MB → **0.874MB（−65.3%）**，已 roll 段 1MB → 228KB（**4.6x**），解压 20000 条全一致；无收益段保留原样。`stats` 的 `disk_bytes` 改为**实际文件大小**（跟随冷层链接；旧值用逻辑长度掩盖收益）。`archive <dir> <file> [--list] [--extract --into <dir>]` 打包 MLAR 单文件（对象存储等价物，零依赖），**包含 AUDIT/TTL_AUDIT 审计文件**（合规证据）；归档应针对主目录（symlink 穿透冷段）。实测：90 条三桶 tier 后 scan/aggregate/query 透明（冷桶 30 命中），归档 12 文件（含审计）恢复后可查 90 条。定位：hot=活跃段、warm=LZSS、cold=symlink 指向可更换的廉价路径/设备（后续单文件 PUT 对象存储）。
- **日志检索**：结构化键查询（`get_many`/`get_latest`/`scan_prefix`/`scan_key_range`）；**全文检索** `search`（线性扫描 key/value 子串，支持字段选择、ASCII 忽略大小写、limit、offset 区间）；**上下文关联检索** `context`（按 offset 取前后 N 条，自动 clamp 并跨段）。
- **日志分析**：**多维聚合统计** `aggregate`（key/value/kind/UTC 时间/键前缀/`--kv-field` 字段维度，top-N，可选 JSON）；**错误自动聚类** `cluster`（数字/十六进制/引号串归一化为模板后按形态计数，变量内容自动折叠）；**趋势可视化** `trend`（UTC 分钟/小时/天分桶 + 文本直方图）。
- **告警监控**：**阈值告警** `alert`（按 UTC 窗口计数对比阈值）；**异常基线检测** `baseline`（窗口计数的均值/标准差 z-score，超 sigma 标记异常）；**多渠道通知分发**（stdout / `--notify-file` JSONL 追加 / `--webhook` 经 curl POST 且失败降级不中断）。
- **运维管理与 RBAC**：`rbac` 以 `<dir>/RBAC` 规则文件（`role=<name> token=<token> allow=<cmds|*> [scope=<prefix>]`）控制命令访问——文件存在时除 `rbac init`/`rbac check` 外均需 `MOONLOG_TOKEN` 且角色允许该命令，拒绝事件写入 `<dir>/AUDIT`；无 RBAC 文件时保持开放（向后兼容）。定位说明：本地 CLI 的**防误操作与审计**手段，进程可绕过文件，不构成多租户强隔离。
- **操作审计**（6.3）：`<dir>/AUDIT` JSONL 留痕——**查询/导出/删除维护/配置变更四类命令**执行前自动记录 `{ts, actor, action, decision, target}`：actor=MOONLOG_TOKEN 匹配的 RBAC 角色（token 本身永不落盘；无 RBAC 的本地模式为 `local`、未匹配 token 为 `unknown`），target=参数摘要（截断 200 字符，`rbac add`/`init` 的 token 打码），越权拒绝同格式记 `deny`——关键操作可定位到人与时间。启用条件：`AUDIT` 或 `RBAC` 文件存在（本地单用户 `touch AUDIT` 显式开启，未开启零行为变化）；`rbac init` 总是留痕。写入为 **O_APPEND 原子追加**（新增 stub）——多进程并发不丢不串，替代旧读改写；`AUDIT`/`TTL_AUDIT` 命名刻意避开 `.log` 后缀——recover 曾把 `AUDIT.log` 当段文件截断（已修：recover 只认 `<16 位数字>.log` 规范段名，旧审计文件首次使用时自动改名迁移保留历史）。范围：put/put-batch/ingest 等写入不审计（数据本身即日志）；QUOTA/TTL 策略文件为手动编辑，运行效果由 TTL_AUDIT 与 deny 审计覆盖。实测：19/19 冒烟——四类操作全留痕、actor/ts 可定位、token 不落盘、并发 3 进程 3 事件、旧文件迁移、未开启不产生文件。
- **自监控**（6.4）：`selfmon <dir> [--json]` **独立健康巡检**——不依赖业务进程存活，一轮扫描输出 `STATUS=ok|warn|crit`（cron/grep 友好）与四维指标：①**磁盘水位**（statvfs 新 stub：fs used%/剩余字节 + `dir_log_bytes` 目录段字节，WARN≥80% CRIT≥90%）；②**写入积压**（http writer 以 1s 节流原子快照写 `<dir>/SELFMON/http.json`：pending/队首滞留 ms/backlog 告警计数，selfmon 读快照按阈值判定——优雅关闭写终态 pending=0，**writer 崩溃（kill -9）残留积压被 selfmon 发现**）；③**采集停滞**（最新段 mtime 年龄 ≥ 阈值且快照显示 writer 活跃 → 告警——数据不动但进程活着；空闲目录不误报）；④**查询失败率**（所有 CLI 命令失败的统一落点 main catch 追加 `<dir>/SELFMON_ERRORS` JSONL，selfmon 按窗口计数，分母对账 AUDIT allow 事件；**配额拒绝（6.2）不计入**——预期租户行为非故障）。阈值经 `MOONLOG_SELFMON_*` 可调（DISK_WARN_PCT/DISK_CRIT_PCT/BACKLOG_WARN/LAG_WARN_MS/STALE_MS/FAILS_WARN/WINDOW_MS/ACTIVE_WINDOW_MS）。`--json` 输出单行结构化结果。边界：selfmon 为诊断类命令——不在审计白名单、RBAC 下需 admin/allow=selfmon 角色；深度数据校验归 `fsck`，ingest 位点滞后归 `cursor-lag`。实测：20/20 冒烟——磁盘 warn/crit 触发、优雅关闭与崩溃残留积压分别 ok/warn、失败留痕与配额过滤、停滞告警与空闲不误报。
- **备份与恢复演练**（6.5）：备份/恢复/归档**全量携带配置与索引**——`is_backup_file`（backup/restore/replicate 共用）与 `archive_file_names`（MLAR 归档）扩展为 MANIFEST + 段 + `.index`/`.keys`/`.inv` sidecar + **策略文件 RBAC/TTL/QUOTA**（恢复副本连同配置一体还原，LOCK/游标/AUDIT 等运行态仍不进备份）；新增 **`drill <dir> [--keep]` 一键恢复演练**——备份到临时目录 → `restore` 到第二临时目录 → `verify_fast` 完整性校验 → 记录数/offset 对账 → 配置逐字节一致性 → 首尾记录 spot 读验证 → `DRILL status=ok|fail` 报告 → 临时目录清理（`--keep` 保留现场），源目录全程只读（独占锁内 flush 后仅备份、共享锁内对账），演练操作进 `AUDIT` 留痕。实测：20/20 冒烟——drill status=ok（records 3/3 对账、spot ok、config ok、临时清理、幂等、--keep）、backup/restore 四类文件齐备且配置逐字节一致、恢复目录 RBAC scope 查询正常、.inv 备份恢复 1/1 且 indexed 查询在位、archive 提取配置在位且数据可查、drill 审计留痕。
- **归档导出与合规删除**（6.6）：`export-jsonl` 加**查询过滤**——`--prefix <p>`（key 前缀）/ `--match <text>`（key/value 子串）/ `--from/--until <ms>`（时间窗），任意查询结果直接导出为**通用可解析 JSONL**（每行含 offset/timestamp/kind/key/value，`python json.loads` 逐行可验证；位置参数 `text|base64` 向后兼容）；新增 **`purge <dir> <prefix> [--into <file>]` 合规删除闭环**——`--into` 删除前把匹配记录导出为留存副本 → 匹配 live key 写 tombstone → `compact` **物理压实**（被删记录与 tombstone 一并移出段文件）→ **压实后前缀扫描验证 0 残留** → `PURGE status=ok|fail` 报告（exported/deleted/compacted/verified 明细）；purge 进审计白名单（删除类操作留痕），offset 重排需重置游标（报告含提示）。实测：18/18 冒烟——前缀/子串/时间窗过滤导出各自计数正确、导出与留存文件逐行 JSON 可解析、purge 后前缀扫描 0 命中且单键 getkey 无数据、其他前缀数据完好（2 records）、全库 7-3=4 对账、重复 purge 幂等、审计留痕（本地模式 touch AUDIT opt-in 后）。
- **配额管理**（6.2）：**租户 = RBAC 角色**，配额定义在 `<dir>/QUOTA` 策略文件（`role=<name|default> write-bytes=<n> storage-bytes=<n> query-concurrent=<n> retain-days=<n>`，缺省字段不限）：**写入量**按 1h 滚动窗口限制角色写入字节（用量持久化在 `<dir>/QUOTA_STATE/<role>.write`，**重启不重置**，超限显式拒绝——put/put-batch/ingest 报错、HTTP 429 + `tenant write quota exceeded`）；**存储量**限制该角色占用的段数据字节（`*.log` 实时统计 + 待写字节超限拒绝）；**查询并发**在全局槽（4.6 QLOCK）之下加租户专属槽 `QLOCK.<role>.<i>`（先全局后租户，两级限流防单租户占满池）；**保留天数**按角色 scope 前缀经 TTL `prefix` 规则生效（与 TTL 文件取更严者，配额只能收紧不能延长）。`rbac add` 支持可选 `scope=<prefix>` 参数；HTTP 推送在 RBAC 生效时强制 `Authorization: Bearer <token>`（匿名/坏 token 401、无 put 权限 403、`/health` 探活保持开放、`/stats` 需有效 token），202 记账在入队时（落盘由 drain 完成，skip_quota 不重复记账）；无角色归属的调用方（匿名推送、开放本地模式）受 `role=default` 行兜底。`quota <dir>` 列出策略与当前窗口用量。实测：tenant-a 写满窗口后 CLI 拒绝且 tenant-b 不受影响、存储超限拒绝、HTTP 匿名 401/超配额 429/合法 202、flock 占满租户槽后该租户 query 被拒（释放后恢复）、tenant-a 8 天旧段被按 retain-days=7 回收而 tenant-b（30 天）保留。
- **修复模式**：`fsck --fix`（`repair_log_dir`）隔离整段校验失败的段（改名 `.corrupt` 保留证据）、截断损坏尾部、重建缺失/损坏的 MANIFEST 与段 sidecar。
- **尾随读**：`follow` 持续打印新追加的记录（`tail -f` 语义），支持从持久化游标续读并 `--commit` 自动提交；发布观察/线上调试的过滤（`--match`/`--level-min`/`--service`）同时识别 KV 与 JSON 结构化值，持续流立即续轮，终态报告过滤数与最大实时滞后（4.5）。
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

  put <dir> <key> <value> [--ts <ms>] [--idempotent] [--dedup-id <id>]
      [--partition day|hour]
                                追加一条 key/value 记录（`--dedup-id` 为显
                                式唯一 ID：重复 ID 即使 value 不同也跳过；
                                `--partition` 开启按天/小时时间分区，跨桶
                                自动滚动新段）
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
                                应用运行的清理动作追加到 TTL_AUDIT
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
            [--match <text>] [--level-min <lv>] [--service <svc>] [--flush]
                                持续打印新追加的记录（`-` 从持久化游标续读，
                                `tail` 从当前末尾开始；`--commit` 每批后提交
                                游标，`--name` 指定命名游标以支持多消费者各
                                自 follow/提交；`--json` 以单行 JSON 输出
                                （UTF-8 文本，与 export-jsonl 同构）；`--once`
                                拉取一轮即退出；轮询间隔可用
                                `MOONLOG_FOLLOW_INTERVAL` 调整，默认 200ms）；
                                live-debug 过滤（4.5）：`--match`（key/value
                                子串）、`--level-min`（严重度下界，未知级别
                                排除）、`--service`（记录键或统一 schema 的
                                service 字段，大小写不敏感）——只收窄打印
                                流，游标照常推进（被过滤记录视为已消费）；
                            字段过滤同时识别 `k=v` 与 JSON 值（按 2.1 展平，
                            含 `severity`/`svc` 等别名，level 大小写不敏感）；
                                 `--flush` 逐条刷新 stdout（管道/重定向观测
                                 实时输出）；持续有新记录时立即续轮（1ms
                                 让出）而不空等轮询间隔；SIGTERM/SIGINT
                                 优雅退出并打印终态
                                 `(N records, cursor C; F filtered, max lag Lms)`
  ingest <dir> <file> [--follow] [--once] [--fifo]
                    [--format lines|kv|json|template] [--template <tpl>]
                    [--key <name>] [--key-field <name>] [--value-field <name>]
                    [--ts-field <name>] [--from <bytes>] [--batch N]
                    [--interval ms] [--idempotent] [--dedup-field <name>]
                    [--min-level <level>]
                    [--level-field <name>] [--sample-rate 0-100]
                    [--include <text>] [--exclude <text>] [--schema]
                    [--clock-skew <ms>] [--clock-skew-field <name>] [--mask]
                    [--mask-fields <csv>]
                    [--meta <csv>] [--partition day|hour]
                                采集外部日志文件：每行按格式解析为字段并写入
                                （`lines` 默认整行为 value；`kv` 解析空格分
                                隔 name=value 对；`json` 解析顶层 JSON 对象
                                字段；`template` 按 `--template "<a> <b>"`
                                的字面+`<name>` 占位符提取——轻量 Grok 等
                                价，不含正则）；`--key-field` 字段提升为记
                                录键、`--value-field` 字段作为 value（缺省
整行）、`--ts-field` 从字段取时间戳；`--idem
                                potent` 内容幂等去重；`--dedup-field <name>`
                                唯一 ID 去重（该字段已见则跳过，ID 持久化在
DEDUP，payload 变化也不重复）；`--min-level`/
                                 `--sample-rate`/`--include`/`--exclude`
                                 源头采样限流（按级别可读解析字段或纯文本
                                 行内 `level=warn`）；
                                 `--schema` 统一六字段（服务名提升为键、标
                                 准字段重组 value、别名归一，详见下 `query`）；
`--clock-skew <ms>` 为全部记录时间戳加固定
                                偏移（校正采集端时钟慢/快）；`--clock-skew-
                                field <name>` 从每条记录字段读取每源偏移并
                                叠加（多 agent 不同漂移）；时间值自动识别
                                秒/毫秒/微秒/纳秒与 ISO-8601 扩展形态（2.3）；
                                 `--mask` 写入前脱敏（敏感字段名/Bearer/JWT
                                 →[REDACTED]，手机号/证件号保留前 3 后 4，
                                 长 hex→[REDACTED]；`--mask-fields` 追加敏
                                 感字段名）；`--meta k=v,k2=v2` 为每条记录
                                 追加部署元数据（环境/版本/地域富化，2.4）；
                                 `--partition day|hour|off` 按时间分区（跨
                                 桶自动滚动新段；缺省沿用
                                 `partition-policy` 持久化的 PARTITION 策略，
                                 显式参数覆盖；旧分区可经 prune-before 整段
                                 淘汰，3.1）；
                                `--once` 导入到当前末尾即退出，`--follow` 持
                                续跟踪追加（半行留待下轮、截断/轮转自动从零
                                重采）；`--fifo` 改为订阅命名管道（写者推送
                                批次，跨写者持续采集，SIGTERM/SIGINT 时
                                flush 后打印终态并干净退出）；采集位点以命名游标
                                `ingest-<basename>` 持久化，重跑自动续采
                                （`--from` 可覆盖），`--batch` 控制每批写入
                                条数（默认 256）
  parse-check <file> [--format lines|kv|json|template] [--template <tpl>]
              [--sample N] [--json] [--schema]
                                用与 ingest 相同的字段提取器解析样例文件：逐
                                行打印 `name=value` 字段，汇总 parsed/lines
                                准确率与空字段数；只读，用于入库前校验模板/
                                JSON 形状（`--json` 输出可机读）；`--schema`
                                额外输出六字段归一结果与 `schema N fields`
  http <dir> [--port N] [--queue N] [--queue-bytes N] [--batch N]
            [--backlog-alert N]
            [--format lines|kv] [--key <name>] [--key-field <name>]
            [--ts-field <name>] [--schema] [--clock-skew <ms>]
            [--clock-skew-field <name>]
            [--dedup-field <name>]
            [--mask] [--mask-fields <csv>] [--meta <csv>]
            [--partition day|hour]
                                在 127.0.0.1 上提供 HTTP 推送端点：`POST /`
                                或 `/push` 先进入**有界队列**（`--queue` 行
                                数上限，默认 10000；可选 `--queue-bytes`
                                字节预算）并返回 202；队列/字节预算满时返回
                                **429 + Retry-After**（明确反压，客户端重试
                                即可，不静默丢数据）；后台按 `--batch` 行
                                分批落库，**有积压时全速连续 drain**（Batch
                                持久化，每批一次 fsync）；积压超
                                `--backlog-alert`（默认 5000）时进入告警打印
                                一次 `WARN backlog`、排空后打印一次
                                `RESOLVED`（含持续 ms 与峰值，不按批刷屏）；
                                `/stats` 含 `pending`/`pending_peak`/
                                `pending_bytes`/`backlog_alerts`/
                                `rejected_requests`/`rejected_lines` 与
                                `accepted`/`written`/`sampled_out`/`duplicates`；
                                `--dedup-field <name>` 唯一 ID 去重（已见 ID
                                跳过并计入 duplicates）；SIGTERM/
                                SIGINT 优雅关闭前会清空队列并打印终态计数；
                                每连接设 5s 读超时 + 10s 请求总期限（慢/
                                滴漏客户端不会卡死串行 accept），读 body
                                期间穿插 drain，短于 Content-Length 的
                                请求返回 400 且不入库；另有 `GET /health`、
                                `GET /stats`；SDK 直接调用库 API
                                `Log::append`
  serve <dir> <max-segments> [ttl] [--every ms] [--fsck-every N] [--once]
                                周期性执行维护（合并 + 冗余回收 + 可选过期折
                                叠 + 压缩 + flush 元数据）；`--every` 或
                                `MOONLOG_SERVE_INTERVAL` 设置周期，默认
                                60000ms；`--fsck-every N` 每 N 轮跑一次快
                                速 fsck 并输出报告；`--once` 执行一轮即退出
  backup <dir> <dst>            将目录的一致快照拷贝到空目录 dst（独占锁内
                                flush 数据与元数据后原样拷贝段文件、sidecar
                                （.index/.keys/.inv）、MANIFEST 与策略文件
                                RBAC/TTL/QUOTA；不拷贝 LOCK/游标/审计文件）
  restore <src> <dst>           将 backup 产物还原到空目录 dst（offset 原样
                                保留，恢复后可无缝续写、游标仍有效；完成后
                                自动 verify_fast 校验并输出报告）
  drill <dir> [--keep]          一键恢复演练（6.5）：备份到临时目录 → restore
                                到第二临时目录 → verify_fast → 记录数/offset
                                对账 → 配置一致性 → 首尾记录 spot 读验证，
                                输出 DRILL status=ok|fail 报告后清理临时目
                                录（--keep 保留现场）；源目录只读
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
                                导出记录为 JSON Lines（每行一个 JSON 对象：
                                offset/timestamp/kind/key/value；默认文本
                                模式假定 UTF-8 文本、控制字符转义，`base64`
                                模式对任意字节无损）；可加过滤——`--prefix <p>`
                                （key 前缀）、`--match <text>`（key/value 子
                                串）、`--from/--until <ms>`（时间窗），查询
                                结果直接导出为通用可解析格式（6.6）
  purge <dir> <prefix> [--into <file>]
                                合规删除（6.6）：删除 key 以 prefix 开头的
                                全部记录；`--into` 先把匹配记录导出为可解
                                析 JSONL 留存副本；随后写 tombstone 并物理
                                compact（被删记录与 tombstone 移出段文件），
                                压实后前缀扫描验证 0 残留，输出 PURGE status
                                =ok|fail 报告；offset 重排（游标需重置）
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
                    [--since <ms>] [--until <ms>] [--require-time]
                    [--timeout <ms>]
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
                              提前停止，`--from`/`--to` 限定 offset 区间；
                              缺省结果上限 `MOONLOG_MAX_RESULTS`（1000），
                              `--limit -1` 解除；与 `query` 共享 4.6 的并发
                              槽位/超时/扫描预算
query <dir> [--level <lv>] [--service <svc>] [--host <h>]
              [--trace-id <id>] [--level-min <lv>] [--level-max <lv>]
              [--contains <text>] [--since <ts>] [--until <ts>]
              [--limit N] [--indexed] [--sort-by-time] [--json]
              [--require-time] [--timeout <ms>]
                              统一 Schema 联合过滤：全部给定条件按 AND 匹配
                              （`--service` 匹配记录键或解析的服务字段；
                              `--level-min`/`--level-max` 按严重度排序过
                              滤（debug<info<warn<error<fatal，双界取区
                              间；范围过滤要求已知 level——未知级别被排
                              除）；`--contains` 大小写不敏感子串匹配 value；
                              `--since`/`--until` 限定记录时间戳区间，
                              epoch ms 含端点；`--limit` 提前停止，缺省上限
                              1000——`--limit -1` 解除）；
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
              [--trace-id <id|auto>] [--service <svc>]
                              上下文检索：打印目标 offset 前后各 N 条（默认
                              3/3，自动 clamp 到日志边界并跨段）；
                              `--trace-id auto` 从锚点记录提取 trace_id、
                              `--trace-id <id>`/`--service <svc>` 显式指
                              定——关联模式下上下文只含匹配记录（交错请
                              求的日志跳过且不占名额，offset 序还原同一
                              请求的完整现场）；锚点越界报错
aggregate <dir> [--by key|value|kind|hour|prefix:N] [--kv-field <name>]
                  [--match <text>] [--top N] [--json] [--quantile <field>]
                  [--since <ts>] [--until <ts>]
                               多维聚合统计：按 key/value/kind/UTC 小时/键前
                               缀 N 字节计数，`--kv-field` 按 value 内的
                               name=value 字段聚合（JSON 值按 2.1 展平后
                               同样可聚合），`--match` 过滤记录，
                               输出前 N 桶（`--json` 结构化）；
                               `--quantile <field>` 改为对 value 内数值字
                               段做分布统计——每桶输出 count/min/avg/
                               p50/p95/p99/max（最近邻秩法，零依赖），
                               非数值或缺字段计入 skipped；无 `--since` 时
                               默认最近 24h（`--since 0` 全表），时间界经
                               段级 min_ts/max_ts 下推跳段；与 query 共享
                               并发槽/超时/扫描预算，扫描不持写锁
cluster <dir> [--match <text>] [--top N] [--stacks] [--json]
          [--since <ts>] [--until <ts>]
                              错误自动聚类：把匹配行归一化为模板（数字/
                              十六进制/引号串替换为占位符）后按模板计数，
                              变量内容折叠为消息形态（默认匹配 "error"）；
                              `--stacks` 堆栈感知——Java/Python/.NET/Node/
                              Rust/Go 帧、`Caused by`/`Suppressed`/`... N more`
                              链行归并到最近匹配头（帧行本身不含 match 也
                              保留；非匹配头会中断链条），同异常类不同 id/
                              行号聚为同簇，每簇附 frames 数与 sample；
                              JSON 记录带 `stack`/`stacktrace`/`exception`
                              字段时按归一化堆栈聚簇（同堆栈不同 message
                              也同簇）并统计帧数；`--json` 输出机器可读簇；
                              无 `--since` 时默认最近 24h（`--since 0` 全表），
                              时间界经段级 min_ts/max_ts 下推跳段；与 query
                              共享并发槽/超时/扫描预算，扫描不持写锁
dashboard <dir> [--last sec] [--since ms] [--until ms]
                [--bucket minute|hour|day] [--by service|level|host|key]
                [--service <svc>] [--quantile-field <f>] [--top N] [--json]
                              值班巡检面板（5.5）：单遍扫描输出最近窗口的
                              量+错误率直方图（每桶 total/errors/err%）、
                              每桶延迟趋势（p50/p95/p99/max + 条形）、窗
                              口汇总、维度切换与分位数；--since/--until
                              回看历史故障窗口，--by 切换维度（默认 service）
anomalies <dir> [--baseline sec] [--recent sec] [--since ms] [--until ms]
                [--service <svc>] [--sigma N] [--min-count N] [--top N] [--json]
                              自动异常检测（5.6）：基线期/最近期对比，零规
                              则配置识别三类异常——量突增（分钟桶 z-score
                              越界）、新错误模式（模板差集，附 sample；JSON
                              按 message 归一）、季节性偏离（hour-of-day 泊
                              松近似）；KV/JSON 值均可；--since/--until 回
                              看历史窗口，--service 收窄检测范围
trend <dir> [--bucket minute|hour|day] [--match <text>] [--width N]
           [--since <ts>] [--until <ts>]
                              趋势可视化：按 UTC 时间桶计数并以文本直方图
                              输出（按时间序，`--width` 控制最长条宽）；
                              无 `--since` 时默认最近 24h（`--since 0` 全表），
                              时间界经段级 min_ts/max_ts 下推跳段；与 query
                              共享并发槽/超时/扫描预算，扫描不持写锁
alert <dir> <match> --threshold N [--window minute|hour|day]
                [--notify-file <path>] [--webhook <url>] [--json]
                              阈值告警：按 UTC 窗口统计匹配记录数，超过阈值
                              的窗口告警（`--json` 输出事件；`--notify-file`
                              追加 JSONL 通知；`--webhook` 经 curl POST，
                              失败仅告警不中断）
watch <dir> <match> --threshold N [--window-sec S] [--every ms]
                [--metric <field> --metric-threshold <v>] [--level-min <lv>]
                [--service <svc>] [--min-samples N] [--resolve-after N]
                [--snooze-until <epoch_ms>]
                [--notify-file <path>] [--webhook <url>]
                [--dingtalk <url>] [--wecom <url>] [--email <to>]
                [--smtp-url <url>] [--escalate-sec S] [--notify-dry-run]
                [--json] [--once]
                              阈值告警：**滑动窗口持续监控**——每 `--every`
                              （默认 1s）重估最近 `--window-sec` 窗口，计数
                              或数值指标（`--metric` 字段窗口均值）越界即
                              触发；有新记录时立即重评估（触发延迟降到一轮
                              处理，实测 687ms @every=1000）；字段过滤/指标
                              同时解析 KV 与 JSON 值（level 大小写不敏感、
                              service 匹配键或 schema 字段）；firing/resolved
                              状态机每波动只发一条告警+一条恢复（无误报风
                              暴），`--min-samples` 过滤样本过少的尖峰、
                              `--resolve-after N` 连续 N 轮不越界才恢复
                              （防抖动）；告警事件立即 flush（管道/重定向
                              实时可见），SIGTERM/SIGINT 优雅退出并输出
                              evals/firings/resolved 统计（`--json` 终态为
                              summary JSON，stdout 全程可解析）；通知复用
                              三渠道；**升级** `--escalate-sec` firing 持续
                              S 秒发 1 条 ESCALATED；**抑制** `--snooze-until`
                              到指定 epoch-ms 前不投递任何外部渠道（维护窗），
                              事件仍输出并带 `suppressed=true` 供审计，升级
                              同样被抑制；**通知可观测**终态 summary 输出
                              notified/notify_failures/suppressed（`--json`
                              下投递失败不再以文本 warning 污染 stdout）；**
                              渠道适配**钉钉/企微机器人信封与 curl SMTP 邮件，
                              `--notify-dry-run` 验证投递组装（`--json` 时
                              dry-run 也是 JSON 事件）；`--once` 单轮评估
baseline <dir> [--match <text>] [--window minute|hour|day] [--sigma N]
               [--min-windows N] [--notify-file <path>] [--webhook <url>]
                              异常基线检测：按窗口计数计算均值/标准差，
                              |z-score| > sigma（默认 3）且窗口数达标即标记
                              异常，可走文件/webhook 通知
rbac <dir> init <token> | add <name> <token> <allow> [scope=<prefix>] | list
         | remove <name> | check <command>
                              管理目录 RBAC 规则（`<dir>/RBAC`）；文件一旦存
                              在，除 `rbac init` 与 `rbac check`（诊断）外所
                              有命令需提供 MOONLOG_TOKEN 且角色 allow 列表
                              含该命令（或 `*`），拒绝事件追加到 `AUDIT`；
                              查询/导出/删除/配置变更类命令的操作留痕
                              （6.3，actor+ts+参数摘要）也写入 `AUDIT`
quota <dir>                   列出每租户配额策略（`<dir>/QUOTA`：write-bytes/
                              storage-bytes/query-concurrent/retain-days）与
                              当前写入窗口用量；写入/存储/并发/保留四维限制，
                              超限显式拒绝（CLI 报错、HTTP 429）
selfmon <dir> [--json]        独立自监控巡检（6.4）：磁盘水位（fs 剩余/目录段
                              字节）、写入积压（SELFMON/http.json 快照：pend
                              ing/队首滞留）、采集停滞（writer 活跃但最新段老
                              化）、查询失败率（SELFMON_ERRORS 窗口计数）；输出
                              STATUS=ok|warn|crit 首行 + 各维指标，--json 结构
                              化；阈值经 MOONLOG_SELFMON_* 可调
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
- M128 上下文检索同请求关联（4.4）：`context` 新增 `--trace-id <id|auto>` 与 `--service <svc>` 关联过滤——上下文只取与锚点同 trace（`auto` 从锚点记录自身提取 trace_id）或同服务的记录，**不匹配的交错记录跳过且不占名额**（offset 序连续可读），实现改为流式单遍扫描（锚点前匹配记录的环形缓冲 + 锚点后计数早停，替代 M106 的 clamp 窗口——无关联选项时行为等价 M106 物理前后 N 条）；锚点越界从静默空输出改为报错。实测：A/B 两请求物理交错入库（各 4 条），锚定 reqA step3 `--trace-id auto --before 2 --after 2` 输出 reqA 完整序列 step1-4（reqB 全部过滤、offset 序）；显式 `--trace-id reqB` 还原 reqB 序列；`--service` 附加同服务条件（svc2 的 reqC 记录被排除）；无关联选项回归 M106 物理上下文（7 条窗口）；锚点越界 `offset out of range` 报错。开发注记：流式上下文算法的环形缓冲用 `Array::remove(0)` 淘汰最老记录；关联判定在 trace_filter/service_filter 均缺省时完全短路（不 parse value，保持无关联路径零开销）；锚点存在性检查统一前置（auto 提取与越界报错共用一次 get）
- M129 Live tail 过滤与延迟证据（4.5）：`follow` 新增 live-debug 过滤——`--match <text>`（key/value 子串，复用 match_needle）、`--level-min <level>`（core `level_rank` 严重度下界，未知级别排除与 query 语义一致，非法 level 报错）、`--service <svc>`（记录键）：**只收窄打印流，游标照常推进**（被过滤记录视为已消费，`--commit` 不卡住）；新增 `--flush`（每条打印后 `fflush(stdout)`——新增 stub `moonlog_fflush_stdout` + `backend_native.flush_stdout`，C 运行时对管道/文件全缓冲是 live tail 管道与重定向观测的硬阻塞）。**端到端延迟证据**：约定口径 = 发现延迟 ≤ 轮询间隔（默认 200ms，`MOONLOG_FOLLOW_INTERVAL` 可调）+ 一轮处理；实测（`--flush` + bash 观测、含 put 进程开销）记录级 108-196ms、最差 <600ms——**远低于秒级约定**。实测过滤：`--level-min error` 2 条（info 排除）、`--match db` 2 条、`--service orders` 2 条（svcB 排除）、过滤 + `--commit` 游标到 10 后二次 follow 0 条不重放。开发注记：MoonBit println 走 C stdio——重定向到文件时全缓冲，stdbuf 对（可能的）静态链接二进制无效，观测 live tail 必须进程内 flush（`--flush`）或依赖进程退出的隐式 flush；bash grep 轮询观测的延迟含 put 进程启动开销（保守上界），CLOCK_REALTIME 回拨可产生负值样本（rec5 -173ms）——取中位/多数样本口径
- M130 查询保护（4.6）：`query` 内建三重防线——①**超时**：`--timeout <ms>`/env `MOONLOG_QUERY_TIMEOUT_MS`（默认 30s，0=禁用），新增 `QueryGuard`（t0/timeout/budget/scanned/segs）在段级 check（raise 包装 `check_soft`）+ **记录级每 512 条采样**（`check_soft` 非 raise 返回违规消息——`for_each`/`for_each_while` 回调非 raise 签名不能调 raise 函数，闭包内用 abort_msg 收集、段循环后统一 raise）；②**扫描预算**：env `MOONLOG_MAX_SCAN_BYTES`（默认 512MB，0=禁用），时间下推后的扫描集字节累积超限即拒绝；③**并发限流**：native 新增 `try_query_slot`（`<dir>/QLOCK.<i>` 非阻塞 flock 槽位——基础 `moonlog_flock` 本就 LOCK_NB，零新 stub；`backend_native` 无 mbti 快照文件），CLI `acquire_query_slot` 小步重试至 lock 超时后拒绝，槽位生命周期=进程（CLI 短命退出即释放，无泄漏）。实测（4 万条数据集）：`--timeout 1` → `query timeout after 19 ms (8 segments, 501845 bytes scanned)`、`MOONLOG_MAX_SCAN_BYTES=2000` → `scan budget exceeded`、`MOONLOG_MAX_CONCURRENT_QUERIES=1` + 长查询占槽 → 第二查询 `too many concurrent queries (limit 1)`、释放后 44000 条全量正常、被拒后 put 正常（不拖垮）。开发注记：**`guard` 是 MoonBit 保留关键字**（不能作变量名，91 个 Parse error 的根因）；`Int.reinterpret_as_uint64` 不存在（用 `to_uint64`）；超时的段级 check 有盲区（单段超长扫描段内不中断）——记录级采样补齐；小数据集上超时不触发是正确行为（elapsed 本就 <1ms），慢查询须用大数据构造（4 万条 ingest 约 0.5s）；sh（dash）不支持 `VAR=x (subshell &)` 形式——env 前缀直接跟命令加 `&`
- M131 聚合统计分位数（5.1）：`aggregate` 新增 `--quantile <field>`——对 value 内 kv 数值字段做分布统计，与 `--by`/`--kv-field` 维度组合（每桶独立）：输出 count/min/avg/p50/p95/p99/max（**最近邻秩法** `vals[ceil(q*n)-1]`，手写 `pct_of` 无 math 库依赖；`@string.parse_double` 解析、非数值/缺字段计 `skipped` 不进分布；JSON 输出含 quantile/skipped 字段）；无 `--quantile` 保持纯计数模式向后兼容。**秒级验收**：4 万条 latency（`i%997` 均匀序列）聚合实测 **426ms**、分布 min=0/max=996/P50=496/P95=946/P99=986 与理论吻合；10 样本等差手工验算 P50=35/P95=70/P99=70/avg=38.5 精确；`--kv-field level --quantile latency` 正交组合、count 模式与 trend 回归正常。开发注记：`@string.parse_double(StringView) -> Double raise` 是 core 自带（无需手写浮点解析）；catch 分支类型须与主表达式一致（Double vs None 用 try 表达式包 Option）；Int→Double 用 `to_double()`（百位数值 avg 无精度损失）
- M132 错误聚类堆栈归并（5.2）：core 新增 `stackframe.mbt` 的 `is_stack_frame`（Java `at ` 前缀+`(…:…)` 位置、Python `File "` 前缀、`Caused by: ` 链行——trim 后字符级判定，+1 单测 9 断言）与 `cluster --stacks` 状态机模式——帧行归并到最近非帧行的模板簇（`current` 状态 + `frames`/`samples` 旁表；孤立帧行兜底自成簇；缺省回归 M107 单行语义）。实测：两个 NPE（user 42/77/91）+ ISE + Python 帧交错 11 行——单行聚类 6 簇 vs `--stacks` 2 簇（NPE count=3+frames=5 同类堆栈同簇、ISE count=1+frames=2），sample 展示首条原始行；`--match ""` 全量匹配（堆栈行不含 error 字样）。开发注记：Python 帧归入"最近头"（NPE 簇）——归并语义按最近非帧行，跨语言混排时帧归属跟随上下文；cmd_cluster 的 stacks 分支曾误写 `match needle { Some(n) }`（needle 是 Bytes 非 Option）——复制别处 Option 模式前先确认变量实际类型
- M133 阈值告警滑动窗口（5.3）：CLI 新增 `watch <dir> <match> --threshold N`——**滑动窗口持续监控**（内存缓冲最近 `--window-sec` 记录 + 每 `--every` 默认 1s 重估，**触发延迟 ≤ 评估周期**，替代固定窗口的整窗延迟）；两类指标（计数 `--match`/数值 `--metric`+`--metric-threshold` 窗口 avg）；**firing/resolved 状态机**（越界 1 条 ALERT、持续越界静默、回落 1 条 RESOLVED——无误报风暴）；`--level-min`/`--service` 窄化（M129/M126 语义）；通知复用 `dispatch_notification` 三渠道；`--once` 从 `from 0` 评估现有窗内数据（tail 起点会跳过启动前数据——冒烟暴露后修正）。实测：burst1 → `ALERT firing count=3`（1s 内）、burst2 无新告警（去重）、窗口滑出 `RESOLVED value=1`、burst3 re-firing、1h 窗 9 条全计数、指标 avg=336.67>100 firing、notify-file firing/resolved JSONL、`alert` 固定窗口回归。开发注记：cmd_watch 的 python 插入曾把 JSON 转义 `\"` 被 python 吃掉一层导致 27 个 Parse error——**用 read 定位后整体函数重写**（python raw 三引号 r''' 保证 `\"` 原样落盘）比小补丁可靠；match_text 是必填 String 非 Option（照 alert 风格，match_b 直接 Some 包装）；`--once` 语义修正（from 0）属行为变更已在 README 注明
- M134 告警收敛与通知（5.4）：`watch` 新增**升级策略**——`--escalate-sec S`：firing 持续 S 秒未恢复发 1 条 ESCALATED 事件（elapsed_ms 可审计），升级后静默直到 resolved 重置（升级有界不风暴，`escalated`/`fired_at` 状态位）；**通知渠道适配器**——`notify_extra` 扇出钉钉（`{"msgtype":"text","text":{"content":…}}`）与企微（`{"msgtype":"text","content":{"content":…}}`）机器人信封、邮件（curl SMTP：.eml 临时文件含 Subject/From/To + `--mail-from/--mail-rcpt/-T`，`--email` 需配 `--smtp-url`）、`--notify-dry-run` 打印投递动作验证组装（零 SMTP 客户端/SDK 依赖，复用 `moonlog_run_command`+`shell_quote`）；firing/resolved/escalated 每次转换全渠道各投 1 次。实测：风暴收敛（burst → firing@0.2s → escalated@2.2s（elapsed_ms=2007 精确对应 `--escalate-sec 2`）→ 持续越界静默）；**通知可达性闭环**——`--webhook` 指向本仓库 `http` 端点，firing/escalated 事件 JSON 真实入库（scan 可查）；钉钉/企微/邮件组装经 `--notify-dry-run` 验证。范围决策：跨规则抑制在单机单目录单规则 watch 下无场景（README 注明）。开发注记：**fired_at 必须在 firing 分支赋值**（初版误落 resolved 分支导致 elapsed=绝对时间戳、escalation 立即触发——冒烟的 elapsed_ms 字段直接暴露）；含 `"` 转义的 moon 代码编辑改用 **write 脚本文件 + python 普通三引号双反斜杠**（heredoc 截断与 mtime 竞态双规避）
- M135 可视化看板值班面板（5.5）：CLI 新增 `dashboard <dir>`——**单遍扫描多指标综合面板**（值班一眼看全，替代 trend/aggregate/query 三命令拼接）：①量+错误率直方图（每桶 total/errors/err% + `#` 条形，error=level rank≥3 或无 level 时 value 含 "error" 兜底）；②窗口汇总（total/errors/err_rate/services）；③延迟分位数（`--quantile-field`，复用 5.1 `pct_of`）；④top services（key 量降序，维度切换入口提示 aggregate --by 深挖）；时间窗 `--last <sec>`（默认 1h）经段级 `min_ts/max_ts` 下推（4.2），`--bucket minute|hour`、`--service` 过滤、`--json` 结构化（windows/summary/quantile）。**秒级验收**：4 万条（5% error + latency）实测 **391ms**——错误率 5% 精确、分位数与 5.1 理论一致、svc 子集（13333/666）正确、`--last 86400 --bucket hour` 概览、`trend minute` 深钻与 `query --level-min error --since` 时间窗过滤（666 条）链路验证——**值班下钻流程闭环**。范围决策：无交互式 UI/Web 服务（文本面板 + JSON 即看板数据面，勿提议前端框架）。
- M136 异常检测自动基线（5.6，进阶）：CLI 新增 `anomalies <dir>`——**零规则配置**的三类自动检测（基线期 [now-baseline, now-recent] vs 最近期 [now-recent, now]，默认 7d/1h）：①**VOLUME_SPIKE**（最近分钟桶 vs 基线分钟桶分布 mean/std，z>σ）；②**NEW_PATTERN**（错误模板——level rank≥3 或含 "error"——基线/最近差集：最近期新出现的模板，`--min-count` 滤噪声、附 sample）；③**SEASONAL_DEVIATION**（hour-of-day 对齐：基线期每小时多日均值 vs 最近期该小时计数，泊松近似 z=(c-mean)/√mean）；`--sigma`/`--top`/`--json` 三数组。实测（非均匀基线 617 条，σ=3）：**三类全触发**——VOLUME_SPIKE 2 桶（z=30.07/7.20）、NEW_PATTERN 识别 ISE 新模板（3x）且正确排除基线已有的 NPE（差集语义）、SEASONAL hour_utc=0（z=4.90）；均匀基线（std=0）时 spike 不触发属统计保护语义；滑动窗口语义验证（recent 窗右移后旧 spike 不再报告）。开发注记：**MoonBit 的 `a..b` 是含端 range**（`0..n` 多跑一次致数组越界 abort，fmt 规范化为 `0..<=n` 可见——排他循环必须写 `a..<b`）；FixedArray::make(24, 0) 做 hour-of-day 累计；泊松近似（√mean）绕开零方差基线的 z-score 未定义问题
- M137 按租户配额管理（6.2）：**租户 = RBAC 角色**，四维配额定义在 `<dir>/QUOTA` 策略文件（`role=<name|default> write-bytes= storage-bytes= query-concurrent= retain-days=`，缺省不限；core `QuotaRule`/`parse_quota_line`/`quota_for_role` + 单测）——**验收：单租户无法打爆整个集群**。①写入量：1h 滚动窗口字节上限，用量持久化 `<dir>/QUOTA_STATE/<role>.write`（`QuotaUsage` 编解码 + 窗口 age-out 重置，**重启不重置**）；put/put-if/put-batch/ingest 在目录锁内先查后记（超限报错无静默丢失，幂等跳过不消耗配额），HTTP 入队时按请求记账（202 契约，429 `tenant write quota exceeded`）。②存储量：`dir_log_bytes` 实时统计 `*.log` 段字节 + 待写字节超限拒绝。③查询并发：租户专属 flock 槽 `QLOCK.<role>.<i>`（`try_named_lock`，先全局后租户两级限流）。④保留天数：`retain-days` 经角色 scope 前缀转 TTL `prefix` 规则（3.4 扩展该 scope，`ttl_days_of` 取更严者——配额只能收紧），`ttl-expire`/`maintain` 统一走 `effective_ttl_policy` 合并。配套：`rbac add` 支持可选 `scope=<prefix>`；HTTP 强制 Bearer 认证（匿名/坏 token 401、无 put 权限 403、`/health` 开放、`/stats` 需 token），`HttpRequest.authorization` 头解析（core 单测）；无角色调用方受 `role=default` 兜底；`quota <dir>` 列策略+窗口用量。**冒烟 23/23**：tenant-a 写满 2000B 后第 4 笔被拒且 tenant-b 照常、存储超限拒绝、HTTP 匿名 401/超配额 429/合法 202/drain 落盘、flock 占满租户槽该租户 query 被拒（释放恢复）、tenant-a 8 天旧段按 retain-days=7 回收而 tenant-b（30）保留。开发注记：QUOTA 行必须 `role=default`（裸 `default` 行会被解析器按无角色丢弃）；租户槽文件名是 role 原样（连字符）——占位测试勿写下划线变体；CLI 拒绝路径 exit 0（断言须看输出非返回码）
- M138 操作审计（6.3）：`<dir>/AUDIT` JSONL 留痕——**查询/导出/删除维护/配置变更四类命令**（47 个命令白名单）执行前自动记 `{ts, actor, action, decision, target}`，越权拒绝同格式记 `deny`——**关键操作可定位到人与时间**（actor=RBAC 角色，token 永不落盘；本地模式 `local`、未匹配 token `unknown`；target=参数摘要截 200 字符，`rbac add/init` 的 token 打码）。启用：`AUDIT` 或 `RBAC` 文件存在（本地 `touch AUDIT` 显式 opt-in，未开启零行为变化），`rbac init` 总是留痕（引导即配置变更）。**O_APPEND 原子追加**（新增 `moonlog_append_file` stub + `append_file` 绑定）替代三处读改写（AUDIT/TTL_AUDIT 并发会互相覆盖）。**顺带修复存储缺陷**：`recover_log_dir` 以 `has_suffix(".log")` 匹配段——`AUDIT.log` 被当段 recover、JSONL 内容截断为 0（冒烟 15/17 场景抓到：无 MANIFEST 目录走 recover 路径）；收紧为 `parse_base_from_log_name is Some(_)`（`<16 位数字>.log` 规范段名）——任意用户 `.log` 文件不再被当段；`AUDIT`/`TTL_AUDIT` 命名避开 `.log`，旧文件首次使用自动 rename 迁移保历史。审计点在 dispatch RBAC 检查后（发起留痕语义——失败的尝试同样可见）。实测 **19/19**：init/add 留痕且 token 打码、四类操作全留痕、deny 可定位到人（tenant-a/unknown）、put/check 不留痕、本地 opt-in、未开启零变化、并发 3 进程 3 事件、旧文件迁移、**query 后审计文件不被截断**。开发注记：审计在 cmd_rbac 的 ensure_dir 之前执行——audit_log 内 ensure_dir（幂等）；stub.c 改动须 touch 强制重编译；mtime 纳秒对比（三文件同刻）是定位"谁清空了文件"的关键证据手法
- M139 自监控（6.4）：`selfmon <dir> [--json]` **独立健康巡检**——验收"日志系统自身故障能先被发现"。四维指标：①**磁盘水位**——新 `moonlog_statvfs_avail/total` stub（`fs_bytes_available/total`）测 fs 剩余 + `dir_log_bytes` 目录段字节，WARN≥80%/CRIT≥90%；②**写入积压**——http writer drain 尾部 **1s 节流**原子快照 `<dir>/SELFMON/http.json`（pending/队首滞留 `head_ts`/告警计数），优雅关闭写终态 pending=0，**kill -9 残留积压被 selfmon 按 BACKLOG_WARN 发现**（writer 崩溃先于用户报错被看见）；③**采集停滞**——最新段 mtime 年龄（`file_mtime_ns`/字典序最大段名）≥ STALE_MS 且快照 writer 活跃 → 告警，空闲目录不误报；④**查询失败率**——**main catch 为所有命令失败的统一落点**：追加 `<dir>/SELFMON_ERRORS` JSONL（ts/cmd/error），selfmon 窗口计数为分子、AUDIT allow 事件为分母；**配额拒绝过滤不计入**（bytes_contains "quota exceeded"——预期租户行为非故障）。阈值 8 个 `MOONLOG_SELFMON_*` 环境变量。边界：selfmon 诊断类不在审计白名单；深度校验归 fsck、ingest 位点滞后归 cursor-lag（不重复造轮子）。**冒烟 20/20**：磁盘 warn/crit、优雅关闭 ok 与崩溃残留 warn、失败留痕+配额过滤、停滞告警+空闲不误报、RBAC 兼容+审计豁免。开发注记：**catch 类型必须与主表达式一致**（json_object_fields 返回 Array 不能 `catch { _ => None }`——用 `try { Some(expr) } catch { _ => None }` 的 try-Option 手法）；Int/Int64 比较须显式 to_int64；json_object_fields 复用解析审计/快照行（raise ParseError 靠 try-Option 兜底）；idle 循环 pending=0 时 drain 提前 return 不上报——快照冻结在最后活跃状态，正是崩溃检测需要的语义
- M140 备份与恢复演练（6.5）：备份清单扩展——`is_backup_file`（backup/restore/replicate 三命令共用）加 **`.inv` 倒排 sidecar 与策略文件 RBAC/TTL/QUOTA**（此前恢复副本丢配置需手工重建、倒排索引靠 lazy 重建首次 indexed 查询变慢）；`archive_file_names`（MLAR）同步加配置（.inv 原已含）。新增 **`drill <dir> [--keep]` 一键恢复演练**：独占锁内 flush+backup 到 `<dir>.drill-backup` → `restore_log_dir` 到 `<dir>.drill-restore` → 共享锁内 `verify_fast` + count/next_offset 对账 + **首尾记录 spot 字节比对** + `drill_config_check`（RBAC/TTL/QUOTA 三态 absent/ok/mismatch 逐字节）→ `DRILL status=ok|fail` + 分步报告 → 清理（`--keep` 保留现场）；源目录全程只读，`remove_tree` 清临时目录（list_dir+逐文件 remove+目录本体，moonlog_remove 的 rmdir 语义）。drill 加入审计白名单（备份/恢复类操作留痕）。**冒烟 20/20——恢复演练实际成功**：drill status=ok（3/3 记录对账、spot ok、config ok、清理/幂等/--keep）、backup 四类文件齐备、恢复目录配置逐字节一致且 RBAC scope 查询正常、.inv 备份恢复 1/1 且 indexed 查询在位、archive 提取配置在位数据可查、drill 审计留痕。开发注记：冒烟曾"archive 提取后目录空"——**M124 的 extract 语法是 `archive <dir> <file> --extract`（arg2 恒为数据目录、arg3 为归档文件）**，把 `--extract` 写在 arg2 位会把该字符串当归档文件读而静默失败（错误被 >/dev/null 吞）；VerifyReport.records 与 count() 同为 Int32 可直接对账；run_locked 闭包内对外层 mut 变量赋值可行（引用捕获，M137 同款手法）
- M141 归档导出与合规删除（6.6）：`export-jsonl` 加查询过滤（`--prefix`/`--match`/`--from/--until`，位置参数 text|base64 向后兼容）——**导出文件可解析**（JSONL 每行 offset/timestamp/kind/key/value）；新增 **`purge <dir> <prefix> [--into <file>]` 合规删除闭环**——`--into` 先导出匹配记录为留存副本 → 匹配 live key 收集（单遍 sweep 导出+去重收集）→ tombstone → `log.compact` 物理压实（**被删记录与 tombstone 一并移出段文件**，非仅逻辑删除）→ 压实后前缀扫描验证 0 残留 → `PURGE status=ok|fail` 报告（exported/deleted/compacted/verified 明细 + 游标重置提示）；purge 进审计白名单。**冒烟 18/18——导出可解析、删除可验证**：前缀/子串/时间窗过滤各自计数正确、导出与留存文件 python 逐行 JSON 解析通过、purge 后 scan-prefix 0 命中 + getkey 无数据 + 其他前缀完好 + 全库 7-3=4 对账、重复 purge 幂等、审计留痕（touch AUDIT opt-in 后）。开发注记：core 的 bytes_has_prefix 是 ttlpolicy 私有——CLI 侧手写 bytes_has_prefix_cli；for_each_while 回调用 `return true` 继续（过滤不中断扫描）；match into { Some(file) } 回调内未用绑定改 Some(_)（unused_value 警告清零）
- M142 .inv sidecar 删除修复（系列审查发现）：`remove_segment_files` 只删段数据/`.index`/`.keys`，**漏删 M120 引入的 `.log.inv`**——任何删段后复用同一 base offset 的重写（`compact`、`purge`、`merge`）会让 `load_segment_inv`（仅校验文件存在+可解码，无段指纹）把旧索引当作当前段索引装入，**`search --inverted` 返回幽灵记录（已删数据）**。实测修复前：compact 删 k1/k2 后 `search --inverted "alpha"` 返回已删记录、purge 后 `search --inverted "ERROR"` 2 条幽灵；修复后均与线性查询一致（0 条），首查 lazy 重建正确。修复：删段时同步删除 `.inv`（一行）。回归冒烟 **9/9**（compact/purge/merge 三条删段路径 inverted==线性 + lazy 重建）；既有五轮冒烟（23/19/20/20/18）全绿；native/wasm 154 全绿。开发注记：审查中 `query --match` 返回全量属参数误解（query 用 `--contains`，`--match` 被忽略无报错）；幽灵触发面是 `search --inverted`（词查询走 InvIndex）；M120 起既有缺陷，6.6 purge 使其常态化；`backup`/`archive` 曾把残留 .inv 传播到副本，修复后一并消失
- M143 多源接入链路健壮性优化（1.1 复核后加固）：针对串行 HTTP 端点与 FIFO 订阅的可用性缺口做四项优化——①**慢客户端防护**：连接 accept 后设 `SO_RCVTIMEO`/`SO_SNDTIMEO`（5s）+ **10s 请求总期限**，慢速滴漏客户端不再永久占住 accept 循环（基线实测：partial body 占住连接时 `/health` 3s 超时失败；优化后 4.76s 内返回 200，且部分 body 不入库）；②**截断/超大 body 拒绝**：短于 `Content-Length` 的请求返回 400 而非持久化半行；③**可靠响应写出**：`conn_write` 循环写全 + 响应后 `shutdown(SHUT_WR)` 再 close，避免短写与 RST 截断；读 body 期间穿插 `http_queue_drain`，大请求不再饿死落盘；④**端到端计数与 FIFO 优雅退出**：`/stats` 新增 `accepted`/`written`/`sampled_out`（与 `pending` 可对账），关闭时打印同样终态；`ingest --fifo` 安装 SIGTERM/SIGINT 协作式 handler（EINTR 打断阻塞 open/read），flush 已接收行后以 exit 0 退出并打印终态（基线为 raw signal death / exit 143）。实测：四类来源均正常入库、正常 POST 3 条 → accepted=3/written=3、慢客户端健康检查恢复、截断请求 0 入库、FIFO 有/无写者时 SIGTERM 均 exit 0；native/wasm 测试全绿。
- M144 高吞吐写入路径优化（1.2 复核后优化）：定位并修复三类真实开销——①**写入缓冲 O(n²)**：`NativeFileLog` 的 `pending = pending + chunk` 每条记录都重新分配并复制整个 64KB 缓冲，改为**定长 `FixedArray` + 已用长度原地 blit**（新增 `moonlog_pwrite_len` stub 只写有效前缀，短写保留未写尾部）；②**记录编码多次分配**：`Record::encode` 原用两个 `Buffer` + 两次 `to_bytes`，改为按固定布局一次分配并原地写字段/CRC（磁盘格式逐字节不变）；③**压测口径偏差**：`bench-write` 原把最后的全量 durability flush（36 段 fsync + 元数据，实测 0.8–1.0s）计入计时窗口，预热越多、段数越多，QPS 越低（150k 预热后仅 41k/s）。现**计时截止到写入循环结束，final flush 单列**，并加可选 `--warmup N`；压测 key 改为单次分配的数字编码。实测（20 万条）：batch 1000 **14.7 万 records/s**（旧口径 8.7–9.2 万）、batch 5000 **19.3 万**、`--sync never` **28.4 万**、`--sync always` 585/s；final flush 0.86–1.04s 透明展示；所有场景 verify `ok (no loss)`。native/wasm 测试全绿。
- M145 缓冲与背压优化（1.3 复核后优化）：定位并修复三个真实缺口——①**积压消化被串行节拍拖慢**：主循环每轮只 drain 一批 256 行后再 poll 等 200ms，无新连接时恢复速率被锁死在 ~1.3k 行/s；改为有积压时连续 drain（每轮上限一整队列的批数，避免饿死 accept）。②**drain 逐条 fsync**：`ingest_lines` 走 CLI 默认 `SyncPolicy::Always`，HTTP 过载时每行一次 fsync（实测 3000 行导入 5.2s）；`IngestOptions.sync` 显式化，HTTP drain 用 **Batch**（每 `--batch` 一次），并把日志打开/元数据写入从"每 256 行一次"改为"每窗口（≤16 批）一次"（长流仍按窗口释放目录锁）。③**告警刷屏与反压不可观测**：积压告警改为状态机（进入 WARN 一次、排空 RESOLVED 一次，含持续 ms/峰值）；新增 `--queue-bytes` 字节预算与 `pending_peak`/`pending_bytes`/`rejected_requests`/`rejected_lines` 计数，并入 `/stats` 与关闭终态。实测：3000 行积压 **109ms 排空**（旧 4s+）；一次积压 1 WARN + 1 RESOLVED（旧 9 条 WARN）；字节预算 429 后拆小重试 **1000/1000 零丢失**；SIGTERM 立即关闭仍全量 drain 3000 条；`ingest --follow` 回归通过；native 195/195、wasm 154/154。
- M146 唯一 ID 幂等与重放（1.4 复核后补齐）：原实现只有 `(key, value)` 内容等值 + latest-wins 去重，不满足"通过唯一 ID / 批次号去重"——同 key 交替重放 e1/e2 会重复，且相同内容的不同事件会被误去重。新增**显式唯一 ID**：`ingest`/`http` 的 `--dedup-field <name>`（从解析字段取 ID）与 `put --dedup-id <id>`，已见 ID 一律跳过（不看 payload/key 是否变化）。持久化 `<dir>/DEDUP`（`<offset>\t<id>`）并把 `__uid=<id>` 内嵌进记录 value，使日志成为权威源：启动时读 sidecar 后扫描其未覆盖的尾部补齐，**删除/截断 DEDUP 后仍能重建**（崩溃窗口收敛）。HTTP `/stats` 与关闭终态新增 `duplicates`。实测：`put` 同 ID 不同 value 跳过、同 value 不同 ID 写入；`ingest --from 0` 重放 2 行 0 新增/2 duplicates；同 key 交替重放 0 新增；删除 DEDUP 与截断 sidecar 后重放仍 0 新增；对照内容幂等把"同 key 同 value 不同 ID"误去重为 1 条、唯一 ID 正确写 2 条；HTTP 同 payload 两次 202（accepted=4）→ written=2/duplicates=2；`ingest --follow` 与断点续传回归正常；native/wasm 全绿。
- M147 源头采样限流优化（1.5 复核后优化）：①**纯文本级别采样缺口**：`--min-level` 原只读解析字段，`--format lines`（最常见）无 fields 时阈值完全不生效；core 新增 `level_rank_in_line` 从原始行识别 `level=warn` / `level:"warn"` / `"level":"warn"`（边界校验避免误匹配 `mylevel=`），仅在 fields 无该字段时回退，kv/json/template 行为不变；②**HTTP 双重采样**：入站 `sampling_filter_lines` 已过滤一次，drain 的 `ingest_lines` 又跑一遍 `sampling_allows`；新增 `skip_sampling` 参数，HTTP drain 传 true，采样只在入站发生（accepted == written 可直接对账；确定性哈希下结果本就不会二次丢，但消除了重复解析/哈希开销与语义歧义）。实测：lines 400 行 `--min-level warn` → **200 写入 / 200 sampled**（旧实现全写 400）；`--sample-rate 0/50/100` → 0/215/400，两个独立目录的 50% 结果完全一致；HTTP 入站 min-level warn → accepted=written=200、sampled_out=200；kv 与 FIFO 回归一致；非法 rate 101 显式报错；native 196/wasm 全绿。
- M148 结构化解析增强（2.1 复核后优化）：①**模板解析从"字面 + 占位符"升级为受限 Grok 子集**：`<name:pattern>` 支持单字符类 + 量词（`\d`/`\w`/`\s`/`\S`/`.`/`[^...]`/`[a-z]`，`?`/`*`/`+` 与 `+?` 非贪婪），字符类内支持 `\d` 等转义；贪婪模式在字符类窗口内回溯到下一个字面，`<name>` 旧语义完全保留；②**JSON 递归展平**：嵌套对象输出点号字段（`request.user_id`），数字/布尔/null 转文本、数组紧凑序列化，顶层非对象仍返回空；③新增只读 `parse-check <file> --format ... [--template] [--sample N] [--json]`：逐行打印字段并汇总 `parsed/lines` 准确率、空字段数，`--json` 可机读。实测：nginx combined 模板 2/2 行、16 字段、0 空（100%）；JSON 嵌套 2/2 行 8 字段，`request.user_id`/`request.path` 正确；畸形 JSON 3 行 2 parsed（66%）并标记 `<unparsed>`；`--json` 输出可被 `json.loads` 解析；ingest 用同一模板入库字段一致；core 新增 3 个单测；native 199/wasm 全绿。
- M149 统一 Schema 归一增强（2.2 复核后优化）：①**字段名归一**：`canonical_field`/`schema_from_fields` 先做大小写 + `.`/`-`/`_`/`@` 分隔符 squash 再匹配，新增 OTel/常见别名（`service.name`/`serviceName`/`service-name`/`svc`、`trace.id`、`host.name`/`node`、`severity_text`/`lvl`、`body`/`log`），解决 2.1 JSON 展平后嵌套字段不被识别、驼峰/连字符/大写命名不统一的问题；②**联合过滤值比较大小写不敏感**：`schema_matches` 的 service/host/trace_id 采用 ASCII ci，level 额外识别 warn/warning 同义，`--service ORDERS --level ERROR` 可命中小写存储；③`parse-check --schema` 离线输出归一六字段与 `schema N fields`。实测三种命名（OTel JSON 嵌套 / 驼峰 kv / 连字符+大写 kv）均 6/6 字段归一，ingest 后三条 key 均为 orders、value 固定 `level=… host=… trace_id=… message=…`；`query --service ORDERS --level ERROR --trace-id T9` 命中 3/3，service=nope 0 条；core 新增 3 个单测；native 202/wasm 全绿。
- M150 时间规范化增强（2.3 复核后优化）：①**常见格式缺口**：`parse_iso8601_ms` 原只认 `YYYY-MM-DD[T ]HH:MM:SS[.frac]`，实测逗号毫秒（`02:00:02,123`，Java/log4j）、斜杠日期（`2026/11/09`）、` UTC`/` GMT` 后缀全部回退为到达时间；现支持 `.`/`,` 小数、`-`/`/` 日期分隔、秒可选（`HH:MM`）、`Z`/`z`、`±HH:MM`/`±HHMM`/`±HH`、` UTC`/`GMT`（ci），并保持严格拒绝未知后缀。②**时钟偏移只支持全局固定值**：新增 `--clock-skew-field <name>`，从每条记录字段读取每源毫秒偏移并与 `--clock-skew` 叠加，适配多 agent 不同漂移。实测：五种格式 ts 全部正确（1794189602123/3000/4000/5123/6000）；乱序到达 `e4 e2 e5 e1 e3`（含 `+08:00`/`-05:00`/`Z`/逗号毫秒）`--sort-by-time` 输出 `e1 e2 e3 e4 e5` 且 ts 严格递增；`skew=1000`+全局 500 → +1500、`skew=-2000` → -1500、缺字段 → +500；小写 z/数字精度回归；core 新增 1 单测；native 203/wasm 全绿。
- M151 脱敏增强（2.4 复核后优化）：①**JSON 字段名漏掩**：`mask_sensitive` 原只认 `name=`，实测 `{"token":"sk-...","password":"p@ss"}` 原样明文落盘（`search` 各 1 match）；字段匹配改为同时接受 `=` 与 JSON 冒号（`"name":"..."` / `"name": "..."` / 空格变体），引号值截到闭合引号（含空格也整体掩码）。②**令牌前缀**：`Bearer`/JWT/长 hex 之外新增 `sk-`（OpenAI/Anthropic）、`AKIA`（AWS）、`ghp_`/`github_pat_`（GitHub）、`xox?-`（Slack）整段 `[REDACTED]`，带前缀最小长度避免误伤（`disk-usage-report-2026` 保留）。实测：JSON token/password 明文 0；四种前缀独立出现明文 0、普通连字符标识保留；kv/lines/HTTP/schema 四路径零明文；message 内嵌令牌/手机号仍掩；core 新增 1 单测；native 204/wasm 全绿。
- M152 分区策略持久化（3.1 复核后优化）：复现发现**漏带 `--partition` 即静默退化**——4 条跨两天数据被写成 1 段，`partitions` 视图把整段归到段首桶（records=4、span 跨两天），过期清理无法按天淘汰；根因是分区模式原先只在命令参数里临时存在。新增目录级策略 `<dir>/PARTITION`（一行 day/hour/off）+ `partition-policy <dir> [day|hour|off] [--json]` 读写；`put`/`ingest`/`http` 在未显式带 `--partition` 时自动读取策略（显式参数仍优先，`--partition off` 可临时关闭），`partitions` 文本/JSON 输出当前 policy。实测：策略 day 后不带参数 ingest 跨天 → **2 桶**（旧 1 桶混合）；显式 off → 1 桶、显式 hour 覆盖 → 2 小时桶；`prune-before` 删旧日段（dropped 2）后仅剩 day2 且 scan 正确；显式 `--partition` 回归不变；native/wasm 全绿。
- M153 倒排索引落盘与 sidecar 生命周期（3.2 复核后优化）：量化发现**查询进程构建的索引从不落盘**——4 万条 schema 数据 `query --indexed` 首次 0.87s、跨进程仍 0.82s（每次重建），甚至慢于线性 0.53-0.77s；且 `quarantine_segment` 漏处理 `.inv`（M142 只修了删段路径）、repair 截断段后陈旧 `.inv` 残留（加载校验兜底但每次重建）。优化：①新增 backend `save_segment_inv`/`has_segment_inv`，`query --indexed` 与 `search --inverted` 在共享读锁下 lazy 构建后**原子写回**（tmp+fsync+rename）——实测首次 0.96s（构建+4 个 sidecar）、跨进程 **0.45s**，indexed 与线性输出逐字节一致（37 命中）；②`quarantine_segment` 把 `.inv` 改名为 `.inv.corrupt`（扩展既有 repair 隔离单测断言）；③repair 截断段后删除陈旧 `.inv`。回归：native 204/wasm 163、fmt clean。
- M154 列式压缩增强（3.3 复核后优化）：量化发现 `.inv` 才是存储大头——4 万条 schema 数据段数据 3.58MB、`.inv` 却 3.76MB（v2 仅 postings delta+varint，terms/fields 每条完整重复 key，`trace_id=...`/`message=...` 高基数条目占满）。优化为 **sidecar v3 = delta+varint + front coding**：编码前把 terms/fields 按 key 字典序排序，每条只写"共享前缀长度(varint) + 后缀长度(varint) + 后缀 + posting 数 + delta postings"；解码用一次精确分配 + blit 重建 key（零拷贝 Bytes 视图做 map key）。实测 `.inv` **3,758,004B → 1,452,624B（−61.3%）**；跨进程 indexed 0.50s（Buffer 版）→ **0.43s**（FixedArray 版），优于 v2 0.45s 与线性 0.76s；indexed==linear 37 命中一致；旧 v2 sidecar 精确版本拒绝后**删除并重建 v3**（篡改 version=2 冒烟：结果仍 37、文件 version 恢复 3），CRC 失败同样删除；新增 front coding roundtrip 单测；native 205/wasm 全绿。
- M155 TTL 配置匹配与审计增强（3.4 复核后优化）：量化发现 **大小写不一致时差异化规则静默失效**——`service Orders 1` 对 key `orders`、`level ERROR 2` 对记录 `error` 都不命中，退回 default（或缺省永不过期），与 3.4"按项目/级别差异化配置"验收不符；且审计缺少触发来源、命令无可机读输出。优化：①`ttl_days_of` 的 service/level 与 `ttl_record_level` 的 `Level=` 字段名改为 ASCII 大小写不敏感（prefix 保持字节精确）；②审计新增 `"trigger":"cli"|"maintain"`；③`ttl-expire --json` 输出 `segments_dropped`/`records_expired`/`audited`（dry-run 时 audited=false）。实测：`service Orders` 命中 `orders` 删 1 段、`level ERROR` 命中 `error` 删 1 段、default/未命中保留 1 条；dry-run --json 不删不审计；CLI 与 maintain 审计分别 trigger=cli/maintain；core 新增 1 单测；native 206/wasm 全绿。
- M156 副本角色与自动切换（3.5 复核后优化）：复现最危险失败模式——**failover 后旧正向同步裁掉副本新写数据**：主 10 条 → 宕机期副本写入至 12 → 主恢复后旧 follow 一轮 `replicate` 按源端为准把副本删回 10（丢失 2 条）；此外切换需人工改目录、无可观测角色。优化：①`<dir>/HA_STATE`（role=primary|standby、switched_at/from）；`replicate_pass` 检测到目标是 primary 时**拒绝正向同步**（实测 12 保持）；②`ha-failover <primary> <replica> [--active <link>] [--json]` 提升副本并把可达旧主标 standby，`--active` 用 backend 新增 `replace_symlink`（tmp+rename）原子重指稳定路径（active 写入落到副本，13 条）；③`ha-status --json` 角色/可达性/切换时间；④`ha-rebalance <old> <new>` 反向追平（旧主 13 条）并标旧主 standby，方向验证 `R→P` 允许、`P→R` 拒绝；⑤`ha-watch --active ... --interval --fail-threshold [--once]` 连续 N 次探测不到主目录自动 failover 后退出（主存活不切、消失 3 轮后自动切并更新 active）。回归：正常主→副本同步不受影响；native/wasm 全绿。
- M157 热温冷分层修复与成本证据（3.6 复核后优化）：复现两个真实缺陷——①**相对 cold-dir 生成悬空 symlink**：`tier <dir> relcold` 把段迁到 `relcold`，链接按主目录解析 → `stats` disk=0、`scan` 只读到 16477/40000（数据不可用）；现在 CLI 与 backend 双重拒绝非绝对 cold-dir。②**LZSS 压缩反而膨胀**：`lz_find_match` 只线性回扫最近 64 个位置，日志行间距 ~89B 匹配不到，2.52MB 段压缩后反而变大（+2.6%），而 `stats disk_bytes` 用逻辑长度掩盖；改为 3 字节哈希链（4096 桶、链深 256）后 2.52MB→**0.874MB（−65.3%，已 roll 段 4.6x）**，解压 20000 条全一致；无收益段保留原样不膨胀。③`stats` 的 `disk_bytes` 改实际文件大小（跟随冷层链接）。④`archive` 纳入 `AUDIT`/`TTL_AUDIT` 审计文件。⑤`tier --json`。实测：绝对 cold-dir 迁移后 scan/query/aggregate 透明（冷桶 30 命中）、归档 12 文件（含审计）恢复 90 条；新增 LZ 压缩比单测；native 207/wasm 全绿。
- M158 全文检索短语与中文增强（4.1 复核后优化）：复现两个真实缺陷——①**倒排短语假阳性**：`search --inverted "user login"` 是 token AND、不校验相邻与顺序，命中 `login failed for user bob`（2 条，线性 1 条）；②**中文倒排 0 命中**：`tokenize` 只产 ASCII 词、CJK 不产 token，`--inverted 数据库` 返回 0（线性 1）。优化：①`tokenize` 把非 ASCII 文本按 UTF-8 **字符 unigram** 入索引（零依赖、非词典分词），`INV_VERSION` 3→4 旧 sidecar 自动重建；②查询侧**自适应路由**：含空格（短语）或非 ASCII（CJK）时走精确线性子串路径，英文单 token 仍走倒排词级——短语相邻语义正确，且中文 4 万条实测 **0.244s**（倒排候选+精滤版 0.444s、线性 0.243s），不再比线性慢。实测：`user login` 2→1（==线性）、`数据库` 0→1（==线性）、`数据库连接` 1、`数据失败` 0、`login` 2（词级倒排不变）；旧 v3 sidecar 自动重建 v4；新增 CJK tokenize 单测；native 208/wasm 全绿。
- M159 组合条件下推强化（4.2 复核后优化）：复现发现 `--indexed` 只按**第一个**等值/范围条件预筛，其余条件在内存精滤——`--level error --service svc3 --host h7` 只下推 level（候选 8021），service/host 未在存储层过滤，与"组合条件下推到存储层执行"的验收口径不符。优化：`idx_sel` 单条件改为 `idx_filters` 列表（level 精确/范围、service、host、trace_id 全部下推）；段循环对每个条件取字段列 posting 并集，**任一为空即整段跳过**，多条件取**最短 posting** 作候选（2087 vs 8021）再全条件 AND 精滤；新增 `--explain` 输出 pushed/candidates/segments_skipped。实测：多条件候选 2087、42 命中与线性一致；范围+等值 4082/1625；`--until 1` 跳 4 段 0 候选；未知 trace_id 组合 0 候选（存储层直接判定无需精滤）；native/wasm 全绿。
- M160 强制时间范围扩展到 search（4.3 复核后优化）：复现发现两处真实缺口——①**`query --json` 被默认窗 INFO 行污染**：无 `--since` 时首行是 `INFO query scoped to...` 而非 JSON，破坏自动化管道；②**`search` 仍可无边界全表扫描**：无时间参数，2 天前的旧数据照常命中（3 条），与"查询默认或强制携带时间范围"不符。优化：①`query --json` 时抑制 INFO（文本模式保留提示）；②`search` 新增 `--since/--until`（事件时间）与 `--require-time`，无 `--since` 默认降级 24h 并提示，`--since 0` 显式全表；线性与倒排两条路径都按记录 ts 过滤，`--from/--to` 保持 offset 语义可组合。实测：search 默认窗 1 条（旧 2 条排除）、`--require-time` 拒绝、`--since 0` 3 条、`--since 0 --until <new-ts>` 2 条、`--inverted` 同样 1/3、`MOONLOG_QUERY_WINDOW_MS=1` 0 条；query --json 首行为 JSON；4.1 回归不变；native 208/wasm 全绿。
- M161 上下文检索同线程/JSON 关联与事件时间顺序（4.4 复核后优化）：量化发现三处真实缺口——①**JSON 记录的 `--trace-id auto` 静默失效**：`{"trace_id":"tJ",...}` 的 value 不是 KV 形态，旧提取只扫 `trace_id=` → 过滤退化为物理窗口（锚点 7 输出 4,5,6,7 混入他请求）；②**无同线程入口**：`--thread-id` 未实现且未知参数被静默忽略（原文"同线程/同请求"）；③**乱序到达时顺序错误**：窗口按 offset 序输出（ts 1000,5000,4000,6000），无事件时间排序（原文"顺序正确"）。优化：①关联提取 `ctx_value_fields`（首字节 `{` 走 2.1 JSON 展平，否则 KV）+ `ctx_name_eq` 字段名 squash（`trace_id`/`traceId`/`trace.id`）；②新增 `--thread-id <id|auto>`，与 trace/service 同时 AND；③新增 `--sort-by-time`（收集窗口后按 ts 升序、tie offset）；④service/trace/thread 值比较 ci。实测：JSON auto 2 条（旧混入）、thread auto 4 条、sort 输出 0→4→2→5、默认 offset 序与 M106 无关联回归不变；native 208/wasm 全绿。
- M162 Live tail 结构化过滤与生产可观测（4.5 复核后优化）：复现三处真实缺口——①**JSON 结构化日志的过滤静默失效**：`--level-min error`/`--service orders` 只认 `k=v` 文本与记录键，SDK 追加的 `{"level":"ERROR","service":"orders",...}` 被整体排除（level 只命中 1 条 KV、service 0 条），与 2.1/2.2 的 JSON 展平与统一 schema 脱节；②**level 大小写敏感**：`ERROR`/`Warn` 落 unknown 被排除，线上结构化日志常见；③**生产可观测缺失**：SIGTERM/SIGINT 直接杀进程，终态统计与游标不可见，且无过滤数/实时滞后指标。优化：过滤改为 `ctx_value_fields`（首字节 `{` 走 2.1 JSON 展平）+ `schema_from_fields` 取统一字段，`--service` 匹配记录键或 service 字段（大小写不敏感），level 取别名（severity/lvl 等）并 ASCII 小写后 `level_rank`（未知仍排除）；安装 shutdown handler 协作退出，终态输出 `(N records, cursor C; F filtered, max lag Lms)`（`--flush` 一并刷新）；**持续有新记录时立即续轮（1ms 让出）**，空闲轮保持 `MOONLOG_FOLLOW_INTERVAL`（默认 200ms）。实测：JSON `level-min error` 3 条（旧 1）、`service orders` 3 条（旧 0）、`ERROR`/`Warn` 大写正确命中；无过滤 4 条、`--commit` 后二次 0 条不重放、命名游标 3；SIGTERM/SIGINT 退出码 0 且统计落盘（旧无统计）；记录级延迟 24–198ms 仍远低于秒级；native 208/wasm 167 全绿、fmt clean。
- M163 查询保护覆盖 search、结果上限与快照读（4.6 复核后优化）：复现四处真实缺口——①**search 完全绕过保护**：无并发槽/超时/预算（`MOONLOG_QUERY_TIMEOUT_MS=1` 无效，40 万条全扫 3.6s），4.3 已把时间窗扩到 search 但 4.6 仍只护 query；②**结果集无默认上限**：`query --since 0` 输出 40 万行（3.9s），原文"结果集上限"未落地；③**长查询阻塞写入**：query 持共享目录锁扫描 3.9s，期间 put 实测 **3815ms**（idle 629ms）——默认 30s 超时下单条慢查询可把写入拖住 30s；④search 不受槽位约束（占槽后仍立即执行）。优化：①`run_read_snapshot`——只在打开时持共享锁，随后释放扫描（段 append-only + 打开 fd 保证快照可读），query/search 两条路径（线性+倒排）改用；②search 接入 `acquire_query_slot` + `QueryGuard`（段级 check + 每 512 条采样，`--timeout` 参数）；③结果上限 `default_max_results`（env `MOONLOG_MAX_RESULTS` 默认 1000，`--limit -1`/env 0 解除），终态标注 "stopped at limit" 并提示。实测（40 万条）：search `--timeout 1` 384ms 中止（旧忽略）、预算 2000 直接拒绝、占槽被拒（旧绕过）；query/search 无 `--limit` 均 1000 条、`--limit -1` 全量 400010 行、env 50/0 生效；长 query 期间 put **3815ms→579–665ms**（idle 449–484ms）；查询快照不含期间新写（0 条）、下次查询可见；小数据 3/1 条全量、`--explain`/`--inverted`/context/aggregate 回归正常；native 208/wasm 167 全绿。
- M164 聚合统计 JSON 字段与时间下推（5.1 复核后优化）：复现四处真实缺口——①**JSON 记录的 kv-field/quantile 静默失效**：`{"latency":120,"service":"orders"}` 在 `--quantile latency` 下 3 条 skipped（仅 1 条 KV 命中）、`--kv-field service` 输出 3 个 `<missing>`；②**聚合持锁扫描阻塞写入**：aggregate 全表 2.6s，期间 put **2529ms**（idle ~450–600ms），与 4.6 修复前的 query 同病但分析命令未纳入；③**聚合不受 4.6 保护**：`MOONLOG_QUERY_TIMEOUT_MS=1` 对 aggregate/trend 无效（仍全表跑完）；④**无时间范围**：aggregate/trend 只能全表，40 万条 2.6s，无法按窗口秒级返回。优化：①`--kv-field`/`--quantile` 改用 `ctx_value_fields`（首字节 `{` 走 2.1 JSON 展平）；②aggregate/trend 加 `--since/--until` + 默认 24h 窗（`--since 0` 全表，`--json` 下不打印 INFO）、段级 min_ts/max_ts 下推跳段；③改用 `run_read_snapshot` + `acquire_query_slot` + `QueryGuard`（段级 + 每 512 条），扫描不持写锁、超时/预算生效。实测（40 万条）：quantile JSON+KV 4 桶 0 skipped（旧 1 桶 3 skipped）、kv-field service orders 3/payments 1（旧 3 `<missing>`+1）；1h 窗 aggregate **447ms**（旧全表 2.6s）、默认 24h 结果与全表一致（200016 桶）；aggregate 期间 put **2529ms→511ms**（idle 量级）；timeout 1ms 在 380–393ms 中止（旧忽略）；trend `--since/--until` 正常、JSON 输出无 INFO 污染；native 208/wasm 167 全绿。
- M165 错误聚类上下文匹配与跨语言/JSON 堆栈（5.2 复核后优化）：复现四处真实缺口——①**默认 `--match "error"` 下 `--stacks` 帧全丢**：帧行本身不含 error 被过滤，NPE 堆栈 frames=0（`--match ""` 才 4），默认生产路径等于没有堆栈归并；②**帧判定只认 Java/Python/Caused by**：Go 的 `goroutine`/`main.handler(0x…)`/`x.go:12 +0x1d`、Rust 数字帧与 `at ./x.rs:12`、JVM `... 23 more` 全部按行拆簇（实测 9 簇）；③**JSON 记录的内嵌堆栈不识别**：`{"stack":"…\n\tat …"}` 的 frames=0、模板是整条 JSON；④**无保护/时间窗/JSON 输出**：`MOONLOG_QUERY_TIMEOUT_MS=1` 无效（40 万条全扫 4.3s）、聚类持锁期间 put 被拖住、`--json` 静默忽略。优化：①帧行判定先于 `--match` 归并到最近匹配头（非匹配头清空链条，孤立帧兜底成簇）；②`is_stack_frame` 扩展 Go（goroutine/created by/`(0x`/`+0x`+`.go:`）、Rust（`N: x::y`、`at path:line`）、`Suppressed:`、JVM 省略帧尾；③JSON `stack`/`stacktrace`/`exception` 字段按行拆、按归一化 stack 聚簇（同堆栈不同 message 同簇）、帧数按 `is_stack_frame` 行统计、sample 用 message；④`--since/--until` + 默认 24h 窗 + 段下推、`run_read_snapshot` + 槽位/`QueryGuard`、`--json` 输出 `{mode,clusters,total}`、未知选项报错。实测：默认 `--stacks` frames **0→4**；跨语言 **9→2 簇**（Go 5 帧、Rust 5 帧）；JSON 3 条不同 message 同堆栈 → **1 簇 frames=6**、sample 可读；timeout 1ms 在 366ms 中止（旧 4.3s）；聚类期间 put **464ms**（idle 量级）；M132 NPE/ISE 回归 2 簇帧数正确；native 209/wasm 168 全绿。
- M166 阈值告警 JSON 指标与实时可观测（5.3 复核后优化）：复现五处真实缺口——①**JSON 记录的指标/过滤静默失效**：`--metric latency` 对 `{"latency":400}` samples=0（无 ALERT）、`--level-min error` 排除全部 JSON（0 条）、`--service orders` 只认记录键（0 条）且大小写敏感；②**告警输出未 flush**：重定向到文件时 ALERT 不可见（C stdio 全缓冲），SIGTERM 直接杀进程无终态统计；③**`--json` 的 stdout 被 `(watch ended...)` 污染**；④**触发延迟 2190ms**（every=1000，固定 sleep 等满周期）；⑤**抖动无防护**：metric 单样本尖峰可 firing、窗口空/低立即 resolved（firing/resolved 反复），且无 min-samples/resolve-after。优化：①字段解析改 `ctx_value_fields` + `schema_from_fields`（level ASCII 小写后 `level_rank`、service 匹配键或 schema 字段 ci、metric 字段名 squash）；②事件与终态 `flush_stdout`，装 shutdown handler 协作退出，`--json` 终态输出 summary JSON；③有新增记录 1ms 续轮；④新增 `--min-samples`（默认 1）与 `--resolve-after`（默认 1，连续 N 轮不越界才 RESOLVED）；⑤未知选项报错。实测：JSON metric firing avg=500（旧无事件）、level-min 4 条（旧 0）、service 4 条（旧 0）、`Orders` 命中 `--service orders`；`--json` 2 行均可解析；触发延迟 **2190ms→687ms**；SIGTERM 输出 ALERT+summary（旧无）；resolve-after 1/2/3 恢复延迟 **1003/1203/1403ms**（+200ms/轮）；min-samples 2 单样本不触发；M133 storm 回归 1 ALERT+1 RESOLVED、escalate 正常；native 209/wasm 168 全绿。
- M167 告警抑制与通知可达性（5.4 复核后优化）：复现四处真实缺口——①**抑制缺失**：原文明确要求"抑制"，`watch` 只有去重/升级，无维护窗口静默（发布期仍会向所有渠道风暴）；②**通知失败不可观测**：webhook/钉钉/企微/邮件失败只 `println` 文本 warning 到 stdout（`--json` 下 3 行中 1 行非 JSON）、无计数与终态，失败后也不重试；③**dry-run 污染 `--json`**（命令文本行）；④**钉钉/企微 payload 非法**：`"content":` 直接拼未加引号的 summary（`{"content":ALERT firing…}`），真实平台会拒绝——M134 的 dry-run 只打印未校验 JSON。优化：①新增 `--snooze-until <epoch_ms>` 维护窗抑制：事件照常输出（`"suppressed":true`）但不投递任何外部渠道（含升级），终态统计 suppressed；②`dispatch_notification`/`notify_extra` 返回失败数，watch 累计 `notified/notify_failures`，`--json` 下不再打印文本 warning（summary 字段替代），文本模式保留 warning；③dry-run 在 `--json` 下输出 JSON 事件（channel/url/payload）；④钉钉/企微 payload 的 content 值补引号，真实 POST 可被平台接受。实测：抑制 firing `suppressed=true`、summary suppressed=1/notified=0、notify-file 不生成；无抑制 webhook 失败 `notify_failures=1` 且 stdout 2 行纯 JSON；dry-run JSON 2 渠道可解析；python 收 POST 验证钉钉/企微 payload 合法（content 为字符串）；抑制下 escalation 也 suppressed（summary suppressed=2）；webhook 可达时 firing 真实入 hook；alert/baseline 回归；native 209/wasm 168 全绿。
- M168 值班看板延迟趋势、维度切换与历史下钻（5.5 复核后优化）：复现五处真实缺口——①**原文"延迟趋势图"缺失**：`--quantile-field` 只给窗口级 min/avg/p50/p95/p99/max，没有按桶趋势；②**JSON 记录被旧解析坑害**：`{"level":"INFO","msg":"no error observed"}` 无 level 字段识别，被 "error" 子串兜底误判为错误（错误率 75% vs 真实 50%），`{"latency":900}` 完全不参与分位数（样本 20 vs 40）；③**维度切换不在面板内**：只有 top services，切换维度要另跑 aggregate；④**无法回看历史**：只有 `--last` 相对窗口，`--since/--until` 被静默忽略；⑤**扫描持共享锁**：无快照读/槽位/超时，慢看板可拖住写入。优化：①每桶 latency（n/p50/p95/p99/max）+ p95 条形趋势，JSON `windows[].latency`；②`ctx_value_fields` 统一 KV/JSON，level 别名 + ASCII 小写 + rank≥3，仅无 level 字段才兜底 "error"；③`--by service|level|host|key` + `--top N` 维度表（每维 total/errors/err%/p95）；④`--since/--until` 绝对事件时间窗（`--since 0` 全表），非法窗口与未知选项报错；⑤`run_read_snapshot` + `QLOCK` 槽位 + `QueryGuard`（段级 + 每 512 条）+ 段级下推，并在取槽前 ensure_dir（修复新目录被误报 "too many concurrent queries"）。实测：混合 40 条错误率 75%→50%、延迟样本 20→40、每桶 p95=900 可见、`--by level` error/info 各 20、`--since/--until` 5 分钟窗 20 条、`--service ORDERS` 命中 JSON 10 条；4 万条（5% error）**419–473ms**（旧 391ms 同量级）、错误率 4.98%、p50/p95/p99=496/947/987、期间 put **25ms**、timeout 1ms 3ms 中止、空目录 0 面板；native 209/wasm 168 全绿、fmt clean。
- M169 异常检测 JSON 语义、历史窗口与查询保护（5.6 复核后优化）：复现五处真实缺口——①**JSON 假阳性**：`{"level":"INFO","msg":"no error observed"}` 只走 "error" 子串兜底，被报为新错误模式 ×3；②**JSON 新错误漏报**：模板基于整条 JSON，`trace_id` 不同把同一错误拆成 3 个单例模板，低于 `--min-count 2` 而不报；③**无历史回看**：只有 baseline/recent 相对 now，`--since/--until` 被静默忽略；④**无保护**：`run_locked` 内全表扫描、无槽位/QueryGuard/超时，慢检测阻塞写入；⑤**`--json` 非法**：new_patterns 的 sample 缺关闭引号，一旦有检出 Python 无法解析（旧验收只打印未解析）。优化：①`ctx_value_fields` 统一 KV/JSON，level 别名 + ASCII 小写 + rank≥3，仅无 level 字段才兜底 "error"；②JSON 错误模板取 message 类字段，KV/纯文本保持整条 value（避免空格截断）；③`--since/--until` 绝对最近期窗口（基线=同长度前一段）、`--service` 收窄、未知选项报错；④`ensure_dir` + `run_read_snapshot` + 槽位 + `QueryGuard` + 段级下推；⑤JSON 增加 `window`/`counts`/`generated_at` 并修复 sample 引号。实测：假阳性 3→0、cart cache miss 3 个单例→1 簇 ×3、payment declined 正确排除、KV 三类全触发、历史窗 19 条、`--service CART` 正确、4 万条 343ms、期间 put 21ms、timeout 1ms 3ms 中止、空目录 0；native 209/wasm 168、fmt clean。
- **Live tail**（4.5）：实时流式跟踪由 `follow <dir> tail` 承载（200ms 轮询、游标持久化、`--json`，M104 前既有），本子项补**发布观察/线上调试的过滤与延迟证据**——`follow --match <text>`（key/value 子串）、`--level-min <level>`（严重度下界，未知级别排除，与 query 语义一致）、`--service <svc>`（记录键）：只收窄打印流、**游标照常推进**（被过滤记录视为已消费，--commit 不卡住）；`--flush` 逐条刷新 stdout（C 运行时对管道/文件全缓冲，live tail 管道与重定向观测必需）。**端到端延迟**：约定口径 = 发现延迟 ≤ 轮询间隔（默认 200ms）+ 一轮处理时间；实测（`--flush` + bash 观测，含 put 进程启动开销）记录级 108-196ms、最差 <600ms——**远低于秒级约定**，且 `MOONLOG_FOLLOW_INTERVAL` 可调更紧。实测：三维度过滤（error 级 2 条/db 子串 2 条/orders 服务 2 条）各自正确、过滤 + `--commit` 后游标推进到最新（二次 follow 0 条不重放）、`--level bogus` 报错。
- **查询保护**（4.6）：`query`/`search` 共用四重防线，单条异常查询不拖垮库（也不阻塞写入）——①**超时**（执行中熔断）：`--timeout <ms>`（默认 30s，env `MOONLOG_QUERY_TIMEOUT_MS`，0=禁用），`QueryGuard` 在段级 + **每 512 条记录**采样时钟，超限即报错并附扫描统计（段数/字节）；②**扫描预算**（执行前/中熔断）：`MOONLOG_MAX_SCAN_BYTES`（默认 512MB，0=禁用）——时间下推后的扫描集字节累积超限即拒绝（与 4.2/4.3 闭环：窗外段不入账）；③**并发限流**（槽位信号量）：`<dir>/QLOCK.<i>` 非阻塞 flock 槽位（默认 4，`MOONLOG_MAX_CONCURRENT_QUERIES`），全忙等待至锁超时后拒绝 "too many concurrent queries"；槽位生命周期=进程（CLI 短命退出即释放）。**结果集上限**：`query`/`search` 在未给 `--limit` 时默认停在 `MOONLOG_MAX_RESULTS`（1000），终态显式标注截断并提示 `--limit -1` 解除。**查询不持锁扫描**：读路径只在打开快照时持共享锁，随后释放——长查询期间写入照常进行（旧实现写者要等整条查询结束）。`search` 的线性与倒排两条路径同样经过并发槽位/超时/预算/结果上限。实测：`--timeout 1` → `query timeout after 19 ms (8 segments, 501845 bytes scanned)`、`MOONLOG_MAX_SCAN_BYTES=2000` → `scan budget exceeded: 501845 bytes > 2000`、1 槽 + 长查询占位 → 第二查询 `too many concurrent queries (limit 1)`、异常查询被拒后 put/query 全部正常。2026-11-09 优化实测（40 万条数据集）：`search --timeout 1` 384ms 中止（旧参数被忽略、全扫 3.6s）、`MOONLOG_MAX_SCAN_BYTES=2000` 直接拒绝、占槽后 `search` 被拒（旧绕过）、`query`/`search` 无 `--limit` 均停在 1000 条、`--limit -1` 恢复全量；长 query 期间的 `put` 3815ms→579–665ms（idle 449–484ms），写入不再被查询阻塞。
- **聚合统计：分位数**（5.1）：`aggregate --quantile <field>` 对 value 内数值字段做分布统计（KV `name=value` 与 JSON 值按 2.1 展平后均可解析）——与 `--by`/`--kv-field` 维度组合（每桶独立分布），每桶输出 **count/min/avg/p50/p95/p99/max**（最近邻秩法 `ceil(q*n)-1`，零依赖无 math 库；`@string.parse_double` 解析、非数值或缺字段计入 `skipped`）；无 `--quantile` 时保持纯计数模式（向后兼容）。**秒级验收**：4 万条 latency 数据集 `aggregate --quantile latency` 实测 **426ms**（<1s），分布与理论吻合（`i%997`：P50=496/P95=946/P99=986）；40 万条全表 2.6s，但 1h 窗（段级下推）**447ms**。**时间范围与保护（M164）**：`aggregate`/`trend` 支持 `--since/--until`，无 `--since` 默认最近 24h（`--since 0` 全表，`--json` 不打印 INFO），时间界经段级 `min_ts`/`max_ts` 跳段；与 `query` 共享 `QLOCK` 并发槽/`QueryGuard`（段级 + 每 512 条采样）并改用快照读——长聚合不再阻塞写入（put 2529ms→511ms）。实测 JSON `{"latency":120,...}` 聚合 0 skipped（旧 3 skipped）、`--kv-field service` 正确分组（旧 3 个 `<missing>`）；手工验算 10 样本等差序列 P50=35/P95=70/P99=70/avg=38.5 精确正确；count 模式与 trend 回归正常。
- **错误聚类：堆栈归并**（5.2）：`cluster --stacks`——多行堆栈不再按行拆簇：Java/.NET/Node `at …(…:…)`、Python `File "…"`、Rust `N: x::y` 与 `at path:line`、Go `goroutine`/`main.handler(0x…)`/`x.go:12 +0x1d`、`Caused by`/`Suppressed`/`... N more` 链行（core `is_stack_frame`）**归并到最近匹配头**（帧行本身不含 `--match` 也保留；非匹配头中断链条），每簇附 frames 数与 sample（JSON 堆栈用 message）；同异常类不同 id/行号同簇；JSON 记录的 `stack`/`stacktrace`/`exception` 字段按归一化堆栈聚簇（同堆栈不同 message 也同簇）；`--json` 输出 `{mode,clusters,total}`；无 `--since` 时默认最近 24h（`--since 0` 全表），时间界经段级 `min_ts`/`max_ts` 下推，与 query 共享并发槽/超时/预算且扫描不持写锁。实测：默认 `--stacks` frames 0→4、跨语言 9→2 簇、JSON 3 条不同 message 同堆栈 1 簇 frames=6
- **阈值告警：滑动窗口 watch**（5.3）：`watch <dir> <match-text> --threshold N`——**滑动窗口持续监控**（内存缓冲最近 `--window-sec` 的记录，每 `--every <ms>` 默认 1s 重估，**触发延迟 ≤ 评估周期**；有新记录时立即重评估，实测 687ms @every=1000）；两类指标：**计数**（窗口内匹配记录数）与**数值指标**（`--metric <field> --metric-threshold <v>`——窗口内该字段数值的 **avg** 越界，延迟类指标）；`--level-min`/`--service` 窄化（**KV 与 JSON 值都解析**，level 大小写不敏感、service 匹配键或 schema 字段）；**不产生误报风暴**：firing/resolved 状态机——越界进入 firing 只发 1 条告警，持续越界不重复，回落发 resolved；`--min-samples N` 过滤样本过少的尖峰、`--resolve-after N` 连续 N 轮不越界才恢复（实测恢复延迟 1003/1203/1403ms 对应 1/2/3 轮）；**事件立即 flush**（管道/重定向实时可见），SIGTERM/SIGINT 优雅退出输出 evals/firings/resolved 统计，`--json` 终态为 summary JSON（stdout 全程可解析）；通知复用三渠道（`--notify-file`/`--webhook`）；`--once` 单轮评估（`from 0` 评估现有窗内数据）。实测：JSON metric firing avg=500、level-min 4 条、service 4 条（旧均静默失效）；burst1 3 条 → 1 ALERT、持续无重复、窗口滑出 1 RESOLVED；escalate 正常；`alert` 固定窗口回归（M108）。
- **告警收敛与通知**（5.4）：`watch` 支持**抑制、去重、升级与通知可观测**：`--snooze-until <epoch_ms>` 维护窗抑制（事件照常输出 `suppressed=true` 供审计，不投递任何渠道，升级同样抑制，终态统计 suppressed）；`--escalate-sec S` 升级（firing 持续 S 秒发 **1 条 ESCALATED**，elapsed_ms 可审计，升级有界）；去重沿用 firing/resolved + `--resolve-after` 状态机；**通知渠道适配器**——`--dingtalk <url>`（`{"msgtype":"text","text":{"content":…}}` 钉钉机器人信封）、`--wecom <url>`（`{"msgtype":"text","content":{"content":…}}` 企微机器人信封）、`--email <to>` + `--smtp-url <url>`（curl SMTP：.eml 临时文件 + `--mail-from/--mail-rcpt/-T`，零 SMTP 客户端依赖）、`--notify-dry-run`（打印投递动作验证组装）；firing/resolved/escalated 每次转换全渠道各投 1 次（`dispatch_notification` 三渠道 + 适配器）；**通知可达性可观测**：dispatch/notify_extra 返回失败数，summary 输出 `notified/notify_failures/suppressed`，`--json` 下失败不再以文本 warning 污染 stdout，dry-run 也输出 JSON 事件。范围决策：跨规则抑制/多源收敛在单机单目录单规则 watch 下无场景（README 注明定位），单规则维护窗抑制由 `--snooze-until` 覆盖。实测：风暴收敛（burst → 1 ALERT + 1 RESOLVED；抑制期 0 投递，summary suppressed=1/2）；webhook 可达时 firing 真实入库、不可达时 notify_failures=1 且 stdout 纯 JSON；钉钉/企微 payload 经 python POST 校验为合法 JSON（content 为字符串）；`--notify-dry-run` JSON 可解析；alert/baseline 回归正常。
- **可视化看板：值班面板**（5.5）：`dashboard <dir>`——**单遍扫描输出综合巡检面板**（值班一眼看全）：①量+错误率直方图（每桶 total/errors/err% + `#` 条形）；②**每桶延迟趋势**（`--quantile-field` 时每桶 n/p50/p95/p99/max + p95 条形，文本与 `--json` 的 `windows[].latency` 同时给出）；③窗口汇总与窗口级延迟分位数；④**维度切换** `--by service|level|host|key`（默认 service，每维 total/errors/err%/p95 + `--top N`）。字段解析统一走 `ctx_value_fields`（KV 与 JSON 展平），level 认 `level/severity/severity_text/lvl/loglevel/log.level` 且**大小写不敏感**，仅当记录没有 level 字段时才用 "error" 子串兜底（避免 `{"level":"INFO","msg":"no error"}` 假阳性）；错误判定 rank≥3。时间窗两条路径：`--last <sec>`（默认 1h）或绝对 `--since/--until <ms>`（`--since 0` 全表）用于**历史故障回看**；段级 `min_ts/max_ts` 下推跳段。**生产可用（M168）**：`run_read_snapshot` 快照读 + `QLOCK` 并发槽 + `QueryGuard`（段级 + 每 512 条采样，超时/扫描预算）、未知选项报错、空目录正常出 0 面板。**实测**：混合 40 条 KV+JSON，错误率 75%→50%（假阳性消除）、延迟样本 20→40、`--by level` error/info 各 20、`--since/--until` 5 分钟窗精确 20 条、`--service ORDERS` 大小写不敏感命中 JSON 10 条；4 万条（5% error）综合面板 **419–473ms**（仍 <1s），错误率 4.98%、p50/p95/p99=496/947/987 与理论一致，dashboard 扫描期间 put **25ms**、`MOONLOG_QUERY_TIMEOUT_MS=1` 3ms 中止；native 209/wasm 168 全绿。范围决策：无交互式 UI/Web 服务（文本面板 + JSON 即看板数据面，勿提议前端框架）。
- **异常检测：自动基线**（5.6，进阶）：`anomalies <dir>`——**零规则配置**的三类自动检测：①**VOLUME_SPIKE**（最近分钟桶 vs 基线分钟桶分布 mean/std，z>σ）；②**NEW_PATTERN**（错误模板的基线/最近**差集**，`--min-count` 滤噪声、附 sample）；③**SEASONAL_DEVIATION**（hour-of-day 日均值 vs 最近计数，泊松近似 z）。**M169 复核优化**：①字段解析统一 `ctx_value_fields`（KV/JSON），level 别名 + 大小写不敏感 + rank≥3，仅无 level 字段才兜底 "error"（修 `{"level":"INFO","msg":"no error"}` 假阳性）；②JSON 错误按 `message/msg/body/error/exception` 字段归一化模板，`trace_id` 等易变兄弟字段不再把同一错误拆成多模板（`cart cache miss` 从 3 个单例模板→1 簇 ×3，已有 `payment declined` 仍正确排除；KV/纯文本保持整条 value 语义，避免 `msg=a b` 截断）；③新增 `--since/--until` 绝对事件窗回看历史（基线自动取同长度前一段）、`--service` 按服务收窄三类检测，未知选项报错；④接入 `ensure_dir` + `run_read_snapshot` + `QLOCK` 槽位 + `QueryGuard`（段级 + 每 512 条采样）+ 段级 `min_ts/max_ts` 下推，扫描不阻塞写入；⑤`--json` 增加 `window`（基线/最近绝对区间）、`counts`（记录/错误/非空分钟桶/基线天数）、`generated_at`，并修复 sample 缺关闭引号导致有 new_patterns 时 JSON 不可解析的旧缺陷。**实测**：JSON INFO "no error" 假阳性 3→0、JSON 新错误 3 个单例模板→1 簇 ×3、已有模板正确排除、KV 三类全触发（burst z=14.3、`disk full` ×3、seasonal z=20.9）、历史 `--since/--until` 精确 19 条、`--service CART` 只报 cart、空目录 0 面板；4 万条 343ms、期间 put 21ms、timeout 1ms 3ms 中止；native 209/wasm 168 全绿。

## 许可

Apache-2.0