import Foundation
import Synchronization


import GRDB

/// JsonData 存储层错误。
public enum JsonDataStoreError: Error, LocalizedError, CustomNSError, Sendable {
    case databaseIntegrityFailed(String)
    case databaseOpenFailed(underlying: Error)
    case schemaMigrationFailed(model: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .databaseIntegrityFailed(let message):
            return "Database integrity check failed: \(message)"
        case .databaseOpenFailed(let underlying):
            return "Failed to open database: \(underlying.localizedDescription)"
        case .schemaMigrationFailed(let model, let underlying):
            return "Failed to migrate model \(model): \(underlying.localizedDescription)"
        }
    }
    public static var errorDomain: String { "JsonData.Store" }
    public var errorCode: Int {
        switch self {
        case .databaseIntegrityFailed: return 1
        case .databaseOpenFailed: return 2
        case .schemaMigrationFailed: return 3
        }
    }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "Database error"]
        switch self {
        case .databaseIntegrityFailed: break
        case .databaseOpenFailed(let error), .schemaMigrationFailed(_, let error):
            info[NSUnderlyingErrorKey] = error
        }
        return info
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

internal final class WeakRef {
    weak var value: (any PersistentModel)?

    init(_ value: any PersistentModel) {
        self.value = value
    }
}

private final class WeakContextRef: @unchecked Sendable {
    weak var context: ModelContext?
    init(_ context: ModelContext) {
        self.context = context
    }
}

private let globalContextsLock = Mutex([WeakContextRef]())

/// Database snapshots are read off-thread; live UI models are merged on MainActor.
@MainActor
private final class ObservedRows {
    var rows: [PersistentIdentifier: Row] = [:]
}

private struct ObservedSnapshot: @unchecked Sendable {
    let revision: Int
    let rows: [Row]
}

@_cdecl("_JsonDataCore_PerformExitAutosave")
func _JsonDataCore_PerformExitAutosave() {
    globalContextsLock.withLock { contexts in
        for ref in contexts {
            ref.context?._performExitAutosave()
        }
    }
}

private let _registerAtExitOnce: Void = {
    atexit {
        _JsonDataCore_PerformExitAutosave()
    }
}()

private func registerAtExit() {
    _ = _registerAtExitOnce
}

/// 数据模型上下文，管理持久化对象的生命周期与数据库操作。
public final class ModelContext: @unchecked Sendable {
    /// 共享的单例上下文实例。
    public static let shared: ModelContext = {
        do {
            return try ModelContext()
        } catch {
            fatalError("JsonData default store failed to open: \(error)")
        }
    }()
    /// 数据库文件所在的基础目录 URL。
    public let baseURL: URL

    internal let identityMapLock = Mutex(())
    internal var identityMap: [PersistentIdentifier: WeakRef] = [:]
    
    internal var insertedModels: [PersistentIdentifier: any PersistentModel] = [:]
    internal var changedModels: [PersistentIdentifier: any PersistentModel] = [:]
    private var changedProperties: [PersistentIdentifier: Set<String>] = [:]
    internal var deletedModels: [PersistentIdentifier: any PersistentModel] = [:]
    private var savingModels: [PersistentIdentifier: (model: any PersistentModel, count: Int)] = [:]
    private var savingDeletions: [PersistentIdentifier: Int] = [:]
    private let observationRevision = Mutex(0)
    private var observedModelRevisions: [PersistentIdentifier: Int] = [:]
    /// `_bootstrapSchema` 注册的模型类型，供非泛型 `model(for:)` 扫描加载。
    internal var schemaTypes: [any PersistentModel.Type] = []
    
    /// 是否启用自动保存。默认为 `true`。
    public var autosaveEnabled: Bool = true
    /// 自动保存的调度状态：改动一到就开始一次保存，保存期间又来的改动让它
    /// 再保存一次。取消并重启定时器的写法会让连续的改动无限期推迟保存。
    private let autosaveLock = Mutex(())
    private var autosaveRunning = false
    private var autosaveDirty = false
    private let autosaveFailureLock = Mutex(())
    private var autosaveFailure: Error?

    /// 最近一次自动保存失败的错误；保存成功时清空。
    public var lastAutosaveError: Error? {
        autosaveFailureLock.withLock { _ in autosaveFailure }
    }

    /// 自动保存失败时发出的通知名称，`userInfo["error"]` 是错误。
    public static let autosaveDidFail = Notification.Name("JsonData.ModelContextAutosaveDidFail")

