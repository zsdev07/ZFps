import 'package:flutter/services.dart';

import '../models/device_stats.dart';
import '../models/overlay_config.dart';

/// Dart-side facade for the floating overlay window.
///
/// The overlay itself is a native `WindowManager` TYPE_APPLICATION_OVERLAY
/// window rendered by `OverlayService.kt`; this class just forwards calls.
class OverlayService {
  OverlayService._();
  static final OverlayService instance = OverlayService._();

  static const MethodChannel _channel = MethodChannel('com.zsdev.fpsmonitor/channel');

  /// Start/refresh the floating overlay (native side enforces the
  /// SYSTEM_ALERT_WINDOW permission and silently no-ops without it).
  Future<bool> startOverlay() async {
    try {
      return await _channel.invokeMethod<bool>('startOverlay') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopOverlay() async {
    try {
      return await _channel.invokeMethod<bool>('stopOverlay') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Push fresh stats into the overlay window (top-right corner).
  Future<void> updateOverlay(DeviceStats stats, {bool paused = false}) async {
    try {
      await _channel.invokeMethod<bool>('updateOverlay', {
        'fps': stats.fps,
        'cpuTemp': stats.cpuTemp,
        'gpuTemp': stats.gpuTemp,
        'freeRamMb': stats.freeRamMb,
        'cpuUsage': stats.cpuUsage,
        'gpuUsage': stats.gpuUsage,
        'batteryCurrentMa': stats.batteryCurrentMa,
        'batteryPowerWatts': stats.batteryPowerWatts,
        'paused': paused,
      });
    } on PlatformException {
      // Overlay may be gone (user revoked permission); ignore.
    }
  }

  /// Saved overlay look (defaults if nothing was saved yet).
  Future<OverlayConfig> getConfig() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('getOverlayConfig');
      return map == null ? const OverlayConfig() : OverlayConfig.fromMap(map);
    } on PlatformException {
      return const OverlayConfig();
    }
  }

  /// Saves the look and applies it live if the overlay is currently showing.
  Future<void> saveConfig(OverlayConfig config) async {
    try {
      await _channel.invokeMethod<bool>('setOverlayConfig', config.toMap());
    } on PlatformException {
      // ignore: the next save will retry
    }
  }
}
