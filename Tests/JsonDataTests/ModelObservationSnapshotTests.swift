import Foundation
import XCTest
@testable import JsonDataCore

final class ModelObservationSnapshotTests: XCTestCase {
    @MainActor
    func testObservationKeepsPendingModelsAndTheirIdentitiesOnTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservationSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: ObservationSnapshotRow.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("db.sqlite")))
        let context = container.mainContext
        context.autosaveEnabled = false
        let edited = ObservationSnapshotRow(name: "Saved")
        let removed = ObservationSnapshotRow(name: "Removed")
        context.insert(edited)
        context.insert(removed)
        try context.save()

        edited.name = "Local edit"
        let inserted = ObservationSnapshotRow(name: "Pending insert")
        context.insert(inserted)
        context.delete(removed)

        let received = XCTestExpectation(description: "pending changes merged into the observed database rows")
        var delivered = false
        let observation = context.startObservation(
            FetchDescriptor<ObservationSnapshotRow>(),
            onError: { error in
                XCTFail("Observation failed: \(error)")
                received.fulfill()
            },
            onChange: { rows in
                guard !delivered else { return }
                delivered = true
                XCTAssertEqual(rows.count, 2)
                XCTAssertTrue(rows.contains { $0 === edited })
                XCTAssertTrue(rows.contains { $0 === inserted })
                XCTAssertFalse(rows.contains { $0 === removed })
                XCTAssertEqual(edited.name, "Local edit", "an older database snapshot must not overwrite a pending edit")
                received.fulfill()
            })
        defer { observation.cancel() }
        let result = await XCTWaiter.fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(delivered)
    }
}

@Model
private final class ObservationSnapshotRow {
    var name: String = ""

    init(name: String = "") {
        self.name = name
    }
}
