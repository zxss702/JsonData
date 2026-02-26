import SwiftCrossUI
import Foundation

@MainActor
public final class QueryResult<T: JsonModel>: SwiftCrossUI.ObservableObject {
    @SwiftCrossUI.Published public var items: [T] = []
    
    public init() {
        self.items = ModelContext.shared.fetch()
        NotificationCenter.default.addObserver(forName: ModelContext.contextDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.items = ModelContext.shared.fetch()
            }
        }
    }
}

@propertyWrapper
public struct Query<Element: JsonModel>: ObservableProperty {
    @State private var result: QueryResult<Element>
    
    @MainActor
    public init() {
        self._result = State(wrappedValue: QueryResult<Element>())
    }
    
    @MainActor
    public var wrappedValue: [Element] {
        result.items
    }
    
    public var didChange: SwiftCrossUI.Publisher {
        _result.didChange
    }
    
    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: Self?) {
        _result.update(with: environment, previousValue: previousValue?._result)
    }
}
