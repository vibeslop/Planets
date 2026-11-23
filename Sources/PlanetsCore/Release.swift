import Foundation

public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]

    public init?(_ text: String) {
        let bare = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard (1...3).contains(parts.count), numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static func < (a: Version, b: Version) -> Bool { a.numbers.lexicographicallyPrecedes(b.numbers) }
    public var description: String { numbers.map(String.init).joined(separator: ".") }
}

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

    public func update(after current: Version) -> (version: Version, archive: URL)? {
        guard let version = Version(tag), version > current,
              let archive = assets.first(where: { $0.name == "Planets-\(version)-macos.zip" }) else { return nil }
        return (version, archive.url)
    }
}
