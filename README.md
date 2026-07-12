# JsonData

**JsonData** 是一个专为 Swift 跨平台生态设计的数据持久化框架。它提供了与 Apple **SwiftData** 完全一致的心智模型和 API，但在底层由久经考验的 [GRDB](https://github.com/groue/GRDB.swift) 强力驱动，支持 **Linux**、**Windows** 跨平台。

无论是服务端的重度并发查询，还是跨平台客户端的响应式 UI，JsonData 都能为您提供如同 SwiftData 一样丝滑优雅的开发体验。

> **关于命名**：为什么叫 JsonData 这么一个奇怪的名字？翻翻 Git 提交记录就知道了——这个库最初确实是用 JSON 文件来做持久化的。后来发现性能实在太差了，所以就切换到了 GRDB，但名字嘛……改起来牵一发而动全身，索性就这样了。

---

## 核心特性

- **默认回退SwiftData**: 在 macOS、iOS 上，`import JsonData` 等价于 `import SwiftData`，在其他平台是自动切换为 GRDB 实现的 JsonData。
- **SwiftData API 对齐**：`@Model`、`ModelContext` 与 `ModelContainer` 与 SwiftData 一致；View 用的 `@Query` 由 UI 层提供（SwiftUI / SwiftTUI），显式 `context:` 版在独立产品 `JsonData_Query` 中。
- **GRDB**：底层使用 SQLite ，这基本与 SwiftData 后端一致。

## 安装 (Swift Package Manager)

在项目的 `Package.swift` 中添加以下依赖：

```swift
dependencies: [
    .package(url: "https://github.com/zxss702/JsonData.git", branch: "main")
]
```

将所需产品添加到对应 Target 的依赖中：

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            "JsonData", // Apple 上为 SwiftData；其他平台为 JsonDataCore。若想在 Apple 上强制 GRDB，请改依赖 JsonDataCore。
            // "JsonData_Query", // 仅当需要显式 context 版 @Query（非 SwiftUI/SwiftTUI）时再加
        ]
    )
]
```

## 快速上手

### 1. 定义你的数据模型
使用与 SwiftData 完全一样的 `@Model` 宏，无需繁琐的数据库建表语句：

```swift
import JsonData // 只有这里有差异！！

@Model
public final class TodoItem {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var isCompleted: Bool
    public var createdAt: Date
    
    public init(title: String) {
        self.id = UUID()
        self.title = title
        self.isCompleted = false
        self.createdAt = Date()
    }
}
```

### 2. 配置与初始化容器
在应用启动时（或 SwiftUI 的入口处）初始化你的数据容器：

> 我非常推荐使用全局变量。

```swift
// 创建内存数据库（测试用）或持久化 SQLite 数据库
let container = try ModelContainer(for: TodoItem.self)
let context = ModelContext(container)
```

### 3. 数据增删改查
类型安全的 `Predicate` 查询机制：

```swift
// 插入新数据
let newItem = TodoItem(title: "Learn JsonData")
context.insert(newItem)
try? context.save()

// 查询数据
let descriptor = FetchDescriptor<TodoItem>(
    predicate: #Predicate { $0.isCompleted == false }, // 基本一致，但是支持的没有 SwiftData 用的 Foundation 的 Predicate 全面，JsonDataCore 的 Predicate 是内部重新实现的。
    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
)

let pendingTodos = try context.fetch(descriptor)
```

### 4. 响应式查询（分层，对齐 SwiftData / SwiftUI）

持久化核心（`JsonData` / `JsonDataCore`）**不**自带 View 用的 `@Query`，与 Apple 的分层一致：`@Query` 出现在 UI 集成层。

| 场景 | Import | `@Query` |
|------|--------|----------|
| 只做持久化 | `import JsonData` | 无 |
| SwiftUI（Apple） | `import SwiftUI` + `import JsonData` | 系统 `_SwiftData_SwiftUI` 的环境注入版 |
| SwiftTUI | `import SwiftTUI` | SwiftTUI 的环境注入版（已 re-export JsonData） |
| 无 UI / 显式 context | `import JsonData` + `import JsonData_Query` | `init(filter:sort:context:)` |

**SwiftUI 示例：**

```swift
import SwiftUI
import JsonData

struct TodoListView: View {
    @Environment(\.modelContext) private var context
    
    @Query(sort: [SortDescriptor(\.createdAt)])
    var todos: [TodoItem]
    
    var body: some View {
        List(todos) { todo in
            Text(todo.title)
        }
    }
}
```

**非 UI（显式传入 context）需要额外依赖 `JsonData_Query`：**

```swift
// Package.swift
dependencies: [
    .product(name: "JsonData", package: "JsonData"),
    .product(name: "JsonData_Query", package: "JsonData"),
]

// 源码
import JsonData
import JsonData_Query

struct Worker {
    @Query(sort: [SortDescriptor(\.createdAt)], context: ModelContext.shared)
    var todos: [TodoItem]
}
```

不要在同一文件同时使用 `JsonData_Query` 与 SwiftTUI/SwiftUI 的 `@Query`，否则会模块撞名。

### Windows 构建要求

JsonDataCore 在 Linux / Windows 上通过 GRDB 的 `ValueObservation` 实现查询的响应式更新（`QueryState` / `JsonData_Query`）。GRDB 在 Windows 上默认启用 `SQLITE_ENABLE_SNAPSHOT`，因此消费方必须自行编译并链接带 snapshot 支持的 SQLite，而不能使用未启用该选项的预编译库。

编译 SQLite amalgamation 时需启用以下选项（与 GRDB 默认一致）：

- `-DSQLITE_ENABLE_SNAPSHOT` — 提供 `sqlite3_snapshot_*` 符号，满足 ValueObservation
- `-DSQLITE_ENABLE_FTS5` — 全文检索支持

链接时通过 Swift Package Manager 传入头文件与库路径，例如：

```powershell
swift build -c release `
  -Xcc -I"path/to/prebuilt_sqlite/windows_x64" `
  -Xlinker -L"path/to/prebuilt_sqlite/windows_x64" `
  -Xlinker sqlite3.lib
```

MSVC 编译示例：

```powershell
cl.exe /c /O2 /DSQLITE_ENABLE_SNAPSHOT /DSQLITE_ENABLE_FTS5 sqlite3.c
lib.exe /OUT:sqlite3.lib sqlite3.obj
```

更多细节见 GRDB 官方文档 [CustomSQLiteBuilds.md](https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md)。

## 参与贡献
我们非常欢迎你为 JsonData 提交代码或提出宝贵建议！在提交代码前，请务必阅读我们的 [贡献指南 (CONTRIBUTING.md)](CONTRIBUTING.md)。

## 开源协议
本项目采用 **MPL-2.0 (Mozilla Public License 2.0)** 协议开源。

这意味着：
- **您可以自由地**将本框架用于您的商业闭源项目中（无需将您的 App 开源）。
- **但如果您直接修改了本框架的源码**，您必须将这些针对本框架的修改以 MPL-2.0 协议开源回馈给社区。我们鼓励大家共同将 JsonData 维护得更好！

## 获赞历史

<a href="https://star-history.com/#zxss702/JsonData">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date" />
  </picture>
</a>
