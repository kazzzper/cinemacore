import SwiftUI
import WebKit

/// The in-app web player for `web`-kind renditions.
///
/// StreamHype's playback is delivered by embedded third-party players whose
/// resolution path is deliberately hostile to being reproduced natively:
/// single-use IP-bound tokens, per-window WASM response crypto and rotating
/// file hosts (docs/streamhype-network-map.md §3). Those defenses are satisfied by
/// a *real browser* opening the embed page — so that is what this view does,
/// inside the app rather than leaving it.
///
/// The webview is hardened, because the embed pages are wrapped in the same
/// advertising and anti-analysis stack the map documents (§7):
///
/// - **Ad and tracker loads are denied** by a `WKContentRuleList` covering the
///   domains the map identified on every player chain (pop-under loaders, the
///   histats/AppNexus/data-broker families, bid gateways).
/// - **Pop-under script entry points are stubbed** by an injected user script,
///   so a rule list miss still cannot spawn anything.
/// - **Anti-devtools and sandbox-cage scripts are denied**; they blank the page
///   and kill playback when they think they are being inspected, and a
///   WKWebView environment can trip them as a false positive.
///
/// There is deliberately no re-implementation of a player UI here: the embed
/// owns the clock, quality and captions. Downloads do not apply to this
/// surface — `AppModel` refuses to queue a web embed — and resume cannot
/// promise a position the embed player never reports back.
struct WebStreamView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Autoplay is the embed's whole contract; sound follows the page.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The embed players self-manage storage; nothing this view does should
        // persist between sessions.
        configuration.websiteDataStore = .nonPersistent()

        let controller = WKUserContentController()
        for script in Self.userScript {
            controller.addUserScript(script)
        }
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // No navigation delegate on purpose: in-place navigation is allowed by
        // default, and the deny path is the content rule list's job. A policy
        // callback here could black-hole an embed that re-tokens itself
        // mid-play, while window-level pop-ups are already dead via the user
        // script.
        webView.isOpaque = false
        webView.backgroundColor = .black

        // The first load waits for the deny rules to compile, so the embed's
        // own anti-analysis scripts cannot slip in before the rules are in
        // place. A compile failure is not fatal: the user-script stubs keep
        // the pop-under entry points closed and playback still starts.
        Self.load(with: webView, url: url)
        return webView
    }

    /// `updateUIView` is intentionally router-blind: the embed player owns
    /// navigation once the first load has begun, and re-issuing the request on
    /// every SwiftUI update would restart the player mid-film.
    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Load

    private static func load(with webView: WKWebView, url: URL) {
        let store = WKContentRuleListStore.default()
        guard let store else {
            webView.load(URLRequest(url: url))
            return
        }
        // `add(contentRuleList:)` compiles into the content controller at
        // insertion; done before first load it applies to that load too.
        store.compileContentRuleList(
            forIdentifier: "streamhype.hardening",
            encodedContentRuleList: blockingRules
        ) { list, _ in
            if let list {
                webView.configuration.userContentController.add(list)
            }
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Hardening

    /// The user script stubs the pop-under entry points the ad loaders (§7)
    /// reach for before their rotating domains resolve, and stops the
    /// sandbox-cage frames from distinguishing themselves from the top frame.
    /// Applied at document start on every frame, because the players run
    /// inside other frames.
    static var userScript: [WKUserScript] {
        let source = """
        window.open = function() { return null; };
        try { Object.defineProperty(window, 'top', { get: function() { return window; } }); } catch (e) {}
        """
        return [WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )]
    }

    /// deny rules sourced from docs/streamhype-network-map.md §7-§8. Kept a literal
    /// so it is reviewable. Rotating pop-under subdomains cannot be enumerated
    /// (that is the rotation's purpose) — which is why the user-script stubs
    /// are the second layer, and rule-list matches the first.
    static let blockingRules = """
    [
      {"trigger":{"url-filter":"[^/]*histats\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*dtscout\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*dtscdn\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*crwdcntrl\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*mrktmtrcs\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*adnxs\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*gtcinfight\\\\.cfd"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*juchartfardinglazybed\\\\.cfd"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*eo145lzbx5hw2wpq\\\\.cfd"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*jokeconnect\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*disable-devtool\\\\.js"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"[^/]*sbx\\\\.js"},"action":{"type":"block"}}
    ]
    """
}
