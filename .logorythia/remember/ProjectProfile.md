# 项目画像：JsonData

## 仓库基线信息

- **路径**：`file:///Volumes/知阳/开发/Packges/JsonData/`
- **类型**：Swift 包（SPM），提供数据持久化抽象层
- **技术栈**：Swift 6，宏（SwiftSyntax），可选 SwiftData 透传

## 架构概览

```
SwiftData (macOS 14+) → SwiftData 原生
非 SwiftData 分支 → SwiftData-compatible runtime（GRDB 存储层）
```

### 核心文件

| 文件 | 职责 |
|------|------|
| `Sources/JsonData/JsonData.swift` | 宏定义（`@Model`、`@Transient`）、协议（`PersistentModel`）、类型（`FetchDescriptor`、`Field`、`SortDescriptor`） |
| `Sources/JsonData/ModelContext.swift` | 核心存储操作：CRUD、fetch、faulting、identity map |
| `Sources/JsonData/ModelContainer.swift` | 容器管理，关联 schema 和 context |
| `Sources/JsonData/Query.swift` | 查询相关类型 |
| `Sources/JsonData/SchemaMetadata.swift` | Schema 元数据类型（`_JsonDataColumnKind`、`_JsonDataColumnInfo`、`_JsonDataSchemaProviding`），仅在非 SwiftData 分支生效 |
| `Sources/JsonData/Compatibility/` | 兼容性处理目录 |
| `Sources/JsonDataMacros/JsonDataMacros.swift` | 宏实现，生成 `persistentModelID`、`_modelContext` 等 |

### 当前存储机制（非 SwiftData 分支）

- **路径**：SQLite 数据库（GRDB.swift 7.10.0）
- **Identity Map**：弱引用缓存，fault 对象原地更新，`identity map` 指向首次创建的 fault 实例
- **变更通知**：`Notification.Name("JsonData.ModelContextDidChange")`

### 条件编译策略
- macOS：走 SwiftData 原生路径（`canImport(SwiftData)`）
- Linux/Windows：走 GRDB/SQLite 路径（`!canImport(SwiftData)`）
- **禁止**：`JSONDATA_FORCE_CUSTOM_RUNTIME` 之类人为分叉

## 关键类型

### `PersistentModel` 协议
- 继承：`AnyObject`、`Codable`、`Observable`
- 必需属性：`persistentModelID: String`、`_modelContext: ModelContext?`、`_isFault`、`_isFaulting`
- 必需方法：`access(keyPath:)`、`withMutation(keyPath:_:)`、`fault()`、`_copy(from:)`

### `ModelContext` 核心方法
- `insert(_:)`：注册到 identity map + 触发 `_save()`
- `_save(_:)`：序列化模型为 JSON 写入文件
- `delete(_:)`：从 identity map 移除 + 删除文件
- `fetch(_:limit:)`：扫描目录、过滤、排序、反序列化
- `model(for:)`：按 ID 读取单个模型
- `_faultIn(_:)`：触发 fault 模型加载

## 构建命令

```bash
swift build                    # 开发构建
swift test                    # 测试
swift build --target JsonData # 单目标构建
```

## 现有依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| swift-syntax | 601.0.0+ | 宏实现 |
| GRDB.swift | 7.10.0 | SQLite 存储层（Linux/Windows，非 SwiftData 分支） |

## 项目目标

- **最终目标**：SwiftData 兼容运行时——心智模型和 public API 与 SwiftData 100% 对齐
- **存储后端**：JSON 文件 → SQLite（GRDB.swift）
- **平台**：Linux + Windows
- **ABI 兼容**：glibc + musl
- **约束**：public API 完全对齐；若有差异必须可枚举、可测试、可文档化

## SwiftData 兼容目标（三层分级）

### Level 1：API 同形
- **目标**：用户代码几乎不改，能编，能跑
- **要求**：`@Model`、`@Transient`、`PersistentModel`、`ModelContainer`、`ModelContext`、`FetchDescriptor`、`SortDescriptor` 的命名、可见性、基本调用方式完全对齐

