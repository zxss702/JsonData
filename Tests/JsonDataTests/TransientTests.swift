
import Foundation
import XCTest
@testable import JsonDataCore

final class TransientTests: XCTestCase {
    func testTransientFieldsDoNotRoundTripThroughModelContext() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataTransientTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = TransientNote(title: "hello", cache: "skip", qualifiedCache: "skip-too")
        let insertContext = ModelContext(url: dbURL)
        insertContext.insert(note)
        try? insertContext.save()

        let reloadedContext = ModelContext(url: dbURL)
        let reloaded: TransientNote? = reloadedContext.model(for: note.persistentModelID)
        XCTAssertEqual(reloaded?.title, "hello")
        XCTAssertNil(reloaded?.cache)
        XCTAssertNil(reloaded?.qualifiedCache)

        let faultContext = ModelContext(url: dbURL)
        let fetched = try faultContext.fetch(FetchDescriptor<TransientNote>())
        let faulted = try XCTUnwrap(fetched.first)
        XCTAssertTrue(faulted._isFault)
        XCTAssertNil(faulted.cache)
        XCTAssertNil(faulted.qualifiedCache)

        XCTAssertEqual(faulted.title, "hello")
        XCTAssertNil(faulted.cache)
        XCTAssertNil(faulted.qualifiedCache)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class TransientNote {
    var title: String = ""
    @Transient var cache: String? = nil
    @JsonDataCore.Transient var qualifiedCache: String? = nil

    init(title: String = "", cache: String? = nil, qualifiedCache: String? = nil) {
        self.title = title
        self.cache = cache
        self.qualifiedCache = qualifiedCache
    }
}
