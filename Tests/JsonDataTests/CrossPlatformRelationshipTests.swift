import Foundation
import XCTest



@testable import JsonDataCore

@Model
private final class ParentRecord {
    var name: String
    @Relationship(deleteRule: .cascade) var child: ChildRecord?

    init(name: String = "", child: ChildRecord? = nil) {
        self.name = name
        self.child = child
    }
}

@Model
private final class ChildRecord {
    var title: String

    init(title: String = "") {
        self.title = title
    }
}

final class CrossPlatformRelationshipTests: XCTestCase {
    func testCascadeDelete() throws {
        let directory = try makeTemporaryDirectory(prefix: "Relationships")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: ParentRecord.self, ChildRecord.self, configurations: config)
        let context = ModelContext(container)

        let child1 = ChildRecord(title: "Child 1")
        let parent = ParentRecord(name: "Parent", child: child1)

        context.insert(child1)
        context.insert(parent)
        try context.save()

        let readContext = ModelContext(container)
        let parents = try readContext.fetch(FetchDescriptor<ParentRecord>())
        XCTAssertEqual(parents.count, 1)
        let children = try readContext.fetch(FetchDescriptor<ChildRecord>())
        XCTAssertEqual(children.count, 1)

        let deleteContext = ModelContext(container)
        if let p = try deleteContext.fetch(FetchDescriptor<ParentRecord>()).first {
            deleteContext.delete(p)
            try deleteContext.save()
        }

        let verifyContext = ModelContext(container)
        let remainingParents = try verifyContext.fetch(FetchDescriptor<ParentRecord>())
        let remainingChildren = try verifyContext.fetch(FetchDescriptor<ChildRecord>())

        XCTAssertEqual(remainingParents.count, 0)
        XCTAssertEqual(remainingChildren.count, 0)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
