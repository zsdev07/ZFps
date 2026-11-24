import 'package:flutter/services.dart';

import '../models/device_info.dart';
import '../models/device_stats.dart';
import '../models/installed_app.dart';

/// Result of `checkShizuku` on the native side.
class ShizukuStatus {
  /// Shizuku manager process is alive.
  final bool running;

  /// Shizuku API version, or -1 when unknown.
  final int version;

  /// True when this app holds the Shizuku permission.
  final bool permissionGranted;

  /// True when the privileged user service is connected and bound.
  final bool bound;

  /// Shizuku server is older than v11.
  final bool preV11;

  const ShizukuStatus({
    required this.running,
    required this.version,
    required this.permissionGranted,
    required this.bound,
    required this.preV11,
  });

  const ShizukuStatus.offline()
      : running = false,
        version = -1,
        permissionGranted = false,
        bound = false,
        preV11 = false;

  factory ShizukuStatus.fromMap(Map<dynamic, dynamic> map) {
    return ShizukuStatus(
      running: map['ping'] == true,
      version: (map['version'] as num?)?.toInt() ?? -1,
      permissionGranted: (map['permission'] as num?)?.toInt() == 0,
      bound: map['bound'] == true,
      preV11: map['preV11'] == true,
    );
  }

  /// Ready to collect privileged stats.
  bool get isOperational => running && permissionGranted && bound;
}

/// New frame times (ms) read from SurfaceFlinger since the previous poll.
class FrameBatch {
  final List<double> frameTimesMs;

  /// False when frame data is unavailable (game not running, no Shizuku, ...).
  final bool valid;

  const FrameBatch({required this.frameTimesMs, required this.valid});

  const FrameBatch.invalid()
      : frameTimesMs = const <double>[],
        valid = false;
}

/// Low-level access to the native channel: Shizuku state, shell commands
/// and per-poll metric collection.
class ShizukuService {
  ShizukuService._();
  static final ShizukuService instance = ShizukuService._();

  static const MethodChannel _channel = MethodChannel('com.zsdev.fpsmonitor/channel');

  DeviceInfo? _cachedDeviceInfo;

  DeviceInfo? get cachedDeviceInfo => _cachedDeviceInfo;

  Future<DeviceInfo?> getDeviceInfo({bool refresh = false}) async {
    if (!refresh && _cachedDeviceInfo != null) return _cachedDeviceInfo;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (res == null) return _cachedDeviceInfo;
      _cachedDeviceInfo = DeviceInfo.fromMap(res);
      return _cachedDeviceInfo;
    } on PlatformException {
      return _cachedDeviceInfo;
    } on MissingPluginException {
      return _cachedDeviceInfo;
    }
  }

  Future<ShizukuStatus> checkShizuku() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('checkShizuku');
      if (res == null) return const ShizukuStatus.offline();
      return ShizukuStatus.fromMap(res);
    } on PlatformException {
      return const ShizukuStatus.offline();
    } on MissingPluginException {
      return const ShizukuStatus.offline();
    }
  }

  /// Requests the Shizuku permission (if needed) and binds the user service.
  /// Binding completes asynchronously; poll [checkShizuku] until `bound`.
  Future<bool> bindShizuku() async {
    try {
      return await _channel.invokeMethod<bool>('bindShizuku') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Run a shell command through the privileged service.
  /// Output lines starting with "ERR:" indicate failure.
  Future<String> runShell(String command) async {
    try {
      return await _channel.invokeMethod<String>('runShell', {'command': command}) ??
          'ERR: empty result';
    } on PlatformException catch (e) {
      return 'ERR: ${e.message}';
    }
  }

  /// Collect one full stats sample. Pass [includeStorage] every ~10 s to
  /// avoid hammering storage with benchmarks.
  Future<DeviceStats> collectStats(String packageName, {bool includeStorage = false}) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('getStats', {
      'packageName': packageName,
      'includeStorage': includeStorage,
    });
    return DeviceStats.fromMap(res ?? const <String, dynamic>{});
  }

  /// Frames presented by [packageName] since the previous call.
  /// Pass [reset] on the first call of a session.
  Future<FrameBatch> pollFrames(String packageName, {bool reset = false}) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getFrames', {
        'packageName': packageName,
        'reset': reset,
      });
      if (res == null) return const FrameBatch.invalid();
      final raw = res['frames'];
      final frames = raw is List
          ? raw.whereType<num>().map((e) => e.toDouble()).toList()
          : <double>[];
      return FrameBatch(frameTimesMs: frames, valid: res['valid'] == true);
    } on PlatformException {
      return const FrameBatch.invalid();
    } on MissingPluginException {
      return const FrameBatch.invalid();
    }
  }

  /// Battery level 0-100, or -1 when unknown.
  Future<int> getBatteryLevel() async {
    try {
      return await _channel.invokeMethod<int>('getBatteryLevel') ?? -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Launchable installed apps with icons, sorted by name.
  Future<List<InstalledApp>> getInstalledApps() async {
    try {
      final res = await _channel.invokeListMethod<dynamic>('getInstalledApps');
      if (res == null) return [];
      return res
          .whereType<Map<dynamic, dynamic>>()
          .map(InstalledApp.fromMap)
          .toList();
    } on PlatformException {
      return [];
    }
  }

  // ---------------------------------------------------------- overlay gate

  Future<bool> checkOverlayPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkOverlayPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's "Display over other apps" system settings page.
  Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  // --------------------------------------------------- battery & alerts

  /// True when the system is not restricting background battery usage for
  /// this app (crucial on OEM ROMs like Funtouch OS when RAM drops < 300 MB).
  Future<bool> isBatteryOptimizationIgnored() async {
    try {
      return await _channel.invokeMethod<bool>('checkBatteryOptimization') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Launches Android's quick "Allow app to always run in background" prompt.
  Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      return await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimization') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens App Info / Battery settings so OEM toggles (e.g. "Unrestricted" /
  /// "Allow high background power consumption") can be configured manually.
  Future<bool> openBatterySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// True when notifications are enabled and POST_NOTIFICATIONS is granted.
  Future<bool> isNotificationPermissionGranted() async {
    try {
      return await _channel.invokeMethod<bool>('checkNotificationPermission') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
