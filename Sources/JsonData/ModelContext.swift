import Foundation

public final class ModelContext: Sendable {
    public static let shared = ModelContext()
    let baseURL: URL
    
    public static let contextDidChange = Notification.Name("JsonData.ModelContextDidChange")
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseURL = docs.appendingPathComponent("JsonDataStore")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
    
    public func insert<T: JsonModel>(_ model: T) {
        let typeName = String(describing: T.self)
        let dir = baseURL.appendingPathComponent(typeName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Write the individual JSON
        let fileURL = dir.appendingPathComponent("\(model.id).json")
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL)
            // Fire the notification so that any Views holding @Query reload their data
            NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
        }
    }
    
    public func delete<T: JsonModel>(_ model: T) {
        let typeName = String(describing: T.self)
        let fileURL = baseURL.appendingPathComponent(typeName).appendingPathComponent("\(model.id).json")
        try? FileManager.default.removeItem(at: fileURL)
        NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
    }
    
    public func fetch<T: JsonModel>() -> [T] {
        let typeName = String(describing: T.self)
        let dir = baseURL.appendingPathComponent(typeName)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        
        var results: [T] = []
        for file in files where file.hasSuffix(".json") {
            let fileURL = dir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: fileURL),
               let model = try? JSONDecoder().decode(T.self, from: data) {
                results.append(model)
            }
        }
        
        // Let's sort results by time if possible? The user has createdAt wait, we don't know the fields.
        // SwiftData @Query usually allows sorting.
        // For simple arrays we just return them.
        return results
    }
}
