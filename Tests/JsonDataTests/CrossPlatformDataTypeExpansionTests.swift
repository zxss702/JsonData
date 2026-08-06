import Foundation
import XCTest
@testable import JsonDataCore

enum Role: String, Codable {
    case admin, user, guest
}

enum Status: Int, Codable {
    case active = 1, inactive = 0, suspended = -1
}

struct MetadataPayload: Codable, Equatable {
    var tags: [String]
    var config: [String: Double]
}

@Model
private final class DataTypesTarget {
    var id: UUID
    var date: Date
    var binary: Data
    var floatVal: Float
    var role: Role
    var status: Status
    var metadata: MetadataPayload
    
    init(id: UUID, date: Date, binary: Data, floatVal: Float, role: Role, status: Status, metadata: MetadataPayload) {
        self.id = id
        self.date = date
        self.binary = binary
        self.floatVal = floatVal
        self.role = role
        self.status = status
        self.metadata = metadata
    }
}

final class CrossPlatformDataTypeExpansionTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var testDir: URL!
    
    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDir = tempDir
        container = try ModelContainer(for: [DataTypesTarget.self], at: testDir.appendingPathComponent("datatypes.sqlite"))
        context = container.mainContext
    }
    
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: testDir)
    }
    
    func testUUIDDataType() throws {
        let u1 = UUID()
        let t1 = DataTypesTarget(id: u1, date: Date(), binary: Data(), floatVal: 1.0, role: .user, status: .active, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].id, u1)
    }
    
    func testDateDataType() throws {
        let d = Date(timeIntervalSince1970: 10000000)
        let t1 = DataTypesTarget(id: UUID(), date: d, binary: Data(), floatVal: 1.0, role: .user, status: .active, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        // GRDB might map Date to Float/Double or String. Equatable should work if precision is preserved.
        XCTAssertEqual(res[0].date.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.001)
    }
    
    func testDataDataType() throws {
        let data = "Hello World".data(using: .utf8)!
        let t1 = DataTypesTarget(id: UUID(), date: Date(), binary: data, floatVal: 1.0, role: .user, status: .active, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].binary, data)
    }
    
    func testEnumStringDataType() throws {
        let t1 = DataTypesTarget(id: UUID(), date: Date(), binary: Data(), floatVal: 1.0, role: .admin, status: .active, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].role, .admin)
    }
    
    func testEnumIntDataType() throws {
        let t1 = DataTypesTarget(id: UUID(), date: Date(), binary: Data(), floatVal: 1.0, role: .user, status: .suspended, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].status, .suspended)
    }
    
    func testCodableStructDataType() throws {
        let payload = MetadataPayload(tags: ["x", "y"], config: ["zoom": 1.5, "alpha": 0.9])
        let t1 = DataTypesTarget(id: UUID(), date: Date(), binary: Data(), floatVal: 1.0, role: .user, status: .active, metadata: payload)
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].metadata, payload)
    }
    
    func testFloatPrecision() throws {
        let t1 = DataTypesTarget(id: UUID(), date: Date(), binary: Data(), floatVal: 3.14159, role: .user, status: .active, metadata: MetadataPayload(tags: [], config: [:]))
        context.insert(t1)
        try context.save()
        
        let rc = ModelContext(container)
        let res = try rc.fetch(FetchDescriptor<DataTypesTarget>())
        XCTAssertEqual(res[0].floatVal, 3.14159, accuracy: 0.0001)
    }
}
