# 任务进度与可恢复点

## 2026-04-21 · GRDB/SwiftData 兼容实现 · L3 实施阶段

### 任务目标
实现 JsonData L3：macOS 走 SwiftData 原生路径，Linux/Windows 走 GRDB/SQLite；Predicate 编译成 SQL，不退回内存遍历。遵守最小修改原则。

### L3 实施计划（用户明确）

| 原则 | 说明 |
|------|------|
| 最小验证 | 增量测试，逐项验证通过再继续 |
| 隔离测试 | 新路径独立测试，不影响现有功能 |
| public API 不变 | 对外接口保持一致 |
| 非 SwiftData 路径改 SQLite/GRDB | Linux/Windows 切换存储后端 |
| predicate 编译成 SQL | 不接受内存遍历降级 |
| faulting/identity map 保持 | 心智模型与 SwiftData 对齐 |

### 已落地实现

| 文件 | 功能 |
|------|------|
| `Package.swift` | GRDB.swift 7.10.0 依赖接入 |
| `SchemaMetadata.swift` | `_JsonDataColumnKind`、`_JsonDataColumnInfo`、`_JsonDataSchemaProviding` |
| `JsonData.swift` | 宏定义、协议、类型导出 |
| `JsonDataMacros.swift` | `@Model` 宏生成，`_copy(from:)` 逐属性复制模板 |
| `ModelContext.swift` | GRDB runtime：存储层、fetch、predicate→SQL、identity map、faulting |
| 5 个隔离测试文件 | SchemaMetadataTests、TransientTests、SQLiteRuntimeTests 等 |

### 技术约束（铁律）

- macOS 必须走 SwiftData 原生路径，禁止 `JSONDATA_FORCE_CUSTOM_RUNTIME` 类人为分叉
- Linux/Windows 改为 SQLite/GRDB
- fetch predicate 必须编译成 SQL，禁止退回内存遍历
- 外部 public API 与写法不变
- 最小修改原则

### 最新修复（本次）

| 修复项 | 内容 |
|--------|------|
| `ModelContext.swift` - `_loadModel(for:)` | 从 `model(for:)` 抽出为独立方法 |
| `ModelContext.swift` - `_faultIn` | 不再调用 `model(for:)` 新建对象，而是就地 `_copy(from:)` 并保持 identity map 指向原 fault 实例 |
| 语义保证 | 同 ID 实例复用：`identity map` 始终指向首次创建的 fault 对象，fault 激活后原地更新数据而非替换引用 |

### 测试状态

| 环境 | 结果 |
|------|------|
| glibc Debian orb 全量测试 | 6 项测试曾通过 |
| agent tests 首次在 Debian orb | 5 项里 4 项通过，**faulting_identityMap 失败** |
| 修复后再次在 Debian orb | SwiftPM 构建缓存/auxiliary file not registered 内部错误 |
| clean 重跑 | GRDB 依赖拉取卡住，TLS/RPC early EOF，**已中断** |

### 当前需要（优先级）

1. **优先**：本地或��稳妥的 Debian 验证，确认 agent tests 尤其 `faulting_identityMap` 修复后通过
2. **其次**：跑全量测试验证
3. **musl/static-linux**：仍未打通，根因是 GRDB `systemLibrary` 依赖 `sqlite3.h`，而 static SDK musl sysroot 不含 SQLite

### 复现与验证路径

```bash
# macOS 构建
swift build

# Debian 测试（glibc）
orb -m debian
swift test

# Debian 测试（musl/static - 阻塞）
orb -m debian
swift test --swift-sdk swift-6.3-RELEASE_static-linux-0.1.0
```
