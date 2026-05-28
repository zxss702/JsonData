import Foundation


public enum _JsonDataColumnKind: String, Sendable {
    case string
    case integer
    case double
    case bool
    case uuid
    case date
    case data
    case codableJSON
}

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

public struct _JsonDataRelationshipInfo: Sendable {
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

public struct _JsonDataIndexInfo: Sendable, Equatable {
    public let properties: [String]
    public init(properties: [String]) {
        self.properties = properties
    }
}

public struct _JsonDataUniqueInfo: Sendable, Equatable {
    public let properties: [String]
    public init(properties: [String]) {
        self.properties = properties
    }
}

public protocol _JsonDataSchemaProviding {
    static var _jsonDataTableName: String { get }
    static var _jsonDataColumns: [_JsonDataColumnInfo] { get }
    static var _jsonDataRelationships: [_JsonDataRelationshipInfo] { get }
    static var _jsonDataIndexes: [_JsonDataIndexInfo] { get }
    static var _jsonDataUniques: [_JsonDataUniqueInfo] { get }
    static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String?
}

