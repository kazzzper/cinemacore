import Foundation

/// Rewrites an `hev1` sample entry to `hvc1` so AVFoundation will render it.
///
/// Apple's HLS authoring spec asks for `hvc1` rather than `hev1` — the
/// difference is *where the parameter sets live*, not which codec is used
/// (rule 1.10). `hvc1` keeps VPS/SPS/PPS in the `hvcC` sample description;
/// `hev1` permits them in-band. AVFoundation is built around `hvc1` and
/// commonly draws nothing for `hev1`, while the AAC track plays on — the black
/// picture with sound.
///
/// When `hvcC` already carries the parameter sets, the two layouts are
/// byte-identical apart from the four-character code, so the conversion is a
/// four-byte patch. Verified on every genuine `hev1` file sampled from the
/// provider: `numOfArrays == 4`, VPS/SPS/PPS/SEI each present once.
///
/// The rewrite is deliberately narrow. It never touches `mdat`, and it refuses
/// (returns `nil`) whenever the file is not exactly the shape it can prove it
/// understands, because a wrong patch here corrupts the index rather than
/// failing visibly.
public enum HEVCSampleEntry {
    /// The layout the patch produces.
    public static let target: String = "hvc1"
    /// The layout the provider serves and AVFoundation often will not draw.
    public static let source: String = "hev1"

    /// The result of inspecting one `moov`.
    public struct Inspection: Sendable, Hashable {
        /// Four-character codes of every video sample entry found.
        public let videoSampleEntries: [String]
        /// `numOfArrays` from the `hvcC` beside the first video entry, when one
        /// could be read. Non-zero means the parameter sets are in the sample
        /// description, which is what makes a rename lossless.
        public let parameterSetArrays: Int?
        /// Byte offsets of the four-character codes that need patching, relative
        /// to the start of the buffer that was inspected.
        public let entryOffsets: [Int]

        public var needsRewrite: Bool {
            videoSampleEntries.contains(source)
                && (parameterSetArrays ?? 0) > 0
                && !entryOffsets.isEmpty
        }
    }

    /// Walks a buffer holding a complete `moov` box and reports what it found.
    ///
    /// Returns `nil` only when the buffer does not begin with a `moov`, which is
    /// a caller error rather than a property of the file.
    public static func inspect(moov: Data) -> Inspection? {
        let bytes = [UInt8](moov)
        guard let root = parseBox(bytes, at: 0, base: 0), root.type == "moov" else { return nil }

        var entries: [String] = []
        var offsets: [Int] = []
        var arrays: Int?

        for trak in children(of: root, type: "trak") {
            guard let mdia = children(of: trak, type: "mdia").first,
                  let hdlr = children(of: mdia, type: "hdlr").first,
                  handlerIsVideo(hdlr.body),
                  let minf = children(of: mdia, type: "minf").first,
                  let stbl = children(of: minf, type: "stbl").first,
                  let stsd = children(of: stbl, type: "stsd").first
            else { continue }

            // `stsd` is a full box: version+flags (4), entry count (4), entries.
            // The entry list starts 8 bytes into the body, so the absolute base
            // for those entries is the body offset plus 8.
            let entriesBytes = Array(stsd.body.dropFirst(8))
            for entry in childBoxes(entriesBytes, absoluteBase: stsd.bodyOffset + 8) {
                guard entry.type == source || entry.type == target else { continue }
                entries.append(entry.type)
                if entry.type == source {
                    offsets.append(entry.typeOffset)
                    if arrays == nil {
                        arrays = parameterSetArrayCount(in: entry)
                    }
                }
            }
        }

        return Inspection(
            videoSampleEntries: entries,
            parameterSetArrays: arrays,
            entryOffsets: offsets
        )
    }

    /// Direct children of a parsed box, at the correct absolute base.
    private static func children(of box: Box, type: String) -> [Box] {
        childBoxes(box.body, absoluteBase: box.bodyOffset).filter { $0.type == type }
    }

    /// Patches every `hev1` video sample entry in `moov` to `hvc1`.
    ///
    /// Returns the rewritten buffer, or `nil` when the file is not the shape the
    /// patch is valid for — in particular when `hvcC` carries no parameter sets,
    /// where renaming would claim the sample description describes the stream
    /// when it does not.
    public static func rewrite(moov: Data) -> Data? {
        guard let inspection = inspect(moov: moov), inspection.needsRewrite else { return nil }
        var bytes = [UInt8](moov)
        for offset in inspection.entryOffsets {
            guard offset + 4 <= bytes.count else { return nil }
            // `hvc1` and `hev1` are the same length, so every offset after this
            // one stays valid.
            bytes.replaceSubrange(offset..<(offset + 4), with: Array(target.utf8))
        }
        return Data(bytes)
    }

    // MARK: - Box walking

    /// One box, with offsets relative to the original `moov` buffer.
    private struct Box {
        let type: String
        /// Offset of the four-character type code, from the buffer's start.
        let typeOffset: Int
        let body: [UInt8]
        /// Offset of `body` from the buffer's start.
        let bodyOffset: Int
        /// Total box size including the header.
        let size: Int
    }

    private static func handlerIsVideo(_ hdlrBody: [UInt8]) -> Bool {
        // Full box: version+flags (4), pre_defined (4), handler_type (4).
        guard hdlrBody.count >= 12 else { return false }
        return Array(hdlrBody[8..<12]) == Array("vide".utf8)
    }

    /// `numOfArrays` from the `hvcC` box inside a visual sample entry.
    private static func parameterSetArrayCount(in entry: Box) -> Int? {
        // VisualSampleEntry fields before the child boxes are 78 bytes.
        let children = Array(entry.body.dropFirst(min(78, entry.body.count)))
        guard let hvcc = childBoxes(children, absoluteBase: 0).first(where: { $0.type == "hvcC" }),
              hvcc.body.count >= 23 else { return nil }
        return Int(hvcc.body[22])
    }

    /// Every box in a buffer, in order.
    ///
    /// `absoluteBase` is where this buffer sits inside the original `moov`, so
    /// the offsets a caller patches with are absolute rather than relative to
    /// whatever slice the walk happens to be holding.
    private static func childBoxes(_ bytes: [UInt8], absoluteBase: Int) -> [Box] {
        var out: [Box] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            guard let box = parseBox(bytes, at: offset, base: absoluteBase) else { break }
            out.append(box)
            if box.size <= 0 { break }
            offset += box.size
        }
        return out
    }

    private static func parseBox(_ bytes: [UInt8], at offset: Int, base: Int) -> Box? {
        guard offset + 8 <= bytes.count else { return nil }
        var size = Int(u32(bytes, offset))
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        var header = 8
        if size == 1 {
            // 64-bit size in the following eight bytes.
            guard offset + 16 <= bytes.count else { return nil }
            let large = u64(bytes, offset + 8)
            guard large <= UInt64(Int.max) else { return nil }
            size = Int(large)
            header = 16
        } else if size == 0 {
            size = bytes.count - offset
        }
        guard size >= header, offset + size <= bytes.count else { return nil }
        let bodyStart = offset + header
        return Box(
            type: type,
            typeOffset: base + offset + 4,
            body: Array(bytes[bodyStart..<(offset + size)]),
            bodyOffset: base + bodyStart,
            size: size
        )
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
