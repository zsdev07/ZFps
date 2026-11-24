package com.zsdev.fpsmonitor

import android.Manifest
import android.app.NotificationManager
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Platform channel: com.zsdev.fpsmonitor/channel
 *
 * Methods:
 *  - getStorageDir               -> String (app private files dir, used by Hive)
 *  - checkShizuku                -> {ping, version, permission, bound, preV11}
 *  - bindShizuku                 -> Boolean (starts async bind + permission request)
 *  - runShell (command)          -> String (stdout+stderr, or "ERR: ...")
 *  - getStats (packageName,      -> {fps, cpuTemp, gpuTemp, freeRamMb, cpuUsage,
 *            includeStorage)        gpuUsage, storageSpeed, refreshRate,
 *                                   batteryCurrentMa, batteryPowerWatts}
 *  - getDeviceInfo               -> {deviceModel, socName, totalRamMb}
 *  - getFrames (packageName,     -> {frames: List<Double> ms, valid: Boolean} new frame times
 *            reset)                  since the previous call (see FrameSampler)
 *  - shareFile (bytes, fileName, -> Boolean (opens the Android share sheet for a CSV / PNG)
 *            mimeType, title)
 *  - getBatteryLevel             -> Int (0-100, or -1 when unknown)
 *  - checkOverlayPermission      -> Boolean (canDrawOverlays)
 *  - requestOverlayPermission    -> Boolean (opens system settings)
 *  - startMonitoring (appName)   -> Boolean (starts FGS + overlay)
 *  - stopMonitoring              -> Boolean
 *  - updateOverlay               -> Boolean (pushes live stats into the overlay)
 *  - getOverlayConfig / setOverlayConfig -> overlay look (see OverlayConfig)
 *  - getInstalledApps            -> List<Map{name, packageName, icon: Uint8List}>
 */
