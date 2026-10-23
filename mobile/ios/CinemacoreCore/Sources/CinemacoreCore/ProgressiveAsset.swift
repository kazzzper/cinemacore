import Foundation

/// The bytes of an in-progress download that the player may read while the
/// engine keeps appending to `.part`.
public struct ProgressiveAsset: Sendable, Hashable {
    public let id: String
    /// The contiguous committed prefix. It grows while the item downloads.
    public let partialURL: URL
    /// The finished file. When it exists it wins over `partialURL`.
    public let completeURL: URL
    public let totalBytes: Int64
    public let contentType: String
    /// A `moov` atom prefetched out of order. `moovURL` is a small file holding
    /// exactly the bytes in this range, so the server can answer a request for
    /// metadata even when `.part` has not reached the end yet.
    public let moovRange: ByteRange?
    public let moovURL: URL?
    /// Committed bytes needed before the player may start. The caller derives
    /// this from the container's metadata; zero means "as soon as any bytes".
    public let readyThreshold: Int64

    public init(
        id: String,
        partialURL: URL,
        completeURL: URL,
        totalBytes: Int64,
        contentType: String = "video/mp4",
        moovRange: ByteRange? = nil,
        moovURL: URL? = nil,
        readyThreshold: Int64 = 0
    ) {
        self.id = id
        self.partialURL = partialURL
        self.completeURL = completeURL
        self.totalBytes = totalBytes
        self.contentType = contentType
        self.moovRange = moovRange
        self.moovURL = moovURL
        self.readyThreshold = readyThreshold
    }
}

/// Immutable description of one HTTP response. The NIO handler writes the body;
/// the store owns range decisions so they are testable without sockets.
public struct ProgressiveAssetResponse: Sendable {
    public enum Body: Sendable {
        case bytes(Data)
        case file(URL, ByteRange)
        case empty
    }

    public let status: Int
    public let headers: [String: String]
    public let body: Body

