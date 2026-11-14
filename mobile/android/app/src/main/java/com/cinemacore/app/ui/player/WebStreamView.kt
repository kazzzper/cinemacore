package com.cinemacore.app.ui.player

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.cinemacore.app.BuildConfig
import com.cinemacore.app.ui.theme.CinemaColors
import java.io.ByteArrayInputStream
import org.json.JSONObject

/**
 * StreamHype embeds are pages, not media. They stay in a WebView and never
 * reach ExoPlayer or the download queue.
 *
 * The embed chain checks for a normal browser in several ways, so the WebView
 * is given a Chrome-shaped user agent, document-start stubs for `window.open`
 * and `top`, and a real fullscreen host for the HTML video element. The same
 * ad/tracker hosts iOS denies are denied here.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebStreamView(
    url: String,
    modifier: Modifier = Modifier,
    controller: WebStreamController = remember { WebStreamController() },
    onFullscreenChanged: (Boolean) -> Unit = {},
    onTap: () -> Unit = {},
    /** Where the embed should pick up, in milliseconds. */
    startAtMs: Long? = null,
    /** The embed's own clock, reported by the injected script. */
    onProgress: (Long, Long) -> Unit = { _, _ -> },
) {
    var loading by remember(url) { mutableStateOf(true) }
    val webViewRef = remember { java.util.concurrent.atomic.AtomicReference<WebView?>() }
    val currentOnTap = rememberUpdatedState(onTap)
    val lifecycleOwner = LocalLifecycleOwner.current
    // A backgrounded WebView keeps decoding the embed's audio. Mirror the
    // activity's own stop/start so web playback pauses with the app.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> webViewRef.get()?.let {
                    it.onPause()
                    it.pauseTimers()
                }
                Lifecycle.Event.ON_START -> webViewRef.get()?.let {
                    it.resumeTimers()
                    it.onResume()
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            webViewRef.get()?.let {
                it.onPause()
                it.pauseTimers()
            }
        }
    }
    Box(modifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                WebView(context).apply {
                    webViewRef.set(this)
                    setBackgroundColor(Color.BLACK)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.databaseEnabled = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    settings.loadsImagesAutomatically = true
                    settings.cacheMode = WebSettings.LOAD_DEFAULT
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                    settings.javaScriptCanOpenWindowsAutomatically = false
                    settings.setSupportMultipleWindows(false)
                    settings.builtInZoomControls = false
                    settings.displayZoomControls = false
                    // A WebView advertises `wv` in its UA. Several of the
                    // embed's gates treat that as a cage; strip the marker while
                    // keeping the installed WebView's real Chrome version.
                    settings.userAgentString = settings.userAgentString
                        ?.replace("; wv)", ")")
                        ?.replace(" Version/4.0 ", " ")
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                    if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)

                    // A tap over the video toggles the app's top bar. The
                    // listener returns false so the embed still receives the
                    // same gesture for its own play/pause controls.
                    var downX = 0f
                    var downY = 0f
                    var downAt = 0L
                    setOnTouchListener { view, event ->
                        when (event.actionMasked) {
                            MotionEvent.ACTION_DOWN -> {
                                downX = event.x
                                downY = event.y
                                downAt = event.eventTime
                            }

                            MotionEvent.ACTION_UP -> {
                                val slop = 12f * view.resources.displayMetrics.density
                                if (event.eventTime - downAt < 300 &&
                                    kotlin.math.abs(event.x - downX) < slop &&
                                    kotlin.math.abs(event.y - downY) < slop
                                ) {
                                    currentOnTap.value()
                                }
                            }
                        }
                        false
                    }

                    installDocumentStartScript(this, startAtMs)
                    installProgressListener(this, onProgress)

                    val chrome = StreamChromeClient(context) { showing ->
                        onFullscreenChanged(showing)
                    }
                    controller.chrome = chrome
                    webChromeClient = chrome
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(
                            view: WebView?,
                            url: String?,
                            favicon: android.graphics.Bitmap?,
                        ) {
                            loading = true
                        }

                        override fun onPageCommitVisible(view: WebView?, url: String?) {
                            loading = false
                        }

                        override fun onPageFinished(view: WebView?, url: String?) {
                            loading = false
                        }

                        override fun onReceivedError(
                            view: WebView?,
                            request: WebResourceRequest?,
                            error: android.webkit.WebResourceError?,
                        ) {
                            if (request?.isForMainFrame == true) loading = false
                        }

                        override fun shouldInterceptRequest(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): WebResourceResponse? {
                            val target = request?.url ?: return null
                            val host = target.host?.lowercase() ?: return null
                            val path = target.path.orEmpty()
                            if (BLOCKED_HOSTS.any { host == it || host.endsWith(".$it") }) {
                                return blocked()
                            }
                            if (path.contains("disable-devtool", ignoreCase = true)) {
                                return blocked()
                            }
                            return null
                        }

                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean {
                            val target = request?.url ?: return false
                            val scheme = target.scheme ?: return true
                            // Keep navigation inside the embed; never hand an
                            // arbitrary redirect to an external browser.
                            return scheme != "http" && scheme != "https"
                        }
                    }
                }
            },
            update = { view ->
                if (view.tag != url) {
                    view.tag = url
                    if (url.startsWith("http://") || url.startsWith("https://")) {
                        view.loadUrl(url)
                    }
                }
            },
            onRelease = { view ->
                (view.webChromeClient as? StreamChromeClient)?.release()
                controller.chrome = null
                webViewRef.set(null)
                view.webChromeClient = null
                view.webViewClient = WebViewClient()
                view.stopLoading()
                view.clearHistory()
                view.loadUrl("about:blank")
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
            },
        )
        if (loading) {
            CircularProgressIndicator(
                color = CinemaColors.TextPrimary,
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(40.dp),
            )
        }
    }
}

