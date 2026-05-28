import Foundation


/// 类似 SwiftData 的 ModelContainer，管理数据存储和 ModelContext 的生命周期
public final class ModelContainer: @unchecked Sendable {
    /// 与该容器关联的主上下文
    public let mainContext: ModelContext
    
    /// 该容器管理的模型类型 schema
    public let schema: [any PersistentModel.Type]
    public let configurations: [ModelConfiguration]
    
    /// 使用默认路径 ~/Documents/JsonDataStore 初始化
    public init(for types: any PersistentModel.Type...) throws {
        self.schema = types
        self.configurations = [ModelConfiguration()]
        self.mainContext = ModelContext.shared
    }
    
    /// 使用指定模型类型数组初始化容器（默认路径）
    public init(for types: [any PersistentModel.Type]) throws {
        self.schema = types
        self.configurations = [ModelConfiguration()]
        self.mainContext = ModelContext.shared
    }
    
    /// 使用自定义存储路径初始化容器
    public init(for types: [any PersistentModel.Type], at url: URL) {
        self.schema = types
        self.configurations = [ModelConfiguration(url: url)]
        self.mainContext = ModelContext(url: url)
    }

    public init(for types: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {
        self.schema = types
        self.configurations = configurations
        if let firstConfig = configurations.first, let url = firstConfig.url {
            self.mainContext = ModelContext(url: url)
        } else {
            self.mainContext = ModelContext.shared
        }
    }
}

public struct ModelConfiguration: Sendable {
    public var url: URL?
    public var isStoredInMemoryOnly: Bool

    public init(isStoredInMemoryOnly: Bool = false) {
        self.url = nil
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
    }

    public init(url: URL) {
        self.url = url
        self.isStoredInMemoryOnly = false
    }
}

