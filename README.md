# JsonData

> **English** | [简体中文](README.zh-CN.md)

**JsonData** is a data persistence framework designed for the Swift cross-platform ecosystem. It offers a mental model and API that are fully consistent with Apple's **SwiftData**, but under the hood it is powered by the battle-tested [GRDB](https://github.com/groue/GRDB.swift), and it supports **Linux** and **Windows**.

Whether you need heavy concurrent queries on the server side or a responsive UI on cross-platform clients, JsonData delivers a SwiftData-like, silky-smooth development experience.

> **About the name**: Why such an odd name, "JsonData"? Check the git commit history — this library originally persisted data using JSON files. The performance turned out to be too poor, so it switched to GRDB, but the name... well, changing it would ripple through everything, so it stuck.

---

## Core Features

- **Falls back to SwiftData by default**: on macOS and iOS, `import JsonData` is equivalent to `import SwiftData`; on other platforms it automatically switches to the GRDB-backed JsonData implementation.
- **SwiftData API parity**: `@Model`, `ModelContext`, and `ModelContainer` match SwiftData; the View-side `@Query` is provided by the UI layer (SwiftUI / SwiftTUI), while the explicit `context:` variant lives in the standalone product `JsonData_Query`.
- **GRDB**: The underlying engine is SQLite, which is essentially the same backend SwiftData uses.

## Installation (Swift Package Manager)

Add the following dependency to your project's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zxss702/JsonData.git", branch: "main")
]
```

Add the desired product to the corresponding target's dependencies:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            "JsonData", // SwiftData on Apple platforms; JsonDataCore elsewhere. To force GRDB on Apple, depend on JsonDataCore instead.
            // "JsonData_Query", // Only needed when you require the explicit-context @Query (non-SwiftUI/SwiftTUI)
        ]
    )
]
```

## Quick Start

### 1. Define Your Data Model
Use the `@Model` macro exactly as you would with SwiftData — no tedious database schema statements required:

```swift
import JsonData // This is the only difference!!

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

### 2. Configure and Initialize a Container
Initialize your data container at app launch (or at the SwiftUI entry point):

> I highly recommend using a global variable.

```swift
// Create an in-memory database (for testing) or a persistent SQLite database
let container = try ModelContainer(for: TodoItem.self)
let context = ModelContext(container)
```

### 3. CRUD Operations
Type-safe `Predicate` query mechanism:

```swift
// Insert new data
let newItem = TodoItem(title: "Learn JsonData")
context.insert(newItem)
try? context.save()

// Query data
let descriptor = FetchDescriptor<TodoItem>(
    predicate: #Predicate { $0.isCompleted == false }, // Mostly the same, but not as comprehensive as Foundation's Predicate used by SwiftData; JsonDataCore's Predicate is a self-contained reimplementation.
    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
)

let pendingTodos = try context.fetch(descriptor)
```

### 4. Reactive Queries (Layered, Aligned with SwiftData / SwiftUI)

The persistence core (`JsonData` / `JsonDataCore`) does **not** ship with the View-side `@Query`, matching Apple's layering: `@Query` lives in the UI integration layer.

| Scenario | Import | `@Query` |
|----------|--------|----------|
| Persistence only | `import JsonData` | None |
| SwiftUI (Apple) | `import SwiftUI` + `import JsonData` | System `_SwiftData_SwiftUI` environment-injected version |
| SwiftTUI | `import SwiftTUI` | SwiftTUI's environment-injected version (re-exports JsonData) |
| No UI / explicit context | `import JsonData` + `import JsonData_Query` | `init(filter:sort:context:)` |

**SwiftUI example:**

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

**Non-UI (explicit context) requires the extra `JsonData_Query` dependency:**

```swift
// Package.swift
dependencies: [
    .product(name: "JsonData", package: "JsonData"),
    .product(name: "JsonData_Query", package: "JsonData"),
]

// Source
import JsonData
import JsonData_Query

struct Worker {
    @Query(sort: [SortDescriptor(\.createdAt)], context: ModelContext.shared)
    var todos: [TodoItem]
}
```

Do not use `JsonData_Query` together with SwiftTUI/SwiftUI's `@Query` in the same file, or the modules will collide.

## Contributing
We welcome your code contributions and suggestions! Before submitting, please read our [Contributing Guide (CONTRIBUTING.md)](CONTRIBUTING.md).

## License
This project is licensed under **MPL-2.0 (Mozilla Public License 2.0)**.

This means:
- **You are free to** use this framework in your commercial, closed-source projects (no need to open-source your App).
- **But if you directly modify this framework's source code**, you must open-source those modifications back to the community under MPL-2.0. We encourage everyone to help make JsonData better together!

## Star History

<a href="https://star-history.com/#zxss702/JsonData">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=zxss702/JsonData&type=Date" />
  </picture>
</a>
