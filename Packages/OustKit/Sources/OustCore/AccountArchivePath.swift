import Foundation

package enum AccountArchivePath {
    package static let root = URL(fileURLWithPath: "/Users/Deleted Users", isDirectory: true)

    package static func isDiskImage(_ name: String) -> Bool {
        name.range(of: ".dmg", options: [.caseInsensitive, .anchored, .backwards]) != nil
    }
}
