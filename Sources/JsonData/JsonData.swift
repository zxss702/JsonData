#if canImport(SwiftData)
@_exported import SwiftData

public extension SwiftData.ModelContext {
    func model<T>(for id: PersistentIdentifier) -> T? where T: SwiftData.PersistentModel {
        if let m: T = self.registeredModel(for: id) { return m }
        if let m = self.model(for: id) as? T { return m }
        return nil
    }
}

public nonisolated extension SwiftData.ModelContainer {
    func freshContext() -> SwiftData.ModelContext {
        SwiftData.ModelContext(self)
    }
}

#else
@_exported import JsonDataCore
#endif
