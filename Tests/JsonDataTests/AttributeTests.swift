import XCTest
@testable import JsonData

@Model
final class UniqueUser {
    @Attribute(.unique) var name: String
    var age: Int
    
    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}

final class AttributeTests: XCTestCase {
    func testUniqueAttributeGeneratesUniqueConstraint() throws {
        #if !canImport(SwiftData)
        let columns = UniqueUser._jsonDataColumns
        guard let nameColumn = columns.first(where: { $0.propertyName == "name" }) else {
            XCTFail("name column missing")
            return
        }
        
        XCTAssertTrue(nameColumn.options.contains(.unique))
        #endif
    }
}
