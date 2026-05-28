import Foundation
import Observation

import GRDB

@Observable
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
    public func attach(to context: ModelContext) {
        guard !isAttached else { return }
        isAttached = true
        
        // Initial fetch
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

#if canImport(SwiftUI)
import SwiftUI

private struct ModelContextKey: EnvironmentKey {
    static let defaultValue: ModelContext? = nil
}

public extension EnvironmentValues {
    var modelContext: ModelContext? {
        get { self[ModelContextKey.self] }
        set { self[ModelContextKey.self] = newValue }
    }
}

@MainActor
@propertyWrapper
public struct Query<Element: PersistentModel & Sendable>: DynamicProperty {
    @Environment(\.modelContext) private var modelContext: ModelContext?
    @State private var state: QueryState<Element>
    
    @MainActor
    public init(filter: Predicate<Element>? = nil, sort: [SortDescriptor<Element>] = [], context: ModelContext? = nil) {
        let descriptor = FetchDescriptor(predicate: filter, sortBy: sort)
        self._state = State(wrappedValue: QueryState(descriptor: descriptor, context: context))
    }
    
    public var wrappedValue: [Element] {
        return state.items
    }
    
    nonisolated public func update() {
        MainActor.assumeIsolated {
            if let ctx = modelContext {
                state.attach(to: ctx)
            }
        }
    }
}
#else

@MainActor
@propertyWrapper
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
#endif
