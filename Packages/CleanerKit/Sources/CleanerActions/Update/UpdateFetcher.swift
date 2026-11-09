import Foundation

/// Fetches one file. The real one uses URLSession; tests serve fixture files.
public protocol UpdateFetcher: Sendable {
    /// Writes the body of `url` to `destination` (a path that does not exist yet).
    ///
    /// - Parameters:
    ///   - maxBytes: Stop with an error when the body is longer than this.
    ///   - progress: Called with bytes received so far and the expected total, if known.
    func fetch(
        _ url: URL, to destination: URL, maxBytes: Int64,
        progress: @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws
}

/// Downloads with an ephemeral URLSession: no cookies, no cache, and redirects only to the hosts
/// in ``UpdateURLPolicy``. The only network code that downloads an update.
public struct URLSessionUpdateFetcher: UpdateFetcher {
    /// Creates the fetcher.
    public init() {}

    /// Writes the body of `url` to `destination`. Throws unless the answer is HTTP 200.
    @concurrent
    public func fetch(
        _ url: URL, to destination: URL, maxBytes: Int64,
        progress: @Sendable (Int64, Int64?) -> Void
    ) async throws {
        guard UpdateURLPolicy.isAllowedAssetURL(url) else {
            throw UpdateError.disallowedURL(url.absoluteString)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("TruongCleaner", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("unexpected answer from the server")
        }
        let expected: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let expected, expected > maxBytes { throw UpdateError.downloadFailed("the file is too large") }

        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw UpdateError.downloadFailed("cannot write to the temporary folder")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                received += Int64(chunk.count)
                guard received <= maxBytes else { throw UpdateError.downloadFailed("the file is too large") }
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                progress(received, expected)
            }
        }
        if !chunk.isEmpty {
            received += Int64(chunk.count)
            guard received <= maxBytes else { throw UpdateError.downloadFailed("the file is too large") }
            try handle.write(contentsOf: chunk)
        }
        progress(received, expected)
        if let expected, received != expected { throw UpdateError.downloadFailed("the file is incomplete") }
    }
}

/// Refuses any redirect that leaves the allow-list.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let target = request.url, UpdateURLPolicy.isAllowedRedirect(target) else { return nil }
        return request
    }
}
