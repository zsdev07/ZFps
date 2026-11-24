package com.zsdev.fpsmonitor

import android.content.Context

/**
 * User-chosen look of the floating overlay. Persisted in SharedPreferences so
 * the overlay service (which has no Flutter engine) can read it directly.
 */
data class OverlayConfig(
    val showFps: Boolean = true,
    val showFpsLabel: Boolean = true,
    val showCpuTemp: Boolean = true,
    val showGpuTemp: Boolean = true,
    val showRam: Boolean = true,
    val showCpuUsage: Boolean = false,
    val showGpuUsage: Boolean = false,
    val showPower: Boolean = false,
    /** 0 = fully transparent, 100 = solid dark card */
    val bgOpacity: Int = 90,
    /** Text size multiplier */
    val textScale: Float = 1.0f
) {

    fun toMap(): Map<String, Any> = mapOf(
        "showFps" to showFps,
        "showFpsLabel" to showFpsLabel,
        "showCpuTemp" to showCpuTemp,
        "showGpuTemp" to showGpuTemp,
        "showRam" to showRam,
        "showCpuUsage" to showCpuUsage,
        "showGpuUsage" to showGpuUsage,
        "showPower" to showPower,
        "bgOpacity" to bgOpacity,
        "textScale" to textScale.toDouble()
    )

    fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("showFps", showFps)
            .putBoolean("showFpsLabel", showFpsLabel)
            .putBoolean("showCpuTemp", showCpuTemp)
            .putBoolean("showGpuTemp", showGpuTemp)
            .putBoolean("showRam", showRam)
            .putBoolean("showCpuUsage", showCpuUsage)
            .putBoolean("showGpuUsage", showGpuUsage)
            .putBoolean("showPower", showPower)
            .putInt("bgOpacity", bgOpacity)
            .putFloat("textScale", textScale)
            .apply()
    }

    companion object {
        private const val PREFS = "overlay_cfg"

        fun load(context: Context): OverlayConfig {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val d = OverlayConfig()
            return OverlayConfig(
                showFps = p.getBoolean("showFps", d.showFps),
                showFpsLabel = p.getBoolean("showFpsLabel", d.showFpsLabel),
                showCpuTemp = p.getBoolean("showCpuTemp", d.showCpuTemp),
                showGpuTemp = p.getBoolean("showGpuTemp", d.showGpuTemp),
                showRam = p.getBoolean("showRam", d.showRam),
                showCpuUsage = p.getBoolean("showCpuUsage", d.showCpuUsage),
                showGpuUsage = p.getBoolean("showGpuUsage", d.showGpuUsage),
                showPower = p.getBoolean("showPower", d.showPower),
                bgOpacity = p.getInt("bgOpacity", d.bgOpacity).coerceIn(0, 100),
                textScale = p.getFloat("textScale", d.textScale).coerceIn(0.6f, 2.0f)
            )
        }

        fun fromMap(map: Map<*, *>): OverlayConfig {
            val d = OverlayConfig()
            fun b(key: String, def: Boolean) = (map[key] as? Boolean) ?: def
            return OverlayConfig(
                showFps = b("showFps", d.showFps),
                showFpsLabel = b("showFpsLabel", d.showFpsLabel),
                showCpuTemp = b("showCpuTemp", d.showCpuTemp),
                showGpuTemp = b("showGpuTemp", d.showGpuTemp),
                showRam = b("showRam", d.showRam),
                showCpuUsage = b("showCpuUsage", d.showCpuUsage),
                showGpuUsage = b("showGpuUsage", d.showGpuUsage),
                showPower = b("showPower", d.showPower),
                bgOpacity = ((map["bgOpacity"] as? Number)?.toInt() ?: d.bgOpacity).coerceIn(0, 100),
                textScale = ((map["textScale"] as? Number)?.toFloat() ?: d.textScale).coerceIn(0.6f, 2.0f)
            )
        }
    }
}
