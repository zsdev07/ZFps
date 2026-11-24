package com.zsdev.fpsmonitor

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.Random
import kotlin.math.abs

/**
 * Collects runtime performance metrics.
 *
 * Sources (in order of preference):
 *  - CPU / GPU temperature ......... kernel thermal zones (/sys/class/thermal) via Shizuku shell
 *  - Free RAM ...................... MemAvailable from /proc/meminfo via shell, ActivityManager fallback
 *  - CPU usage % ................... delta between two /proc/stat samples
 *  - GPU usage % ................... Qualcomm kgsl gpu_busy_percentage, gpubusy ratio, Mali fallback
 *  - FPS ........................... SurfaceFlinger frame timestamps (via shell) clamped to the
 *                                    display refresh rate; falls back to refresh rate when unavailable
 *  - Storage speed ................. app-side sequential write benchmark (no root needed)
 */
class SystemMetrics(private val context: Context) {

    // ---- cached / stateful bits ----
    @Volatile
    private var lastStorageSpeedMbps: Double = -1.0

    private var prevCpuTotal: Long = -1
    private var prevCpuIdle: Long = -1

    @Volatile private var lastHal: Map<Int, List<Double>> = emptyMap()
    @Volatile private var lastHalAt: Long = 0L
    @Volatile private var loggedThermalMiss = false
    @Volatile private var lastGpuSource: String? = null
    @Volatile private var loggedGpuMiss = false

