import Foundation

#if !canImport(SwiftData)
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
    
    public func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        limit: Int? = nil
    ) throws -> [T] {
        let effectiveLimit = descriptor.fetchLimit ?? limit
        if let effectiveLimit, effectiveLimit <= 0 {
            return []
        }
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
                    if try predicate.evaluate(cached) {
                        results.append(cached)
                    }
                } else {
                    results.append(cached)
                }
            } else {
                // 2. 缓存未命中
                if let predicate = descriptor.predicate {
                    let fileURL = dir.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: fileURL),
                          let parsed = try? JSONDecoder().decode(T.self, from: data) else { continue }
                    
                    if try predicate.evaluate(parsed) {
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
        
        if !descriptor.sortBy.isEmpty {
            results.sort(using: descriptor.sortBy)
        }

        if let fetchOffset = descriptor.fetchOffset, fetchOffset > 0 {
            results = Array(results.dropFirst(fetchOffset))
        }

        if let effectiveLimit {
            results = Array(results.prefix(effectiveLimit))
        }
        
        return results
    }
    
    // MARK: - 通过 persistentModelID 获取单个模型
    
    /// 根据 persistentModelID 获取对应的模型对象
    /// - Parameter id: 模型的 persistentModelID（UUID 字符串）
    /// - Returns: 对应的模型对象，若不存在则返回 nil
    public func model<T: PersistentModel>(for id: String) -> T? {
        identityMapLock.lock()
        defer { identityMapLock.unlock() }
        
        // 1. 先查 Identity Map 缓存
        if let ref = identityMap[id], let cached = ref.value as? T {
            return cached
        }
        
        // 2. 缓存未命中，从磁盘读取
        let typeName = String(describing: T.self)
        let fileURL = baseURL
            .appendingPathComponent(typeName)
            .appendingPathComponent("\(id).json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let model = try? JSONDecoder().decode(T.self, from: data) else {
            return nil
        }
        
        model._modelContext = self
        model._isFault = false
        identityMap[id] = WeakRef(model)
        return model
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
#endif
