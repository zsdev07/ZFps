package com.zsdev.fpsmonitor

import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.TypedValue
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Draws the floating statistics window (top-right by default).
 *
 *  - The window can be dragged anywhere; its position is remembered.
 *  - Its content and look (which stats, background opacity, text size) come
 *    from [OverlayConfig], editable from the app's Customize screen and applied live.
 *
 * Regular (non-foreground) service: [MonitorService] keeps the process alive.
 */
@SuppressLint("SetTextI18n")
class OverlayService : Service() {

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var fpsText: TextView? = null
    private var tempText: TextView? = null
    private var usageText: TextView? = null
    private var ramText: TextView? = null
    private var powerText: TextView? = null

    private var config = OverlayConfig()

    // Latest values, so a config change can re-render immediately
    private var fps = -1.0
    private var cpuTemp = -1.0
    private var gpuTemp = -1.0
    private var freeRam = -1.0
    private var cpuUsage = -1.0
    private var gpuUsage = -1.0
    private var batteryCurrentMa = -1.0
    private var batteryPowerWatts = -1.0
    private var paused = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> showOverlay()
            ACTION_UPDATE -> {
                readValues(intent)
                render()
            }
            ACTION_CONFIG -> {
                if (overlayView == null) {
                    stopSelf()
                } else {
                    config = OverlayConfig.load(this)
                    applyConfig()
                    render()
                }
            }
            ACTION_STOP -> stopAndRemove()
        }
        return START_NOT_STICKY
    }

    // ------------------------------------------------------------- window

    private fun showOverlay() {
        if (overlayView != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !android.provider.Settings.canDrawOverlays(this)) {
            return
        }
        try {
            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            val view = LayoutInflater.from(this).inflate(R.layout.overlay_stats, null)
            fpsText = view.findViewById(R.id.fps_text)
            tempText = view.findViewById(R.id.temp_text)
            usageText = view.findViewById(R.id.usage_text)
            ramText = view.findViewById(R.id.ram_text)
            powerText = view.findViewById(R.id.power_text)

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            ).apply {
                // x is measured from the right edge (Gravity.END), y from the top
                gravity = Gravity.TOP or Gravity.END
                val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
                x = prefs.getInt(KEY_X, dp(12))
                y = prefs.getInt(KEY_Y, dp(96))
            }

            config = OverlayConfig.load(this)
            overlayView = view
            windowManager = wm
            applyConfig()
            render()
            enableDragging(view, wm, params)
            wm.addView(view, params)
        } catch (t: Throwable) {
            // Never crash the process because of the overlay; monitoring continues in-app.
            t.printStackTrace()
            overlayView = null
            stopSelf()
        }
    }

    /** Lets the user drag the overlay anywhere; position is saved when released. */
    @SuppressLint("ClickableViewAccessibility")
    private fun enableDragging(view: View, wm: WindowManager, params: WindowManager.LayoutParams) {
        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var dragging = false

        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = event.rawX
                    touchY = event.rawY
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (!dragging && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                        dragging = true
                    }
                    if (dragging) {
                        val dm = resources.displayMetrics
                        val maxX = (dm.widthPixels - v.width).coerceAtLeast(0)
                        val maxY = (dm.heightPixels - v.height).coerceAtLeast(0)
                        // Gravity.END: moving the finger right decreases x
                        params.x = (startX - dx).coerceIn(0, maxX)
                        params.y = (startY + dy).coerceIn(0, maxY)
                        try {
                            wm.updateViewLayout(v, params)
                        } catch (_: Throwable) {
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) savePosition(params.x, params.y) else v.performClick()
                    dragging = false
                    true
                }
                else -> false
            }
        }
    }

    private fun savePosition(x: Int, y: Int) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putInt(KEY_X, x)
            .putInt(KEY_Y, y)
            .apply()
    }

    // ------------------------------------------------------------- look & content

    private fun hasOtherLines(c: OverlayConfig) =
        c.showCpuTemp || c.showGpuTemp || c.showRam || c.showCpuUsage || c.showGpuUsage || c.showPower

    /** FPS is forced on if the user switched everything off, so the bar is never empty. */
    private fun fpsVisible(c: OverlayConfig) = c.showFps || !hasOtherLines(c)

    /** Applies sizes, background, padding and visibility from [config]. */
    private fun applyConfig() {
        val view = overlayView ?: return
        val c = config
        val otherLines = hasOtherLines(c)
        val showFps = fpsVisible(c)
        val onlyFps = showFps && !otherLines
        val transparent = c.bgOpacity <= 0
        val scale = c.textScale.coerceIn(0.6f, 2.0f)

        // Background: none when transparent, otherwise dark rounded card with the chosen opacity
        if (transparent) {
            view.background = null
        } else {
            val alpha = c.bgOpacity.coerceIn(0, 100) * 255 / 100
            view.background = GradientDrawable().apply {
                setColor(Color.argb(alpha, 0x12, 0x16, 0x1D))
                cornerRadius = dp(14).toFloat()
                setStroke(dp(1), Color.argb(alpha * 3 / 4, 0x3A, 0x44, 0x57))
            }
        }

        val padH = if (transparent) dp(6) else dp(14)
        val padV = if (transparent) dp(2) else dp(8)
        view.setPadding(padH, padV, padH, padV)
        // Keep a comfortable touch target for dragging even when only a tiny number is shown
        view.minimumWidth = if (transparent || onlyFps) dp(48) else dp(132)
        view.minimumHeight = dp(40)
        (view as? LinearLayout)?.gravity = if (onlyFps) Gravity.CENTER_HORIZONTAL else Gravity.START

        // Text sizes
        fpsText?.setTextSize(TypedValue.COMPLEX_UNIT_SP, (if (onlyFps) 28f else 21f) * scale)
        listOf(tempText, usageText, ramText, powerText).forEach {
            it?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f * scale)
        }

        // Soft shadow so transparent / faint bars stay readable on bright game scenes
        val shadowRadius = if (c.bgOpacity < 40) dp(3).toFloat() else 0f
        listOf(fpsText, tempText, usageText, ramText, powerText).forEach {
            it?.setShadowLayer(shadowRadius, 0f, 1f, Color.BLACK)
        }

        // Which lines are visible
        fpsText?.visibility = if (showFps) View.VISIBLE else View.GONE
        tempText?.visibility = if (c.showCpuTemp || c.showGpuTemp) View.VISIBLE else View.GONE
        usageText?.visibility = if (c.showCpuUsage || c.showGpuUsage) View.VISIBLE else View.GONE
        ramText?.visibility = if (c.showRam) View.VISIBLE else View.GONE
        powerText?.visibility = if (c.showPower) View.VISIBLE else View.GONE
    }

    private fun readValues(intent: Intent) {
        fps = intent.getDoubleExtra(EXTRA_FPS, -1.0)
        cpuTemp = intent.getDoubleExtra(EXTRA_CPU_TEMP, -1.0)
        gpuTemp = intent.getDoubleExtra(EXTRA_GPU_TEMP, -1.0)
        freeRam = intent.getDoubleExtra(EXTRA_FREE_RAM, -1.0)
        cpuUsage = intent.getDoubleExtra(EXTRA_CPU_USAGE, -1.0)
        gpuUsage = intent.getDoubleExtra(EXTRA_GPU_USAGE, -1.0)
        batteryCurrentMa = intent.getDoubleExtra(EXTRA_CURRENT_MA, -1.0)
        batteryPowerWatts = intent.getDoubleExtra(EXTRA_POWER_WATTS, -1.0)
        paused = intent.getBooleanExtra(EXTRA_PAUSED, false)
    }

    /** Writes the latest values into the visible lines. */
    private fun render() {
        val c = config

        if (paused) {
            fpsText?.text = "PAUSED"
            fpsText?.setTextColor(0xFFFBBF24.toInt())
        } else {
            val fpsValue = if (fps >= 0) "${fps.toInt()}" else "--"
            // The "FPS" label is optional; the lone-number look reads best without it
            fpsText?.text = if (c.showFpsLabel) "$fpsValue FPS" else fpsValue
            fpsText?.setTextColor(fpsColor(fps))
        }

        val temps = mutableListOf<String>()
        if (c.showCpuTemp) temps.add("CPU ${fmtTemp(cpuTemp)}")
        if (c.showGpuTemp) temps.add("GPU ${fmtTemp(gpuTemp)}")
        tempText?.text = temps.joinToString("  ")

        val usage = mutableListOf<String>()
        if (c.showCpuUsage) usage.add("CPU ${fmtPercent(cpuUsage)}")
        if (c.showGpuUsage) usage.add("GPU ${fmtPercent(gpuUsage)}")
        usageText?.text = usage.joinToString("  ")

        ramText?.text = if (freeRam >= 0) "RAM ${freeRam.toInt()} MB free" else "RAM -- MB free"

        val maText = if (batteryCurrentMa >= 0) "${"%.0f".format(batteryCurrentMa)} mA" else "-- mA"
        val wText = if (batteryPowerWatts >= 0) "${"%.2f".format(batteryPowerWatts)} W" else "-- W"
        powerText?.text = "$maText  $wText"
    }

    /** 55+ green (60, 90, 120...), 30-54 yellow, below 30 red. */
    private fun fpsColor(v: Double): Int = when {
        v < 0 -> 0xFFE5E7EB.toInt()
        v >= 55 -> 0xFF4ADE80.toInt()
        v >= 30 -> 0xFFFBBF24.toInt()
        else -> 0xFFF87171.toInt()
    }

    private fun stopAndRemove() {
        try {
            overlayView?.let { windowManager?.removeView(it) }
        } catch (_: Throwable) {
        }
        overlayView = null
        fpsText = null
        tempText = null
        usageText = null
        ramText = null
        powerText = null
        stopSelf()
    }

    override fun onDestroy() {
        // Best-effort cleanup
        try {
            overlayView?.let { windowManager?.removeView(it) }
        } catch (_: Throwable) {
        }
        overlayView = null
        super.onDestroy()
    }

    // ------------------------------------------------------------- helpers

    private fun fmtTemp(v: Double): String =
        if (v >= 0) "${"%.0f".format(v)}°" else "--°"

    private fun fmtPercent(v: Double): String =
        if (v >= 0) "${"%.0f".format(v)}%" else "--%"

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    companion object {
        const val NOTIFICATION_ID = 4101

        private const val PREFS = "overlay_prefs"
        private const val KEY_X = "pos_x"
        private const val KEY_Y = "pos_y"

        const val ACTION_START = "com.zsdev.fpsmonitor.overlay.START"
        const val ACTION_UPDATE = "com.zsdev.fpsmonitor.overlay.UPDATE"
        const val ACTION_STOP = "com.zsdev.fpsmonitor.overlay.STOP"
        const val ACTION_CONFIG = "com.zsdev.fpsmonitor.overlay.CONFIG"

        const val EXTRA_FPS = "fps"
        const val EXTRA_CPU_TEMP = "cpuTemp"
        const val EXTRA_GPU_TEMP = "gpuTemp"
        const val EXTRA_FREE_RAM = "freeRamMb"
        const val EXTRA_CPU_USAGE = "cpuUsage"
        const val EXTRA_GPU_USAGE = "gpuUsage"
        const val EXTRA_CURRENT_MA = "batteryCurrentMa"
        const val EXTRA_POWER_WATTS = "batteryPowerWatts"
        const val EXTRA_PAUSED = "paused"

        fun start(context: Context) {
            val intent = Intent(context, OverlayService::class.java).setAction(ACTION_START)
            context.startService(intent)
        }

        fun update(
            context: Context,
            fps: Double,
            cpuTemp: Double,
            gpuTemp: Double,
            freeRamMb: Double,
            cpuUsage: Double = -1.0,
            gpuUsage: Double = -1.0,
            batteryCurrentMa: Double = -1.0,
            batteryPowerWatts: Double = -1.0,
            paused: Boolean = false
        ) {
            val intent = Intent(context, OverlayService::class.java)
                .setAction(ACTION_UPDATE)
                .putExtra(EXTRA_FPS, fps)
                .putExtra(EXTRA_CPU_TEMP, cpuTemp)
                .putExtra(EXTRA_GPU_TEMP, gpuTemp)
                .putExtra(EXTRA_FREE_RAM, freeRamMb)
                .putExtra(EXTRA_CPU_USAGE, cpuUsage)
                .putExtra(EXTRA_GPU_USAGE, gpuUsage)
                .putExtra(EXTRA_CURRENT_MA, batteryCurrentMa)
                .putExtra(EXTRA_POWER_WATTS, batteryPowerWatts)
                .putExtra(EXTRA_PAUSED, paused)
            context.startService(intent)
        }

        /** Tells a running overlay to re-read the saved [OverlayConfig]. */
        fun reloadConfig(context: Context) {
            val intent = Intent(context, OverlayService::class.java).setAction(ACTION_CONFIG)
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, OverlayService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