    private companion object {
        const val TAG = "FpsThermal"
        const val GPU_TAG = "FpsGpu"

        // One shell call that prints "tag:value" lines for every GPU node that exists.
        // r() = read a file into one line and echo it with a tag.
        const val GPU_SCRIPT =
            "r() { v=\$(cat \"\$2\" 2>/dev/null | tr '\\n' ' '); [ -n \"\$v\" ] && echo \"\$1:\$v\"; }; " +
                "r kgsl_pct /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage; " +
                "r kgsl_busy /sys/class/kgsl/kgsl-3d0/gpubusy; " +
                "r kgsl_load /sys/class/kgsl/kgsl-3d0/devfreq/gpu_load; " +
                "r gpu_busy /sys/kernel/gpu/gpu_busy; " +
                "r ged /sys/kernel/ged/hal/gpu_utilization; " +
                "r ged /sys/kernel/debug/ged/hal/gpu_utilization; " +
                "r ged /sys/module/ged/parameters/gpu_loading; " +
                "r mali /sys/class/misc/mali0/device/utilization; " +
                "r mali /proc/mali/utilization; " +
                "r mali /sys/devices/platform/mali/utilization; " +
                "for f in /sys/devices/platform/*.mali/utilization " +
                "/sys/devices/platform/soc/*.mali/utilization " +
                "/sys/devices/platform/*.gpu/utilization " +
                "/sys/devices/platform/soc/*.gpu/utilization; do " +
                "[ -e \"\$f\" ] && r mali \"\$f\"; done; " +
                "for f in /sys/class/drm/card*/device/gpu_busy_percent; do " +
                "[ -e \"\$f\" ] && r drm_busy \"\$f\"; done; " +
                "for d in /sys/class/devfreq/*; do " +
                "case \"\$d\" in *bw*|*bus*|*mem*|*ddr*|*l3*) ;; " +
                "*gpu*|*mali*|*kgsl*|*g3d*|*sgpu*|*adreno*|*pvr*|*rogue*|*rgx*|*valhall*) " +
                "r devfreq_load \"\$d/load\"; " +
                "r devfreq_load \"\$d/utilization\"; " +
                "c=\$(cat \"\$d/cur_freq\" 2>/dev/null); " +
                "m=\$(cat \"\$d/max_freq\" 2>/dev/null); " +
                "a=\$(cat \"\$d/available_frequencies\" 2>/dev/null | tr '\\n' ' '); " +
                "[ -n \"\$c\" ] && [ -n \"\$m\" ] && echo \"freq:\$c \$m\"; " +
                "[ -n \"\$c\" ] && [ -n \"\$a\" ] && echo \"freq_avail:\$c \$a\";; esac; done; " +
                "kc=\$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null); " +
                "km=\$(cat /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null); " +
                "ka=\$(cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies 2>/dev/null | tr '\\n' ' '); " +
                "[ -n \"\$kc\" ] && [ -n \"\$km\" ] && echo \"freq:\$kc \$km\"; " +
                "[ -n \"\$kc\" ] && [ -n \"\$ka\" ] && echo \"freq_avail:\$kc \$ka\"; " +
                "gc=\$(cat /sys/kernel/gpu/gpu_clock 2>/dev/null); " +
                "gm=\$(cat /sys/kernel/gpu/gpu_max_clock 2>/dev/null); " +
                "ga=\$(cat /sys/kernel/gpu/gpu_available_frequencies 2>/dev/null | tr '\\n' ' '); " +
                "[ -n \"\$gc\" ] && [ -n \"\$gm\" ] && echo \"freq:\$gc \$gm\"; " +
                "[ -n \"\$gc\" ] && [ -n \"\$ga\" ] && echo \"freq_avail:\$gc \$ga\"; " +
                "gs=\$(cat /proc/gpufreqv2/gpufreq_status 2>/dev/null | tr '\\n' ' '); " +
                "gt=\$(cat /proc/gpufreqv2/gpu_working_opp_table 2>/dev/null | head -n 5 | tr '\\n' ' '); " +
                "[ -n \"\$gs\" ] && [ -n \"\$gt\" ] && echo \"mtk_gpufreq:\$gs|\$gt\"; " +
                "true"
        const val HAL_CACHE_MS = 5000L
        const val HAL_CPU = 0
        const val HAL_GPU = 1
        const val HAL_BATTERY = 2
        const val HAL_SKIN = 3

        val GPU_SENSOR = Regex("gpu|kgsl|gpuss|g3d|mali|adreno")
        val CPU_SENSOR = Regex("cpu|cpuss|acpu|apcpu|cluster|silver|gold|prime|kryo|tsens|soc_|big|little|mtktscpu|mtk-cpu")
        val IGNORED_SENSOR = Regex("batt|bat_|charger|usb|pmic|pm8|pm6|wlan|modem|mdm|quiet|ambient|flash|camera|display|lcd|sdm|nand|ufs|wireless")

        // One shell call: thermal zones + hwmon sensors + Adreno temp ("name=value" lines)
        const val THERMAL_SCRIPT =
            "for z in /sys/class/thermal/thermal_zone*; do " +
                "t=\$(cat \$z/type 2>/dev/null); v=\$(cat \$z/temp 2>/dev/null); " +
                "[ -n \"\$v\" ] && echo \"\$t=\$v\"; done; " +
                "for h in /sys/class/hwmon/hwmon*; do " +
                "n=\$(cat \$h/name 2>/dev/null); v=\$(cat \$h/temp1_input 2>/dev/null); " +
                "[ -n \"\$v\" ] && echo \"hwmon_\$n=\$v\"; done; " +
                "v=\$(cat /sys/class/kgsl/kgsl-3d0/temp 2>/dev/null); " +
                "[ -n \"\$v\" ] && echo \"kgsl_gpu=\$v\"; true"
    }

    // ------------------------------------------------------------------ collect

    fun collect(packageName: String, includeStorage: Boolean, shizuku: ShizukuClient): Map<String, Any> {
        val refreshRate = displayRefreshRate()
        // Real FPS comes from FrameSampler (per-frame timestamps). This value is only
        // the fallback used when frame data is unavailable on the device.
        val fps = refreshRate
        val temps = readThermalTemps(shizuku)
        val freeRam = readFreeRamMb(shizuku)
        val cpuUsage = readCpuUsagePercent(shizuku)
        val gpuUsage = readGpuUsagePercent(shizuku)
        val batteryPower = readBatteryPower(shizuku)

        val storage = if (includeStorage) {
            benchmarkStorageSpeed()
        } else if (lastStorageSpeedMbps > 0) {
            lastStorageSpeedMbps
        } else {
            -1.0
        }

        return mapOf(
            "fps" to fps,
            "cpuTemp" to temps.first,
            "gpuTemp" to temps.second,
            "freeRamMb" to freeRam,
            "cpuUsage" to cpuUsage,
            "gpuUsage" to gpuUsage,
            "storageSpeed" to storage,
            "refreshRate" to refreshRate,
            "batteryCurrentMa" to batteryPower.first,
            "batteryPowerWatts" to batteryPower.second
        )
    }

