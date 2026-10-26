package com.cinemacore.app.ui.player

import android.annotation.SuppressLint
import android.graphics.Color
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

/**
 * StreamHype embeds are pages, not media. They stay in a WebView and never
 * reach ExoPlayer or the download queue.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebStreamView(
    url: String,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                setBackgroundColor(Color.BLACK)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.mediaPlaybackRequiresUserGesture = false
                settings.loadsImagesAutomatically = true
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                webChromeClient = WebChromeClient()
                webViewClient = object : WebViewClient() {
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
            view.stopLoading()
            view.loadUrl("about:blank")
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
        },
    )
}
