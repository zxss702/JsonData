import Foundation

#if !canImport(SwiftData)
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

    public init(
        propertyName: String,
        columnName: String,
        kind: _JsonDataColumnKind,
        isOptional: Bool
    ) {
        self.propertyName = propertyName
        self.columnName = columnName
        self.kind = kind
        self.isOptional = isOptional
    }
}

public protocol _JsonDataSchemaProviding {
    static var _jsonDataTableName: String { get }
    static var _jsonDataColumns: [_JsonDataColumnInfo] { get }
    static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String?
}
#endif