    public init(status: Int, headers: [String: String] = [:], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The registry the loopback server reads.
public actor ProgressiveAssetStore {
    private var assets: [String: ProgressiveAsset] = [:]

    public init() {}

    public func register(_ asset: ProgressiveAsset) {
        assets[asset.id] = asset
    }

    public func register(_ values: [ProgressiveAsset]) {
        for asset in values { assets[asset.id] = asset }
    }

    public func remove(_ id: String) {
        assets[id] = nil
    }

    public func asset(_ id: String) -> ProgressiveAsset? {
        assets[id]
    }

    public func all() -> [ProgressiveAsset] {
        Array(assets.values)
    }

    /// The committed prefix, or the whole file once it has been renamed.
    public func availableBytes(for asset: ProgressiveAsset) -> Int64 {
        let manager = FileManager.default
        if manager.fileExists(atPath: asset.completeURL.path) {
            return max(asset.totalBytes, fileSize(asset.completeURL))
        }
        return min(max(fileSize(asset.partialURL), 0), max(asset.totalBytes, 0))
    }

    public func isReady(_ id: String) -> Bool {
        guard let asset = assets[id] else { return false }
        // Once the download is renamed there is no gap left to wait for; a
        // prefetched moov that was never written must not stall a complete file.
        if FileManager.default.fileExists(atPath: asset.completeURL.path) { return true }
        let available = availableBytes(for: asset)
        guard asset.readyThreshold > 0 else { return available > 0 }
        guard available >= asset.readyThreshold else { return false }
        if asset.moovRange != nil, let moovURL = asset.moovURL {
            return FileManager.default.fileExists(atPath: moovURL.path)
        }
        return true
    }

    /// Resolves one request into status, headers and a body description.
    ///
    /// The decision lives here rather than in the NIO handler so AVPlayer's
    /// range patterns are testable without a socket, and so the server never
    /// needs to know how many bytes have arrived.
    public func response(for id: String, method: String, rangeHeader: String?) -> ProgressiveAssetResponse {
        guard let asset = assets[id] else {
            return Self.emptyResponse(status: 404)
        }

        let manager = FileManager.default
        let complete = manager.fileExists(atPath: asset.completeURL.path)
        let available = availableBytes(for: asset)
        var total = max(asset.totalBytes, 0)
        // A finished file is the strongest size signal when the caller could
        // not learn the length before the rename.
        if total == 0, complete { total = available }

        if method == "HEAD" {
            return ProgressiveAssetResponse(
                status: 200,
                headers: Self.headers(asset: asset, contentLength: total),
                body: .empty
            )
        }
        guard method == "GET" else {
            return Self.emptyResponse(status: 405, extra: ["Allow": "GET, HEAD"])
        }

        if let rangeHeader, !rangeHeader.isEmpty {
            guard let requested = Self.parseRange(rangeHeader, total: total) else {
                return Self.emptyResponse(
                    status: 416,
                    extra: [
                        "Content-Type": asset.contentType,
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes */\(total)",
                    ]
                )
            }
            return Self.rangedResponse(
                asset: asset,
                requested: requested,
                available: available,
                total: total,
                complete: complete
            )
        }

        if complete || (total > 0 && available >= total) {
            guard total > 0 else {
                return ProgressiveAssetResponse(
                    status: 200,
                    headers: Self.headers(asset: asset, contentLength: 0),
                    body: .empty
                )
            }
            return ProgressiveAssetResponse(
                status: 200,
                headers: Self.headers(asset: asset, contentLength: total),
                body: .file(complete ? asset.completeURL : asset.partialURL, ByteRange(start: 0, end: total - 1))
            )
        }

        // The player gets the contiguous prefix plus a Content-Range that
        // names the full length, so it can ask for the remainder by range.
        guard available > 0 else {
            return Self.retryResponse(asset: asset)
        }
        let end = min(available, total > 0 ? total : available) - 1
        return ProgressiveAssetResponse(
            status: 206,
            headers: Self.headers(
                asset: asset,
                contentLength: end + 1,
                contentRange: "bytes 0-\(end)/\(total)"
            ),
            body: .file(asset.partialURL, ByteRange(start: 0, end: end))
        )
    }

    private static func rangedResponse(
        asset: ProgressiveAsset,
        requested: ByteRange,
        available: Int64,
        total: Int64,
        complete: Bool
    ) -> ProgressiveAssetResponse {
        let sourceURL = complete ? asset.completeURL : asset.partialURL

        // A range that begins inside the committed prefix is served from the
        // file, shortened to what has actually landed. Shortening is safe: the
        // player compares Content-Range with its request and asks again.
        if start(requested, isWithin: available) {
            let end = min(requested.end, available - 1)
            let served = ByteRange(start: requested.start, end: end)
            return ProgressiveAssetResponse(
                status: 206,
                headers: headers(
                    asset: asset,
                    contentLength: served.length,
                    contentRange: "bytes \(served.start)-\(served.end)/\(total)"
                ),
                body: .file(sourceURL, served)
            )
        }

        // AVPlayer asks for the `moov` atom long before the contiguous prefix
        // reaches it. That atom was prefetched into its own small file, so a
        // request fully answered from it never waits for the download.
        if let moovRange = asset.moovRange,
           let moovURL = asset.moovURL,
           requested.start >= moovRange.start,
           requested.start <= moovRange.end {
            let end = min(requested.end, moovRange.end)
            if let data = Self.moovBytes(
                at: moovURL,
                moovRange: moovRange,
                requested: ByteRange(start: requested.start, end: end)
            ) {
                return ProgressiveAssetResponse(
                    status: 206,
                    headers: headers(
                        asset: asset,
                        contentLength: Int64(data.count),
                        contentRange: "bytes \(requested.start)-\(end)/\(total)"
                    ),
                    body: .bytes(data)
                )
            }
        }

        // The requested start sits in the hole between the committed prefix and
        // the prefetched moov (or past both). 503 is retryable by design; the
        // prefix grows while the player waits.
        return retryResponse(asset: asset)
    }

    /// Reads only the slice of the small prefetched `moov` file the request
    /// needs. The media file itself is never buffered.
    private static func moovBytes(
        at url: URL,
        moovRange: ByteRange,
        requested: ByteRange
    ) -> Data? {
        guard let contents = try? Data(contentsOf: url),
              let offset = Int(exactly: requested.start - moovRange.start),
              let length = Int(exactly: requested.length),
              offset >= 0,
              length > 0,
              offset + length <= contents.count
        else { return nil }
        let start = contents.startIndex + offset
        return Data(contents[start..<(start + length)])
    }

    private static func start(_ range: ByteRange, isWithin available: Int64) -> Bool {
        available > 0 && range.start < available
    }

    private static func headers(
        asset: ProgressiveAsset,
        contentLength: Int64,
        contentRange: String? = nil
    ) -> [String: String] {
        var headers = [
            "Content-Type": asset.contentType,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(max(0, contentLength))",
            "Cache-Control": "no-store",
        ]
        if let contentRange { headers["Content-Range"] = contentRange }
        return headers
    }

    private static func emptyResponse(status: Int, extra: [String: String] = [:]) -> ProgressiveAssetResponse {
        var headers = ["Content-Length": "0", "Cache-Control": "no-store"]
        headers.merge(extra) { _, new in new }
        return ProgressiveAssetResponse(status: status, headers: headers)
    }

    private static func retryResponse(asset: ProgressiveAsset) -> ProgressiveAssetResponse {
        ProgressiveAssetResponse(
            status: 503,
            headers: [
                "Content-Type": asset.contentType,
                "Accept-Ranges": "bytes",
                "Content-Length": "0",
                "Cache-Control": "no-store",
                "Retry-After": "1",
            ]
        )
    }

    /// Accepts exactly one `bytes=` range. Multiple ranges and malformed
    /// headers are rejected rather than guessed at: AVPlayer only sends one,
    /// and a wrong guess corrupts playback.
    private static func parseRange(_ header: String, total: Int64) -> ByteRange? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst("bytes=".count)
        guard !spec.contains(","), total > 0 else { return nil }
        guard let dash = spec.firstIndex(of: "-") else { return nil }

        let startText = spec[..<dash]
        let endText = spec[spec.index(after: dash)...]

        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            return ByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(startText), start >= 0, start < total else { return nil }
        guard !endText.isEmpty else {
            return ByteRange(start: start, end: total - 1)
        }
        guard let end = Int64(endText), end >= start else { return nil }
        return ByteRange(start: start, end: min(end, total - 1))
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              values.isDirectory != true
        else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}
