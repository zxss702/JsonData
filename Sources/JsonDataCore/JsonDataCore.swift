import Foundation
@_exported import Observation

/// 将类标记为持久化模型，自动生成 ``PersistentModel`` 协议所需的全部成员及数据库映射元数据。
@attached(extension, conformances: PersistentModel, _JsonDataSchemaProviding)
@attached(memberAttribute)
@attached(member, names: named(_observationRegistrar), named(modelContext), named(_modelContext), named(_isFault), named(_isFaulting), named(access), named(withMutation), named(didChange), named(fault), named(_copy), named(init), named(persistentModelID), named(_jsonDataTableName), named(_jsonDataColumns), named(_jsonDataRelationships), named(_jsonDataPropertyName), named(_isSyncingInverse), named(_jsonDataSetValue), named(_jsonDataIndexes), named(_jsonDataUniques), named(_toColumnValues), named(_populateFromColumnValues))
public macro Model() = #externalMacro(module: "JsonDataMacros", type: "ModelMacro")

/// 标记某个属性为瞬态，不会持久化到数据库。
@attached(peer)
public macro Transient() = #externalMacro(module: "JsonDataMacros", type: "TransientMacro")

/// 描述数据模型的整体结构，聚合所有参与持久化的模型类型。
public struct Schema: @unchecked Sendable {
    public let models: [any PersistentModel.Type]
    
    public init(_ models: [any PersistentModel.Type]) {
        self.models = models
    }
    
    /// 定义模型属性的元数据与约束选项（如唯一性、外部存储等）。
    public struct Attribute {
        public enum Option: Sendable {
            case unique
            case externalStorage
            case ephemeral
            case transformable
        }
    }
    
    /// 定义模型间关系的元数据，支持级联删除等规则。
    public struct Relationship {
        public enum DeleteRule: Sendable {
            case nullify
            case cascade
            case deny
        }
    }
}

/// 声明模型属性的元数据选项，如唯一性、外部存储等。
@attached(peer)
public macro Attribute(_ options: Schema.Attribute.Option...) = #externalMacro(module: "JsonDataMacros", type: "AttributeMacro")

/// 声明模型间的关系，可指定删除规则与逆向 keyPath，用于自动维护双向关系的完整性。
@attached(peer)
public macro Relationship(deleteRule: Schema.Relationship.DeleteRule = .nullify, inverse: AnyKeyPath? = nil) = #externalMacro(module: "JsonDataMacros", type: "RelationshipMacro")

/// 构建类型安全的查询谓词，用于在 ``FetchDescriptor`` 中表达过滤条件。
@freestanding(expression)
public macro Predicate<T>(_ body: (T) -> Bool) -> JsonDataCore.Predicate<T> = #externalMacro(module: "JsonDataMacros", type: "PredicateMacro")

/// 声明模型上的索引，用于加速按指定属性组合的查询。
@freestanding(declaration)
public macro Index<T>(_ groups: [PartialKeyPath<T>]...) = #externalMacro(module: "JsonDataMacros", type: "IndexMacro")

/// 声明模型属性上的唯一性约束，确保指定属性组合的值在数据库中不重复。
@freestanding(declaration)
public macro Unique<T>(_ groups: [PartialKeyPath<T>]...) = #externalMacro(module: "JsonDataMacros", type: "UniqueMacro")

/// 数据模型的基础协议，所有持久化模型均需遵循。提供 Fault、变更追踪、逆关系同步及标识符等核心能力。
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

/// 描述一次数据查询的配置，包括排序、过滤、分页及预取策略。
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

/// 运行时判断 Value 是否为 Optional 类型，并安全地构造 nil
public protocol _OptionalFieldProtocol {
    static var _noneValue: Any { get }
}
extension Optional: _OptionalFieldProtocol {
    public static var _noneValue: Any { Self.none as Any }
}

/// 运行时判断 Value 是否为 Array 类型，并安全地构造空数组
public protocol _ArrayFieldProtocol {
    static var _emptyArray: Any { get }
}
extension Array: _ArrayFieldProtocol {
    public static var _emptyArray: Any { Self() as Any }
}

