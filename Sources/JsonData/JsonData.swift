import Foundation

@attached(extension, conformances: PersistentModel, Codable)
@attached(memberAttribute)
@attached(member, names: named(_modelContext), named(_isFault), named(_isFaulting), named(didChange), named(fault), named(_copy), named(CodingKeys), named(init), named(persistentModelID))
public macro Model() = #externalMacro(module: "JsonDataMacros", type: "ModelMacro")

public protocol PersistentModel: AnyObject, Codable {
    var persistentModelID: String { get set }
    var _modelContext: ModelContext? { get set }
    var _isFault: Bool { get set }
    var _isFaulting: Bool { get set }
    func fault()
    func _copy(from other: any PersistentModel)
    init()
}

public struct SortDescriptor<T: PersistentModel> {
    public enum SortOrder {
        case forward
        case reverse
    }
    public var keyPath: PartialKeyPath<T>
    public var order: SortOrder
    
    public init(_ keyPath: PartialKeyPath<T>, order: SortOrder = .forward) {
         self.keyPath = keyPath
         self.order = order
    }
}

public struct FetchDescriptor<T: PersistentModel> {
    public var sortBy: [SortDescriptor<T>]
    public var predicate: ((T) -> Bool)?
    
    public init(sortBy: [SortDescriptor<T>] = [], predicate: ((T) -> Bool)? = nil) {
        self.sortBy = sortBy
        self.predicate = predicate
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
            instance.fault()
            let storage = instance[keyPath: storageKeyPath]
            // fault() 之后 value 一定会被填充；
            // 非 fault 对象则通过用户 init 设置了 defaultValue
            return storage.value ?? storage.defaultValue!
        }
        set {
            instance.fault()
            instance[keyPath: storageKeyPath].value = newValue
            
            if !instance._isFaulting {
                instance._modelContext?._save(instance)
            }
        }
    }
    
    @available(*, unavailable)
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }
}
