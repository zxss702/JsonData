# 任务进度与可恢复点

## ✅ 已完成：清理 JsonDataCore Darwin/macOS 残留

### 任务目标
移除 JsonDataCore 中所有 Darwin/macOS 代码，使其纯净支持 Linux/Windows。
macOS 上 JsonData 嫁接到 SwiftData，不经过 JsonDataCore。

### 修改结果（已完成 ✅）
JsonDataCore 中 **2 处** Darwin/macOS 依赖已全部移除：

| 文件 | 变更 | 编译验证 |
|------|------|----------|
| `ModelContext.swift` | 移除 `#if canImport(Darwin)` → `import Darwin`，Glibc 升为主分支 | ✅ |
| `Query.swift` | 移除 `#if canImport(SwiftUI)` 整个分支（含 `DynamicProperty`、`EnvironmentValues` 扩展），精简至仅保留非 SwiftUI 版本 | ✅ |

其余源文件均无 Darwin 引用，无需修改。

### 结论
JsonDataCore 现已无 Darwin/macOS 依赖，仅面向 Linux（Glibc/Musl）与 Windows（ucrt）编译。