### Level 2：核心心智同构
- **目标**：单模型 CRUD、faulting、predicate 查询、排序分页、`@Transient`、identity map 与 observation 主要行为对齐
- **必须对齐的行为验收项**：
  1. 同一 `ModelContext` 中，对同一记录反复查询，返回对象身份一致
  2. `insert` 后对象立刻拥有上下文归属，且可按 id 取回
  3. `delete` 后对象不再能被新查询命中
  4. 无 predicate 的 `fetch` 返回可 fault 的对象壳
  5. 有 predicate 的 `fetch` 由数据库执行筛选
  6. `sortBy / fetchOffset / fetchLimit` 语义与 SwiftData 对齐
  7. `@Transient` 字段不落库、不回填、不影响 faulting
  8. 首次访问 fault 对象属性时触发按主键加载
  9. 属性 mutation 的观察语义与上下文联动保持稳定
  10. 对不支持的 predicate，给出可预期错误，而不是静默降级

### Level 3：高阶语义逼近
- **目标**：更广的 predicate 支持、复杂类型策略、关系、迁移、并发与性能表现逐步接近 SwiftData
- **高风险差异区**：
  - Predicate 编译覆盖率（SQL 下推 vs 内存遍历）
  - SortDescriptor 的 SQL 化
  - 复杂字段类型（嵌套 Codable、数组、字典）的谓词支持
  - 保存时机（即时写库 vs 上下文感知的延后保存）
  - 并发与上下文隔离（多平台线程/锁模型验证）
  - 关系与预取

### 跨平台验收标准
- macOS 非 SwiftData 路径可编译、可测
- Debian glibc 环境可编译、可测
- Debian musl 环境可编译、至少通过核心 CRUD 与 predicate 测试
- Windows 至少能完成 build，并逐步覆盖核心测试
- 所有平台上，模型定义与 public API 用法完全一致，不允许出现平台差异泄漏

## GRDB 实施计划

### 架构分层

```
运行时模型（宏生成） → ModelContext（public API 不变） → GRDBStore（私有存储层）
```

### 表结构（单表方案）

```sql
CREATE TABLE jsondata_records (
    type_name TEXT NOT NULL,
    id TEXT NOT NULL,
    payload BLOB NOT NULL,  -- JSON 编码结果
    updated_at REAL NOT NULL,
    PRIMARY KEY (type_name, id)
);
CREATE INDEX idx_type ON jsondata_records(type_name);
```

### ModelContext 方法映射

| 原方法 | GRDB 实现 |
|--------|-----------|
| `_save(_:)` | `INSERT OR REPLACE` + JSON payload |
| `insert(_:)` | 保留调用顺序：identity map → `_modelContext` → fault → `_save()` |
| `delete(_:)` | `DELETE FROM jsondata_records WHERE type_name=? AND id=?` |
| `model(for:)` | identity map 查询优先，再 `SELECT payload WHERE type_name=? AND id=?` |
| `fetch(_:)` | 无 predicate：仅查 id 列构造 fault； 有 predicate：查 payload 后内存过滤 |
| `_faultIn(_:)` | `model(for:)` 截断，返回完整对象再 `_copy(from:)` |

### 关键设计决策

1. **JSON payload 策略**：不拆字段列，复用宏生成的 `CodingKeys` 和 `Codable`
2. **内存排序**：predicate decode 后内存求值；sort/offset/limit 先内存处理
3. **@Transient 保留**：宏阶段排除，不受存储后端影响
4. **Identity map key**：改为 `"\(typeName)::\(id)"` 复合 key

### 实施阶段

1. 引入 GRDB 依赖，条件编译准备
2. ModelContext 加 private store 适配层
3. 实现 GRDBStore，建库建表
4. 替换 CRUD/fetch/faultin 存储路径
5. 测试：回归 + CRUD + faulting + 查询语义
6. 跨平台验证：macOS → orb glibc → orb musl → Windows