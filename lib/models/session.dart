import 'package:hive/hive.dart';

import '../utils/frame_stats.dart';

part 'session.g.dart';

/// A completed (or in-progress) monitoring session, persisted with Hive.
@HiveType(typeId: 1)
class Session extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String appName;

  @HiveField(2)
  String packageName;

  @HiveField(3)
  DateTime startTime;

  @HiveField(4)
  DateTime endTime;

  @HiveField(5)
  List<double> fpsSamples;

  @HiveField(6)
  List<double> cpuTempSamples;

  @HiveField(7)
  List<double> gpuTempSamples;

  @HiveField(8)
  List<double> freeRamSamples;

  @HiveField(9)
  List<double> cpuUsageSamples;

  @HiveField(10)
  List<double> gpuUsageSamples;

  @HiveField(11)
  List<double> storageSpeedSamples;

  /// Battery percentage points drained over the session (can be 0).
  @HiveField(12)
  double batteryDropPercent;

  /// Per-poll "1% low" FPS, same length as [fpsSamples] (-1 = unknown).
  /// Null for sessions recorded before frame-time stats existed.
  @HiveField(13)
  List<double>? lowFpsSamples;

  /// Frame-time histogram (see [FrameStats]). Null for older sessions.
  @HiveField(14)
  List<int>? frameTimeHist;

  /// True when FPS came from real per-frame timestamps; false when it was only
  /// estimated from the display refresh rate; null for older sessions.
  @HiveField(15)
  bool? realFrameData;

  /// How many 2 s polls had passed when the first FPS sample was recorded.
  /// Lets exports line FPS up with the other metrics. Null for older sessions.
  @HiveField(16)
  int? fpsStartPoll;

  /// Per-poll battery current draw in mA (-1 = unknown). Null for older sessions.
  @HiveField(17)
  List<double>? batteryCurrentSamples;

  /// Per-poll battery power draw in Watts (-1 = unknown). Null for older sessions.
  @HiveField(18)
  List<double>? powerWattsSamples;

  /// Device model (e.g. "Samsung SM-S918B"). Null for older sessions.
  @HiveField(19)
  String? deviceModel;

  /// Device chipset / SoC name (e.g. "Qualcomm SM8550"). Null for older sessions.
  @HiveField(20)
  String? socName;

  /// Total device RAM in MB. Null for older sessions.
  @HiveField(21)
  double? totalRamMb;

  /// Number of loading-screen / 0 FPS polls filtered out during the session.
  @HiveField(22)
  int? excludedSamples;

  /// Total seconds manually paused during the session.
  @HiveField(23)
  int? pausedSeconds;

  /// Per-poll frame-time stability score 0-100 (-1 = unknown), aligned to [fpsSamples].
  @HiveField(24)
  List<double>? stabilitySamples;

  /// Number of valid frames in each poll, aligned to [fpsSamples].
  @HiveField(25)
  List<int>? frameCountSamples;

  Session({
    required this.id,
    required this.appName,
    required this.packageName,
    required this.startTime,
    required this.endTime,
    required this.fpsSamples,
    required this.cpuTempSamples,
    required this.gpuTempSamples,
    required this.freeRamSamples,
    required this.cpuUsageSamples,
    required this.gpuUsageSamples,
    required this.storageSpeedSamples,
    required this.batteryDropPercent,
    this.lowFpsSamples,
    this.frameTimeHist,
    this.realFrameData,
    this.fpsStartPoll,
    this.batteryCurrentSamples,
    this.powerWattsSamples,
    this.deviceModel,
    this.socName,
    this.totalRamMb,
    this.excludedSamples,
    this.pausedSeconds,
    this.stabilitySamples,
    this.frameCountSamples,
  });

  // ------------------------------------------------------------ durations

  Duration get duration {
    final raw = endTime.difference(startTime);
    final paused = pausedSeconds ?? 0;
    if (paused <= 0) return raw;
    final active = raw - Duration(seconds: paused);
    return active.isNegative ? Duration.zero : active;
  }

  String get durationFormatted {
    final d = duration;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    }
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  // ------------------------------------------------------- averages (≥ 0)

  static bool _hasData(List<double> xs) => xs.any((e) => e >= 0);

  static double _avg(List<double> xs) {
    final valid = xs.where((e) => e >= 0).toList();
    if (valid.isEmpty) return 0;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  static double _max(List<double> xs) {
    final valid = xs.where((e) => e >= 0).toList();
    if (valid.isEmpty) return 0;
    return valid.reduce((a, b) => a > b ? a : b);
  }

  static double _min(List<double> xs) {
    final valid = xs.where((e) => e >= 0).toList();
    if (valid.isEmpty) return 0;
    return valid.reduce((a, b) => a < b ? a : b);
  }

  // Idle windows (0 FPS: loading screens, paused game, app in background) are
  // not performance data, so FPS stats only use samples above zero.
  static List<double> _pos(List<double> xs) => xs.where((e) => e > 0).toList();

  double get avgFps => _avg(_pos(fpsSamples));
  double get maxFps => _max(_pos(fpsSamples));
  double get minFps => _min(_pos(fpsSamples));

  // -1 = no data (Fmt.temp shows "--" instead of a misleading 0°C)
  double get avgCpuTemp => _hasData(cpuTempSamples) ? _avg(cpuTempSamples) : -1;
  double get maxCpuTemp => _hasData(cpuTempSamples) ? _max(cpuTempSamples) : -1;
  double get avgGpuTemp => _hasData(gpuTempSamples) ? _avg(gpuTempSamples) : -1;
  double get maxGpuTemp => _hasData(gpuTempSamples) ? _max(gpuTempSamples) : -1;
  double get avgFreeRam => _avg(freeRamSamples);
  double get minFreeRam => _hasData(freeRamSamples) ? _min(freeRamSamples) : -1;

  double get avgCpuUsage => _hasData(cpuUsageSamples) ? _avg(cpuUsageSamples) : -1;
  double get maxCpuUsage => _hasData(cpuUsageSamples) ? _max(cpuUsageSamples) : -1;

  double get avgGpuUsage => _hasData(gpuUsageSamples) ? _avg(gpuUsageSamples) : -1;
  double get maxGpuUsage => _hasData(gpuUsageSamples) ? _max(gpuUsageSamples) : -1;

  double get avgStorageSpeed => _avg(storageSpeedSamples);

  List<double> get batteryCurrents => batteryCurrentSamples ?? const <double>[];
  List<double> get powerWatts => powerWattsSamples ?? const <double>[];

  double get avgBatteryCurrentMa =>
      _hasData(batteryCurrents) ? _avg(batteryCurrents) : -1;
  double get maxBatteryCurrentMa =>
      _hasData(batteryCurrents) ? _max(batteryCurrents) : -1;

  double get avgPowerWatts => _hasData(powerWatts) ? _avg(powerWatts) : -1;
  double get maxPowerWatts => _hasData(powerWatts) ? _max(powerWatts) : -1;

  int get sampleCount => fpsSamples.where((e) => e >= 0).length;

  // ------------------------------------------------------- frame-time stats

  List<double> get lows => lowFpsSamples ?? const <double>[];

  /// True when this session has usable frame-time data.
  bool get hasFrameData =>
      realFrameData == true &&
      frameTimeHist != null &&
      FrameStats.totalFrames(frameTimeHist!) >= 30;

  /// FPS equivalent of the slowest 1% of frames (null when unavailable).
  double? get onePercentLow =>
      hasFrameData ? FrameStats.lowFps(frameTimeHist!, 0.01) : null;

  /// FPS equivalent of the slowest 0.1% of frames (null when unavailable).
  double? get pointOnePercentLow =>
      hasFrameData ? FrameStats.lowFps(frameTimeHist!, 0.001) : null;

  /// Average frame time in milliseconds (null when unavailable).
  double? get avgFrameTimeMs =>
      hasFrameData ? FrameStats.avgFrameMs(frameTimeHist!) : null;

  /// Percentage of frames within +/- 3 ms of target frame pacing (null when unavailable).
  double? get stabilityPercent {
    if (hasFrameData) {
      return FrameStats.stabilityPercent(frameTimeHist!);
    }
    final list = stabilitySamples;
    if (list == null) return null;
    final valid = list.where((e) => e >= 0).toList();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  List<double> get stabilities => stabilitySamples ?? const <double>[];
  List<int> get frameCounts => frameCountSamples ?? const <int>[];
}