class PlatformChannelHandler(
    private val activity: MainActivity,
    messenger: BinaryMessenger
) {
    private val appContext = activity.applicationContext
    private val shizuku = ShizukuClient(appContext)
    private val metrics = SystemMetrics(appContext)
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "fps-metrics").apply { isDaemon = true }
    }

    // Separate thread so frame polling never waits behind the slower stats poll
    private val frameSampler = FrameSampler()
    private val frameExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "fps-frames").apply { isDaemon = true }
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun register() {
        // Channel is registered eagerly in the property initializer above.
        Log.i(TAG, "Method channel registered: $CHANNEL")
    }

    // ------------------------------------------------------------- dispatch

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Storage folder for Hive (replaces path_provider)
            "getStorageDir" -> replyOnUi(result) { appContext.filesDir.absolutePath }

            "checkShizuku" -> replyOnUi(result) { shizuku.status() }

            "bindShizuku" -> replyOnUi(result) {
                shizuku.bind()
                true
            }

            "runShell" -> {
                val command = call.argument<String>("command") ?: ""
                executor.execute {
                    val output = shizuku.runShell(command)
                    replyOnUi(result) { output }
                }
            }

            "getStats" -> {
                val packageName = call.argument<String>("packageName") ?: ""
                val includeStorage = call.argument<Boolean>("includeStorage") ?: false
                executor.execute {
                    val stats = try {
                        metrics.collect(packageName, includeStorage, shizuku)
                    } catch (t: Throwable) {
                        Log.e(TAG, "collect() failed: ${t.message}")
                        fallbackStats()
                    }
                    replyOnUi(result) { stats }
                }
            }

            "getDeviceInfo" -> executor.execute {
                val info = try {
                    metrics.deviceInfo(shizuku)
                } catch (t: Throwable) {
                    Log.e(TAG, "deviceInfo() failed: ${t.message}")
                    mapOf(
                        "deviceModel" to (Build.MODEL ?: "Android Device"),
                        "socName" to (Build.HARDWARE ?: "Unknown SoC"),
                        "totalRamMb" to -1.0
                    )
                }
                replyOnUi(result) { info }
            }

            "getFrames" -> {
                val packageName = call.argument<String>("packageName") ?: ""
                val reset = call.argument<Boolean>("reset") ?: false
                frameExecutor.execute {
                    val batch = try {
                        frameSampler.poll(packageName, shizuku, reset)
                    } catch (t: Throwable) {
                        Log.e(TAG, "frame poll failed: ${t.message}")
                        FrameSampler.MISS
                    }
                    replyOnUi(result) {
                        mapOf("frames" to batch.frameTimesMs, "valid" to batch.valid)
                    }
                }
            }

            "shareFile" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val fileName = call.argument<String>("fileName") ?: "export"
                val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                val title = call.argument<String>("title") ?: "Share"
                if (bytes == null) {
                    result.error("bad_args", "bytes missing", null)
                } else {
                    executor.execute {
                        val uri = try {
                            writeExport(bytes, fileName)
                        } catch (t: Throwable) {
                            Log.e(TAG, "writeExport failed: ${t.message}")
                            null
                        }
                        replyOnUi(result) {
                            if (uri == null) {
                                false
                            } else {
                                launchShare(uri, mime, title)
                                true
                            }
                        }
                    }
                }
            }

            "getBatteryLevel" -> replyOnUi(result) { batteryLevelPercent() }

            "checkBatteryOptimization" -> replyOnUi(result) { isIgnoringBatteryOptimizations() }

            "requestIgnoreBatteryOptimization" -> replyOnUi(result) {
                requestIgnoreBatteryOptimization()
            }

            "openBatterySettings" -> replyOnUi(result) { openBatterySettings() }

            "checkNotificationPermission" -> replyOnUi(result) { hasNotificationPermission() }

            "requestNotificationPermission" -> replyOnUi(result) {
                requestNotificationPermission()
            }

            "checkOverlayPermission" -> replyOnUi(result) { overlayPermitted() }

            "requestOverlayPermission" -> replyOnUi(result) {
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${activity.packageName}")
                    )
                    activity.startActivity(intent)
                    true
                } catch (t: Throwable) {
                    Log.e(TAG, "open overlay settings failed: ${t.message}")
                    false
                }
            }

            "startMonitoring" -> replyOnUi(result) {
                val appName = call.argument<String>("appName") ?: "App"
                try {
                    MonitorService.start(appContext, appName)
                    true
                } catch (t: Throwable) {
                    Log.e(TAG, "startMonitoring failed: ${t.message}")
                    false
                }
            }

            "stopMonitoring" -> replyOnUi(result) {
                try {
                    MonitorService.stop(appContext)
                    true
                } catch (t: Throwable) {
                    Log.e(TAG, "stopMonitoring failed: ${t.message}")
                    false
                }
            }

            "updateNotification" -> replyOnUi(result) {
                val fps = call.argument<Number>("fps")?.toDouble() ?: -1.0
                val cpuTemp = call.argument<Number>("cpuTemp")?.toDouble() ?: -1.0
                val freeRam = call.argument<Number>("freeRamMb")?.toDouble() ?: -1.0
                val elapsedSec = call.argument<Number>("elapsedSeconds")?.toInt() ?: 0
                val paused = call.argument<Boolean>("paused") ?: false
                try {
                    MonitorService.updateNotification(
                        appContext,
                        fps,
                        cpuTemp,
                        freeRam,
                        elapsedSec,
                        paused
                    )
                    true
                } catch (t: Throwable) {
                    Log.w(TAG, "updateNotification failed: ${t.message}")
                    false
                }
            }

            // Kept for compatibility with overlay-only flows
            "startOverlay" -> replyOnUi(result) {
                try {
                    OverlayService.start(appContext)
                    true
                } catch (t: Throwable) {
                    false
                }
            }

            "stopOverlay" -> replyOnUi(result) {
                OverlayService.stop(appContext)
                true
            }

            "updateOverlay" -> replyOnUi(result) {
                val fps = call.argument<Number>("fps")?.toDouble() ?: -1.0
                val cpuTemp = call.argument<Number>("cpuTemp")?.toDouble() ?: -1.0
                val gpuTemp = call.argument<Number>("gpuTemp")?.toDouble() ?: -1.0
                val freeRam = call.argument<Number>("freeRamMb")?.toDouble() ?: -1.0
                val cpuUsage = call.argument<Number>("cpuUsage")?.toDouble() ?: -1.0
                val gpuUsage = call.argument<Number>("gpuUsage")?.toDouble() ?: -1.0
                val batteryCurrentMa = call.argument<Number>("batteryCurrentMa")?.toDouble() ?: -1.0
                val batteryPowerWatts = call.argument<Number>("batteryPowerWatts")?.toDouble() ?: -1.0
                val paused = call.argument<Boolean>("paused") ?: false
                OverlayService.update(
                    appContext,
                    fps,
                    cpuTemp,
                    gpuTemp,
                    freeRam,
                    cpuUsage,
                    gpuUsage,
                    batteryCurrentMa,
                    batteryPowerWatts,
                    paused
                )
                true
            }

            "getOverlayConfig" -> replyOnUi(result) { OverlayConfig.load(appContext).toMap() }

            "setOverlayConfig" -> replyOnUi(result) {
                val cfg = OverlayConfig.fromMap(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                cfg.save(appContext)
                try {
                    OverlayService.reloadConfig(appContext)
                } catch (t: Throwable) {
                    Log.w(TAG, "reloadConfig failed: ${t.message}")
                }
                true
            }

            "getInstalledApps" -> executor.execute {
                val apps = try {
                    metrics.launchableApps()
                } catch (t: Throwable) {
                    Log.e(TAG, "launchableApps failed: ${t.message}")
                    emptyList<Map<String, Any>>()
                }
                replyOnUi(result) { apps }
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- helpers

    private fun replyOnUi(result: MethodChannel.Result, block: () -> Any?) {
        activity.runOnUiThread {
            try {
                result.success(block())
            } catch (t: Throwable) {
                Log.e(TAG, "channel call failed: ${t.message}")
                result.error("channel_error", t.message, null)
            }
        }
    }

    /** Writes [bytes] to cache/exports and returns the content:// uri served by [ExportProvider]. */
    private fun writeExport(bytes: ByteArray, fileName: String): Uri {
        val dir = File(appContext.cacheDir, "exports").apply { mkdirs() }
        // Housekeeping: drop exports older than 24 h
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }

        val safe = fileName.replace(Regex("[^A-Za-z0-9._-]"), "_").take(100).ifBlank { "export" }
        File(dir, safe).writeBytes(bytes)
        return Uri.Builder()
            .scheme("content")
            .authority("${appContext.packageName}.exports")
            .appendPath(safe)
            .build()
    }

    private fun launchShare(uri: Uri, mime: String, title: String) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, title)
            clipData = ClipData.newRawUri(title, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(send, title))
    }

    private fun overlayPermitted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(activity)
        } else {
            true
        }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
            pm?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
        } catch (_: Throwable) {
            false
        }
    }

    private fun requestIgnoreBatteryOptimization(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}")
            )
            activity.startActivity(intent)
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS failed: ${t.message}")
        }
        return openBatterySettings()
    }

    private fun openBatterySettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${activity.packageName}")
            )
            activity.startActivity(intent)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "openBatterySettings failed: ${t.message}")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    activity.startActivity(
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    )
                    true
                } else {
                    false
                }
            } catch (_: Throwable) {
                false
            }
        }
    }

    private fun hasNotificationPermission(): Boolean {
        val mgr = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            mgr?.areNotificationsEnabled() ?: true
        } else {
            true
        }
        if (!enabled) return false
        return if (Build.VERSION.SDK_INT >= 33) {
            appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) {
            val granted = appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4201)
                return true
            }
        }
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                }
            } else {
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")
                )
            }
            activity.startActivity(intent)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "requestNotificationPermission failed: ${t.message}")
            false
        }
    }

    private fun batteryLevelPercent(): Int {
        return try {
            val bm = appContext.getSystemService(BatteryManager::class.java)
            val property = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            if (property in 0..100) {
                property
            } else {
                // Fallback: sticky battery intent
                @Suppress("DEPRECATION")
                val intent = appContext.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                if (intent != null) {
                    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                    if (level >= 0 && scale > 0) level * 100 / scale else -1
                } else {
                    -1
                }
            }
        } catch (t: Throwable) {
            -1
        }
    }

    private fun fallbackStats(): Map<String, Any> = mapOf(
        "fps" to -1.0,
        "cpuTemp" to -1.0,
        "gpuTemp" to -1.0,
        "freeRamMb" to -1.0,
        "cpuUsage" to -1.0,
        "gpuUsage" to -1.0,
        "storageSpeed" to -1.0,
        "refreshRate" to 60.0,
        "batteryCurrentMa" to -1.0,
        "batteryPowerWatts" to -1.0
    )

    companion object {
        const val CHANNEL = "com.zsdev.fpsmonitor/channel"
        private const val TAG = "FpsChannel"
    }
}