    // ------------------------------------------------------------------ device info

    fun deviceInfo(shizuku: ShizukuClient): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val prettyMfg = if (manufacturer.isNotEmpty() && manufacturer[0].isLowerCase()) {
            manufacturer[0].uppercaseChar() + manufacturer.substring(1)
        } else {
            manufacturer
        }
        val deviceModel = when {
            model.isEmpty() -> prettyMfg.ifEmpty { "Android Device" }
            prettyMfg.isEmpty() -> model
            model.lowercase().startsWith(prettyMfg.lowercase()) -> model
            else -> "$prettyMfg $model"
        }

        val socName = resolveSocName(shizuku)
        val totalRamMb = readTotalRamMb(shizuku)

        return mapOf(
            "deviceModel" to deviceModel,
            "socName" to socName,
            "totalRamMb" to totalRamMb
        )
    }

    private fun resolveSocName(shizuku: ShizukuClient): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val socModel = Build.SOC_MODEL?.trim()
                ?.takeIf { it.isNotEmpty() && !it.equals("unknown", ignoreCase = true) }
            val socMfg = Build.SOC_MANUFACTURER?.trim()
                ?.takeIf { it.isNotEmpty() && !it.equals("unknown", ignoreCase = true) }
            if (socModel != null) {
                return if (socMfg != null && !socModel.lowercase().contains(socMfg.lowercase())) {
                    "$socMfg $socModel"
                } else {
                    socModel
                }
            }
        }

        try {
            val out = shizuku.runShell(
                "for p in ro.soc.model ro.vendor.qti.soc_name ro.hardware.chipname " +
                    "ro.mediatek.platform ro.board.platform; do " +
                    "v=\$(getprop \$p 2>/dev/null); [ -n \"\$v\" ] && echo \"\$p=\$v\"; done; " +
                    "grep -m1 -i '^Hardware' /proc/cpuinfo 2>/dev/null; true"
            )
            val props = HashMap<String, String>()
            var cpuHardware: String? = null
            out.lineSequence().forEach { line ->
                val trimmed = line.trim()
                if (trimmed.lowercase().startsWith("hardware")) {
                    val idx = trimmed.indexOf(':')
                    if (idx > 0) {
                        val h = trimmed.substring(idx + 1).trim()
                        if (h.isNotEmpty() && !h.equals("unknown", ignoreCase = true)) {
                            cpuHardware = h
                        }
                    }
                } else {
                    val idx = trimmed.indexOf('=')
                    if (idx > 0) {
                        val k = trimmed.substring(0, idx).trim()
                        val v = trimmed.substring(idx + 1).trim()
                        if (v.isNotEmpty() && !v.equals("unknown", ignoreCase = true)) {
                            props[k] = v
                        }
                    }
                }
            }
            for (k in listOf("ro.soc.model", "ro.vendor.qti.soc_name", "ro.hardware.chipname", "ro.mediatek.platform")) {
                props[k]?.let { return it }
            }
            cpuHardware?.let { return it }
            props["ro.board.platform"]?.let { return it }
        } catch (_: Throwable) {
        }

        val hw = Build.HARDWARE?.trim().orEmpty()
        val board = Build.BOARD?.trim().orEmpty()
        return when {
            hw.isNotEmpty() && !hw.equals("qcom", ignoreCase = true) -> hw
            board.isNotEmpty() -> board
            hw.isNotEmpty() -> hw
            else -> "Unknown SoC"
        }
    }

    private fun readTotalRamMb(shizuku: ShizukuClient): Double {
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (am != null) {
                val info = ActivityManager.MemoryInfo()
                am.getMemoryInfo(info)
                if (info.totalMem > 0L) {
                    return info.totalMem / (1024.0 * 1024.0)
                }
            }
        } catch (_: Throwable) {
        }
        try {
            val out = shizuku.runShell("cat /proc/meminfo 2>/dev/null")
            val match = Regex("MemTotal:\\s+(\\d+)\\s+kB").find(out)
            if (match != null) {
                val kb = match.groupValues[1].toDoubleOrNull()
                if (kb != null && kb > 0) return kb / 1024.0
            }
        } catch (_: Throwable) {
        }
        return -1.0
    }

    // ------------------------------------------------------------------ installed apps

    data class InstalledApp(
        val name: String,
        val packageName: String,
        val iconPng: ByteArray
    )

    fun launchableApps(): List<Map<String, Any>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = try {
            pm.queryIntentActivities(intent, 0)
        } catch (t: Throwable) {
            emptyList()
        }
        val iconSizePx = 96
        return resolved
            .mapNotNull { ri ->
                val pkg = ri.activityInfo?.packageName ?: return@mapNotNull null
                if (pkg == context.packageName) return@mapNotNull null
                val label = try {
                    ri.loadLabel(pm)?.toString()?.takeIf { it.isNotBlank() } ?: pkg
                } catch (t: Throwable) {
                    pkg
                }
                val icon = try {
                    drawableToPng(ri.loadIcon(pm), iconSizePx)
                } catch (t: Throwable) {
                    ByteArray(0)
                }
                mapOf(
                    "name" to label,
                    "packageName" to pkg,
                    "icon" to icon
                )
            }
            .sortedBy { (it["name"] as String).lowercase() }
    }

    private fun drawableToPng(drawable: Drawable, sizePx: Int): ByteArray {
        val bitmap = when (drawable) {
            is BitmapDrawable -> drawable.bitmap?.let { Bitmap.createScaledBitmap(it, sizePx, sizePx, true) }
            else -> {
                val bmp = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, sizePx, sizePx)
                drawable.draw(canvas)
                bmp
            }
        } ?: Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)

        val scaled = if (bitmap.width != sizePx || bitmap.height != sizePx) {
            Bitmap.createScaledBitmap(bitmap, sizePx, sizePx, true)
        } else {
            bitmap
        }
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 90, out)
        return out.toByteArray()
    }

    // ------------------------------------------------------------------ FPS

    private fun displayRefreshRate(): Double {
        return try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                ?: return 60.0
            @Suppress("DEPRECATION")
            val rate = wm.defaultDisplay?.refreshRate?.toDouble() ?: 60.0
            if (rate in 20.0..500.0) rate else 60.0
        } catch (t: Throwable) {
            60.0
        }
    }

    // ------------------------------------------------------------------ temperatures

    /**
     * Reads CPU / GPU temperature from several sources, best first:
     *  1. kernel thermal zones, hwmon sensors and kgsl temp (via Shizuku shell)
     *  2. Android thermal HAL (`dumpsys thermalservice`) - works on most phones
     *     where the sysfs files are hidden or use odd units
     *  3. last resort: skin / battery temperature so the UI is never blank
     * Returns Pair(cpuCelsius, gpuCelsius); -1 when unknown.
     */
    private fun readThermalTemps(shizuku: ShizukuClient): Pair<Double, Double> {
        val cpuTemps = mutableListOf<Double>()
        val gpuTemps = mutableListOf<Double>()
        val allTemps = mutableListOf<Double>()

        val zonesOut = try {
            shizuku.runShell(THERMAL_SCRIPT)
        } catch (t: Throwable) {
            ""
        }

        zonesOut.lineSequence().forEach { line ->
            val idx = line.indexOf('=')
            if (idx <= 0) return@forEach
            val type = line.substring(0, idx).trim().lowercase()
            val raw = line.substring(idx + 1).trim().toDoubleOrNull() ?: return@forEach
            val celsius = normalizeCelsius(raw) ?: return@forEach
            if (IGNORED_SENSOR.containsMatchIn(type)) return@forEach
            allTemps.add(celsius)
            when {
                GPU_SENSOR.containsMatchIn(type) -> gpuTemps.add(celsius)
                CPU_SENSOR.containsMatchIn(type) -> cpuTemps.add(celsius)
            }
        }

        // Thermal HAL: only queried when sysfs did not give both values
        val hal = if (cpuTemps.isEmpty() || gpuTemps.isEmpty()) readHalTemps(shizuku) else emptyMap()

        val cpu = cpuTemps.averageOrNull()
            ?: hal[HAL_CPU]?.averageOrNull()
            ?: allTemps.averageOrNull()
            ?: hal[HAL_SKIN]?.averageOrNull()
            ?: hal[HAL_BATTERY]?.averageOrNull()
            ?: batteryTempC()
        val gpu = gpuTemps.averageOrNull()
            ?: hal[HAL_GPU]?.averageOrNull()
            ?: allTemps.averageOrNull()
            ?: hal[HAL_SKIN]?.averageOrNull()
            ?: hal[HAL_BATTERY]?.averageOrNull()
            ?: batteryTempC()

        if (cpu == null && gpu == null && !loggedThermalMiss) {
            loggedThermalMiss = true
            Log.w(TAG, "No temperature source worked. zones output: ${zonesOut.take(300)}")
        }
        return (cpu ?: -1.0) to (gpu ?: -1.0)
    }

    /** Handles milli-degrees (45000), deci-degrees (450) and plain degrees (45). */
    private fun normalizeCelsius(raw: Double): Double? {
        val c = when {
            raw > 1000.0 -> raw / 1000.0
            raw > 150.0 -> raw / 10.0
            else -> raw
        }
        return if (c in 1.0..125.0) c else null
    }

    /** `dumpsys thermalservice` -> map of HAL type id to temperatures (Celsius). */
    private fun readHalTemps(shizuku: ShizukuClient): Map<Int, List<Double>> {
        val now = System.currentTimeMillis()
        if (now - lastHalAt < HAL_CACHE_MS) return lastHal
        val result = mutableMapOf<Int, MutableList<Double>>()
        try {
            val out = shizuku.runShell("dumpsys thermalservice 2>/dev/null")
            Regex("mValue=(-?[0-9.]+),\\s*mType=(\\d+)").findAll(out).forEach { m ->
                val v = m.groupValues[1].toDoubleOrNull() ?: return@forEach
                val type = m.groupValues[2].toIntOrNull() ?: return@forEach
                if (v in 1.0..125.0) result.getOrPut(type) { mutableListOf() }.add(v)
            }
        } catch (_: Throwable) {
        }
        lastHal = result
        lastHalAt = now
        return result
    }

    private fun batteryTempC(): Double? = try {
        val i = context.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val t = i?.getIntExtra("temperature", Int.MIN_VALUE) ?: Int.MIN_VALUE
        if (t != Int.MIN_VALUE && t > 0) t / 10.0 else null
    } catch (_: Throwable) {
        null
    }

    private fun List<Double>.averageOrNull(): Double? = if (isEmpty()) null else average()

    // ------------------------------------------------------------------ RAM

    private fun readFreeRamMb(shizuku: ShizukuClient): Double {
        try {
            val out = shizuku.runShell("cat /proc/meminfo")
            val match = Regex("MemAvailable:\\s+(\\d+)\\s+kB").find(out)
            if (match != null) {
                return match.groupValues[1].toDouble() / 1024.0
            }
        } catch (_: Throwable) {
            // fall through to ActivityManager
        }
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            info.availMem / (1024.0 * 1024.0)
        } catch (t: Throwable) {
            -1.0
        }
    }

    // ------------------------------------------------------------------ CPU / GPU usage

    /** Delta-based CPU usage between two /proc/stat samples. First call returns -1. */
    private fun readCpuUsagePercent(shizuku: ShizukuClient): Double {
        return try {
            val out = shizuku.runShell("cat /proc/stat")
            val firstLine = out.lineSequence().firstOrNull { it.startsWith("cpu ") } ?: return -1.0
            val parts = firstLine.trim().split(Regex("\\s+")).drop(1)
            if (parts.size < 4) return -1.0
            val nums = parts.mapNotNull { it.toLongOrNull() }
            if (nums.size < 4) return -1.0
            val idle = (nums.getOrElse(3) { 0L }) + (nums.getOrElse(4) { 0L }) // idle + iowait
            val total = nums.sum()

            if (prevCpuTotal < 0) {
                prevCpuTotal = total; prevCpuIdle = idle
                return -1.0
            }
            val totalDelta = total - prevCpuTotal
            val idleDelta = idle - prevCpuIdle
            prevCpuTotal = total; prevCpuIdle = idle
            if (totalDelta <= 0) return -1.0
            val usage = 100.0 * (1.0 - idleDelta.toDouble() / totalDelta.toDouble())
            usage.coerceIn(0.0, 100.0)
        } catch (t: Throwable) {
            -1.0
        }
    }

    /**
     * GPU load in percent. One shell call probes the known sysfs nodes for
     * Qualcomm (kgsl), MediaTek (ged), Mali / Exynos and generic devfreq GPUs,
     * then the first usable one wins. If none expose a real load figure it
     * estimates from GPU clock (cur_freq / max_freq). Returns -1 when unknown.
     */
    private fun readGpuUsagePercent(shizuku: ShizukuClient): Double {
        val out = try {
            shizuku.runShell(GPU_SCRIPT)
        } catch (t: Throwable) {
            ""
        }

        val raw = HashMap<String, MutableList<String>>()
        out.lineSequence().forEach { line ->
            val i = line.indexOf(':')
            if (i <= 0) return@forEach
            val tag = line.substring(0, i).trim()
            val value = line.substring(i + 1).trim()
            if (value.isNotEmpty()) raw.getOrPut(tag) { mutableListOf() }.add(value)
        }

        val numRegex = Regex("-?\\d+(?:\\.\\d+)?")
        val pctRegex = Regex("(-?\\d+(?:\\.\\d+)?)\\s*%")

        fun doubles(s: String): List<Double> =
            numRegex.findAll(s).mapNotNull { it.value.toDoubleOrNull() }.toList()

        fun firstPercentValue(s: String): Double? {
            val pctMatch = pctRegex.find(s)?.groupValues?.get(1)?.toDoubleOrNull()
            if (pctMatch != null) return if (pctMatch in 0.0..100.0) pctMatch else null
            val first = doubles(s).firstOrNull() ?: return null
            return if (first in 0.0..100.0) first else null
        }

        fun report(source: String, value: Double): Double {
            if (source != lastGpuSource) {
                lastGpuSource = source
                Log.i(GPU_TAG, "GPU usage source: $source")
            }
            return value.coerceIn(0.0, 100.0)
        }

        // 1) Real load figures, best source first
        for (tag in listOf("kgsl_pct", "kgsl_load", "gpu_busy", "ged", "mali", "drm_busy", "devfreq_load")) {
            val values = raw[tag] ?: continue
            for (v in values) {
                val pct = firstPercentValue(v) ?: continue
                return report(tag, pct)
            }
        }

        // 2) Adreno busy/total counters
        var hasZeroKgslBusy = false
        for (v in raw["kgsl_busy"].orEmpty()) {
            val busy = doubles(v)
            if (busy.size >= 2) {
                if (busy[1] > 0.0 && busy[0] >= 0.0) {
                    return report("kgsl_busy", 100.0 * busy[0] / busy[1])
                } else if (busy[0] == 0.0 && busy[1] == 0.0) {
                    hasZeroKgslBusy = true
                }
            }
        }

        // 3) Estimate from clock speed (cur_freq / max_freq)
        for (v in raw["freq"].orEmpty()) {
            val freq = doubles(v)
            if (freq.size >= 2 && freq[0] >= 0.0 && freq[1] > 0.0) {
                return report("freq-estimate", 100.0 * freq[0] / freq[1])
            }
        }

        // 4) Estimate from cur_freq / max(available_frequencies)
        for (v in raw["freq_avail"].orEmpty()) {
            val freq = doubles(v)
            if (freq.size >= 2 && freq[0] >= 0.0) {
                val maxF = freq.drop(1).maxOrNull() ?: 0.0
                if (maxF > 0.0) {
                    return report("freq-avail-estimate", 100.0 * freq[0] / maxF)
                }
            }
        }

        // 5) MediaTek gpufreqv2 status/table estimate
        for (v in raw["mtk_gpufreq"].orEmpty()) {
            val sep = v.indexOf('|')
            if (sep > 0) {
                val statusPart = v.substring(0, sep)
                val tablePart = v.substring(sep + 1)
                val cur = Regex("cur_freq:\\s*(\\d+)").find(statusPart)?.groupValues?.get(1)?.toDoubleOrNull()
                val maxF = Regex("freq:\\s*(\\d+)").findAll(tablePart)
                    .mapNotNull { it.groupValues[1].toDoubleOrNull() }
                    .maxOrNull()
                if (cur != null && cur >= 0.0 && maxF != null && maxF > 0.0) {
                    return report("mtk-gpufreqv2", 100.0 * cur / maxF)
                }
            }
        }

        if (hasZeroKgslBusy) {
            return report("kgsl_busy-idle", 0.0)
        }

        if (!loggedGpuMiss) {
            loggedGpuMiss = true
            Log.w(GPU_TAG, "No GPU usage source worked. output: ${out.take(300)}")
        }
        return -1.0
    }

    // ------------------------------------------------------------------ battery current / wattage

    private fun readBatteryPower(shizuku: ShizukuClient): Pair<Double, Double> {
        var voltageV = -1.0
        try {
            val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val vRaw = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1
            voltageV = normalizeVolts(vRaw.toDouble())
        } catch (_: Throwable) {
        }

        var currentMa = -1.0
        try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            var raw = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW) ?: Int.MIN_VALUE
            if (raw == Int.MIN_VALUE || raw == 0) {
                val avg = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE) ?: Int.MIN_VALUE
                if (avg != Int.MIN_VALUE && avg != 0) raw = avg
            }
            if (raw != Int.MIN_VALUE && raw != 0) {
                currentMa = normalizeMilliamps(raw.toLong())
            }
        } catch (_: Throwable) {
        }

        if (currentMa < 0 || voltageV < 0) {
            try {
                val out = shizuku.runShell(
                    "c=\$(cat /sys/class/power_supply/battery/current_now 2>/dev/null); " +
                        "[ -z \"\$c\" ] && c=\$(cat /sys/class/power_supply/bms/current_now 2>/dev/null); " +
                        "v=\$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null); " +
                        "[ -n \"\$c\" ] && echo \"c=\$c\"; [ -n \"\$v\" ] && echo \"v=\$v\"; true"
                )
                out.lineSequence().forEach { line ->
                    if (line.startsWith("c=") && currentMa < 0) {
                        val c = line.substring(2).trim().toLongOrNull()
                        if (c != null && c != 0L) currentMa = normalizeMilliamps(c)
                    } else if (line.startsWith("v=") && voltageV < 0) {
                        val v = line.substring(2).trim().toDoubleOrNull()
                        if (v != null && v > 0) voltageV = normalizeVolts(v)
                    }
                }
            } catch (_: Throwable) {
            }
        }

        if (currentMa < 0.1 || currentMa > 30_000.0) currentMa = -1.0
        val watts = if (currentMa >= 0 && voltageV >= 1.0 && voltageV <= 15.0) {
            (currentMa / 1000.0) * voltageV
        } else {
            -1.0
        }
        return currentMa to watts
    }

    private fun normalizeMilliamps(raw: Long): Double {
        val a = abs(raw)
        return if (a >= 25_000L) a / 1000.0 else a.toDouble()
    }

    private fun normalizeVolts(raw: Double): Double = when {
        raw <= 0.0 -> -1.0
        raw > 100_000.0 -> raw / 1_000_000.0
        raw > 100.0 -> raw / 1000.0
        else -> raw
    }

    // ------------------------------------------------------------------ storage speed

    /** Sequential-write benchmark of the app cache dir. Returns MB/s. */
    private fun benchmarkStorageSpeed(): Double {
        return try {
            val file = File(context.cacheDir, ".fps_monitor_bench")
            val block = ByteArray(1024 * 1024)
            Random(12345).nextBytes(block)
            val buffer = ByteBuffer.wrap(block)
            val mebibytes = 16
            val start = System.nanoTime()
            FileOutputStream(file).channel.use { ch ->
                repeat(mebibytes) {
                    buffer.clear()
                    while (buffer.hasRemaining()) {
                        ch.write(buffer)
                    }
                }
                ch.force(true)
            }
            val seconds = (System.nanoTime() - start) / 1_000_000_000.0
            file.delete()
            if (seconds <= 0) return -1.0
            val mbps = mebibytes.toDouble() / seconds
            lastStorageSpeedMbps = mbps
            mbps
        } catch (t: Throwable) {
            lastStorageSpeedMbps = -1.0
            -1.0
        }
    }
}
