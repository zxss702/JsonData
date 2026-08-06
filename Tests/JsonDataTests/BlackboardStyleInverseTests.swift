import Foundation
import XCTest

@testable import JsonDataCore

/// Mirrors SYAICommunicationRecord / SYTask + BlackboardUpdateTool write path.
@Model
private final class BoardRecord {
    var name: String = ""
    var analysis: String = ""
    @Relationship(deleteRule: .cascade, inverse: \BoardTask.record)
    var tasks: [BoardTask] = []
    @Relationship(deleteRule: .cascade, inverse: \BoardMotion.record)
    var motions: [BoardMotion] = []
    
    init(name: String = "", analysis: String = "", tasks: [BoardTask] = [], motions: [BoardMotion] = []) {
        self.name = name
        self.analysis = analysis
        self.tasks = tasks
        self.motions = motions
    }
}

@Model
private final class BoardTask {
    var title: String = ""
    var stateRaw: String = "wait"
    var timestamp: Date = Date()
    var record: BoardRecord?
    
    init(title: String, timestamp: Date = Date()) {
        self.title = title
        self.timestamp = timestamp
    }
}

@Model
private final class BoardMotion {
    var fileName: String = ""
    var record: BoardRecord?
    
    init(fileName: String = "") {
        self.fileName = fileName
    }
}

final class BlackboardStyleInverseTests: XCTestCase {
    
    /// Exact BlackboardUpdateTool sequence on a fresh parent.
    func testBlackboardAddPath_insertThenAssignChildRecord() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let record = BoardRecord(name: "session")
        context.insert(record)
        
        var tasksAdded = 0
        for title in ["Catalog variants + VEP", "Write SpCas9 report"] {
            let item = BoardTask(title: title)
            context.insert(item)
            item.record = record
            tasksAdded += 1
        }
        
        XCTAssertEqual(tasksAdded, 2)
        XCTAssertEqual(record.tasks.count, 2, "parent.tasks must reflect child.record assignments (Linux blackboard bug)")
        XCTAssertEqual(Set(record.tasks.map(\.title)), Set(["Catalog variants + VEP", "Write SpCas9 report"]))
    }
    
    /// Parent already persisted and reloaded via model(for:) — DatabaseActor path.
    func testBlackboardAddPath_preSavedParentLoadedByID() throws {
        let directory = try makeTemporaryDirectory(prefix: "BoardPersist")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(
            for: BoardRecord.self, BoardTask.self, BoardMotion.self,
            configurations: config
        )
        
        let recordID: PersistentIdentifier
        do {
            let context = ModelContext(container)
            let record = BoardRecord(name: "session", analysis: "")
            context.insert(record)
            try context.save()
            recordID = record.persistentModelID
        }
        
        let context = ModelContext(container)
        guard let record: BoardRecord = context.model(for: recordID) else {
            return XCTFail("failed to load BoardRecord")
        }
        
        XCTAssertEqual(record.tasks.count, 0)
        
        // analysis works in container logs; tasks did not
        record.analysis = "Task division: explore, VEP, Pfam, SpCas9"
        
        let item = BoardTask(title: "analyze ATRX locus data")
        context.insert(item)
        item.record = record
        
        XCTAssertEqual(
            record.tasks.count, 1,
            "after model(for:) load, child.record=parent must append to parent.tasks"
        )
        XCTAssertEqual(record.tasks.first?.title, "analyze ATRX locus data")
        XCTAssertEqual(record.analysis, "Task division: explore, VEP, Pfam, SpCas9")
        
        try context.save()
        
        let readContext = ModelContext(container)
        let reloaded: BoardRecord? = readContext.model(for: recordID)
        XCTAssertEqual(reloaded?.tasks.count, 1)
        XCTAssertEqual(reloaded?.tasks.first?.title, "analyze ATRX locus data")
        XCTAssertEqual(reloaded?.analysis.isEmpty, false)
    }
    
    /// Same turn: analysis + add (matches Architect's last successful analysis-only update).
    func testBlackboardAddPath_analysisAndAddSameTurn() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let record = BoardRecord()
        context.insert(record)
        try context.save()
        
        record.analysis = "division notes"
        let item = BoardTask(title: "Explore data files and reconstruct WT transcript")
        context.insert(item)
        item.record = record
        
        XCTAssertEqual(record.analysis, "division notes")
        XCTAssertEqual(record.tasks.count, 1, "analysis update must not prevent tasks append")
    }
    
    /// Counter can lie if we only increment after assign without checking parent.tasks.
    func testBlackboardAddPath_tasksAddedCounterVsActual() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let record = BoardRecord()
        context.insert(record)
        
        var tasksAdded = 0
        let item = BoardTask(title: "Example: explore data directory")
        context.insert(item)
        item.record = record
        tasksAdded += 1
        
        // This is the container symptom: OK + tasksAdded>0 but snapshot empty
        XCTAssertEqual(tasksAdded, 1)
        XCTAssertFalse(record.tasks.isEmpty, "snapshot source record.tasks was empty in container despite OK")
    }
    
    /// Claiming looks up by title on record.tasks.
    func testBlackboardClaimLookupFindsAddedTask() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let record = BoardRecord()
        context.insert(record)
        
        let title = "Explore data files and reconstruct WT transcript"
        let item = BoardTask(title: title)
        context.insert(item)
        item.record = record
        
        let found = record.tasks
            .sorted(by: { $0.timestamp < $1.timestamp })
            .first(where: { $0.title == title })
        XCTAssertNotNil(found, "claim_task failed in container with Task does not exist")
    }
    
    /// Unrelated sibling relationship (motions) must not break tasks inverse.
    func testBlackboardAddPath_withSiblingRelationships() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let record = BoardRecord()
        context.insert(record)
        let motion = BoardMotion(fileName: "note.md")
        context.insert(motion)
        motion.record = record
        
        let task = BoardTask(title: "t1")
        context.insert(task)
        task.record = record
        
        XCTAssertEqual(record.motions.count, 1)
        XCTAssertEqual(record.tasks.count, 1)
    }

    private func makeContext() throws -> (ModelContext, () -> Void) {
        let directory = try makeTemporaryDirectory(prefix: "BoardStyle")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(
            for: BoardRecord.self, BoardTask.self, BoardMotion.self,
            configurations: config
        )
        let context = ModelContext(container)
        return (context, { try? FileManager.default.removeItem(at: directory) })
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