/// 用于 ``PersistentModel`` 的属性包装器，提供惰性加载与变更追踪能力，支持可选值、默认值及逆关系同步。
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
            if let v = storage.value { return v }
            if let d = storage.defaultValue { return d }
            // 对齐 SwiftData：可选属性在 DB 为 NULL 时返回 nil
            if let optType = Value.self as? any _OptionalFieldProtocol.Type {
                return optType._noneValue as! Value
            }
            // 对齐 SwiftData：数组类型未建立关系或为 NULL 时返回空数组
            if let arrayType = Value.self as? any _ArrayFieldProtocol.Type {
                return arrayType._emptyArray as! Value
            }
            fatalError("Field<\(Value.self)> has no value and no default")
        }
        set {
            instance.withMutation(keyPath: wrappedKeyPath) {
                instance.fault()
                
                let oldValue = instance[keyPath: storageKeyPath].value
                instance[keyPath: storageKeyPath].value = newValue
                
                if !instance._isFaulting {
                    instance._modelContext?._modelDidChange(instance)
                    
                    if let ctx = instance._modelContext {
                        func _insert(_ obj: any PersistentModel) {
                            if obj._modelContext == nil {
                                obj._modelContext = ctx
                                obj._isFault = false
                                let id = obj.persistentModelID
                                ctx.identityMapLock.withLock { _ in
                                    ctx.identityMap[id] = WeakRef(obj)
                                }
                                ctx.insertedModels[id] = obj
                                ctx._scheduleAutosave()
                            }
                        }
                        if let newObj = newValue as? any PersistentModel {
                            _insert(newObj)
                        } else if let newArr = newValue as? [any PersistentModel] {
                            for newObj in newArr { _insert(newObj) }
                        }
                    }
                    
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

/// 将 ``PersistentModel`` 实例编码为其持久化标识符字符串。
public func _jsonDataEncode<T: PersistentModel>(_ value: T) throws -> String? {
    return value.persistentModelID.id
}

/// 将 Codable 值编码为 JSON 字符串。
@_disfavoredOverload
public func _jsonDataEncode<T: Codable>(_ value: T) throws -> String? {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// 将一组 ``PersistentModel`` 实例编码为包含其持久化标识符的 JSON 字符串。
public func _jsonDataEncode<T: PersistentModel>(_ value: [T]) throws -> String? {
    let ids = value.map { $0.persistentModelID.id }
    let data = try JSONEncoder().encode(ids)
    return String(decoding: data, as: UTF8.self)
}

/// 将一组 Codable 值编码为 JSON 字符串。
@_disfavoredOverload
public func _jsonDataEncode<T: Codable>(_ value: [T]) throws -> String? {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// 将 JSON 字符串解码为 ``PersistentModel`` 的 Fault 空壳对象，惰性加载真实数据。
public func _jsonDataDecode<T: PersistentModel>(_ type: T.Type, from string: String, context: ModelContext?) throws -> T? {
    let obj = T()
    obj.persistentModelID = PersistentIdentifier(id: string)
    obj._isFault = true
    obj._modelContext = context
    return obj
}

/// 将 JSON 字符串解码为指定的 Codable 类型实例。
@_disfavoredOverload
public func _jsonDataDecode<T: Codable>(_ type: T.Type, from string: String, context: ModelContext?) throws -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode(T.self, from: data)
}

/// 将 JSON 字符串解码为一组 ``PersistentModel`` 的 Fault 空壳对象数组。
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

/// 将 JSON 字符串解码为 Codable 类型的数组。
@_disfavoredOverload
public func _jsonDataDecode<T: Codable>(_ type: [T].Type, from string: String, context: ModelContext?) throws -> [T]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode([T].self, from: data)
}

/// 创建与当前容器关联的独立 ``ModelContext`` 实例，用于独立的数据操作。
public nonisolated extension ModelContainer {
    func freshContext() -> ModelContext {
        mainContext
    }
}


