import Foundation

/// A release version such as 0.1.0, compared number by number, so 0.10.0 follows 0.9.0.
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]

    /// Reads "1.2.3" or a tag such as "v1.2.3". Anything else, a "-beta" suffix included, is no
    /// release version.
    public init?(_ text: String) {
        let bare = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard (1...3).contains(parts.count), numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        // 1.2 is 1.2.0, so the two compare equal.
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static func < (a: Version, b: Version) -> Bool { a.numbers.lexicographicallyPrecedes(b.numbers) }
    public var description: String { numbers.map(String.init).joined(separator: ".") }
}

/// The parts of a GitHub release that an update needs, as the API writes them.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    public let tag: String
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case assets
    }

    /// The release's archive when it is newer than `current`. A release still being built has
    /// no archive yet, and one whose tag isn't a version is no update.
    public func update(after current: Version) -> (version: Version, archive: URL)? {
        guard let version = Version(tag), version > current,
              let archive = assets.first(where: { $0.name == "Planets-\(version)-macos.zip" }) else { return nil }
        return (version, archive.url)
    }
}
