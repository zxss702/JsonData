import Foundation



/// JsonData 的自定义谓词类型，持有预编译的 SQL 字符串及其参数。
public struct Predicate<T: PersistentModel>: @unchecked Sendable {
    public let sql: String
    public let arguments: [Any]
    public let memoryFilter: ((T) -> Bool)?
    
    public init(sql: String, arguments: [Any], memoryFilter: ((T) -> Bool)? = nil) {
        self.sql = sql
        self.arguments = arguments
        self.memoryFilter = memoryFilter
    }
}


