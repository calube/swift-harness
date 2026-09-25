import Foundation

let pattern = try! Regex("^[a-z]+$")
func decode(_ data: Data) -> [String] { try! JSONDecoder().decode([String].self, from: data) }
