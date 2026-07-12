import Foundation
import JsonDataCore

@MainActor
@propertyWrapper
/// 属性包装器，根据过滤和排序条件从模型上下文中查询数据。
///
/// 用于非 UI / 显式传入 `ModelContext` 的场景。使用前需 `import JsonData_Query`。
/// SwiftTUI / SwiftUI 界面请使用各自环境注入版的 `@Query`，不要与本模块同时导入以免撞名。
public struct Query<Element: PersistentModel> {
    private var state: QueryState<Element>
    
    @MainActor
    public init(
        filter: JsonDataCore.Predicate<Element>? = nil,
        sort: [JsonDataCore.SortDescriptor<Element>] = [],
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor(predicate: filter, sortBy: sort)
        self.state = QueryState(descriptor: descriptor, context: context)
    }
    
    public var wrappedValue: [Element] {
        return state.items
    }
}
