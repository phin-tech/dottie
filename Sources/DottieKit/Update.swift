import Foundation

/// A release version like `0.1.10` or `v1.2`, compared number by number (so 0.1.10 is after 0.1.9).
/// A pre-release suffix (`-beta.1`) is ignored.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        self.numbers = numbers
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }
}

/// What `GET /repos/phin-tech/dottie/releases/latest` says, as far as an update check needs. That endpoint
/// leaves out drafts and pre-releases.
public struct LatestRelease: Decodable, Sendable {
    public var tagName: String
    public var pageURL: URL

    private enum CodingKeys: String, CodingKey { case tagName = "tag_name", pageURL = "html_url" }

    public static let endpoint = URL(string: "https://api.github.com/repos/phin-tech/dottie/releases/latest")!

    public var version: ReleaseVersion? { ReleaseVersion(tagName) }

    /// The release's version when it is newer than `current`, else nil.
    public func newer(than current: String) -> ReleaseVersion? {
        guard let latest = version, let mine = ReleaseVersion(current), mine < latest else { return nil }
        return latest
    }
}