private fun installDocumentStartScript(webView: WebView, startAtMs: Long?) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return
    WebViewCompat.addDocumentStartJavaScript(
        webView,
        """
        window.open = function() { return null; };
        try { Object.defineProperty(window, 'top', { get: function() { return window; } }); } catch (e) {}
        $FIT_EMBED_VIEWPORT_JS
        ${progressScript(maxOf(startAtMs ?: 0L, 0L))}
        """.trimIndent(),
        setOf("*"),
    )
}

/**
 * Receives the embed's own clock.
 *
 * A web-message listener rather than `addJavascriptInterface`: the page is
 * third-party code, and an interface object would expose arbitrary app methods
 * to it. Only one origin-less JSON payload travels back, and only numbers are
 * read from it.
 */
private fun installProgressListener(webView: WebView, onProgress: (Long, Long) -> Unit) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return
    WebViewCompat.addWebMessageListener(
        webView,
        WebStreamProgressObject,
        setOf("*"),
        object : WebViewCompat.WebMessageListener {
            override fun onPostMessage(
                view: WebView,
                message: WebMessageCompat,
                sourceOrigin: Uri,
                isMainFrame: Boolean,
                replyProxy: JavaScriptReplyProxy,
            ) {
                val parsed = message.data?.let(::parseProgress) ?: return
                onProgress(parsed.first, parsed.second)
            }
        },
    )
}

/// The web-message object the injected script posts through.
private const val WebStreamProgressObject = "cinemacoreProgress"

/// Watches the page's own `<video>`, seeking to [startAtMs] and reporting its
/// clock.
///
/// Injected per frame, because the embed players live inside one. A single seek
/// at `loadedmetadata` was not enough: these players create or reload their
/// `<video>` after document start and some reset the clock as they initialise,
/// so the seek was routinely overwritten and every title restarted. The target
/// is re-asserted on each media event and by a short poll until the page's own
/// clock actually reaches it.
private fun progressScript(startAtMs: Long): String = """
    (function () {
      var target = $startAtMs / 1000;
      // A fresh playback has nothing to settle; only a resume does.
      var settled = !(target > 0);
      var watched = null;
      var deadline = Date.now() + 30000;
      var watchUntil = Date.now() + 30000;

      function activeVideo() {
        var list = document.querySelectorAll('video');
        for (var i = 0; i < list.length; i++) {
          if (list[i].readyState > 0) return list[i];
        }
        return null;
      }
      function settle() { settled = true; }
      function trySeek() {
        var v = activeVideo();
        // A replaced element is a new clock, and the stored position applies
        // to it too.
        if (v && v !== watched) {
          watched = v;
          if (target > 0) {
            settled = false;
            deadline = Date.now() + 30000;
          }
        }
        if (settled || !v) return;
        if (Date.now() > deadline) { settle(); return; }
        if (!isFinite(v.duration) || v.duration <= 0) return;
        // Nothing is left to resume this close to the end.
        if (target >= v.duration - 10) { settle(); return; }
        // At or past the target: either the seek landed or the browser
        // restored the position itself. Re-seeking would rewind the viewer.
        if (v.currentTime >= target - 2) { settle(); return; }
        try { v.currentTime = target; } catch (e) { settle(); }
      }
      function report(v) {
        if (!v || !isFinite(v.duration) || v.duration <= 0 || v.currentTime <= 0) return;
        try {
          window.$WebStreamProgressObject.postMessage(
            JSON.stringify({ p: v.currentTime, d: v.duration })
          );
        } catch (e) {}
      }

      // Media events do not bubble, but a capture listener still runs for them.
      var events = ['loadedmetadata', 'loadeddata', 'durationchange',
                    'canplay', 'playing', 'timeupdate'];
      for (var i = 0; i < events.length; i++) {
        document.addEventListener(events[i], trySeek, true);
      }
      var poll = setInterval(function () {
        trySeek();
        if (Date.now() > watchUntil) clearInterval(poll);
      }, 400);

      setInterval(function () {
        var v = activeVideo();
        if (v && !v.paused) report(v);
      }, 5000);
      document.addEventListener('pause', function () { report(activeVideo()); }, true);
    })();
"""

