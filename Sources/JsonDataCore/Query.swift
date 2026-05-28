//
//import Foundation
//
//@MainActor
//public final class QueryResult<T: PersistentModel>: Sendable {
//    public var items: [T] = []
//    private var descriptor: FetchDescriptor<T>
//    
//    public init(descriptor: FetchDescriptor<T>) {
//        self.descriptor = descriptor
//        self.items = (try? ModelContext.shared.fetch(descriptor)) ?? []
//        NotificationCenter.default.addObserver(forName: ModelContext.contextDidChange, object: nil, queue: .main) { [weak self] _ in
//            guard let self else { return }
//            Task { @MainActor in
//                self.items = (try? ModelContext.shared.fetch(self.descriptor)) ?? []
//            }
//        }
//    }
//}
//
//@propertyWrapper
//public struct Query<Element: PersistentModel> {
//    @State private var result: QueryResult<Element>
//    
//    @MainActor
//    public init(filter: ((Element) -> Bool)? = nil, sort: [SortDescriptor<Element>] = []) {
//        let descriptor = FetchDescriptor<Element>(sortBy: sort, predicate: filter)
//        self._result = State(wrappedValue: QueryResult<Element>(descriptor: descriptor))
//    }
//    
//    @MainActor
//    public var wrappedValue: [Element] {
//        result.items
//    }
//    
//    public var didChange: SwiftCrossUI.Publisher {
//        _result.didChange
//    }
//    
//    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: Self?) {
//        _result.update(with: environment, previousValue: previousValue?._result)
//    }
//}
