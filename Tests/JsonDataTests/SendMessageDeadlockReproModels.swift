import Foundation
@testable import JsonDataCore

@Model
final class ReproEvent {
    var content: String = ""
    var record: ReproRecord?
    init(content: String) { self.content = content }
}