    /// 是否有未保存的更改。
    public var hasChanges: Bool {
        identityMapLock.withLock { _ in
            !insertedModels.isEmpty || !changedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    /// 保存必须发生在主 actor 上。
    ///
    /// 这里不是"随便挑个线程"，理由有两条：
    /// 1. 宿主的主队列不一定有人排空（SwiftOmniUI 的 WinUI/GTK 宿主自带 MainActor
    ///    执行器，`DispatchQueue.main` 上的东西永远不会跑），但 `Task { @MainActor }`
    ///    一定会在宿主下一次 pump 时执行——这是宿主唯一保证会跑的路径。
    /// 2. 读取一直是在主 actor 上做的（`fetch` 由视图调用），把写也放在同一条线程上，
    ///    读写就走同一条 `databaseQueue` 调用序列，不会出现"读得到、写不进去"这种
    ///    只在某个平台上复现的错位。
    ///
    /// 改动本身可以来自任何线程（`_modelDidChange` 由属性 setter 调用），
    /// 所以这里只做一次 actor 交接，等待与保存都在主 actor 内完成：
    /// `Task.sleep` 只挂起任务、不占线程，不会卡住界面。
    ///
    /// 节奏上仍是"改动停下 0.1 秒后存一次，存的过程中又来的改动让它再存一次"，
    /// 连续的改动不会把保存无限期推后。
    ///
    /// 注意：这条自动保存**不是**唯一保险。SwiftData 自己的自动保存并不是一个
    /// 定时器（实测：改动后主 run loop 空转 2 秒也不落盘，`processPendingChanges()`
    /// 也不落盘，只有显式 `save()` 才写盘），所以生命周期节点上的显式保存
    /// （退出时的 `_JsonDataCore_PerformExitAutosave`）同样是必须的，而且它的失败
    /// 必须能被看见，否则数据悄悄丢掉。
    // @contributor
    internal func _scheduleAutosave() {
        guard autosaveEnabled else { return }
        let startsSaving = autosaveLock.withLock { _ -> Bool in
            autosaveDirty = true
            guard !autosaveRunning else { return false }
            autosaveRunning = true
            return true
        }
        guard startsSaving else { return }
        Task { @MainActor [weak self] in
            while true {
                // 等这一串改动停顿下来。这份等待每次保存只付一次，不会被后面的
                // 改动重新开始，所以连续的改动不会把保存一直推后。
                try? await Task.sleep(for: .seconds(0.1))
                guard let self else { return }
                self.autosaveLock.withLock { _ in self.autosaveDirty = false }
                do {
                    try self.save()
                    self.autosaveFailureLock.withLock { _ in self.autosaveFailure = nil }
                } catch {
                    // 保存失败必须留下痕迹：自动保存的错误过去被吞掉了，
                    // 于是数据没写进去也没有任何地方说得出为什么。
                    self._reportAutosaveFailure(error)
                }
                let keepsSaving = self.autosaveLock.withLock { _ -> Bool in
                    if self.autosaveDirty { return true }
                    self.autosaveRunning = false
                    return false
                }
                if !keepsSaving { return }
            }
        }
    }

    private let databaseQueue: DatabaseQueue

    /// 上下文数据发生变更时发出的通知名称。
    public static let contextDidChange = Notification.Name("JsonData.ModelContextDidChange")

    // @contributor
    private func registerSelf() {
        registerAtExit()
        globalContextsLock.withLock { contexts in
            contexts.removeAll { $0.context == nil }
            contexts.append(WeakContextRef(self))
        }
    }

    /// 使用默认文档目录创建上下文。
    init() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let baseURL = docs.appendingPathComponent("JsonDataStore")
        let dbURL = baseURL.appendingPathComponent("JsonData.sqlite")
        self.baseURL = baseURL
        self.databaseQueue = try Self.openDatabaseQueue(at: dbURL, baseURL: baseURL)
        registerSelf()
    }

    /// 使用指定的数据库文件 URL 创建上下文。
    public init(url: URL) throws {
        self.baseURL = url.deletingLastPathComponent()
        self.databaseQueue = try Self.openDatabaseQueue(at: url, baseURL: baseURL)
        registerSelf()
    }

    // @contributor
    private static func openDatabaseQueue(at dbURL: URL, baseURL: URL) throws -> DatabaseQueue {
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            throw JsonDataStoreError.databaseOpenFailed(underlying: error)
        }

        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try queue.read { db in
                try _verifyDatabaseIntegrity(in: db)
            }
            return queue
        } catch let error as JsonDataStoreError {
            throw error
        } catch let error as DatabaseError {
            if error.resultCode == .SQLITE_CORRUPT
                || error.message?.localizedCaseInsensitiveContains("malformed") == true {
                throw JsonDataStoreError.databaseIntegrityFailed(
                    error.message ?? "database disk image is malformed"
                )
            }
            throw JsonDataStoreError.databaseOpenFailed(underlying: error)
        } catch {
            throw JsonDataStoreError.databaseOpenFailed(underlying: error)
        }
    }

    // @contributor
    private static func _verifyDatabaseIntegrity(in db: Database) throws {
        let rows = try String.fetchAll(db, sql: "PRAGMA quick_check")
        let result = rows.joined(separator: ", ")
        guard result.lowercased() == "ok" else {
            throw JsonDataStoreError.databaseIntegrityFailed(result)
        }
    }
    
    /// 从现有的模型容器创建上下文，共享其数据库连接。
    public init(_ container: ModelContainer) {
        self.baseURL = container.mainContext.baseURL
        self.databaseQueue = container.mainContext.databaseQueue
        registerSelf()
        // @ModelActor / child contexts must inherit schema for non-generic model(for:).
        // NOTE: Only copy the schema metadata here — do NOT call `_bootstrapSchema`,
        // which issues a synchronous `databaseQueue.write`. `container.mainContext`
        // already ran that write once at container creation, and this context shares
        // the exact same `databaseQueue`. Re-running it here raced with the shared
        // queue and could reenter GRDB's serialized writer (safe/fatal on Darwin via
        // `SchedulingWatchdog`, but silently deadlocked on Windows where the
        // dispatch-specific reentrancy check isn't reliable). Tables are created
        // lazily by `_ensureTable` the first time each type is actually touched.
        self.schemaTypes = container.schema
    }

    // @contributor
    private func _purgeStaleEntries() {
        identityMap = identityMap.filter { $0.value.value != nil }
        observedModelRevisions = observedModelRevisions.filter { identityMap[$0.key] != nil }
    }

    // @contributor
    private func _postContextDidChange() {
        // 必须是 MainActor 交接，不能用 `DispatchQueue.main.async`：
        // SwiftOmniUI 的宿主（WinUI/GTK）装了自带的 MainActor 执行器，
        // 主队列没人排空，派发到主队列的通知在那些平台上永远不会发出。
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
        }
    }

    /// 进程退出时的最后一次保存。
    ///
    /// 退出路径上已经没有下一次 actor pump 了（`Task { @MainActor }` 不会执行），
    /// 所以这里必须同步保存。但**失败必须留下痕迹**：这里过去是 `try?`，
    /// 保存失败时数据就这么静静地丢了，而「关窗后再打开 sidebar 展开态没了」
    /// 正是丢在这一路上——没有错误、也没有任何地方能说出原因。
    internal func _performExitAutosave() {
        do {
            try save()
            autosaveFailureLock.withLock { _ in autosaveFailure = nil }
        } catch {
            _reportAutosaveFailure(error)
        }
    }

    private func _reportAutosaveFailure(_ error: Error) {
        autosaveFailureLock.withLock { _ in autosaveFailure = error }
        let message = "[JsonData] Automatic save failed: \(error.localizedDescription)\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        NotificationCenter.default.post(
            name: ModelContext.autosaveDidFail, object: self, userInfo: ["error": error])
    }

    // @contributor
    private func _tableName(for type: any PersistentModel.Type) -> String {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataTableName
        }
        return String(describing: type)
    }

    // @contributor
    private func _columns(for type: any PersistentModel.Type) -> [_JsonDataColumnInfo] {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataColumns
        }
        return []
    }

    // @contributor
    fileprivate static func _keyPathResolver(for type: any PersistentModel.Type) -> ((AnyKeyPath) -> String?)? {
        guard let schemaType = type as? any _JsonDataSchemaProviding.Type else { return nil }
        return { keyPath in
            schemaType._jsonDataPropertyName(for: keyPath)
        }
    }

    private let tableInitLock = Mutex(())
    private var initializedTables: Set<String> = []
    
    /// 根据给定的模型类型列表初始化数据库表结构。此方法供内部使用。
    public func _bootstrapSchema(_ schema: [any PersistentModel.Type]) throws {
        try databaseQueue.write { db in
            for modelType in schema {
                try self._ensureTable(for: modelType, in: db)
            }
        }
        schemaTypes = schema
    }

    // @contributor
    private func _ensureTable(for type: any PersistentModel.Type, in db: Database? = nil) throws {
        let tableName = _tableName(for: type)
        if tableInitLock.withLock({ _ in initializedTables.contains(tableName) }) { return }
        let migrator = ModelSchemaMigrator(modelType: type, tableName: tableName, columns: _columns(for: type))
        let performMigration: (Database) throws -> Void = { db in
            do {
                try migrator.migrate(in: db)
            } catch {
                throw JsonDataStoreError.schemaMigrationFailed(model: tableName, underlying: error)
            }
            // Cache only committed schemas. A later table or write can still
            // fail, rolling back every migration in the enclosing transaction.
            db.afterNextTransaction { [weak self] _ in
                guard let self else { return }
                _ = self.tableInitLock.withLock { _ in self.initializedTables.insert(tableName) }
            }
        }
        if let db {
            try performMigration(db)
        } else {
            try databaseQueue.write { try performMigration($0) }
        }
    }

    // @contributor
    private func _quote(identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Save

    /// 标记模型已发生更改，触发自动保存。由属性变更观察器调用。
    public func _modelDidChange(_ model: any PersistentModel) {
        _modelDidChange(model, propertyName: nil)
    }

    internal func _modelDidChange(_ model: any PersistentModel, propertyName: String?) {
        let properties = propertyName.map { Set([$0]) }
            ?? Set(_columns(for: type(of: model)).map(\.propertyName))
        identityMapLock.withLock { _ in
            let id = model.persistentModelID
            if insertedModels[id] == nil && deletedModels[id] == nil {
                changedModels[id] = model
                changedProperties[id, default: []].formUnion(properties)
            }
        }
        _scheduleAutosave()
    }

    // @contributor
    private func _saveModel(_ model: any PersistentModel, in db: Database) throws {
        let modelType = type(of: model)
        try _ensureTable(for: modelType, in: db)
        let tableName = _tableName(for: modelType)
        
        guard let schemaModel = model as? any _JsonDataSchemaProviding else { return }
        let columnValues = try schemaModel._toColumnValues(context: self)
        
        let cols = _columns(for: modelType)
        var columns = ["_id"]
        var placeholders = ["?"]
        var arguments: [DatabaseValueConvertible?] = [model.persistentModelID.id]
        
        for column in cols {
            columns.append(column.columnName)
            placeholders.append("?")
            let rawValue = columnValues[column.propertyName] ?? nil
            arguments.append(_databaseArgument(for: rawValue))
        }

        let sql = "INSERT OR REPLACE INTO \(_quote(identifier: tableName)) (\(columns.map(_quote(identifier:)).joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
        let updateArguments = StatementArguments(arguments)
        try db.execute(sql: sql, arguments: updateArguments)
    }

    // A context may hold an older copy of fields edited by another context.
    // Update only locally modified columns; replacing the row loses those edits.
    private func _updateModel(
        _ model: any PersistentModel, properties: Set<String>?, in db: Database
    ) throws {
        let modelType = type(of: model)
        try _ensureTable(for: modelType, in: db)
        guard let schemaModel = model as? any _JsonDataSchemaProviding else { return }
        let columns = _columns(for: modelType).filter {
            properties?.contains($0.propertyName) ?? true
        }
        guard !columns.isEmpty else { return }
        let values = try schemaModel._toColumnValues(context: self)
        let assignments = columns.map { "\(_quote(identifier: $0.columnName)) = ?" }
        var arguments: [DatabaseValueConvertible?] = columns.map {
            _databaseArgument(for: values[$0.propertyName] ?? nil)
        }
        arguments.append(model.persistentModelID.id)
        try db.execute(
            sql: "UPDATE \(_quote(identifier: _tableName(for: modelType))) SET \(assignments.joined(separator: ", ")) WHERE _id = ?",
            arguments: StatementArguments(arguments)
        )
    }

    /// 将所有未保存的插入、更新和删除操作写入数据库。
    public func save() throws {
        let (toInsert, toUpdate, toDelete, propertiesToUpdate) = identityMapLock.withLock { _ -> ([any PersistentModel], [any PersistentModel], [any PersistentModel], [PersistentIdentifier: Set<String>]) in
            let inserts = Array(insertedModels.values)
            let updates = Array(changedModels.values)
            let deletes = Array(deletedModels.values)
            let properties = changedProperties

            insertedModels.removeAll()
            changedModels.removeAll()
            changedProperties.removeAll()
            deletedModels.removeAll()
            for model in inserts + updates + deletes {
                let id = model.persistentModelID
                savingModels[id] = (model, (savingModels[id]?.count ?? 0) + 1)
            }
            for model in deletes { savingDeletions[model.persistentModelID, default: 0] += 1 }
            return (inserts, updates, deletes, properties)
        }
        
        if toInsert.isEmpty && toUpdate.isEmpty && toDelete.isEmpty {
            return
        }
        
        defer {
            identityMapLock.withLock { _ in
                for model in toInsert + toUpdate + toDelete {
                    let id = model.persistentModelID
                    if let saving = savingModels[id], saving.count > 1 {
                        savingModels[id] = (saving.model, saving.count - 1)
                    } else { savingModels[id] = nil }
                }
                for model in toDelete {
                    let id = model.persistentModelID
                    if let count = savingDeletions[id], count > 1 { savingDeletions[id] = count - 1 }
                    else { savingDeletions[id] = nil }
                }
            }
        }
        do {
            try databaseQueue.write { db in
                for model in toDelete {
                    let modelType = type(of: model)
                    try _ensureTable(for: modelType, in: db)
                
                    if let schemaType = modelType as? any _JsonDataSchemaProviding.Type {
                        let extDir = baseURL.appendingPathComponent(".externalStorage")
                        for column in schemaType._jsonDataColumns where column.options.contains(.externalStorage) {
                            let filename = "\(model.persistentModelID.id)_\(column.propertyName).dat"
                            let fileUrl = extDir.appendingPathComponent(filename)
                            try? FileManager.default.removeItem(at: fileUrl)
                        }
                    }
                
                    try db.execute(
                        sql: "DELETE FROM \(_quote(identifier: _tableName(for: modelType))) WHERE _id = ?",
                        arguments: [model.persistentModelID.id]
                    )
                }
            
                for model in toInsert {
                    try _saveModel(model, in: db)
                }
            
                for model in toUpdate {
                    try _updateModel(model, properties: propertiesToUpdate[model.persistentModelID], in: db)
                }
            }
        } catch {
            identityMapLock.withLock { _ in
                for model in toInsert where deletedModels[model.persistentModelID] == nil {
                    if insertedModels[model.persistentModelID] == nil { insertedModels[model.persistentModelID] = model }
                }
                for model in toUpdate where deletedModels[model.persistentModelID] == nil {
                    let id = model.persistentModelID
                    if changedModels[id] == nil { changedModels[id] = model }
                    let properties = propertiesToUpdate[id]
                        ?? Set(_columns(for: type(of: model)).map(\.propertyName))
                    changedProperties[id, default: []].formUnion(properties)
                }
                for model in toDelete where insertedModels[model.persistentModelID] == nil {
                    if deletedModels[model.persistentModelID] == nil { deletedModels[model.persistentModelID] = model }
                }
            }
            throw error
        }
        _postContextDidChange()
    }

    // MARK: - Insert / Delete

    /// 将模型插入上下文，在下一次保存时写入数据库。
    public func insert<T: PersistentModel>(_ model: T) {
        let shouldReturn = identityMapLock.withLock { _ -> Bool in
            let id = model.persistentModelID
            if insertedModels[id] != nil {
                return true
            }
            if let ref = identityMap[id], let existing = ref.value {
                if existing === model {
                    insertedModels[id] = model
                    return false
                }
                // Upgrade a relationship fault shell to the live inserted instance.
                if existing._isFault {
                    identityMap[id] = WeakRef(model)
                    insertedModels[id] = model
                    return false
                }
                return true
            }
            identityMap[id] = WeakRef(model)
            insertedModels[id] = model
            return false
        }
        if shouldReturn { return }

        model._modelContext = self
        model._isFault = false
        
        _processCascadeInsert(for: model)
        _scheduleAutosave()
    }
    
    // @contributor
    private func _processCascadeInsert(for model: any PersistentModel) {
        guard let schemaType = type(of: model) as? any _JsonDataSchemaProviding.Type else { return }
        let relationships = schemaType._jsonDataRelationships
        if relationships.isEmpty { return }
        
        let mirror = Mirror(reflecting: model)
        var fields: [String: Any?] = [:]
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            fields[String(label.dropFirst())] = _fieldStorageValue(from: child.value)
        }
        
        for rel in relationships {
            guard let value = fields[rel.propertyName] as? Any else { continue }
            if let relatedModel = value as? any PersistentModel {
                self.insert(relatedModel)
            } else if let relatedArray = value as? [any PersistentModel] {
                for rm in relatedArray {
                    self.insert(rm)
                }
            }
        }
    }

    /// 将模型标记为待删除，在下一次保存时从数据库移除。
    public func delete<T: PersistentModel>(_ model: T) {
        let shouldReturn = identityMapLock.withLock { _ -> Bool in
            let id = model.persistentModelID
            if deletedModels[id] != nil {
                return true
            }
            
            identityMap.removeValue(forKey: id)
            insertedModels.removeValue(forKey: id)
            changedModels.removeValue(forKey: id)
            changedProperties.removeValue(forKey: id)
            deletedModels[id] = model
            return false
        }
        
        if shouldReturn { return }
        
        _processCascadeDelete(for: model)
        _scheduleAutosave()
    }
    
    // @contributor
    private func _processCascadeDelete(for model: any PersistentModel) {
        guard let schemaType = type(of: model) as? any _JsonDataSchemaProviding.Type else { return }
        let cascadeRelationships = schemaType._jsonDataRelationships.filter { $0.deleteRule == .cascade }
        if cascadeRelationships.isEmpty { return }
        
        if model._isFault {
            _faultIn(model)
        }
        
        let mirror = Mirror(reflecting: model)
        var fields: [String: Any?] = [:]
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            fields[String(label.dropFirst())] = _fieldStorageValue(from: child.value)
        }
        
        for rel in cascadeRelationships {
            guard let value = fields[rel.propertyName] as? Any else { continue }
            if let relatedModel = value as? any PersistentModel {
                self.delete(relatedModel)
            } else if let relatedArray = value as? [any PersistentModel] {
                for rm in relatedArray {
                    self.delete(rm)
                }
            }
        }
    }

    // @contributor
    private func _fieldStorageValue(from storage: Any) -> Any? {
        let mirror = Mirror(reflecting: storage)
        for child in mirror.children where child.label == "value" || child.label == "defaultValue" {
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.displayStyle == .optional {
                if let unwrapped = childMirror.children.first?.value {
                    return unwrapped
                }
                continue
            }
            return child.value
        }
        return nil
    }

    // MARK: - Fetch

    /// 根据查询描述符和限制条件从数据库检索模型实例。
    public func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        limit: Int? = nil
    ) throws -> [T] {
        let effectiveLimit = descriptor.fetchLimit ?? limit
        if let effectiveLimit, effectiveLimit <= 0 {
            return []
        }

        try _ensureTable(for: T.self)
        let tableName = _tableName(for: T.self)
        let query = try _buildFetchQuery(for: T.self, descriptor: descriptor, limit: effectiveLimit, tableName: tableName)
        let cols = _columns(for: T.self)
        
        let rows: [Row] = try databaseQueue.read { db in
            try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }

        var results: [T] = []
        identityMapLock.withLock { _ in
            _purgeStaleEntries()
        }

        for row in rows {
            let idStr: String = row["_id"]
            let id = PersistentIdentifier(id: idStr)
            
            let model: T
            let wasFault: Bool
            if let ref = identityMap[id], let cached = ref.value as? T {
                model = cached
                wasFault = cached._isFault
            } else {
                model = T()
                model.persistentModelID = id
                wasFault = true
            }
            
            if descriptor.predicate == nil && wasFault {
                model._isFault = true
                model._modelContext = self
                identityMap[id] = WeakRef(model)
                results.append(model)
                continue
            }

            if wasFault {
                let values = _rowToValues(row, columns: cols)
                if let schemaModel = model as? any _JsonDataSchemaProviding {
                    schemaModel._populateFromColumnValues(values, context: self)
                }
                model._modelContext = self
                model._isFault = false
                identityMap[id] = WeakRef(model)
            }
            
            results.append(model)
        }

        if descriptor.includePendingChanges {
            var pendingInserts: [T] = []
            var deletedIDs: Set<PersistentIdentifier> = []
            identityMapLock.withLock { _ in
                pendingInserts = insertedModels.values.compactMap { $0 as? T }
                deletedIDs = Set(deletedModels.keys)
            }
            
            if let filter = descriptor.predicate?.memoryFilter {
                results.removeAll { deletedIDs.contains($0.persistentModelID) || !filter($0) }
                for insert in pendingInserts {
                    if !deletedIDs.contains(insert.persistentModelID) && filter(insert) {
                        results.append(insert)
                    }
                }
            } else if descriptor.predicate == nil {
                results.removeAll { deletedIDs.contains($0.persistentModelID) }
                results.append(contentsOf: pendingInserts.filter { !deletedIDs.contains($0.persistentModelID) })
            } else {
                results.removeAll { deletedIDs.contains($0.persistentModelID) }
                results.append(contentsOf: pendingInserts.filter { !deletedIDs.contains($0.persistentModelID) })
            }
        }

        if !descriptor.sortBy.isEmpty {
            let sortDescriptors = descriptor.sortBy
            results.sort { a, b in
                for sd in sortDescriptors {
                    if sd.areInIncreasingOrder(a, b) { return true }
                    if sd.areInIncreasingOrder(b, a) { return false }
                }
                return false
            }
        }
        if let effectiveLimit {
            results = Array(results.prefix(effectiveLimit))
        }

        return results
    }

    /// 创建数据观察器，用于监听查询结果的实时变化。
    public func observe<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()
    ) -> ValueObservation<ValueReducers.Fetch<UncheckedSendableArray<T>>> {
        let tableName = _tableName(for: T.self)
        let preparation = Result { try _ensureTable(for: T.self) }
        let effectiveLimit = descriptor.fetchLimit
        
        return ValueObservation.tracking { db in
            try preparation.get()
            let query = try self._buildFetchQuery(for: T.self, descriptor: descriptor, limit: effectiveLimit, tableName: tableName)
            let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            let cols = self._columns(for: T.self)
            
            // IMPORTANT: do NOT hold `identityMapLock` across
            // `_populateFromColumnValues`. Hydrating a model with a to-one
            // relationship calls `_jsonDataDecode(context:)`, which re-enters the
            // identity map via `_registeredModel` / `_registerInIdentityMap` and
            // therefore re-acquires `identityMapLock`. That Mutex is
            // non-recursive, so holding it here self-deadlocks the writer queue
            // during a ValueObservation refresh (every `@Query` on a model with a
            // relationship froze the whole app right after a DB write). Mirror
            // `fetch()`: only take the lock for short identity-map reads/writes.
            var results = [T]()
            for row in rows {
                let idStr: String = row["_id"]
                let id = PersistentIdentifier(id: idStr)

                if let cached = self.identityMapLock.withLock({ _ in self.identityMap[id]?.value as? T }) {
                    results.append(cached)
                    continue
                }

                let model = T()
                model.persistentModelID = id
                let values = self._rowToValues(row, columns: cols)
                if let schemaModel = model as? any _JsonDataSchemaProviding {
                    schemaModel._populateFromColumnValues(values, context: self)
                }
                model._modelContext = self
                model._isFault = false
                self.identityMapLock.withLock { _ in self.identityMap[id] = WeakRef(model) }
                results.append(model)
            }
            // Apply in-memory sort to match fetch behavior,
            // since cached objects may have been mutated in memory
            // and SQL ORDER BY reflects stale DB values.
            if !descriptor.sortBy.isEmpty {
                let sortDescriptors = descriptor.sortBy
                results.sort { a, b in
                    for sd in sortDescriptors {
                        if sd.areInIncreasingOrder(a, b) { return true }
                        if sd.areInIncreasingOrder(b, a) { return false }
                    }
                    return false
                }
            }
            if let limit = effectiveLimit, results.count > limit {
                results = Array(results.prefix(limit))
            }
            return UncheckedSendableArray(results)
        }
    }

    /// 仅查询匹配描述符的持久化标识符，不 hydrate 模型行。
    public func fetchPersistentIdentifiers<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()
    ) throws -> [PersistentIdentifier] {
        let effectiveLimit = descriptor.fetchLimit
        if let effectiveLimit, effectiveLimit <= 0 {
            return []
        }

        try _ensureTable(for: T.self)
        let tableName = _tableName(for: T.self)
        let query = try _buildIdentifierFetchQuery(
            for: T.self,
            descriptor: descriptor,
            limit: effectiveLimit,
            tableName: tableName
        )
        let idStrings: [String] = try databaseQueue.read { db in
            try String.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }
        return idStrings.map { PersistentIdentifier(id: $0) }
    }

    /// 观察谓词结果集的成员（仅 `_id`），供 `@Query` 懒惰判定增删。
    public func observePersistentIdentifiers<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()
    ) -> ValueObservation<ValueReducers.Fetch<UncheckedSendableArray<PersistentIdentifier>>> {
        let tableName = _tableName(for: T.self)
        let preparation = Result { try _ensureTable(for: T.self) }
        let effectiveLimit = descriptor.fetchLimit

        return ValueObservation.tracking { db in
            try preparation.get()
            let query = try self._buildIdentifierFetchQuery(
                for: T.self,
                descriptor: descriptor,
                limit: effectiveLimit,
                tableName: tableName
            )
            let idStrings = try String.fetchAll(db, sql: query.sql, arguments: query.arguments)
            let ids = idStrings.map { PersistentIdentifier(id: $0) }
            return UncheckedSendableArray(ids)
        }
    }

    /// 在主线程启动成员集观察；ID 序列变化时回调（不交付完整模型）。
    @MainActor
    public func startMembershipObservation<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        onError: @escaping (Error) -> Void = { _ in },
        onChange: @MainActor @escaping ([PersistentIdentifier]) -> Void
    ) -> DatabaseCancellable {
        let obs = observePersistentIdentifiers(descriptor)
        let boxedOnChange = UncheckedSendableClosure(onChange)
        let boxedOnError = UncheckedSendableClosure(onError)

        return obs.start(
            in: databaseQueue,
            onError: { err in boxedOnError.closure(err) },
            onChange: { box in
                Task { @MainActor in
                    boxedOnChange.closure(box.value)
                }
            }
        )
    }

    /// 从数据库重新填充已缓存模型的字段，触发 `@Observable` 属性变更。
    public func refreshCachedModels(ids: [PersistentIdentifier]) {
        for id in ids {
            guard let ref = identityMapLock.withLock({ _ in identityMap[id] }),
                  let model = ref.value
            else { continue }
            _faultIn(model)
        }
    }

    public struct UncheckedSendableArray<V>: @unchecked Sendable {
        public let value: [V]
        public init(_ value: [V]) { self.value = value }
    }

    public struct UncheckedSendableClosure<C>: @unchecked Sendable {
        public let closure: C
        public init(_ closure: C) { self.closure = closure }
    }

    private func observeRows<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) -> ValueObservation<ValueReducers.Fetch<ObservedSnapshot>> {
        let tableName = _tableName(for: T.self)
        let preparation = Result { try _ensureTable(for: T.self) }
        return ValueObservation.tracking { db in
            try preparation.get()
            let query = try self._buildFetchQuery(
                for: T.self, descriptor: descriptor, limit: descriptor.fetchLimit, tableName: tableName)
            let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            // Every observation of this context fetches on the same database queue.
            // Its revision also orders snapshots from overlapping queries.
            let revision = self.observationRevision.withLock { $0 += 1; return $0 }
            return ObservedSnapshot(revision: revision, rows: rows)
        }
    }

    /// Preserves identities and pending edits while merging changed database rows.
    @MainActor
    private func mergeObservedRows<T: PersistentModel>(
        _ snapshot: ObservedSnapshot, descriptor: FetchDescriptor<T>, previous: ObservedRows
    ) -> [T] {
        let columns = _columns(for: T.self)
        // Mutex returns a sending result. Live models remain aliased by this context, so capture
        // the snapshot into the caller's MainActor region and return only Void from the lock.
        var pending: (
            inserted: [PersistentIdentifier: any PersistentModel],
            editing: [PersistentIdentifier: any PersistentModel],
            deleted: Set<PersistentIdentifier>
        ) = ([:], [:], [])
        identityMapLock.withLock { _ -> Void in
            pending.inserted = insertedModels
            pending.editing = changedModels.merging(savingModels.mapValues(\.model)) { edited, _ in edited }
            pending.deleted = Set(deletedModels.keys).union(savingDeletions.keys)
        }
        var results: [T] = []
        var seen: Set<PersistentIdentifier> = []
        for row in snapshot.rows {
            let id = PersistentIdentifier(id: row["_id"] as String)
            seen.insert(id)
            guard !pending.deleted.contains(id) else { continue }
            var known: (model: T?, revision: Int) = (nil, 0)
            identityMapLock.withLock { _ -> Void in
                known = (identityMap[id]?.value as? T, observedModelRevisions[id] ?? 0)
            }
            let cached = known.model
            if let local = (pending.inserted[id] ?? pending.editing[id]) as? T {
                results.append(local)
                // Retry after the local edit commits; this snapshot did not land.
                previous.rows[id] = nil
                continue
            }
            if let cached, snapshot.revision < known.revision {
                // Another query has already merged a newer snapshot of this model.
                results.append(cached)
                previous.rows[id] = nil
                continue
            }
            if let cached, !cached._isFault, previous.rows[id] == row {
                identityMapLock.withLock { _ in observedModelRevisions[id] = snapshot.revision }
                results.append(cached)
                continue
            }

            let decoded = T()
            decoded.persistentModelID = id
            (decoded as? any _JsonDataSchemaProviding)?._populateFromColumnValues(
                _rowToValues(row, columns: columns), context: self)
            decoded._isFault = false
            let model: T
            if let cached {
                // Field setters notify Observation, but loading must not autosave
                // the snapshot or modify inverse relationships as a local edit.
                cached._isFaulting = true
                cached._isFault = false
                cached._copy(from: decoded)
                cached._isFaulting = false
                model = cached
            } else {
                model = decoded
                identityMapLock.withLock { _ in identityMap[id] = WeakRef(model) }
            }
            model._modelContext = self
            identityMapLock.withLock { _ in observedModelRevisions[id] = snapshot.revision }
            previous.rows[id] = row
            results.append(model)
        }
        previous.rows = previous.rows.filter { seen.contains($0.key) }
        if descriptor.includePendingChanges {
            for (id, model) in pending.inserted where !seen.contains(id) && !pending.deleted.contains(id) {
                if let model = model as? T { results.append(model) }
            }
        }
        if let filter = descriptor.predicate?.memoryFilter { results.removeAll { !filter($0) } }
        if !descriptor.sortBy.isEmpty {
            results.sort { a, b in
                for order in descriptor.sortBy {
                    if order.areInIncreasingOrder(a, b) { return true }
                    if order.areInIncreasingOrder(b, a) { return false }
                }
                return false
            }
        }
        if let limit = descriptor.fetchLimit { results = Array(results.prefix(limit)) }
        return results
    }

    /// 在主线程启动数据观察，当查询结果变化时回调 `onChange`。
    @MainActor
    public func startObservation<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        onError: @escaping (Error) -> Void = { _ in },
        onChange: @MainActor @escaping ([T]) -> Void
    ) -> DatabaseCancellable {
        let obs = observeRows(descriptor)
        let previous = ObservedRows()
        let boxedOnChange = UncheckedSendableClosure(onChange)
        let boxedOnError = UncheckedSendableClosure(onError)
        
        return obs.start(
            in: databaseQueue,
            // `.mainActor` 用 `DispatchQueue.main.async` 投递，只有在「有人排空主队列」
            // 的进程里才会跑；SwiftOmniUI 的宿主偏偏是「装了自己的 MainActor 执行器、
            // 主队列没人排空」的进程，于是首个值之后观察再也不会回调。`.mainActorHop`
            // 用 `Task { @MainActor }` 交接，同样保序，任何排空自己执行器的宿主都能跑到。
            scheduling: .mainActorHop,
            onError: { @MainActor err in boxedOnError.closure(err) },
            onChange: { @MainActor box in
                // The scheduler preserves commit order and checks cancellation
                // before delivery. Another unstructured Task would lose both.
                let items = self.mergeObservedRows(box, descriptor: descriptor, previous: previous)
                boxedOnChange.closure(items)
            }
        )
    }

    /// 通过持久化标识符查找并返回模型实例（对齐 SwiftData 非泛型 API，便于 `as? ConcreteType`）。
    public func model(for id: PersistentIdentifier) -> any PersistentModel {
        if let cached = identityMapLock.withLock({ _ -> (any PersistentModel)? in
            if let inserted = insertedModels[id] { return inserted }
            if let ref = identityMap[id], let cached = ref.value { return cached }
            return nil
        }) {
            return cached
        }

        for type in schemaTypes {
            if let loaded = try? _loadModelExistential(type: type, id: id) {
                identityMapLock.withLock { _ in
                    identityMap[id] = WeakRef(loaded)
                }
                return loaded
            }
        }

        // SwiftData 在缺失时仍返回模型；这里用 schema 首类型生成 fault，
        // 调用方 `as? ConcreteType` 会得到 nil，语义可接受。
        guard let fallbackType = schemaTypes.first else {
            preconditionFailure(
                "JsonData.ModelContext.model(for:): no schema types registered; call ModelContainer bootstrap first. id=\(id.id)"
            )
        }
        let fault = fallbackType.init()
        fault.persistentModelID = id
        fault._modelContext = self
        fault._isFault = true
        identityMapLock.withLock { _ in
            identityMap[id] = WeakRef(fault)
        }
        return fault
    }

    /// 通过持久化标识符查找并返回指定类型的模型实例。
    public func model<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        if let cached = identityMapLock.withLock({ _ -> T? in
            if let ref = identityMap[id], let cached = ref.value as? T, !cached._isFault, !cached._isFaulting {
                return cached
            }
            return nil
        }) {
            return cached
        }

        do {
            guard let model: T = try _loadModel(for: id) else { return nil }
            identityMapLock.withLock { _ in
                identityMap[id] = WeakRef(model)
            }
            return model
        } catch {
            return nil
        }
    }

    // @contributor
    private func _loadModel<T: PersistentModel>(for id: PersistentIdentifier) throws -> T? {
        try _ensureTable(for: T.self)
        let tableName = _tableName(for: T.self)
        let cols = _columns(for: T.self)
        let selectCols = (["_id"] + cols.map { _quote(identifier: $0.columnName) }).joined(separator: ", ")
        
        let row: Row? = try databaseQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(selectCols) FROM \(_quote(identifier: tableName)) WHERE _id = ?",
                arguments: [id.id]
            )
        }
        guard let row else { return nil }
        
        let model = T()
        model.persistentModelID = id
        let values = _rowToValues(row, columns: cols)
        if let schemaModel = model as? any _JsonDataSchemaProviding {
            schemaModel._populateFromColumnValues(values, context: self)
        }
        model._modelContext = self
        model._isFault = false
        return model
    }

    /// Returns a registered instance for `id` if present (fault or live).
    internal func _registeredModel<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        identityMapLock.withLock { _ in
            identityMap[id]?.value as? T
        }
    }

    /// Registers `model` in the identity map (does not insert / mark dirty).
    internal func _registerInIdentityMap(_ model: any PersistentModel) {
        identityMapLock.withLock { _ in
            identityMap[model.persistentModelID] = WeakRef(model)
        }
    }

    /// 将惰性加载的模型实例填充完整数据。此方法供内部使用。
    /// Only clears `_isFault` after a successful hydrate; load miss / error keeps the fault flag.
    public func _faultIn(_ model: any PersistentModel) {
        do {
            let id = model.persistentModelID
            let type = type(of: model)

            // Prefer a live non-fault instance already in the identity map (same id, different object).
            // Inserted (unsaved) models are also registered in identityMap with _isFault == false.
            // Assign inside the lock (don't return existential) to satisfy Swift 6 sending checks.
            nonisolated(unsafe) var liveSource: (any PersistentModel)?
            identityMapLock.withLock { _ in
                guard let ref = identityMap[id], let cached = ref.value else { return }
                if cached !== model, !cached._isFault, !cached._isFaulting {
                    liveSource = cached
                }
            }

            let fullModel: any PersistentModel
            if let liveSource {
                fullModel = liveSource
            } else if let loaded = try _loadModelExistential(type: type, id: id) {
                fullModel = loaded
            } else {
                // Keep _isFault == true so callers can retry; do not expose empty Fields as hydrated.
                return
            }

            model._isFaulting = true
            defer { model._isFaulting = false }
            // Clear fault flag before _copy so Field setters' fault() calls are no-ops.
            model._isFault = false
            model._copy(from: fullModel)
            model._modelContext = self
            identityMapLock.withLock { _ in
                identityMap[model.persistentModelID] = WeakRef(model)
            }
        } catch {
            return
        }
    }

    private func _loadModelExistential(
        type: any PersistentModel.Type,
        id: PersistentIdentifier
    ) throws -> (any PersistentModel)? {
        try _ensureTable(for: type)
        let tableName = _tableName(for: type)
        let cols = _columns(for: type)
        let selectCols = (["_id"] + cols.map { _quote(identifier: $0.columnName) }).joined(separator: ", ")

        let row: Row? = try databaseQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(selectCols) FROM \(_quote(identifier: tableName)) WHERE _id = ?",
                arguments: [id.id]
            )
        }
        guard let row else { return nil }

        let model = type.init()
        model.persistentModelID = id
        let values = _rowToValues(row, columns: cols)
        if let schemaModel = model as? any _JsonDataSchemaProviding {
            schemaModel._populateFromColumnValues(values, context: self)
        }
        model._modelContext = self
        model._isFault = false
        return model
    }

    // MARK: - Row ↔ Values Helpers

    // @contributor
    private func _rowToValues(_ row: Row, columns: [_JsonDataColumnInfo]) -> [String: Any?] {
        var values: [String: Any?] = [:]
        values["_id"] = row["_id"] as String
        for col in columns {
            switch col.kind {
            case .string, .uuid, .codableJSON, .url:
                values[col.propertyName] = row[col.columnName] as String?
            case .integer:
                values[col.propertyName] = row[col.columnName] as Int64?
            case .double, .date:
                values[col.propertyName] = row[col.columnName] as Double?
            case .bool:
                values[col.propertyName] = row[col.columnName] as Int64?
            case .data:
                values[col.propertyName] = row[col.columnName] as Data?
            }
        }
        
        return values
    }

    // MARK: - Query Building

    // @contributor
    private func _buildFetchQuery<T: PersistentModel>(
        for type: T.Type,
        descriptor: FetchDescriptor<T>,
        limit: Int?,
        tableName: String
    ) throws -> (sql: String, arguments: StatementArguments) {
        let cols = _columns(for: type)
        let selectCols = (["_id"] + cols.map { _quote(identifier: $0.columnName) }).joined(separator: ", ")
        return try _buildFetchQuerySQL(
            for: type,
            descriptor: descriptor,
            limit: limit,
            tableName: tableName,
            selectCols: selectCols
        )
    }

    // @contributor
    private func _buildIdentifierFetchQuery<T: PersistentModel>(
        for type: T.Type,
        descriptor: FetchDescriptor<T>,
        limit: Int?,
        tableName: String
    ) throws -> (sql: String, arguments: StatementArguments) {
        try _buildFetchQuerySQL(
            for: type,
            descriptor: descriptor,
            limit: limit,
            tableName: tableName,
            selectCols: "_id"
        )
    }

    // @contributor
    private func _buildFetchQuerySQL<T: PersistentModel>(
        for type: T.Type,
        descriptor: FetchDescriptor<T>,
        limit: Int?,
        tableName: String,
        selectCols: String
    ) throws -> (sql: String, arguments: StatementArguments) {
        var sql = "SELECT \(selectCols) FROM \(_quote(identifier: tableName))"
        var arguments = StatementArguments()

        if let predicate = descriptor.predicate {
            if !predicate.sql.isEmpty {
                sql += " WHERE \(predicate.sql)"
                let dbArgs = predicate.arguments.map { _databaseArgument(for: $0) }
                arguments += StatementArguments(dbArgs)
            }
        }

        // 处理嵌套 keyPath 产生的 JOIN 子查询（如 $0.subAgent?.callID == xxx）
        if let joinConditions = descriptor.predicate?.joinConditions, !joinConditions.isEmpty {
            if let schemaType = type as? any _JsonDataSchemaProviding.Type {
                for jc in joinConditions {
                    if let rel = schemaType._jsonDataRelationships.first(where: { $0.propertyName == jc.localColumn }),
                       let destSchema = rel.destinationType as? any _JsonDataSchemaProviding.Type {
                        let targetTable = destSchema._jsonDataTableName
                        let prefix = sql.contains("WHERE") ? " AND" : " WHERE"
                        sql += "\(prefix) \(_quote(identifier: jc.localColumn)) IN (SELECT \"_id\" FROM \(_quote(identifier: targetTable)) WHERE \(_quote(identifier: jc.targetColumn)) \(jc.op) ?)"
                        if let dbArg = _databaseArgument(for: jc.argument) {
                            arguments += StatementArguments([dbArg])
                        }
                    }
                }
            }
        }

        let orderBy = _buildOrderByClause(descriptor.sortBy, columns: _columns(for: type))
        if !orderBy.isEmpty {
            sql += " ORDER BY \(orderBy)"
        }

        if let fetchOffset = descriptor.fetchOffset, fetchOffset > 0 {
            sql += " LIMIT -1 OFFSET \(fetchOffset)"
        }
        if let limit {
            if descriptor.fetchOffset != nil {
                sql = sql.replacingOccurrences(of: "LIMIT -1", with: "LIMIT \(limit)")
            } else {
                sql += " LIMIT \(limit)"
            }
        }

        return (sql, arguments)
    }

    // @contributor
    private func _buildOrderByClause<T: PersistentModel>(
            _ sortBy: [SortDescriptor<T>],
            columns: [_JsonDataColumnInfo]
        ) -> String {
            let resolver = Self._keyPathResolver(for: T.self)
            let fragments = sortBy.compactMap { descriptor -> String? in
                guard
                    let propertyName = resolver?(descriptor.keyPath),
                    let column = columns.first(where: { $0.propertyName == propertyName || $0.columnName == propertyName })
                else {
                    return nil
                }
                let isReverse = descriptor.order == .reverse
                return "\(_quote(identifier: column.columnName)) \(isReverse ? "DESC" : "ASC")"
            }
            return fragments.joined(separator: ", ")
        }
}
private func _databaseArgument(for value: Any?) -> DatabaseValueConvertible? {
    switch value {
    case let int as Int: return int
    case let int8 as Int8: return Int64(int8)
    case let int16 as Int16: return Int64(int16)
    case let int32 as Int32: return Int64(int32)
    case let int64 as Int64: return int64
    case let uint as UInt: return Int64(uint)
    case let uint8 as UInt8: return Int64(uint8)
    case let uint16 as UInt16: return Int64(uint16)
    case let uint32 as UInt32: return Int64(uint32)
    case let uint64 as UInt64: return Int64(uint64)
    case let double as Double: return double
    case let float as Float: return Double(float)
    case let string as String: return string
    case let bool as Bool: return bool ? 1 : 0
    case let uuid as UUID: return uuid.uuidString
    case let date as Date:
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    case let url as URL: return url.absoluteString
    case let data as Data: return data
    case let pid as PersistentIdentifier: return pid.id
    case nil: return nil
    default:
        return nil
    }
}

extension ModelContext {
    /// 将外部存储的数据写入文件系统。此方法供内部使用。
    public func _saveExternalData(_ data: Data, modelID: PersistentIdentifier, propertyName: String) throws -> String {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let filename = "\(modelID.id)_\(propertyName).dat"
        let fileUrl = extDir.appendingPathComponent(filename)
        try data.write(to: fileUrl)
        return filename
    }

    /// 从文件系统读取外部存储的数据。此方法供内部使用。
    public func _loadExternalData(from reference: String) throws -> Data {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        let fileUrl = extDir.appendingPathComponent(reference)
        return try Data(contentsOf: fileUrl)
    }
}