/** Reads `{"p": seconds, "d": seconds}` and converts to milliseconds. */
private fun parseProgress(raw: String): Pair<Long, Long>? {
    val body = runCatching { JSONObject(raw) }.getOrNull() ?: return null
    val position = body.optDouble("p", -1.0)
    val duration = body.optDouble("d", -1.0)
    if (!position.isFinite() || !duration.isFinite() || position < 0 || duration <= 0) return null
    return (position * 1000).toLong() to (duration * 1000).toLong()
}

/**
 * The vidsrc-family embeds size every level with `html,body{height:100%}`.
 * This device's WebView resolves that percentage (and `vh`) to 0 even though
 * the view is laid out, so the player frame collapses to 0 px: the stream
 * plays with sound and a black picture. A pixel height is honoured, so pin the
 * root to the measured viewport and re-pin it after a rotation.
 */
private val FIT_EMBED_VIEWPORT_JS = """
    (function () {
      function fit() {
        var root = document.documentElement, body = document.body, h = window.innerHeight;
        if (!root || !body || !h) return;
        var broken = parseFloat(getComputedStyle(root).height) === 0 ||
                     parseFloat(getComputedStyle(body).height) === 0;
        if (!broken && !root.style.height) return;
        var px = h + 'px';
        root.style.setProperty('height', px, 'important');
        body.style.setProperty('height', px, 'important');
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', fit);
      } else {
        fit();
      }
      window.addEventListener('load', fit);
      window.addEventListener('resize', fit);
    })();
""".trimIndent()

private fun blocked(): WebResourceResponse =
    WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))

/** Hosts from docs/streamhype-network-map.md; the embed's ad stack is blocked. */
private val BLOCKED_HOSTS = setOf(
    "histats.com",
    "dtscout.com",
    "dtscdn.com",
    "crwdcntrl.net",
    "mrktmtrcs.net",
    "adnxs.com",
    "gtcinfight.cfd",
    "juchartfardinglazybed.cfd",
    "eo145lzbx5hw2wpq.cfd",
    "jokeconnect.com",
)

/**
 * Lets the screen drive the HTML5 fullscreen host: hardware back and the
 * on-screen back arrow must leave the embed's fullscreen before the player.
 */
class WebStreamController {
    internal var chrome: WebChromeClient? = null

    fun exitFullscreen() {
        (chrome as? WebChromeClient)?.onHideCustomView()
    }
}

/**
 * HTML video inside an iframe asks the host for a fullscreen window. The
 * default `WebChromeClient` drops that request, which is why the embed's own
 * fullscreen button looked dead in Android.
 *
 * The custom view is attached to the activity's decor rather than a `Dialog`:
 * it is the same window, so keep-screen-on, the player's brightness override
 * and the immersive policy all keep working, and there is no second window
 * token to go stale while the player is finishing.
 */
private class StreamChromeClient(
    private val context: Context,
    private val onFullscreen: (Boolean) -> Unit,
) : WebChromeClient() {
    private var customView: View? = null
    private var customCallback: CustomViewCallback? = null

    override fun onShowCustomView(view: View, callback: CustomViewCallback) {
        if (customView != null) {
            callback.onCustomViewHidden()
            return
        }
        val owner = context.findActivity()
        val decor = owner?.window?.decorView as? ViewGroup
        val gone = owner == null ||
            decor == null ||
            owner.isFinishing ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && owner.isDestroyed)
        if (gone) {
            callback.onCustomViewHidden()
            return
        }
        customView = view
        customCallback = callback
        try {
            decor.addView(
                view,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        } catch (_: RuntimeException) {
            clear()
            callback.onCustomViewHidden()
            return
        }
        WindowInsetsControllerCompat(owner.window, decor).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
        onFullscreen(true)
    }

    override fun onHideCustomView() {
        hide()
    }

    fun release() {
        hide()
    }

    private fun hide() {
        val callback = customCallback ?: return
        val view = customView
        clear()
        (view?.parent as? ViewGroup)?.removeView(view)
        callback.onCustomViewHidden()
        onFullscreen(false)
    }

    private fun clear() {
        customView = null
        customCallback = null
    }
}

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
