import Foundation
import XCTest



@testable import JsonDataCore

@Model
private final class UniqueConstraintTestRecord {
    @Attribute(.unique) var uniqueKey: String
    var counter: Int

    init(uniqueKey: String = "", counter: Int = 0) {
        self.uniqueKey = uniqueKey
        self.counter = counter
    }
}

final class CrossPlatformUniqueConstraintTests: XCTestCase {
    func testUniqueConstraintUpsert() throws {
        let directory = try makeTemporaryDirectory(prefix: "UniqueConstraint")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: UniqueConstraintTestRecord.self, configurations: config)
        let context = ModelContext(container)

        let record1 = UniqueConstraintTestRecord(uniqueKey: "KeyA", counter: 1)
        context.insert(record1)
        try context.save()

        let record2 = UniqueConstraintTestRecord(uniqueKey: "KeyA", counter: 2)
        context.insert(record2)
        try context.save()

        let readContext = ModelContext(container)
        let all = try readContext.fetch(FetchDescriptor<UniqueConstraintTestRecord>())
        
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.uniqueKey, "KeyA")
        // SwiftData typically performs an upsert, meaning the latest insert overrides.
        XCTAssertEqual(all.first?.counter, 2)
    }

    func testFindOrCreateWithoutExplicitSave() throws {
        // 模拟 getDialogue 的 "find or create" 模式：
        // 用 predicate + fetchLimit=1 查找，找不到则创建（通过关系 append）
        // 连续两次调用，验证不会重复创建
        
        let directory = try makeTemporaryDirectory(prefix: "FindOrCreate")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: UniqueConstraintTestRecord.self, configurations: config)
        let context = ModelContext(container)
        
        let testKey = "DuplicateTest"
        
        // 第一次 "find or create"：SQL 找不到 → 创建
        let desc1 = FetchDescriptor<UniqueConstraintTestRecord>(
            predicate: #Predicate<UniqueConstraintTestRecord> { $0.uniqueKey == testKey }
        )
        var desc1Mut = desc1
        desc1Mut.fetchLimit = 1
        if try context.fetch(desc1Mut).first == nil {
            let newRecord = UniqueConstraintTestRecord(uniqueKey: testKey, counter: 1)
            context.insert(newRecord)
        }
        
        // 第二次 "find or create"（autosave 还未执行）：应从 insertedModels 找到
        let desc2 = FetchDescriptor<UniqueConstraintTestRecord>(
            predicate: #Predicate<UniqueConstraintTestRecord> { $0.uniqueKey == testKey }
        )
        var desc2Mut = desc2
        desc2Mut.fetchLimit = 1
        let found = try context.fetch(desc2Mut).first
        XCTAssertNotNil(found, "第二次查找应该通过 memoryFilter 找到 pending insert")
        XCTAssertEqual(found?.uniqueKey, testKey)
        XCTAssertEqual(found?.counter, 1)
        
        // 验证没有重复创建
        try context.save()
        let readContext = ModelContext(container)
        let all = try readContext.fetch(FetchDescriptor<UniqueConstraintTestRecord>(
            predicate: #Predicate<UniqueConstraintTestRecord> { $0.uniqueKey == testKey }
        ))
        XCTAssertEqual(all.count, 1, "数据库中不应有重复记录")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
