import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the player needs to know about an MP4 before the download is complete.
public struct MP4ProgressiveMetadata: Sendable, Hashable {
    public let moovRange: ByteRange?
    public let moovURL: URL?
    public let readyThreshold: Int64

    public init(moovRange: ByteRange? = nil, moovURL: URL? = nil, readyThreshold: Int64 = 0) {
        self.moovRange = moovRange
        self.moovURL = moovURL
        self.readyThreshold = readyThreshold
    }
}

/// Locates and prefetches the `moov` atom so AVPlayer can build an asset before
/// the engine has reached the end of the file.
public enum MP4Progressive {
    /// The default threshold is deliberately byte-based: the engine does not
    /// know a title's bitrate until after playback starts, so eight megabytes
    /// is the conservative floor that covers a few seconds of any supported
    /// rendition while keeping start-up fast.
    public static let defaultReadyBytes: Int64 = 8 << 20

    /// Both probes are bounded by this so a metadata lookup can never turn into
    /// a whole-file download, no matter how the boxes are laid out.
    static let probeBytes: Int64 = 1 << 20

    /// Bounds the work an adversarial `mdat` full of `moov`-looking bytes can
    /// cause. A real file has exactly one top-level `moov`.
    private static let maxSuffixCandidates = 64

    private static let moovType: UInt32 = 0x6D6F6F76 // "moov"

    // MARK: - Box parsing

    /// Finds the top-level `moov` box inside the two bounded probes.
    ///
    /// `prefix` describes bytes starting at offset zero and `suffix` describes
    /// the final `suffix.count` bytes of the file. The parser only accepts a
    /// box whose header lies inside one of the probes and whose declared size
    /// fits the advertised total, so a truncated or absurd size is reported as
    /// "not found" rather than clamped into a range that would corrupt the
    /// asset. The suffix is scanned only for a `moov` that can be walked to EOF
    /// through further valid top-level boxes; that walk is what keeps a `moov`
    /// spelled inside an `mdat` payload from being mistaken for the index.
    public static func moovRange(prefix: Data, suffix: Data, totalBytes: Int64) -> ByteRange? {
        guard totalBytes > 0 else { return nil }
        let prefixBytes = [UInt8](prefix)
        let suffixBytes = [UInt8](suffix)
        let prefixEnd = Int64(prefixBytes.count)
        let suffixStart = totalBytes - Int64(suffixBytes.count)

        // When the probes meet or overlap they describe the whole file. Parsing
        // the stitched view is the only way to read a header split exactly on
        // the probe boundary, and it is bounded by twice `probeBytes`.
        if !suffixBytes.isEmpty, suffixStart >= 0, suffixStart <= prefixEnd {
            let overlap = prefixEnd - suffixStart
            if overlap <= Int64(suffixBytes.count) {
                var joined = prefixBytes
                joined.append(contentsOf: suffixBytes[Int(overlap)...])
                if Int64(joined.count) >= totalBytes,
                   let moov = scanTopLevel(joined, origin: 0, totalBytes: totalBytes).moov {
                    return moov
                }
            }
        }

        let head = scanTopLevel(prefixBytes, origin: 0, totalBytes: totalBytes)
        if let moov = head.moov { return moov }

        guard !suffixBytes.isEmpty, suffixStart >= 0 else { return nil }

        // A boundary proved by the prefix lets the suffix parse from a known
        // box start. This avoids ever looking inside an `mdat` body.
        if let boundary = head.nextBoundary, boundary >= suffixStart, boundary <= totalBytes,
           let moov = scanTopLevel(
               suffixBytes,
               origin: suffixStart,
               totalBytes: totalBytes,
               startOffset: boundary
           ).moov {
            return moov
        }

        return scanSuffixCandidates(suffixBytes, suffixStart: suffixStart, totalBytes: totalBytes)
    }

    private struct Scan {
        var moov: ByteRange?
        /// Where the next top-level box begins, when the probe proved it.
        var nextBoundary: Int64?
    }

    private struct BoxHeader {
        var type: UInt32
        var size: Int64
        var extendsToEOF: Bool
    }

    /// Walks complete top-level box headers from `origin` to `totalBytes`.
    private static func scanTopLevel(
        _ bytes: [UInt8],
        origin: Int64,
        totalBytes: Int64,
        startOffset: Int64? = nil
    ) -> Scan {
        let endOfData = origin + Int64(bytes.count)
        var cursor = startOffset ?? origin
        guard cursor >= origin, cursor <= totalBytes else {
            return Scan(moov: nil, nextBoundary: nil)
        }

        while cursor < totalBytes {
            let local = cursor - origin
            guard local >= 0, local + 8 <= Int64(bytes.count) else {
                // The probe ends inside a header, so the next boundary is not
                // provable from this buffer alone.
                return Scan(moov: nil, nextBoundary: nil)
            }
            guard let header = boxHeader(
                bytes,
                at: Int(local),
                remaining: totalBytes - cursor
            ) else {
                return Scan(moov: nil, nextBoundary: nil)
            }
            let boxEnd = cursor + header.size
            if header.type == moovType {
                return Scan(
                    moov: ByteRange(start: cursor, end: boxEnd - 1),
                    nextBoundary: boxEnd
                )
            }
            if boxEnd > endOfData {
                // The box is valid but its body is outside this probe. Its end
                // is still a trustworthy boundary for the other probe.
                return Scan(moov: nil, nextBoundary: boxEnd)
            }
            cursor = boxEnd
        }
        return Scan(moov: nil, nextBoundary: cursor)
    }

