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
- **保留策略**：`Log::drop_before` / `Log::retain_last` 以整段删除的方式回收旧数据。
- **消费游标**：`ConsumerCursor` 保存已提交读位置，按批 `poll`，可续读。
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
  cursor <dir> <start> <limit>  按批读取消费游标
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

## 里程碑

- M0/M1 脚手架、记录编码与内存后端、单段 append
- M2 多段 `Log` 与 native 文件后端
- M3 稀疏索引与范围扫描
- M4 崩溃恢复（torn-tail 截断）
- M5 tombstone、保留策略、消费游标
- M6 CLI 与文档

## 许可

Apache-2.0