
import Foundation
import GRDB

public struct PersistentIdentifier: Hashable, Identifiable, Equatable, Comparable, Codable, Sendable, DatabaseValueConvertible {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
    
    public static func < (lhs: PersistentIdentifier, rhs: PersistentIdentifier) -> Bool {
        return lhs.id < rhs.id
    }
    
    public var databaseValue: DatabaseValue {
        id.databaseValue
    }
    
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> PersistentIdentifier? {
        guard let str = String.fromDatabaseValue(dbValue) else { return nil }
        return PersistentIdentifier(id: str)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.id = try container.decode(String.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

