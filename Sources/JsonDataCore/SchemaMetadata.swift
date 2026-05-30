import Foundation


/// JSON 数据列的数据类型枚举，定义了列所支持的全部存储类型。
public enum _JsonDataColumnKind: String, Sendable {
    case string
    case integer
    case double
    case bool
    case uuid
    case date
    case data
    case codableJSON
    case url
}

/// JSON 数据列信息结构体，描述单个列的元信息，包括属性名、列名、数据类型及可选性等。
public struct _JsonDataColumnInfo: Sendable, Equatable {
    public let propertyName: String
    public let columnName: String
    public let kind: _JsonDataColumnKind
    public let isOptional: Bool
    public let options: [Schema.Attribute.Option]

    public init(
        propertyName: String,
        columnName: String,
        kind: _JsonDataColumnKind,
        isOptional: Bool,
        options: [Schema.Attribute.Option] = []
    ) {
        self.propertyName = propertyName
        self.columnName = columnName
        self.kind = kind
        self.isOptional = isOptional
        self.options = options
    }
}

/// JSON 数据关系信息结构体，描述模型间的关系，包含删除规则、目标类型及反向关系名称。
public struct _JsonDataRelationshipInfo: @unchecked Sendable {
    public let propertyName: String
    public let deleteRule: Schema.Relationship.DeleteRule
    public let destinationType: any PersistentModel.Type
    public let inverseName: String?

    public init(
        propertyName: String,
        deleteRule: Schema.Relationship.DeleteRule,
        destinationType: any PersistentModel.Type,
        inverseName: String? = nil
    ) {
        self.propertyName = propertyName
        self.deleteRule = deleteRule
        self.destinationType = destinationType
        self.inverseName = inverseName
    }
}

/// JSON 数据索引信息结构体，描述为一个或多个属性创建的索引配置。
public struct _JsonDataIndexInfo: Sendable, Equatable {
    public let properties: [String]
    public init(properties: [String]) {
        self.properties = properties
    }
}

/// JSON 数据唯一约束信息结构体，描述为一组属性创建的唯一性约束。
public struct _JsonDataUniqueInfo: Sendable, Equatable {
    public let properties: [String]
    public init(properties: [String]) {
        self.properties = properties
    }
}

/// JSON 数据 Schema 提供协议，定义模型所需暴露的表名、列、关系、索引及唯一约束等结构信息。
public protocol _JsonDataSchemaProviding {
    static var _jsonDataTableName: String { get }
    static var _jsonDataColumns: [_JsonDataColumnInfo] { get }
    static var _jsonDataRelationships: [_JsonDataRelationshipInfo] { get }
    static var _jsonDataIndexes: [_JsonDataIndexInfo] { get }
    static var _jsonDataUniques: [_JsonDataUniqueInfo] { get }
    static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String?
    func _toColumnValues(context: ModelContext?) throws -> [String: Any?]
    func _populateFromColumnValues(_ values: [String: Any?], context: ModelContext?)
}

