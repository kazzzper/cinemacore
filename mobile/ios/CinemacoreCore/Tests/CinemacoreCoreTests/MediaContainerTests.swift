import Testing
import Foundation
@testable import CinemacoreCore

@Suite("MediaContainer")
struct MediaContainerTests {

    private func url(_ raw: String) -> URL {
        guard let url = URL(string: raw) else { preconditionFailure("bad fixture URL: \(raw)") }
        return url
    }

    @Test("file extensions identify the three containers")
    func extensions() {
        #expect(MediaContainer.classify(url: url("https://cdn.test/a.mp4")) == .mp4)
        #expect(MediaContainer.classify(url: url("https://cdn.test/a.M4V")) == .mp4)
        #expect(MediaContainer.classify(url: url("https://cdn.test/a.m3u8?token=1")) == .hls)
        #expect(MediaContainer.classify(url: url("https://cdn.test/a.mpd")) == .dash)
        #expect(MediaContainer.classify(url: url("https://cdn.test/play")) == .unknown)
    }

    @Test("a definite content type beats a misleading extension")
    func contentTypes() {
        #expect(
            MediaContainer.classify(
                url: url("https://cdn.test/a.bin"),
                contentType: "application/vnd.apple.mpegurl; charset=utf-8"
            ) == .hls
        )
        #expect(
            MediaContainer.classify(url: url("https://cdn.test/a.bin"), contentType: "application/dash+xml")
                == .dash
        )
        #expect(
            MediaContainer.classify(url: url("https://cdn.test/a.bin"), contentType: "video/mp4") == .mp4
        )
        // A generic type says nothing, so the extension remains authoritative.
        #expect(
            MediaContainer.classify(url: url("https://cdn.test/a.m3u8"), contentType: "application/octet-stream")
                == .hls
        )
    }

    @Test("only HLS and DASH are manifests")
    func manifestPolicy() {
        #expect(MediaContainer.hls.isManifest)
        #expect(MediaContainer.dash.isManifest)
        #expect(!MediaContainer.mp4.isManifest)
        #expect(!MediaContainer.unknown.isManifest)
        #expect(MediaContainer.mp4.isDirectDownload)
        #expect(MediaContainer.unknown.isDirectDownload)
        #expect(!MediaContainer.hls.isDirectDownload)
        #expect(!MediaContainer.dash.isDirectDownload)
    }

    @Test("local asset suffixes are filesystem-safe")
    func assetExtensions() {
        #expect(MediaContainer.mp4.assetExtension == "mp4")
        #expect(MediaContainer.hls.assetExtension == "hls")
        #expect(MediaContainer.dash.assetExtension == "dash")
        #expect(MediaContainer.unknown.assetExtension == "mp4")
    }

    @Test("a rendition exposes the container its URL names")
    func renditionContainer() {
        let hls = StreamRendition(quality: "1080p", url: "https://cdn.test/index.m3u8")
        let mp4 = StreamRendition(quality: "720p", url: "https://cdn.test/movie.mp4")
        #expect(hls.container == .hls)
        #expect(mp4.container == .mp4)
    }
}
