import Foundation



/// 跨表 JOIN 条件，描述嵌套 keyPath（如 $0.subAgent?.callID）产生的子查询。
public struct JoinCondition: @unchecked Sendable {
    public let localColumn: String
    public let targetColumn: String
    public let op: String
    public let argument: Any
    
    public init(localColumn: String, targetColumn: String, op: String, argument: Any) {
        self.localColumn = localColumn
        self.targetColumn = targetColumn
        self.op = op
        self.argument = argument
    }
}

/// JsonData 的自定义谓词类型，持有预编译的 SQL 字符串及其参数。
public struct Predicate<T: PersistentModel>: @unchecked Sendable {
    public let sql: String
    public let arguments: [Any]
    public let joinConditions: [JoinCondition]
    public let memoryFilter: ((T) -> Bool)?
    
    public init(sql: String, arguments: [Any], joinConditions: [JoinCondition] = [], memoryFilter: ((T) -> Bool)? = nil) {
        self.sql = sql
        self.arguments = arguments
        self.joinConditions = joinConditions
        self.memoryFilter = memoryFilter
    }
}


