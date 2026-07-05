# 已知陷阱与修复

## `#Index` 宏：参数必须包数组括号

- **位置**：`file:///Users/zhiyang/开发/Packges/JsonData/Sources/JsonDataCore/JsonDataCore.swift:<56>`
- **声明签名**：`public macro Index<T>(_ groups: [PartialKeyPath<T>]...) = ...`
- **正确写法**：`#Index<Record>([\.id])`（单列也要加 `[]`）
- **错误写法**：`#Index<Record>(\.id)`（缺括号，编译不通过）
- **说明**：参数类型是 `[PartialKeyPath<T>]...`（数组的变长参数），不是裸 `PartialKeyPath`。SwiftData 官方还支持 `Schema.Index.Types` 形式的第一个重载，JsonDataCore **未实现**该重载，只支持 `[PartialKeyPath]` 形式。
- **测试示例**：`file:///Users/zhiyang/开发/Packges/JsonData/Tests/JsonDataTests/CrossPlatformIndexUniqueTests.swift:<9>` → `#Index<IndexUniqueRecord>([\.firstName], [\.lastName, \.age])`

## `#Index` vs `#Unique`：重复值行为差异

- **`#Index`**：普通索引，**允许**重复值。纯加速查询，不约束唯一性。
- **`#Unique`**：唯一索引，**禁止**重复值。插入重复值时写入报错。
- **依据**：`file:///Users/zhiyang/开发/Packges/JsonData/Sources/JsonDataCore/ModelContext.swift:<220>-<227>`
  - `#Index` → `CREATE INDEX IF NOT EXISTS ...`
  - `#Unique` → `CREATE UNIQUE INDEX IF NOT EXISTS ...`
- **应用示例**：若某字段需要保证不重复（如 `id`），应使用 `#Unique` 而非 `#Index`：
  ```swift
  @Model
  final class MyModel {
      #Unique<MyModel>([\.id])  // 禁止 id 重复
      var id: String
  }
  ```

## PersistentIdentifier 类型映射缺失

- **位置**：`Sources/JsonDataCore/ModelContext.swift` → `_databaseArgument` 函数
- **现象**：数据库查询时 `PersistentIdentifier` 类型的参数返回 `nil`
- **根因**：`_databaseArgument` 函数未处理 `PersistentIdentifier` 类型，导致无法���射为 SQLite 参数
- **修复**：补充 `PersistentIdentifier` → `String` 的映射分支（将其 `stringValue` 作为参数值传入）
- **commit**：`f49f041`

## 锁内快照 + 锁外过滤（pending 变更并发模式）

- **位置**：`Sources/JsonDataCore/ModelContext.swift` → `fetch` 中 pending changes 处理
- **场景**：`includePendingChanges = true` 时处理待定插入/删除
- **设计**：先在锁内快照 pending inserts/deleted 的 ID 集合，释放锁后在锁外执行过滤操作
- **目的**：缩短锁持有时间，避免在临界区内做集合遍历/过滤等可能阻塞的操作
- **commit**：`5c50e8e`
