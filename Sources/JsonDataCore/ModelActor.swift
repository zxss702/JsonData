import Foundation

@available(swift 5.9)
public protocol ModelActor: _Concurrency.Actor {
    nonisolated var modelContainer: ModelContainer { get }
    nonisolated var modelExecutor: any ModelExecutor { get }
}

@available(swift 5.9)
public protocol ModelExecutor: _Concurrency.Executor {
    var modelContext: ModelContext { get }
}

@available(swift 5.9)
public protocol SerialModelExecutor: ModelExecutor, _Concurrency.SerialExecutor {
}

@available(swift 5.9)
extension ModelActor {
    public nonisolated var unownedExecutor: _Concurrency.UnownedSerialExecutor {
        (modelExecutor as! any _Concurrency.SerialExecutor).asUnownedSerialExecutor()
    }

    public var modelContext: ModelContext {
        modelExecutor.modelContext
    }

    public subscript<T>(id: PersistentIdentifier, as _: T.Type) -> T? where T: PersistentModel {
        modelContext.model(for: id)
    }
}

@available(swift 5.9)
public final class DefaultSerialModelExecutor: @unchecked Sendable, SerialModelExecutor {
    public let modelContext: ModelContext
    private let core: CoreActor
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.core = CoreActor()
    }
    
    public func enqueue(_ job: _Concurrency.UnownedJob) {
        fatalError("Enqueue should not be called when delegating asUnownedSerialExecutor")
    }
    
    public func asUnownedSerialExecutor() -> _Concurrency.UnownedSerialExecutor {
        core.unownedExecutor
    }
    
    private actor CoreActor {}
}
