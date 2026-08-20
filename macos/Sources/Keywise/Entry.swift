import Foundation

struct Entry: Identifiable, Sendable {
    let id: Int
    let hostname: String
    let username: String
    let timePasswordChanged: Int64
    let isAccountCredential: Bool
    let isExtension: Bool
}

struct Profile: Identifiable, Sendable {
    let id: Int
    let path: String
    var name: String {
        (path as NSString).lastPathComponent
    }
}
