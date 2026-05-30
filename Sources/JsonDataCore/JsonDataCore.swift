import Foundation
@_exported import Observation

@attached(extension, conformances: PersistentModel, _JsonDataSchemaProviding)
@attached(memberAttribute)
@attached(member, names: named(_observationRegistrar), named(modelContext), named(_modelContext), named(_isFault), named(_isFaulting), named(access), named(withMutation), named(didChange), named(fault), named(_copy), named(init), named(persistentModelID), named(_jsonDataTableName), named(_jsonDataColumns), named(_jsonDataRelationships), named(_jsonDataPropertyName), named(_isSyncingInverse), named(_jsonDataSetValue), named(_jsonDataIndexes), named(_jsonDataUniques), named(_toColumnValues), named(_populateFromColumnValues))
public macro Model() = #externalMacro(module: "JsonDataMacros", type: "ModelMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "JsonDataMacros", type: "TransientMacro")

public struct Schema: @unchecked Sendable {
    public let models: [any PersistentModel.Type]
    
    public init(_ models: [any PersistentModel.Type]) {
        self.models = models
    }
    
    public struct Attribute {
        public enum Option: Sendable {
            case unique
            case externalStorage
            case ephemeral
            case transformable
        }
    }
    
    public struct Relationship {
        public enum DeleteRule: Sendable {
            case nullify
            case cascade
            case deny
        }
    }
}

@attached(peer)
public macro Attribute(_ options: Schema.Attribute.Option...) = #externalMacro(module: "JsonDataMacros", type: "AttributeMacro")

@attached(peer)
public macro Relationship(deleteRule: Schema.Relationship.DeleteRule = .nullify, inverse: AnyKeyPath? = nil) = #externalMacro(module: "JsonDataMacros", type: "RelationshipMacro")

@freestanding(expression)
public macro Predicate<T>(_ body: (T) -> Bool) -> JsonDataCore.Predicate<T> = #externalMacro(module: "JsonDataMacros", type: "PredicateMacro")

@freestanding(declaration)
public macro Index<T>(_ groups: [PartialKeyPath<T>]...) = #externalMacro(module: "JsonDataMacros", type: "IndexMacro")

@freestanding(declaration)
public macro Unique<T>(_ groups: [PartialKeyPath<T>]...) = #externalMacro(module: "JsonDataMacros", type: "UniqueMacro")

public protocol PersistentModel: AnyObject, Observable, Hashable, Equatable, Identifiable {
    var persistentModelID: PersistentIdentifier { get set }
    var modelContext: ModelContext? { get }
    var _modelContext: ModelContext? { get set }
    var _isFault: Bool { get set }
    var _isFaulting: Bool { get set }
    func access<Member>(keyPath: KeyPath<Self, Member>)
    func withMutation<Member, Result>(keyPath: KeyPath<Self, Member>, _ mutation: () throws -> Result) rethrows -> Result
    func fault()
    func _copy(from other: any PersistentModel)
    func _jsonDataSetValue(_ value: Any?, forPropertyName propertyName: String)
    var _isSyncingInverse: Bool { get set }
    init()
}

public extension PersistentModel {
    var id: PersistentIdentifier { persistentModelID }
    
    var modelContext: ModelContext? { _modelContext }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}

public typealias SortDescriptor<T: PersistentModel> = Foundation.SortDescriptor<T>

public struct FetchDescriptor<T: PersistentModel>: @unchecked Sendable {
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
public struct Field<Value> {
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
                
                let oldValue = instance[keyPath: storageKeyPath].value
                instance[keyPath: storageKeyPath].value = newValue
                
                if !instance._isFaulting {
                    instance._modelContext?._modelDidChange(instance)
                    
                    if !instance._isSyncingInverse,
                       let schemaType = type(of: instance) as? any _JsonDataSchemaProviding.Type,
                       let propName = schemaType._jsonDataPropertyName(for: wrappedKeyPath),
                       let rel = schemaType._jsonDataRelationships.first(where: { $0.propertyName == propName }),
                       let inverseName = rel.inverseName {
                        
                        // Set flag to prevent infinite recursion
                        instance._isSyncingInverse = true
                        defer { instance._isSyncingInverse = false }
                        
                        // Clear old inverse
                        if let oldObj = oldValue as? any PersistentModel {
                            oldObj._isSyncingInverse = true
                            oldObj._jsonDataSetValue(nil, forPropertyName: inverseName)
                            oldObj._isSyncingInverse = false
                        } else if let oldArr = oldValue as? [any PersistentModel] {
                            for oldObj in oldArr {
                                oldObj._isSyncingInverse = true
                                oldObj._jsonDataSetValue(nil, forPropertyName: inverseName)
                                oldObj._isSyncingInverse = false
                            }
                        }
                        
                        // Set new inverse
                        if let newObj = newValue as? any PersistentModel {
                            newObj._isSyncingInverse = true
                            // For to-one, we set instance. For to-many, we'd append instance.
                            // But since _jsonDataSetValue does a direct assignment, we must pass the correct type.
                            // However, we don't know the exact array type dynamically.
                            // If the inverse is an array, setting it directly to `instance` will fail the `as? Type` cast.
                            // To perfectly support bidirectional to-many, _jsonDataSetValue would need `append` logic.
                            // For now, we attempt to assign directly (works for to-one).
                            newObj._jsonDataSetValue(instance, forPropertyName: inverseName)
                            newObj._isSyncingInverse = false
                        } else if let newArr = newValue as? [any PersistentModel] {
                            for newObj in newArr {
                                newObj._isSyncingInverse = true
                                newObj._jsonDataSetValue(instance, forPropertyName: inverseName)
                                newObj._isSyncingInverse = false
                            }
                        }
                    }
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

public func _jsonDataEncode<T: PersistentModel>(_ value: T) throws -> String? {
    return value.persistentModelID.id
}

@_disfavoredOverload
public func _jsonDataEncode<T: Codable>(_ value: T) throws -> String? {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

public func _jsonDataEncode<T: PersistentModel>(_ value: [T]) throws -> String? {
    let ids = value.map { $0.persistentModelID.id }
    let data = try JSONEncoder().encode(ids)
    return String(decoding: data, as: UTF8.self)
}

@_disfavoredOverload
public func _jsonDataEncode<T: Codable>(_ value: [T]) throws -> String? {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

public func _jsonDataDecode<T: PersistentModel>(_ type: T.Type, from string: String, context: ModelContext?) throws -> T? {
    let obj = T()
    obj.persistentModelID = PersistentIdentifier(id: string)
    obj._isFault = true
    obj._modelContext = context
    return obj
}

@_disfavoredOverload
public func _jsonDataDecode<T: Codable>(_ type: T.Type, from string: String, context: ModelContext?) throws -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode(T.self, from: data)
}

public func _jsonDataDecode<T: PersistentModel>(_ type: [T].Type, from string: String, context: ModelContext?) throws -> [T]? {
    guard let data = string.data(using: .utf8) else { return nil }
    let ids = try JSONDecoder().decode([String].self, from: data)
    return ids.compactMap { id in
        guard let ctx = context else { return nil }
        let obj = T()
        obj.persistentModelID = PersistentIdentifier(id: id)
        obj._isFault = true
        obj._modelContext = ctx
        return obj
    }
}

@_disfavoredOverload
public func _jsonDataDecode<T: Codable>(_ type: [T].Type, from string: String, context: ModelContext?) throws -> [T]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode([T].self, from: data)
}

public nonisolated extension ModelContainer {
    func freshContext() -> ModelContext {
        mainContext
    }
}