    /// Reads one header. `remaining` is the number of bytes left in the file
    /// from the box start, not in the probe, so a size is validated against the
    /// real file length.
    private static func boxHeader(
        _ bytes: [UInt8],
        at index: Int,
        remaining: Int64
    ) -> BoxHeader? {
        guard index >= 0, index + 8 <= bytes.count, remaining >= 8 else { return nil }
        let size32 = bigEndian32(bytes, at: index)
        let type = bigEndian32(bytes, at: index + 4)
        let size: Int64
        var extendsToEOF = false

        if size32 == 1 {
            guard index + 16 <= bytes.count else { return nil }
            let size64 = bigEndian64(bytes, at: index + 8)
            // The 64-bit form must fit both Int64 and the rest of the file.
            guard size64 >= 16, size64 <= UInt64(Int64.max) else { return nil }
            size = Int64(size64)
        } else if size32 == 0 {
            // A zero size means "to EOF"; the file total is the only authority.
            size = remaining
            extendsToEOF = true
        } else {
            size = Int64(size32)
        }

        guard size >= 8, size <= remaining else { return nil }
        return BoxHeader(type: type, size: size, extendsToEOF: extendsToEOF)
    }

    private static func scanSuffixCandidates(
        _ bytes: [UInt8],
        suffixStart: Int64,
        totalBytes: Int64
    ) -> ByteRange? {
        guard bytes.count >= 8 else { return nil }
        var offset = 0
        var considered = 0
        while offset + 8 <= bytes.count {
            if bigEndian32(bytes, at: offset + 4) == moovType {
                considered += 1
                if considered > maxSuffixCandidates { return nil }
                let start = suffixStart + Int64(offset)
                if let range = validatedMoov(
                    bytes,
                    at: offset,
                    start: start,
                    totalBytes: totalBytes,
                    suffixStart: suffixStart
                ) {
                    return range
                }
            }
            offset += 1
        }
        return nil
    }

    /// A suffix candidate is accepted only when the boxes after it also parse
    /// cleanly and land exactly on EOF. Bytes that merely spell `moov` inside an
    /// `mdat` body almost never satisfy that walk.
    private static func validatedMoov(
        _ bytes: [UInt8],
        at index: Int,
        start: Int64,
        totalBytes: Int64,
        suffixStart: Int64
    ) -> ByteRange? {
        guard start >= 0, start < totalBytes else { return nil }
        guard let header = boxHeader(bytes, at: index, remaining: totalBytes - start) else {
            return nil
        }
        // A size-0 header claims everything to EOF. Inside an unaligned payload
        // that is indistinguishable from random bytes, so only trust it when the
        // probe starts at the actual file start.
        if header.extendsToEOF, suffixStart != 0 { return nil }
        let end = start + header.size
        guard end <= totalBytes else { return nil }
        guard walksToEOF(
            bytes,
            origin: suffixStart,
            totalBytes: totalBytes,
            from: end
        ) else { return nil }
        return ByteRange(start: start, end: end - 1)
    }

    private static func walksToEOF(
        _ bytes: [UInt8],
        origin: Int64,
        totalBytes: Int64,
        from start: Int64
    ) -> Bool {
        var cursor = start
        while cursor < totalBytes {
            let local = cursor - origin
            guard local >= 0, local + 8 <= Int64(bytes.count) else { return false }
            guard let header = boxHeader(
                bytes,
                at: Int(local),
                remaining: totalBytes - cursor
            ) else { return false }
            // `size >= 8` guarantees the cursor advances, so this terminates.
            cursor += header.size
        }
        return cursor == totalBytes
    }

