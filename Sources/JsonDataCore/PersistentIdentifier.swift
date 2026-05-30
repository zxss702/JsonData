
import Foundation
import GRDB

/// 持久化标识符，用作 JSON 数据模型的唯一标识，支持哈希、比较及数据库值转换。
public struct PersistentIdentifier: Hashable, Identifiable, Equatable, Comparable, Sendable, DatabaseValueConvertible {
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
}

