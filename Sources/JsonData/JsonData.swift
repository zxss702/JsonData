import Foundation
@_exported import SwiftCrossUI

@attached(extension, conformances: JsonModel, Codable)
public macro Model() = #externalMacro(module: "JsonDataMacros", type: "ModelMacro")

public protocol JsonModel: Codable, Identifiable {
    var id: String { get set }
}
