import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Repairs an `hev1` source in flight so `AVPlayer` can draw it.
///
/// The provider serves HEVC with an `hev1` sample entry. Apple's CoreMedia has no
/// codec type for `hev1` — `kCMVideoCodecType_HEVC` *is* `'hvc1'` — so the
/// platform plays the audio and never a frame. The two layouts differ only in
/// where the parameter sets live, and every provider file sampled keeps them in
/// `hvcC`, which makes the conversion a four-character patch of the `moov`.
///
/// The repair is deliberately lazy: it runs only after the layer has already
/// failed to produce a frame, so a device that draws `hev1` never pays for it.
public struct HEVCRewrite: Sendable {
    /// The bytes fetched from the CDN, plus the header fields they need.
    public struct Head: Sendable {
        public let moov: Data
        public let totalBytes: Int64
        /// Where `moov` starts, so the caller can tell "at the front" from
        /// "after the media data".
        public let moovOffset: Int64
        /// Whether `mdat` appears before `moov`. A patched index can only be
        /// spliced in place when the media data follows it.
        public let moovPrecedesMedia: Bool
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches enough of `url` to obtain the complete `moov`.
    ///
    /// Returns `nil` for anything this cannot repair: no `moov` in the prefix,
    /// a `moov` larger than `maxMoovBytes`, or a container that is not MP4.
    public func head(
        of url: URL,
        headers: [String: String],
        maxMoovBytes: Int64 = 32 << 20
    ) async -> Head? {
        guard let first = await fetch(url, headers: headers, range: 0...(1 << 20) - 1),
              let total = first.totalBytes, total > 0,
              let scan = Self.scan(in: first.data, totalBytes: total)
        else { return nil }
        let range = scan.moov
        guard range.length <= maxMoovBytes else { return nil }

        let moov: Data
        if range.start == 0 && Int64(first.data.count) >= range.length {
            moov = first.data.prefix(Int(range.length))
        } else {
            guard let fetched = await fetch(
                url,
                headers: headers,
                range: range.start...(range.start + range.length - 1)
            ), Int64(fetched.data.count) >= range.length else { return nil }
            // A server that ignores `Range` sends the whole file; slice the
            // index out of it rather than mistaking `ftyp` for `moov`.
            let start = fetched.data.count > Int(range.length) ? Int(range.start) : 0
            guard start + Int(range.length) <= fetched.data.count else { return nil }
            moov = fetched.data.subdata(in: start..<(start + Int(range.length)))
        }

        guard let inspection = HEVCSampleEntry.inspect(moov: moov), inspection.needsRewrite else {
            return nil
        }
        return Head(
            moov: moov,
            totalBytes: total,
            moovOffset: range.start,
            moovPrecedesMedia: scan.moovPrecedesMedia
        )
    }

    /// The whole file with a patched `moov`, or `nil` when the patch is not
    /// applicable.
    ///
    /// The repair only handles a `moov` that reaches the end of the index — that
    /// is, one followed by the media data it describes. A file whose `moov` sits
    /// *after* `mdat` would need the patched bytes spliced into the middle,
    /// which means rewriting offsets the patch deliberately never touches, so it
    /// is declined rather than guessed at.
    ///
    /// `ftyp` and any other leading boxes are preserved byte for byte: the patch
    /// lands inside `moov`, so everything before and after it is untouched.
    public func repairedFile(
        at url: URL,
        headers: [String: String],
        maxBytes: Int64 = 512 << 20
    ) async -> Data? {
        guard let head = await head(of: url, headers: headers),
              head.moovPrecedesMedia,
              head.totalBytes <= maxBytes,
              head.moovOffset + Int64(head.moov.count) <= head.totalBytes,
              let whole = await fetch(
                  url,
                  headers: headers,
                  range: 0...(head.totalBytes - 1)
              ),
              Int64(whole.data.count) == head.totalBytes
        else { return nil }

        var out = whole.data
        let start = Int(head.moovOffset)
        let end = start + head.moov.count
        guard end <= out.count else { return nil }

        // Patch the copy in place: the enclosing buffers (ftyp, mdat) keep their
        // exact bytes and the `moov` box size never changes.
        guard let patched = HEVCSampleEntry.rewrite(moov: out.subdata(in: start..<end)) else {
            return nil
        }
        out.replaceSubrange(start..<end, with: patched)
        return out
    }

    /// Repairs a file already on disk, without fetching it again.
    ///
    /// The network path fetches a whole copy to splice a patched `moov` into,
    /// which is why it refuses an index that follows `mdat`. A local file has
    /// neither problem: the patch is four bytes inside the `moov`, the box
    /// keeps its size, so the index is edited in place wherever it sits. A
    /// downloaded copy this device will not draw becomes the file the download
    /// was supposed to be, with no round trip and no second copy on disk.
    ///
    /// The `hvcC` check is the same one the fetch path makes: renaming an entry
    /// whose parameter sets are in band would break the file, not fix it. A
    /// file that needs nothing, or cannot be written, returns `false` and is
    /// left byte for byte as it was.
    public func repairInPlace(at fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: fileURL) else { return false }
        defer { try? handle.close() }

