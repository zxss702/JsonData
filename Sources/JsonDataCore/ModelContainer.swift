import Foundation


/// 数据存储容器，负责管理 SQLite 数据库及 ``ModelContext`` 的生命周期。
///
/// 类似 SwiftData 的 `ModelContainer`，通过 ``ModelConfiguration`` 指定存储路径与内存模式。
public final class ModelContainer: @unchecked Sendable {
    public let mainContext: ModelContext
    
    public let schema: [any PersistentModel.Type]
    public let configurations: [ModelConfiguration]
    
    /// 使用默认存储路径初始化容器。
    /// - Parameter types: 需要持久化的模型类型。
    /// - Throws: 若初始化失败则抛出错误。
    public init(for types: any PersistentModel.Type...) throws {
        self.schema = types
        self.configurations = [ModelConfiguration()]
        self.mainContext = ModelContext.shared
        try self.mainContext._bootstrapSchema(self.schema)
    }
    
    /// 使用指定模型类型数组及默认存储路径初始化容器。
    /// - Parameter types: 需要持久化的模型类型数组。
    /// - Throws: 若初始化失败则抛出错误。
    public init(for types: [any PersistentModel.Type]) throws {
        self.schema = types
        self.configurations = [ModelConfiguration()]
        self.mainContext = ModelContext.shared
        try self.mainContext._bootstrapSchema(self.schema)
    }
    
    /// 使用指定模型类型和自定义存储路径初始化容器。
    /// - Parameters:
    ///   - types: 需要持久化的模型类型数组。
    ///   - url: 数据库文件的存储路径。
    /// - Throws: 若初始化失败则抛出错误。
    public init(for types: [any PersistentModel.Type], at url: URL) throws {
        self.schema = types
        self.configurations = [ModelConfiguration(url: url)]
        self.mainContext = try ModelContext(url: url)
        try self.mainContext._bootstrapSchema(self.schema)
    }

    /// 使用指定模型类型及一项或多项配置初始化容器。
    /// - Parameters:
    ///   - types: 需要持久化的模型类型。
    ///   - configurations: 一项或多项 ``ModelConfiguration``。
    /// - Throws: 若初始化失败则抛出错误。
    public init(for types: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {
        self.schema = types
        self.configurations = configurations
        if let firstConfig = configurations.first, let url = firstConfig.url {
            self.mainContext = try ModelContext(url: url)
        } else {
            self.mainContext = ModelContext.shared
        }
        try self.mainContext._bootstrapSchema(self.schema)
    }
    /// 使用 ``Schema`` 及配置列表初始化容器。
    /// - Parameters:
    ///   - schema: 描述模型结构的 ``Schema``。
    ///   - configurations: ``ModelConfiguration`` 数组。
    /// - Throws: 若初始化失败则抛出错误。
    public init(for schema: Schema, configurations: [ModelConfiguration]) throws {
        self.schema = schema.models
        self.configurations = configurations
        if let firstConfig = configurations.first, let url = firstConfig.url {
            self.mainContext = try ModelContext(url: url)
        } else {
            self.mainContext = ModelContext.shared
        }
        try self.mainContext._bootstrapSchema(self.schema)
    }
}

/// 描述 ``ModelContainer`` 的存储配置，包括存储路径、内存模式等。
public struct ModelConfiguration: Sendable {
    public var schema: Schema?
    public var url: URL?
    public var isStoredInMemoryOnly: Bool

    /// 创建一项存储配置。
    /// - Parameters:
    ///   - schema: 关联的 ``Schema``，默认为 `nil`。
    ///   - isStoredInMemoryOnly: 是否仅存储在内存中，默认为 `false`。
    ///   - url: 数据库文件路径，默认为 `nil`。
    public init(schema: Schema? = nil, isStoredInMemoryOnly: Bool = false, url: URL? = nil) {
        self.schema = schema
        self.url = url
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
    }
    
    /// 使用指定路径创建存储配置。
    /// - Parameter url: 数据库文件路径。
    public init(url: URL) {
        self.schema = nil
        self.url = url
        self.isStoredInMemoryOnly = false
    }
}
