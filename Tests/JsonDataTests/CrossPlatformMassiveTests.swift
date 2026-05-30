import Foundation
import XCTest
@testable import JsonDataCore

@Model
private final class MassiveTarget {
    var id: String
    var count: Int
    var isEnabled: Bool
    var ratio: Double
    var name: String
    
    init(id: String, count: Int, isEnabled: Bool, ratio: Double, name: String) {
        self.id = id
        self.count = count
        self.isEnabled = isEnabled
        self.ratio = ratio
        self.name = name
    }
}

final class CrossPlatformMassiveTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var testDir: URL!
    
    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDir = tempDir
        container = ModelContainer(for: [MassiveTarget.self], at: testDir.appendingPathComponent("massive.sqlite"))
        context = container.mainContext
        
        for i in 1...10 {
            context.insert(MassiveTarget(id: "\(i)", count: i, isEnabled: i % 2 == 0, ratio: Double(i) * 1.5, name: "Target_\(i)"))
        }
        try context.save()
    }
    
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: testDir)
    }
    
    func testMassive1() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 1 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive2() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 2 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive3() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 3 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive4() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 4 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive5() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 5 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive6() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 6 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive7() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 7 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive8() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 8 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive9() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 9 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive10() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 10 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive11() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.isEnabled == true }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 5)
    }
    func testMassive12() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.isEnabled == false }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 5)
    }
    func testMassive13() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.ratio > 5.0 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 7) // 4*1.5=6.0
    }
    func testMassive14() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.ratio < 5.0 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 3) // 1.5, 3.0, 4.5
    }
    func testMassive15() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name.hasPrefix("Target_1") }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 2) // 1 and 10
    }
    func testMassive16() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name.hasSuffix("0") }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive17() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count > 2 && $0.isEnabled == true }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 4) // 4,6,8,10
    }
    func testMassive18() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count < 9 && $0.isEnabled == false }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 4) // 1,3,5,7
    }
    func testMassive19() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.ratio >= 15.0 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1) // 10*1.5=15
    }
    func testMassive20() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.ratio <= 1.5 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive21() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name == "Target_5" }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1)
    }
    func testMassive22() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name != "Target_5" }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 9)
    }
    func testMassive23() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count == 5 || $0.count == 6 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 2)
    }
    func testMassive24() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { ($0.count == 1 || $0.count == 2) && $0.isEnabled == true }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 1) // 2 is enabled
    }
    func testMassive25() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count > 0 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 10)
    }
    func testMassive26() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count < 11 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 10)
    }
    func testMassive27() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count > 10 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 0)
    }
    func testMassive28() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.count < 1 }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 0)
    }
    func testMassive29() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name.contains("Target") }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 10)
    }
    func testMassive30() throws {
        let pred: JsonDataCore.Predicate<MassiveTarget> = #Predicate<MassiveTarget> { $0.name.contains("Missing") }
        XCTAssertEqual(try context.fetch(FetchDescriptor(predicate: pred)).count, 0)
    }
}