    private static func bigEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24
            | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8
            | UInt32(bytes[index + 3])
    }

    private static func bigEndian64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = value << 8 | UInt64(bytes[index + offset])
        }
        return value
    }

    // MARK: - Metadata

    public static func metadata(
        url: URL,
        headers: [String: String],
        totalBytes: Int64,
        cacheDirectory: URL,
        session: URLSession = .shared
    ) async throws(CinemacoreError) -> MP4ProgressiveMetadata {
        let fallback = MP4ProgressiveMetadata(readyThreshold: readyThreshold(totalBytes: totalBytes))
        // Without a size neither probe can be bounded, and guessing would risk a
        // whole-file body. The caller can still stream remotely.
        guard totalBytes > 0 else { return fallback }

        let prefixLength = min(totalBytes, probeBytes)
        guard let prefix = await fetchRange(
            url: url,
            headers: headers,
            range: ByteRange(start: 0, end: prefixLength - 1),
            session: session,
            exact: false
        ) else {
            return fallback
        }

        if let range = moovRange(prefix: prefix, suffix: Data(), totalBytes: totalBytes) {
            return await cachedMetadata(
                range: range,
                url: url,
                headers: headers,
                totalBytes: totalBytes,
                cacheDirectory: cacheDirectory,
                session: session
            ) ?? fallback
        }

        // The prefix already reached EOF, so a second request cannot reveal a
        // box the first one did not contain.
        guard prefixLength < totalBytes else { return fallback }

        let suffixLength = min(totalBytes, probeBytes)
        let suffixStart = totalBytes - suffixLength
        guard let suffix = await fetchRange(
            url: url,
            headers: headers,
            range: ByteRange(start: suffixStart, end: totalBytes - 1),
            session: session,
            exact: false
        ) else {
            return fallback
        }

        guard let range = moovRange(prefix: prefix, suffix: suffix, totalBytes: totalBytes) else {
            return fallback
        }
        return await cachedMetadata(
            range: range,
            url: url,
            headers: headers,
            totalBytes: totalBytes,
            cacheDirectory: cacheDirectory,
            session: session
        ) ?? fallback
    }

    /// Reuses a validated cache file, or downloads exactly the moov bytes and
    /// publishes them atomically so a reader never sees a half-written box.
    private static func cachedMetadata(
        range: ByteRange,
        url: URL,
        headers: [String: String],
        totalBytes: Int64,
        cacheDirectory: URL,
        session: URLSession
    ) async -> MP4ProgressiveMetadata? {
        let cacheURL = cacheFileURL(
            url: url,
            totalBytes: totalBytes,
            range: range,
            directory: cacheDirectory
        )
        let result = MP4ProgressiveMetadata(
            moovRange: range,
            moovURL: cacheURL,
            readyThreshold: readyThreshold(totalBytes: totalBytes)
        )
        if isValidMoovFile(at: cacheURL, range: range) { return result }

        guard let payload = await fetchRange(
            url: url,
            headers: headers,
            range: range,
            session: session,
            exact: true
        ) else {
            return nil
        }
        // The server must have returned exactly one well-formed moov box; a
        // proxy error page with a 206 status would otherwise be cached as an
        // index and handed to AVPlayer.
        let payloadTotal = Int64(payload.count)
        guard payloadTotal > 0,
              moovRange(prefix: payload, suffix: Data(), totalBytes: payloadTotal)
                  == ByteRange(start: 0, end: payloadTotal - 1)
        else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try payload.write(to: cacheURL, options: .atomic)
        } catch {
            return nil
        }
        return result
    }

    /// A cached file is only trusted when its length matches the range and its
    /// own header still describes one complete `moov` box.
    private static func isValidMoovFile(at url: URL, range: ByteRange) -> Bool {
        guard let data = try? Data(contentsOf: url), Int64(data.count) == range.length else {
            return false
        }
        let length = Int64(data.count)
        guard length > 0 else { return false }
        return moovRange(prefix: data, suffix: Data(), totalBytes: length)
            == ByteRange(start: 0, end: length - 1)
    }

    private static func cacheFileURL(
        url: URL,
        totalBytes: Int64,
        range: ByteRange,
        directory: URL
    ) -> URL {
        // The range is part of the identity: the same URL can serve a different
        // encode (and therefore a different moov) after a provider change, and a
        // cached box from the old encode must not be paired with new bytes.
        let identity = "\(url.absoluteString)\n\(totalBytes)\n\(range.start)-\(range.end)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = "moov-" + digest.map { String(format: "%02x", $0) }.joined() + ".bin"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func readyThreshold(totalBytes: Int64) -> Int64 {
        guard totalBytes > 0 else { return defaultReadyBytes }
        return min(totalBytes, max(defaultReadyBytes, 0))
    }

    // MARK: - Wire

    /// One bounded ranged GET. A `200` is rejected rather than accepted as a
    /// body: it is the server ignoring `Range`, and reading it would pull the
    /// whole film into memory and break the no-whole-file-download guarantee.
    private static func fetchRange(
        url: URL,
        headers: [String: String],
        range: ByteRange,
        session: URLSession,
        exact: Bool
    ) async -> Data? {
        guard range.start >= 0, range.length > 0 else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        // Exactly the caller's headers: a signed media URL must not gain a
        // signing header here, or the CDN would see a forged request.
        request.allHTTPHeaderFields = headers
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")

        do {
            let (payload, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                return nil
            }
            guard let contentRange = URLSessionDownloadTransport.contentRange(
                http.value(forHTTPHeaderField: "Content-Range")
            ), contentRange.start == range.start, contentRange.end <= range.end else {
                return nil
            }
            let count = Int64(payload.count)
            guard exact ? count == range.length : count <= range.length else { return nil }
            return payload
        } catch {
            return nil
        }
    }
}
