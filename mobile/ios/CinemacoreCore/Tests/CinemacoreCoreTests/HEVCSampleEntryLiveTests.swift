import Foundation
import Testing
@testable import CinemacoreCore

/// Runs the rewrite against a real `moov` captured from the provider, so the
/// synthetic fixture is not the only evidence that the box walk matches the
/// files actually served. Skipped when the capture is absent (it is a 6 MB
/// binary, not committed by default).
@Suite("HEVC sample entry rewrite — captured file")
struct HEVCSampleEntryLiveTests {
    private var capturedMoov: Data? {
        // Written by the probe in .tools/tmpcheck/hevcprobe.
        let path = ProcessInfo.processInfo.environment["CINEMACORE_HEV1_MOOV"]
            ?? "/home/sammy/Desktop/Projects/mov/.tools/tmpcheck/hevcprobe/moov.bin"
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test("a captured provider moov is inspected and patched")
    func capturedFile() throws {
        guard let moov = capturedMoov else { return }
        let inspection = try #require(HEVCSampleEntry.inspect(moov: moov))
        #expect(inspection.videoSampleEntries.contains("hev1"))
        #expect((inspection.parameterSetArrays ?? 0) > 0)

        let rewritten = try #require(HEVCSampleEntry.rewrite(moov: moov))
        #expect(rewritten.count == moov.count)

        let after = try #require(HEVCSampleEntry.inspect(moov: rewritten))
        #expect(after.videoSampleEntries.contains("hvc1"))
        #expect(!after.videoSampleEntries.contains("hev1"))

        // The patch must be local: everything else is byte-identical.
        let a = [UInt8](moov), b = [UInt8](rewritten)
        let differing = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(differing.count <= 4)
    }
}
