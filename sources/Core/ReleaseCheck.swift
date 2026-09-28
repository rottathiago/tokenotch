import Foundation

public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let components: [UInt64]
    public let prerelease: [String]

    public init?(_ tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard value.count <= 128, !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+-".contains($0)) }) else { return nil }
        let build = value.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        if build.count == 2, !Self.identifiers(String(build[1])) { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var parsed: [UInt64] = []
        for number in numbers {
            guard Self.numeric(String(number)), number == "0" || !number.hasPrefix("0"),
                  let integer = UInt64(number) else { return nil }
            parsed.append(integer)
        }
        var identifiers: [String] = []
        if parts.count == 2 {
            let suffix = String(parts[1])
            guard Self.identifiers(suffix) else { return nil }
            identifiers = suffix.components(separatedBy: ".")
            guard identifiers.allSatisfy({ !Self.numeric($0) || $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
        }
        components = parsed
        prerelease = identifiers
    }

    private static func numeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func identifiers(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = numeric(left), rightNumeric = numeric(right)
            if leftNumeric && rightNumeric {
                return left.count == right.count ? left < right : left.count < right.count
            }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum ReleaseCheckError: String, Error, LocalizedError {
    case unavailable = "The release service is unavailable. Check your connection and try again."
    case rateLimited = "GitHub rate-limited the release check. Try again later."
    case noRelease = "No public stable release is available from the official repository."
    case invalid = "The release service returned an unsupported response."
    public var errorDescription: String? { rawValue }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let version: ReleaseVersion
    public var url: URL {
        // Tags are validated as SemVer, so cannot contain paths, queries or credentials.
        URL(string: "https://github.com/\(TokenotchProduct.repository)/releases/tag/\(tag)")!
    }

    public static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        guard data.count <= 131_072 else { throw ReleaseCheckError.invalid }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ReleaseCheckError.invalid }
        guard !response.draft, !response.prerelease,
              let version = ReleaseVersion(response.tag_name), version.prerelease.isEmpty else {
            throw ReleaseCheckError.invalid
        }
        return Self(tag: response.tag_name, version: version)
    }
}

private final class ReleaseRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Repository redirects require updating the owned release configuration deliberately.
        completionHandler(nil)
    }
}

public enum ReleaseCheck {
    public static func latest() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(TokenotchProduct.repository)/releases/latest")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tokenotch/\(TokenotchProduct.version)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseCheckError.invalid }
        switch http.statusCode {
        case 200: break
        case 404: throw ReleaseCheckError.noRelease
        case 403, 429: throw ReleaseCheckError.rateLimited
        default: throw ReleaseCheckError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 131_072 else { throw ReleaseCheckError.invalid }
            data.append(byte)
        }
        return try ReleaseInfo.parse(data)
    }
}
