import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformCascadingDeletionsTests: XCTestCase {
    func testCascadingDeletions() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataCascadingTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Department.self, Employee.self, TaskItem.self, configurations: config)
        let context = ModelContext(container)
        
        let dept = Department(name: "Engineering")
        let emp1 = Employee(name: "Alice")
        let emp2 = Employee(name: "Bob")
        
        let task1 = TaskItem(title: "Task 1")
        let task2 = TaskItem(title: "Task 2")
        let task3 = TaskItem(title: "Task 3")
        
        emp1.tasks = [task1, task2]
        emp2.tasks = [task3]
        
        dept.employees = [emp1, emp2]
        
        context.insert(dept)
        try context.save()
        
        // Ensure everything is saved
        let fetchContext = ModelContext(container)
        let allDepts = try fetchContext.fetch(FetchDescriptor<Department>())
        let allEmps = try fetchContext.fetch(FetchDescriptor<Employee>())
        let allTasks = try fetchContext.fetch(FetchDescriptor<TaskItem>())
        
        XCTAssertEqual(allDepts.count, 1)
        XCTAssertEqual(allEmps.count, 2)
        XCTAssertEqual(allTasks.count, 3)
        
        // Delete Department - should cascade to Employees, and then to Tasks
        if let deptToDelete = allDepts.first {
            fetchContext.delete(deptToDelete)
            try fetchContext.save()
        }
        
        let verifyContext = ModelContext(container)
        let finalDepts = try verifyContext.fetch(FetchDescriptor<Department>())
        let finalEmps = try verifyContext.fetch(FetchDescriptor<Employee>())
        let finalTasks = try verifyContext.fetch(FetchDescriptor<TaskItem>())
        
        XCTAssertEqual(finalDepts.count, 0)
        XCTAssertEqual(finalEmps.count, 0)
        XCTAssertEqual(finalTasks.count, 0)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class Department {
    var name: String
    
    @Relationship(deleteRule: .cascade)
    var employees: [Employee] = []

    init(name: String) {
        self.name = name
    }
}

@Model
private final class Employee {
    var name: String
    
    @Relationship(deleteRule: .cascade)
    var tasks: [TaskItem] = []

    init(name: String) {
        self.name = name
    }
}

@Model
private final class TaskItem {
    var title: String

    init(title: String) {
        self.title = title
    }
}
