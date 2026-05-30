#if canImport(SwiftData)
@_exported import SwiftData

/// SwiftData `ModelContext` 的便利扩展，提供通过 `PersistentIdentifier` 查找模型的快捷方法。
public extension SwiftData.ModelContext {
    /// 根据持久化标识符查找对应的模型实例。
    ///
    /// 优先通过 `registeredModel(for:)` 查找已注册模型，若失败则回退到 `model(for:)` 尝试类型转换。
    /// - Parameter id: 模型的持久化标识符。
    /// - Returns: 对应的模型实例，若未找到则返回 `nil`。
    func model<T>(for id: PersistentIdentifier) -> T? where T: SwiftData.PersistentModel {
        if let m: T = self.registeredModel(for: id) { return m }
        if let m = self.model(for: id) as? T { return m }
        return nil
    }
}

/// SwiftData `ModelContainer` 的便利扩展，提供快速创建 `ModelContext` 的方法。
public nonisolated extension SwiftData.ModelContainer {
    /// 从当前容器创建一个全新的 `ModelContext`。
    ///
    /// - Returns: 与此容器关联的新 `ModelContext` 实例。
    func freshContext() -> SwiftData.ModelContext {
        SwiftData.ModelContext(self)
    }
}

#else
/// 当 SwiftData 不可用时，回退导出 JsonDataCore 以提供等效功能。
@_exported import JsonDataCore
#endif
