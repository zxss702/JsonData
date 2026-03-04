
# 模块/架构笔记

## 模块概览
```mermaid
graph TB
    A[JsonDataMacros<br/>编译时宏] -->|代码生成| B[JsonData<br/>运行时库]
    B --> C[ModelContainer<br/>容器/Schema]
    B --> D[ModelContext<br/>上下文/CRUD]
    B --> E[@Model/@Field<br/>模型标记与属性代理]
```

## JsonDataMacros（编译时）
**职责**：使用 Swift Syntax 实现 `@Model` 宏，编译期为模型类自动生成样板代码。

**生成的代码**：
- `PersistentModel` + `Codable` 协议遵循
- `persistentModelID`、`_modelContext`、`_isFault` 等内部属性
- `fault()` 方法（懒加载触发点）
- `_copy(from:)` 方法（JSON 数据填充）
- `CodingKeys` 枚举 + 构造器
- 所有存储属性自动包裹 `@Field`

## JsonData（运行时）

### PersistentModel 协议
模型类的统一抽象，定义延迟加载与上下文关联所需的基础能力。

### @Field 属性包装器
- **延迟加载**：属性访问时若 `_isFault` 为真，自动调用 `fault()` 从 JSON 加载
- **变更追踪**：通过 `static subscript` 拦截写入，自动触发 `_save()` 持久化到磁盘

### ModelContext
**核心数据管理类**，单例模式（`shared` 或从容器获取）。

| 能力 | 说明 |
|------|------|
| Identity Map | 弱引用缓存，确保同一 `persistentModelID` 对应唯一对象实例 |
| 默认存储 | `~/Documents/JsonDataStore/` |
| insert() | 分配 ID、写入 JSON 文件 |
| delete() | 移除文件、从缓存清除 |
| fetch() | 支持筛选（predicate）、排序（SortDescriptor）、分页 |
| Faulting | 查询返回"空壳"对象，访问属性时才真正加载数据 |

### ModelContainer
- 管理 Schema（模型类型列表）
- 暴露 `mainContext`

## 调用关系与数据流向
```
用户模型类（@Model 标记）
    ↓
@Field 属性访问
    ↓
ModelContext.fault() 或 _save()
    ↓
磁盘 JSON 文件（~/Documents/JsonDataStore/）
```

## 定位与排查线索
- **存储文件位置**：`~/Documents/JsonDataStore/{ModelType}/{persistentModelID}.json`
- **Identity Map 检查**：通过 `ModelContext` 的弱引用缓存确认对象唯一性
- **延迟加载调试**：检查 `_isFault` 属性或 `fault()` 调用点
