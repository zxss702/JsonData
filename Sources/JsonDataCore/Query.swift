import Foundation
import Observation

import GRDB

@Observable
/// 管理查询状态和数据库观察，自动响应数据变更并更新结果集。
public final class QueryState<Element: PersistentModel & Sendable>: @unchecked Sendable {
    public var items: [Element] = []
    private var descriptor: FetchDescriptor<Element>
    private var isAttached = false
    private var observationTask: DatabaseCancellable?
    
    @MainActor
    public init(descriptor: FetchDescriptor<Element>, context: ModelContext?) {
        self.descriptor = descriptor
        if let context = context {
            attach(to: context)
        }
    }
    
    @MainActor
    /// 将查询状态绑定到指定的模型上下文，开始监听数据库变更。
    public func attach(to context: ModelContext) {
        guard !isAttached else { return }
        isAttached = true
        
        self.items = (try? context.fetch(descriptor)) ?? []
        
        self.observationTask = context.startObservation(
            descriptor,
            onError: { _ in },
            onChange: { [weak self] newItems in
                self?.items = newItems
            }
        )
    }
}

@MainActor
@propertyWrapper
/// 属性包装器，根据过滤和排序条件从模型上下文中查询数据。
public struct Query<Element: PersistentModel & Sendable> {
    private var state: QueryState<Element>
    
    @MainActor
    public init(filter: Predicate<Element>? = nil, sort: [SortDescriptor<Element>] = [], context: ModelContext) {
        let descriptor = FetchDescriptor(predicate: filter, sortBy: sort)
        self.state = QueryState(descriptor: descriptor, context: context)
    }
    
    public var wrappedValue: [Element] {
        return state.items
    }
}