        guard let index = Self.moovIndex(in: handle),
              let inspection = HEVCSampleEntry.inspect(moov: index.data),
              inspection.needsRewrite
        else { return false }

        let target = Data(HEVCSampleEntry.target.utf8)
        for offset in inspection.entryOffsets {
            _ = Self.write(handle, at: index.offset + UInt64(offset), target)
        }
        try? handle.synchronize()

        // Read back: a read-only file, a full disk or a short write must not be
        // reported as repaired just because the calls were made.
        guard let recheck = Self.moovIndex(in: handle),
              let after = HEVCSampleEntry.inspect(moov: recheck.data)
        else { return false }
        return !after.needsRewrite
    }

    /// The complete `moov` box and where it starts in the file.
    ///
    /// Walks the top-level boxes by seeking, so the media data is never read:
    /// only the index is, and only once it is found.
    static func moovIndex(
        in handle: FileHandle,
        maxMoovBytes: Int64 = 64 << 20
    ) -> (data: Data, offset: UInt64)? {
        guard let end = try? handle.seekToEnd(), end >= 8 else { return nil }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard let header = Self.read(handle, at: offset, count: 8) else { return nil }
            let bytes = [UInt8](header)
            var size = Int64(Self.u32(bytes, 0))
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            var headerLength: UInt64 = 8
            if size == 1 {
                guard let more = Self.read(handle, at: offset + 8, count: 8) else { return nil }
                size = Int64(bitPattern: Self.u64([UInt8](more), 0))
                headerLength = 16
            } else if size == 0 {
                // A zero size means "to the end of the file".
                size = Int64(end - offset)
            }
            guard size >= Int64(headerLength), UInt64(size) <= end - offset else { return nil }
            guard type == "moov" else {
                offset += UInt64(size)
                continue
            }
            guard size <= maxMoovBytes, let data = Self.read(handle, at: offset, count: Int(size)) else {
                return nil
            }
            return (data, offset)
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count),
              data.count == count
        else { return nil }
        return data
    }

    private static func write(_ handle: FileHandle, at offset: UInt64, _ data: Data) -> Bool {
        guard (try? handle.seek(toOffset: offset)) != nil else { return false }
        return (try? handle.write(contentsOf: data)) != nil
    }

    // MARK: - Range fetch

    private struct Fetched {
        let data: Data
        let totalBytes: Int64?
    }

    private func fetch(
        _ url: URL,
        headers: [String: String],
        range: ClosedRange<Int64>
    ) async -> Fetched? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200
        else { return nil }
        return Fetched(data: data, totalBytes: Self.totalBytes(from: http, data: data, range: range))
    }

    /// `Content-Range`'s total is the only trustworthy size; a 200 answer means
    /// the server ignored the range and sent everything.
    private static func totalBytes(
        from response: HTTPURLResponse,
        data: Data,
        range: ClosedRange<Int64>
    ) -> Int64? {
        if response.statusCode == 200 { return Int64(data.count) }
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/"),
           let total = Int64(contentRange[contentRange.index(after: slash)...]) {
            return total
        }
        return nil
    }

    // MARK: - moov location

    /// Where the top-level `moov` sits, from a prefix that contains it whole.
    static func moovRange(in prefix: Data, totalBytes: Int64) -> ByteRange? {
        scan(in: prefix, totalBytes: totalBytes)?.moov
    }

    /// The `moov` location plus whether the media data follows it.
    struct Scan {
        let moov: ByteRange
        let moovPrecedesMedia: Bool
    }

    static func scan(in prefix: Data, totalBytes: Int64) -> Scan? {
        let bytes = [UInt8](prefix)
        var offset = 0
        var sawMedia = false
        while offset + 8 <= bytes.count {
            var size = Int64(u32(bytes, offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { return nil }
                size = Int64(u64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = totalBytes - Int64(offset)
            }
            guard size >= Int64(header), Int64(offset) + size <= totalBytes else { return nil }
            if type == "moov" {
                guard Int64(offset) + size <= Int64(bytes.count) else { return nil }
                return Scan(
                    moov: ByteRange(start: Int64(offset), end: Int64(offset) + size - 1),
                    moovPrecedesMedia: !sawMedia
                )
            }
            // `mdat` describes the media payload; anything before `moov` means
            // the index cannot be spliced without moving bytes the patch does
            // not own.
            if type == "mdat" { sawMedia = true }
            offset += Int(size)
        }
        return nil
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
