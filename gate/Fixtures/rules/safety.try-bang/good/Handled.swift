import Foundation

let slug = try! Regex("^[a-z0-9-]+$") // swiftgate:allow safety.try-bang — literal pattern; SlugTests compiles it
func decode(_ data: Data) throws -> [String] { try JSONDecoder().decode([String].self, from: data) }
func maybe(_ data: Data) -> [String]? { try? JSONDecoder().decode([String].self, from: data) }
let note = "try! is banned without a reason"
