#if !canImport(SwiftData)
import Foundation
import XCTest
import JsonData

final class TransientTests: XCTestCase {
    func testTransientFieldsAreExcludedFromEncoding() throws {
        let note = TransientNote(title: "hello", cache: "skip", qualifiedCache: "skip-too")

        let data = try JSONEncoder().encode(note)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["title"] as? String, "hello")
        XCTAssertNil(jsonObject["cache"])
        XCTAssertNil(jsonObject["qualifiedCache"])
        XCTAssertNotNil(jsonObject["persistentModelID"])
    }

    func testTransientFieldsAreIgnoredWhenDecoding() throws {
        let json = """
        {
          "persistentModelID": "fixture-id",
          "title": "hello",
          "cache": "skip",
          "qualifiedCache": "skip-too"
        }
        """

        let note = try JSONDecoder().decode(TransientNote.self, from: Data(json.utf8))

        XCTAssertEqual(note.title, "hello")
        XCTAssertNil(note.cache)
        XCTAssertNil(note.qualifiedCache)
    }

    func testTransientFieldsDoNotRoundTripThroughModelContext() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataTransientTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = TransientNote(title: "hello", cache: "skip", qualifiedCache: "skip-too")
        let insertContext = ModelContext(url: directory)
        insertContext.insert(note)

        let reloadedContext = ModelContext(url: directory)
        let reloaded: TransientNote? = reloadedContext.model(for: note.persistentModelID)
        XCTAssertEqual(reloaded?.title, "hello")
        XCTAssertNil(reloaded?.cache)
        XCTAssertNil(reloaded?.qualifiedCache)

        let faultContext = ModelContext(url: directory)
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
    @JsonData.Transient var qualifiedCache: String? = nil

    init(title: String = "", cache: String? = nil, qualifiedCache: String? = nil) {
        self.title = title
        self.cache = cache
        self.qualifiedCache = qualifiedCache
    }
}
#endif
