import Foundation
import SwiftCrossUI

/// 类似 SwiftData 的 ModelContainer，管理数据存储和 ModelContext 的生命周期
public final class ModelContainer: @unchecked Sendable {
    /// 与该容器关联的主上下文
    public let mainContext: ModelContext
    
    /// 该容器管理的模型类型 schema
    public let schema: [any PersistentModel.Type]
    
    /// 使用默认路径 ~/Documents/JsonDataStore 初始化
    public init(for types: any PersistentModel.Type...) {
        self.schema = types
        self.mainContext = ModelContext.shared
    }
    
    /// 使用指定模型类型数组初始化容器（默认路径）
    public init(for types: [any PersistentModel.Type]) {
        self.schema = types
        self.mainContext = ModelContext.shared
    }
    
    /// 使用自定义存储路径初始化容器
    public init(for types: [any PersistentModel.Type], at url: URL) {
        self.schema = types
        self.mainContext = ModelContext(url: url)
    }
}

// MARK: - View modifier

extension SwiftCrossUI.View {
    /// 将 ModelContainer 注入到视图层级的环境中，
    /// 使子视图可以通过 @Environment(\.modelContext) 获取 ModelContext
    ///
    /// 用法：
    /// ```swift
    /// let container = ModelContainer(for: TaskInfo.self)
    /// // 在 App 层级持有 container，避免重复创建
    /// view.modelContainer(container)
    /// ```
    public func modelContainer(_ container: ModelContainer) -> some SwiftCrossUI.View {
        self.environment(\.modelContext, container.mainContext)
    }
}
