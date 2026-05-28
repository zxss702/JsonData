import Foundation



/// A custom Predicate type for JsonData that holds the pre-compiled SQL string and arguments.
public struct Predicate<T: PersistentModel>: @unchecked Sendable {
    public let sql: String
    public let arguments: [Any]
    
    // This closure is kept for potential in-memory evaluation (if needed in the future).
    // Right now we only use the SQL part for database queries.
    // public let evaluate: (T) throws -> Bool
    
    public init(sql: String, arguments: [Any]) {
        self.sql = sql
        self.arguments = arguments
    }
}


