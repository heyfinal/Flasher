import Foundation

struct LinuxPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let filename: String

    var displayName: String {
        name
    }
}
