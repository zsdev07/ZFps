package com.zsdev.fpsmonitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * High-priority foreground service that owns an active monitoring session.
 *
 * Keeps the process alive (with a partial wake lock, high-priority ongoing
 * notification, and stopWithTask=false) while the game is in the foreground,
 * so OEM memory managers (e.g. Funtouch OS) do not kill the collector when
 * free RAM drops. Metric collection is driven from Dart and the floating
 * window is drawn by [OverlayService].
 */
class MonitorService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentAppName: String = "App"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                currentAppName = intent.getStringExtra(EXTRA_APP_NAME) ?: "App"
                isSessionActive = true
                startInForeground(
                    buildNotification(
                        title = "FPS Monitor • $currentAppName",
                        body = "High-priority monitoring active • CSV auto-save on"
                    )
                )
                acquireWakeLock()
                OverlayService.start(applicationContext)
            }
            ACTION_UPDATE -> {
                if (!isSessionActive) {
                    stopSelf()
                } else {
                    val fps = intent.getDoubleExtra(EXTRA_FPS, -1.0)
                    val cpuTemp = intent.getDoubleExtra(EXTRA_CPU_TEMP, -1.0)
                    val freeRam = intent.getDoubleExtra(EXTRA_FREE_RAM, -1.0)
                    val elapsedSec = intent.getIntExtra(EXTRA_ELAPSED_SECONDS, 0)
                    val paused = intent.getBooleanExtra(EXTRA_PAUSED, false)

                    val title = if (paused) {
                        "FPS Monitor • $currentAppName (Paused)"
                    } else {
                        "FPS Monitor • $currentAppName"
                    }
                    val parts = mutableListOf<String>()
                    parts.add(if (paused) "Paused" else if (fps >= 0) "${fps.toInt()} FPS" else "-- FPS")
                    if (cpuTemp >= 0) parts.add("CPU ${"%.0f".format(cpuTemp)}°C")
                    if (freeRam >= 0) parts.add("RAM ${freeRam.toInt()} MB")
                    if (elapsedSec > 0) parts.add(formatElapsed(elapsedSec))

                    val nm = getSystemService(NotificationManager::class.java)
                    nm?.notify(
                        NOTIFICATION_ID,
                        buildNotification(title = title, body = parts.joinToString(" • "))
                    )
                }
            }
            ACTION_STOP -> {
                isSessionActive = false
                OverlayService.stop(applicationContext)
                releaseWakeLock()
                stopForegroundCompat()
                stopSelf()
            }
            null -> {
                // Defensive cleanup if restarted without an action
                isSessionActive = false
                startInForeground(
                    buildNotification(
                        title = "FPS Monitor",
                        body = "Stopping monitoring session"
                    )
                )
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isSessionActive = false
        releaseWakeLock()
        super.onDestroy()
    }

    // ------------------------------------------------------------- notification & FGS

    @Suppress("DEPRECATION")
    private fun buildNotification(title: String, body: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val openPending = PendingIntent.getActivity(this, 0, openIntent, piFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }

        builder
            .setSmallIcon(R.drawable.ic_stat_fps)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(openPending)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build()
    }

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                512 // ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE (API 34)
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fpsmonitor:session").apply {
                setReferenceCounted(false)
            }
        }
        try {
            wakeLock?.acquire(4 * 60 * 60 * 1000L) // safety timeout: 4 hours
        } catch (_: Throwable) {
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Throwable) {
        }
        wakeLock = null
    }

    // ------------------------------------------------------------- channel

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Active FPS monitoring",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "High-priority persistent notification keeping monitoring alive during games"
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun formatElapsed(seconds: Int): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) {
            "%d:%02d:%02d".format(h, m, s)
        } else {
            "%02d:%02d".format(m, s)
        }
    }

    companion object {
        private const val CHANNEL_ID = "fps_monitor_session_hp"
        private const val NOTIFICATION_ID = 4102

        @Volatile
        private var isSessionActive = false

        const val ACTION_START = "com.zsdev.fpsmonitor.monitor.START"
        const val ACTION_UPDATE = "com.zsdev.fpsmonitor.monitor.UPDATE"
        const val ACTION_STOP = "com.zsdev.fpsmonitor.monitor.STOP"
        const val EXTRA_APP_NAME = "app_name"
        const val EXTRA_FPS = "fps"
        const val EXTRA_CPU_TEMP = "cpu_temp"
        const val EXTRA_FREE_RAM = "free_ram"
        const val EXTRA_ELAPSED_SECONDS = "elapsed_seconds"
        const val EXTRA_PAUSED = "paused"

        fun start(context: Context, appName: String) {
            val intent = Intent(context, MonitorService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_APP_NAME, appName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun updateNotification(
            context: Context,
            fps: Double,
            cpuTemp: Double,
            freeRamMb: Double,
            elapsedSeconds: Int,
            paused: Boolean
        ) {
            if (!isSessionActive) return
            val intent = Intent(context, MonitorService::class.java)
                .setAction(ACTION_UPDATE)
                .putExtra(EXTRA_FPS, fps)
                .putExtra(EXTRA_CPU_TEMP, cpuTemp)
                .putExtra(EXTRA_FREE_RAM, freeRamMb)
                .putExtra(EXTRA_ELAPSED_SECONDS, elapsedSeconds)
                .putExtra(EXTRA_PAUSED, paused)
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, MonitorService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
