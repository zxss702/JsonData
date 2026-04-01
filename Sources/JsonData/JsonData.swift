import Foundation

#if canImport(SwiftData)
@_exported import SwiftData

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public extension SwiftData.ModelContext {
    func model<T>(for persistentModelIDString: String) -> T? where T: SwiftData.PersistentModel {
        let records = try? fetch(SwiftData.FetchDescriptor<T>())
        return records?.first(where: { "\($0.persistentModelID)" == persistentModelIDString })
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public nonisolated extension SwiftData.ModelContainer {
    func freshContext() -> SwiftData.ModelContext {
        SwiftData.ModelContext(self)
    }
}
#else
@_exported import Observation

@attached(extension, conformances: PersistentModel)
@attached(memberAttribute)
@attached(member, names: named(_observationRegistrar), named(_modelContext), named(_isFault), named(_isFaulting), named(access), named(withMutation), named(didChange), named(fault), named(_copy), named(CodingKeys), named(init), named(persistentModelID))
public macro Model() = #externalMacro(module: "JsonDataMacros", type: "ModelMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "JsonDataMacros", type: "TransientMacro")

public protocol PersistentModel: AnyObject, Codable, Observable {
    var persistentModelID: String { get set }
    var _modelContext: ModelContext? { get set }
    var _isFault: Bool { get set }
    var _isFaulting: Bool { get set }
    func access<Member>(keyPath: KeyPath<Self, Member>)
    func withMutation<Member, Result>(keyPath: KeyPath<Self, Member>, _ mutation: () throws -> Result) rethrows -> Result
    func fault()
    func _copy(from other: any PersistentModel)
    init()
}

public typealias SortDescriptor<T: PersistentModel> = Foundation.SortDescriptor<T>

public struct FetchDescriptor<T: PersistentModel> {
    public var sortBy: [SortDescriptor<T>]
    public var predicate: Predicate<T>?
    public var fetchLimit: Int?
    public var fetchOffset: Int?
    public var includePendingChanges: Bool
    public var propertiesToFetch: [PartialKeyPath<T>]
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<T>]
    
    public init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = nil
        self.fetchOffset = nil
        self.includePendingChanges = true
        self.propertiesToFetch = []
        self.relationshipKeyPathsForPrefetching = []
    }
}

@propertyWrapper
public struct Field<Value: Codable>: Codable {
    public var value: Value?
    public var defaultValue: Value?
    
    /// 用户自定义 init 中使用（如 init(title: "Hello")）
    public init(wrappedValue: Value) {
        self.defaultValue = wrappedValue
        self.value = nil
    }
    
    /// Fault 空壳对象使用，不需要真实值
    public init() {
        self.value = nil
        self.defaultValue = nil
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(Value.self)
        self.defaultValue = decoded
        self.value = decoded
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value ?? defaultValue!)
    }
    
    public static subscript<T: PersistentModel>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Field<Value>>
    ) -> Value {
        get {
            instance.access(keyPath: wrappedKeyPath)
            instance.fault()
            let storage = instance[keyPath: storageKeyPath]
            // fault() 之后 value 一定会被填充；
            // 非 fault 对象则通过用户 init 设置了 defaultValue
            return storage.value ?? storage.defaultValue!
        }
        set {
            instance.withMutation(keyPath: wrappedKeyPath) {
                instance.fault()
                instance[keyPath: storageKeyPath].value = newValue
                
                if !instance._isFaulting {
                    instance._modelContext?._save(instance)
                }
            }
        }
    }
    
    @available(*, unavailable)
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }
}

public nonisolated extension ModelContainer {
    func freshContext() -> ModelContext {
        mainContext
    }
}
#endif
