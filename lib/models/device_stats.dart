/// A single snapshot of device/performance statistics.
///
/// Negative values mean "unknown / unavailable on this device".
class DeviceStats {
  /// Frames per second (clamped to the display refresh rate).
  final double fps;

  /// CPU thermal-zone average, Celsius.
  final double cpuTemp;

  /// GPU thermal-zone average, Celsius (falls back to device average).
  final double gpuTemp;

  /// Available RAM in megabytes.
  final double freeRamMb;

  /// CPU total usage 0-100.
  final double cpuUsage;

  /// GPU usage 0-100.
  final double gpuUsage;

  /// Sequential write benchmark, MB/s.
  final double storageSpeed;

  /// Display refresh rate, FPS.
  final double refreshRate;

  /// Instantaneous / average battery current draw in milliamperes (-1 = unknown).
  final double batteryCurrentMa;

  /// Estimated battery power draw in watts (-1 = unknown).
  final double batteryPowerWatts;

  /// When the sample was taken.
  final DateTime timestamp;

  const DeviceStats({
    required this.fps,
    required this.cpuTemp,
    required this.gpuTemp,
    required this.freeRamMb,
    required this.cpuUsage,
    required this.gpuUsage,
    required this.storageSpeed,
    required this.refreshRate,
    this.batteryCurrentMa = -1.0,
    this.batteryPowerWatts = -1.0,
    required this.timestamp,
  });

  factory DeviceStats.fromMap(Map<dynamic, dynamic> map) {
    double num0(String key, [double fallback = -1.0]) {
      final v = map[key];
      if (v is num) return v.toDouble();
      return fallback;
    }

    return DeviceStats(
      fps: num0('fps'),
      cpuTemp: num0('cpuTemp'),
      gpuTemp: num0('gpuTemp'),
      freeRamMb: num0('freeRamMb'),
      cpuUsage: num0('cpuUsage'),
      gpuUsage: num0('gpuUsage'),
      storageSpeed: num0('storageSpeed'),
      refreshRate: num0('refreshRate', 60.0),
      batteryCurrentMa: num0('batteryCurrentMa'),
      batteryPowerWatts: num0('batteryPowerWatts'),
      timestamp: DateTime.now(),
    );
  }

  DeviceStats copyWith({
    double? fps,
    double? cpuTemp,
    double? gpuTemp,
    double? freeRamMb,
    double? cpuUsage,
    double? gpuUsage,
    double? storageSpeed,
    double? refreshRate,
    double? batteryCurrentMa,
    double? batteryPowerWatts,
    DateTime? timestamp,
  }) {
    return DeviceStats(
      fps: fps ?? this.fps,
      cpuTemp: cpuTemp ?? this.cpuTemp,
      gpuTemp: gpuTemp ?? this.gpuTemp,
      freeRamMb: freeRamMb ?? this.freeRamMb,
      cpuUsage: cpuUsage ?? this.cpuUsage,
      gpuUsage: gpuUsage ?? this.gpuUsage,
      storageSpeed: storageSpeed ?? this.storageSpeed,
      refreshRate: refreshRate ?? this.refreshRate,
      batteryCurrentMa: batteryCurrentMa ?? this.batteryCurrentMa,
      batteryPowerWatts: batteryPowerWatts ?? this.batteryPowerWatts,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
