import Testing
import Foundation
@testable import CinemacoreCore

@Suite("StreamRecovery")
struct StreamRecoveryTests {

    private func base64URL(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func cloudFrontCookie(resource: String) -> String {
        let policy = "{\"Statement\":[{\"Resource\":\"\(resource)\"}]}"
        let encoded = Data(policy.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "~")
            .replacingOccurrences(of: "=", with: "_")
        return "CloudFront-Policy=\(encoded)"
    }

    private let decoy =
        "https://macdn.aoneroom.com/other/2026/10/10/80da52722ee7de7a4303290af6783424.mp4"

    @Test("a signed decoy prefix is not promoted to a manifest")
    func signedDecoy() {
        let cookie = "urlprefix=\(base64URL(decoy)):sign=f1a522f7"
        #expect(StreamRecovery.manifest(fromSignCookie: cookie) == nil)
    }

    @Test("the notice clip is a decoy even when it is signed")
    func noticeClip() {
        let notice = "https://cdn.example.com/notice.mp4"
        #expect(StreamRecovery.manifest(fromSignCookie: "urlprefix=\(base64URL(notice))") == nil)
        #expect(!StreamRecovery.isUsable(notice))
    }

    @Test("a valid HLS prefix still resolves")
    func hlsPrefix() {
        let prefix = "https://cdn.example.com/hls/title/"
        #expect(
            StreamRecovery.manifest(fromSignCookie: "urlprefix=\(base64URL(prefix))")
                == "https://cdn.example.com/hls/title/index.m3u8"
        )
    }

    @Test("a valid DASH prefix still resolves")
    func dashPrefix() {
        let prefix = "https://cdn.example.com/dash/title/"
        #expect(
            StreamRecovery.manifest(fromSignCookie: "urlprefix=\(base64URL(prefix))")
                == "https://cdn.example.com/dash/title/index.mpd"
        )
    }

    @Test("a CloudFront decoy resource is rejected")
    func cloudFrontDecoy() {
        #expect(StreamRecovery.manifest(fromSignCookie: cloudFrontCookie(resource: decoy)) == nil)
    }

    @Test("a CloudFront DASH resource still resolves")
    func cloudFrontDash() {
        let resource = "https://cdn.example.com/dash/title/*"
        #expect(
            StreamRecovery.manifest(fromSignCookie: cloudFrontCookie(resource: resource))
                == "https://cdn.example.com/dash/title/index.mpd"
        )
    }
}
