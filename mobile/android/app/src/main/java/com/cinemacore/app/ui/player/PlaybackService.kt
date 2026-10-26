package com.cinemacore.app.ui.player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.cinemacore.app.CinemacoreApp
import com.cinemacore.app.MainActivity

/**
 * Publishes the shared player as a media session so playback survives the
 * activity and gets system transport controls. The service never owns the
 * player; [com.cinemacore.app.AppContainer] does.
 */
class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val container = (application as CinemacoreApp).container
        val sessionActivity = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        mediaSession = MediaSession.Builder(this, container.player)
            .setSessionActivity(sessionActivity)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || player.mediaItemCount == 0 || !player.playWhenReady) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) {
            context.startService(Intent(context, PlaybackService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
