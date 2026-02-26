import Foundation

/// 弱引用包装器，用于 Identity Map 中持有模型对象
private class WeakRef {
    weak var value: (any PersistentModel)?
    init(_ value: any PersistentModel) {
        self.value = value
    }
}

public final class ModelContext: @unchecked Sendable {
    /// 默认的共享实例，存储在 ~/Documents/JsonDataStore
    public static let shared = ModelContext()
    
    /// 数据存储的根路径
    public let baseURL: URL
    
    // Identity Map：弱引用缓存，无人持有时 ARC 自动回收
    private let identityMapLock = NSLock()
    private var identityMap: [String: WeakRef] = [:]
    
    public static let contextDidChange = Notification.Name("JsonData.ModelContextDidChange")
    
    /// 使用默认路径 ~/Documents/JsonDataStore 初始化
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseURL = docs.appendingPathComponent("JsonDataStore")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
    
    /// 使用自定义存储路径初始化
    public init(url: URL) {
        self.baseURL = url
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
    
    // MARK: - 定期清理已被 ARC 回收的弱引用
    
    private func _purgeStaleEntries() {
        identityMap = identityMap.filter { $0.value.value != nil }
    }
    
    // MARK: - CRUD
    
    public func _save<T: PersistentModel>(_ model: T) {
        let typeName = String(describing: T.self)
        let dir = baseURL.appendingPathComponent(typeName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let fileURL = dir.appendingPathComponent("\(model.persistentModelID).json")
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
            }
        }
    }
    
    public func save() throws {
        // 属性变更时已自动保存，此方法用于对齐 SwiftData API
    }
    
    public func insert<T: PersistentModel>(_ model: T) {
        identityMapLock.lock()
        identityMap[model.persistentModelID] = WeakRef(model)
        identityMapLock.unlock()
        
        model._modelContext = self
        model._isFault = false
        _save(model)
    }
    
    public func delete<T: PersistentModel>(_ model: T) {
        identityMapLock.lock()
        identityMap.removeValue(forKey: model.persistentModelID)
        identityMapLock.unlock()
        
        let typeName = String(describing: T.self)
        let fileURL = baseURL.appendingPathComponent(typeName).appendingPathComponent("\(model.persistentModelID).json")
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
        }
    }
    
    // MARK: - Fetch（扫描 + 筛选 + 排序）
    
    public func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()) throws -> [T] {
        let typeName = String(describing: T.self)
        let dir = baseURL.appendingPathComponent(typeName)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        
        var results: [T] = []
        
        identityMapLock.lock()
        _purgeStaleEntries()
        
        for file in files where file.hasSuffix(".json") {
            let id = file.replacingOccurrences(of: ".json", with: "")
            
            // 1. 先查 Identity Map 缓存
            if let ref = identityMap[id], let cached = ref.value as? T {
                // 已有缓存对象
                if let predicate = descriptor.predicate {
                    // 有筛选条件：访问属性会触发 fault，仅通过的才加入结果
                    if predicate(cached) {
                        results.append(cached)
                    }
                } else {
                    results.append(cached)
                }
            } else {
                // 2. 缓存未命中
                if let predicate = descriptor.predicate {
                    // 有筛选条件：临时解析 JSON 判断是否通过
                    let fileURL = dir.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: fileURL),
                          let parsed = try? JSONDecoder().decode(T.self, from: data) else { continue }
                    
                    if predicate(parsed) {
                        // 通过筛选，存入 Identity Map 作为已加载对象
                        parsed._modelContext = self
                        parsed._isFault = false
                        identityMap[id] = WeakRef(parsed)
                        results.append(parsed)
                    }
                    // 未通过筛选：不创建任何对象，零内存开销
                } else {
                    // 无筛选条件：创建 fault 空壳，延迟加载
                    let fault = T()
                    fault.persistentModelID = id
                    fault._isFault = true
                    fault._modelContext = self
                    identityMap[id] = WeakRef(fault)
                    results.append(fault)
                }
            }
        }
        
        identityMapLock.unlock()
        
        // 3. 排序（访问排序属性会触发 fault 按需加载）
        for sortDesc in descriptor.sortBy.reversed() {
            results.sort { a, b in
                let lhs = a[keyPath: sortDesc.keyPath]
                let rhs = b[keyPath: sortDesc.keyPath]
                
                // 尝试使用 Comparable 进行比较
                if let lhs = lhs as? any Comparable, let rhs = rhs as? any Comparable {
                    return _compare(lhs, rhs, order: sortDesc.order)
                }
                return false
            }
        }
        
        return results
    }
    
    // MARK: - Faulting
    
    public func _faultIn<T: PersistentModel>(_ model: T) {
        let typeName = String(describing: T.self)
        let fileURL = baseURL.appendingPathComponent(typeName).appendingPathComponent("\(model.persistentModelID).json")
        if let data = try? Data(contentsOf: fileURL),
           let fullModel = try? JSONDecoder().decode(T.self, from: data) {
            model._copy(from: fullModel)
        }
    }
}

// MARK: - 排序比较辅助

private func _compare(_ lhs: any Comparable, _ rhs: any Comparable, order: SortDescriptor<some PersistentModel>.SortOrder) -> Bool {
    func _cmp<T: Comparable>(_ a: T, _ b: any Comparable) -> Bool {
        guard let b = b as? T else { return false }
        switch order {
        case .forward: return a < b
        case .reverse: return a > b
        }
    }
    return _cmp(lhs, rhs)
}
