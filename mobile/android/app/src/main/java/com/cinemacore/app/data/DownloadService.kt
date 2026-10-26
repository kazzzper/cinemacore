package com.cinemacore.app.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.cinemacore.app.CinemacoreApp
import com.cinemacore.app.MainActivity
import com.cinemacore.app.R
import com.cinemacore.app.domain.DownloadStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Keeps the direct-download queue alive while the app is not foregrounded.
 *
 * Android does not allow an unbounded background worker, so the transfer runs
 * in the application scope and this service only supplies the foreground
 * contract and the user-visible progress notification.
 */
class DownloadService : android.app.Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var observer: Job? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val engine = (application as CinemacoreApp).container.downloads
        startForegroundCompat(
            buildNotification(
                title = getString(R.string.notification_downloads_preparing),
                text = getString(R.string.notification_downloads_starting),
                progress = 0.0,
            ),
        )
        observer = scope.launch {
            engine.items.collectLatest { items ->
                val active = items.filter {
                    it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED
                }
                if (active.isEmpty()) {
                    stopSelf()
                    return@collectLatest
                }
                val progress = active.map { it.progress }.average().takeIf { !it.isNaN() } ?: 0.0
                val title = if (active.size == 1) {
                    active.first().title
                } else {
                    getString(R.string.notification_downloads_many, active.size)
                }
                val text = if (active.size == 1) {
                    val item = active.first()
                    if (item.totalBytes > 0) {
                        "${(progress * 100).toInt()}% · ${item.sizeText.orEmpty()}"
                    } else {
                        getString(R.string.notification_downloads_active)
                    }
                } else {
                    getString(R.string.notification_downloads_overall, (progress * 100).toInt())
                }
                getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, buildNotification(title, text, progress))
            }
        }
        engine.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        (application as CinemacoreApp).container.downloads.start()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): android.os.IBinder? = null

    /**
     * Android 15 caps dataSync foreground services at six hours in a rolling
     * 24-hour window. The system calls this before killing the process; pausing
     * the queue is the only honest response, and the UI can resume it later.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        scope.launch {
            (application as CinemacoreApp).container.downloads.pauseAll()
        }
        stopSelf(startId)
    }

    override fun onDestroy() {
        observer?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: android.app.Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Double,
    ): android.app.Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (progress > 0) {
            builder.setProgress(100, (progress * 100).toInt(), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_downloads),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.notification_channel_downloads_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 4101

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DownloadService::class.java),
            )
        }
    }
}
