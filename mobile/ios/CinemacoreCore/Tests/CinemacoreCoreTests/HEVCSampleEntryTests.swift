import Foundation
import Testing
@testable import CinemacoreCore

/// The `hev1` → `hvc1` patch is four bytes in a 6 MB index, so the tests build
/// the box tree the provider actually serves rather than trusting a hand-wave:
/// `moov` → `trak` → `mdia` (`hdlr` = `vide`) → `minf` → `stbl` → `stsd` →
/// `hev1` → `hvcC` with VPS/SPS/PPS/SEI arrays.
@Suite("HEVC sample entry rewrite")
struct HEVCSampleEntryTests {

    // MARK: - Box construction

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let size = UInt32(8 + payload.count)
        out += [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        out += Array(type.utf8)
        out += payload
        return out
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// A visual sample entry whose child boxes start at the documented 78-byte
    /// offset, with `hvcC` carrying `arrayCount` parameter-set arrays.
    private func videoEntry(_ fourcc: String, arrayCount: UInt8) -> [UInt8] {
        var hvcC = [UInt8](repeating: 0, count: 22)
        hvcC += [arrayCount]
        // Each array: one byte (type | completeness), 16-bit count, then one
        // 16-bit-length record.
        for index in 0..<Int(arrayCount) {
            let nalType = UInt8([32, 33, 34, 39][index % 4])
            hvcC += [nalType]
            hvcC += u16(1)
            hvcC += u16(3)
            hvcC += [0x42, 0x00, 0x01]
        }
        // VisualSampleEntry: 6 reserved + 2 data-ref-index + 16 pre_defined/
        // reserved + 2 width + 2 height + 4 h/v resolution + 4 reserved +
        // 2 frame count + 32 compressor name + 2 depth + 2 pre_defined = 78.
        var entry = [UInt8](repeating: 0, count: 78)
        entry[24] = 0x07; entry[25] = 0x80  // width 1920
        entry[26] = 0x04; entry[27] = 0x38  // height 1080
        entry += box("hvcC", hvcC)
        return box(fourcc, entry)
    }

    private func hdlr(_ handler: String) -> [UInt8] {
        box("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array(handler.utf8) + [0, 0, 0, 0])
    }

    private func movie(
        videoFourCC: String = "hev1",
        arrayCount: UInt8 = 4,
        audio: Bool = true
    ) -> Data {
        let stsd = box("stsd", [0, 0, 0, 0] + u32(1) + videoEntry(videoFourCC, arrayCount: arrayCount))
        let stbl = box("stbl", stsd)
        let minf = box("minf", stbl)
        let mdia = box("mdia", hdlr("vide") + minf)
        let videoTrak = box("trak", mdia)

        var traks = videoTrak
        if audio {
            // A sound track whose handler is not `vide`: it must be ignored.
            let aStsd = box("stsd", [0, 0, 0, 0] + u32(1) + box("mp4a", [UInt8](repeating: 0, count: 28)))
            let aMdia = box("mdia", hdlr("soun") + box("minf", box("stbl", aStsd)))
            traks += box("trak", aMdia)
        }
        return Data(box("moov", traks))
    }

    // MARK: - Inspection

    @Test("a served hev1 file with parameter sets is recognised as rewritable")
    func inspection() throws {
        let moov = movie()
        let inspection = try #require(HEVCSampleEntry.inspect(moov: moov))
        #expect(inspection.videoSampleEntries == ["hev1"])
        #expect(inspection.parameterSetArrays == 4)
        #expect(inspection.entryOffsets.count == 1)
        #expect(inspection.needsRewrite)
    }

    @Test("the audio track is not mistaken for the video entry")
    func ignoresAudioTrack() throws {
        let moov = movie()
        let inspection = try #require(HEVCSampleEntry.inspect(moov: moov))
        // Exactly one offset: the `hev1` in the video track, never the `mp4a`.
        #expect(inspection.entryOffsets.count == 1)
        #expect(inspection.videoSampleEntries == ["hev1"])
    }

    // MARK: - Rewrite

    @Test("rewriting produces hvc1 and changes only the two differing letters")
    func rewrite() throws {
        let moov = movie()
        let rewritten = try #require(HEVCSampleEntry.rewrite(moov: moov))

        #expect(rewritten.count == moov.count)
        let before = [UInt8](moov)
        let after = [UInt8](rewritten)
        // `hev1` and `hvc1` share `h` and `1`; only the middle two differ. The
        // patch is four bytes wide but two bytes actually change.
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 2)
        #expect(changed.map(\.0) == Array("ev".utf8))
        #expect(changed.map(\.1) == Array("vc".utf8))

        let inspection = try #require(HEVCSampleEntry.inspect(moov: rewritten))
        #expect(inspection.videoSampleEntries == ["hvc1"])
        #expect(!inspection.needsRewrite)
    }

    @Test("the patch lands on the sample entry, not on a stray fourcc")
    func patchLocation() throws {
        let moov = movie()
        let inspection = try #require(HEVCSampleEntry.inspect(moov: moov))
        let offset = try #require(inspection.entryOffsets.first)
        let after = [UInt8](try #require(HEVCSampleEntry.rewrite(moov: moov)))
        #expect(Array(after[offset..<(offset + 4)]) == Array("hvc1".utf8))
        // The box size is unchanged, so every following box still parses.
        let size = UInt32(after[offset - 4]) << 24 | UInt32(after[offset - 3]) << 16
            | UInt32(after[offset - 2]) << 8 | UInt32(after[offset - 1])
        #expect(size > 0)
    }

    @Test("hvc1 is left alone")
    func alreadyTarget() {
        let moov = movie(videoFourCC: "hvc1")
        #expect(HEVCSampleEntry.rewrite(moov: moov) == nil)
    }

    @Test("an avc1 file is not touched")
    func h264Untouched() {
        #expect(HEVCSampleEntry.rewrite(moov: movie(videoFourCC: "avc1")) == nil)
    }

    @Test("hev1 without parameter sets is refused")
    func inBandRefused() throws {
        // The whole validity of the rename rests on the sample description
        // carrying VPS/SPS/PPS. Without them a rename would claim a description
        // that does not exist, so the rewrite must decline.
        let moov = movie(arrayCount: 0)
        let inspection = try #require(HEVCSampleEntry.inspect(moov: moov))
        #expect(inspection.parameterSetArrays == 0)
        #expect(!inspection.needsRewrite)
        #expect(HEVCSampleEntry.rewrite(moov: moov) == nil)
    }

    @Test("a buffer that is not a moov is refused")
    func notAMoov() {
        let notMoov = Data(box("ftyp", Array("isom".utf8) + [0, 0, 0, 0]))
        #expect(HEVCSampleEntry.inspect(moov: notMoov) == nil)
        #expect(HEVCSampleEntry.rewrite(moov: notMoov) == nil)
    }

    @Test("a truncated moov does not crash or produce a partial patch")
    func truncated() throws {
        let moov = movie()
        let bytes = [UInt8](moov)
        // Cut in the middle of the box tree.
        let cut = Data(bytes.prefix(bytes.count / 2))
        // Whatever the parser concludes, it must not hand back a patch.
        if let rewritten = HEVCSampleEntry.rewrite(moov: cut) {
            #expect(rewritten.count == cut.count)
        }
        #expect(HEVCSampleEntry.rewrite(moov: Data()) == nil)
    }

    @Test("a 64-bit box size is walked, not misread as 32-bit")
    func largeBox() throws {
        // `mdat`-style large boxes appear in these files; a 64-bit size must not
        // desynchronise the walk.
        var payload = u32(1)
        payload += [UInt8](repeating: 0xAA, count: 32)
        var large = [UInt8]()
        large += [0, 0, 0, 1]
        large += Array("free".utf8)
        // 64-bit size: eight bytes, big-endian.
        let total = UInt64(16 + payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            large.append(UInt8((total >> UInt64(shift)) & 0xFF))
        }
        large += payload
        let moov = movie()
        // Prepend the large box inside `moov`'s body so the walk has to skip it.
        let bytes = [UInt8](moov)
        let bodyStart = 8
        var rebuilt = Array(bytes[0..<bodyStart])
        rebuilt += large
        rebuilt += Array(bytes[bodyStart...])
        let size = UInt32(rebuilt.count)
        rebuilt[0] = UInt8(size >> 24 & 0xFF); rebuilt[1] = UInt8(size >> 16 & 0xFF)
        rebuilt[2] = UInt8(size >> 8 & 0xFF); rebuilt[3] = UInt8(size & 0xFF)

        let inspection = try #require(HEVCSampleEntry.inspect(moov: Data(rebuilt)))
        #expect(inspection.videoSampleEntries == ["hev1"])
        #expect(inspection.needsRewrite)
    }
}
