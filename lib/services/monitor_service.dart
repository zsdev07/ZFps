import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../database/app_database.dart';
import '../models/device_info.dart';
import '../models/device_stats.dart';
import '../models/session.dart';
import '../utils/frame_stats.dart';
import 'live_csv_logger.dart';
import 'notification_service.dart';
import 'overlay_service.dart';
import 'shizuku_service.dart';

/// Owns the lifecycle of a monitoring session: start -> poll every 2 s ->
/// stop -> persist a [Session] to Hive -> fire the completion notification.
class MonitorService extends ChangeNotifier {
  MonitorService._();
  static final MonitorService instance = MonitorService._();

  static const Duration pollInterval = Duration(seconds: 2);

  /// Frame timestamps are read more often than the other stats so no frames
  /// are missed on high refresh-rate screens (SurfaceFlinger keeps ~127 frames).
  static const Duration framePollInterval = Duration(milliseconds: 500);

  static const String _settingsBoxName = 'settings';
  static const String _excludeLoadingKey = 'exclude_loading_screens';
  static const String _excludeSub10Key = 'exclude_sub10_fps';

  /// Minimum FPS in a 2 s poll to treat a window as active gameplay rather than
  /// a loading screen / 0 FPS match transition.
  static const double _loadingFpsThreshold = 5.0;

  /// Stricter minimum FPS threshold when "Exclude < 10 FPS Spikes" is enabled.
  static const double _sub10FpsThreshold = 10.0;

  /// Single-frame gaps above this (ms) are loading stalls / pauses, not gameplay.
  static const double _maxGameplayFrameMs = 500.0;

  /// Single-frame gaps above 100 ms correspond to < 10 FPS instantaneous spikes.
  static const double _maxSub10FrameMs = 100.0;

  /// Boundary frames above this (ms) right after a loading screen / pause are
  /// dropped so recovery transitions do not skew 1% / 0.1% lows.
  static const double _recoveryBoundaryFrameMs = 200.0;

  static const MethodChannel _channel =
      MethodChannel('com.zsdev.fpsmonitor/channel');

  Timer? _pollTimer;
  Timer? _frameTimer;
  bool _frameBusy = false;
  bool _frameReset = true;

  /// True once real per-frame data has been read in this session.
  bool _realFrames = false;

  /// Poll index (0-based) at which the first real FPS sample was recorded.
  int? _fpsStartPoll;

  bool _isMonitoring = false;
  bool _isPaused = false;
  bool _excludeLoadingScreens = true;
  bool _excludeSub10Fps = false;
  bool _hasSeenActiveFps = false;
  bool _wasFilteredOrPaused = false;
  int _excludedSamples = 0;

  String? _sessionId;
  String? _appName;
  String? _packageName;
  DateTime? _startTime;
  DateTime? _pauseStartedAt;
  Duration _pausedDuration = Duration.zero;
  DeviceInfo? _sessionDeviceInfo;

  DeviceStats? _current;
  double? _lastStorageSpeed;
  int _pollCount = 0;
  int _batteryStart = -1;
  int _batteryEnd = -1;
  Session? _lastRecoveredSession;

  final List<double> _fpsSamples = [];
  final List<double> _lowSamples = [];
  final List<double> _stabilitySamples = [];
  final List<int> _frameCountSamples = [];

  /// Refresh-rate based FPS, only kept as a fallback if real frame data never arrives.
  final List<double> _fallbackFpsSamples = [];

  /// Frame times collected since the last 2 s poll.
  final List<double> _windowFrames = [];
  List<int> _frameHist = FrameStats.emptyHistogram();
  final List<double> _cpuTempSamples = [];
  final List<double> _gpuTempSamples = [];
  final List<double> _freeRamSamples = [];
  final List<double> _cpuUsageSamples = [];
  final List<double> _gpuUsageSamples = [];
  final List<double> _storageSpeedSamples = [];
  final List<double> _batteryCurrentSamples = [];
  final List<double> _powerWattsSamples = [];

  // -------------------------------------------------------------- getters

  bool get isMonitoring => _isMonitoring;
  bool get isPaused => _isPaused;
  bool get excludeLoadingScreens => _excludeLoadingScreens;
  bool get excludeSub10Fps => _excludeSub10Fps;
  int get excludedSamples => _excludedSamples;
  String? get appName => _appName;
  String? get packageName => _packageName;
  DateTime? get startTime => _startTime;
  DeviceStats? get current => _current;
  int get pollCount => _pollCount;
  int get csvFlushedRows => LiveCsvLogger.instance.flushedRowCount;
  Session? get lastRecoveredSession => _lastRecoveredSession;

  void clearRecoveredNotice() {
    if (_lastRecoveredSession == null) return;
    _lastRecoveredSession = null;
    notifyListeners();
  }

  /// Checks at startup for an unclosed live CSV session from a game crash or
  /// forced OS reboot and restores it into Hive.
  Future<Session?> recoverInterruptedSession() async {
    final recovered = await LiveCsvLogger.instance.recoverInterrupted();
    if (recovered != null) {
      _lastRecoveredSession = recovered;
      notifyListeners();
    }
    return recovered;
  }

  double? get liveStability =>
      _realFrames ? FrameStats.stabilityPercent(_frameHist) : null;

  Duration get elapsed {
    if (_startTime == null) return Duration.zero;
    var total = DateTime.now().difference(_startTime!) - _pausedDuration;
    if (_isPaused && _pauseStartedAt != null) {
      total -= DateTime.now().difference(_pauseStartedAt!);
    }
    return total.isNegative ? Duration.zero : total;
  }

  // -------------------------------------------------------------- settings

  Future<void> loadSettings() async {
    try {
      final box = await Hive.openBox<dynamic>(_settingsBoxName);
      final savedLoading = box.get(_excludeLoadingKey);
      final savedSub10 = box.get(_excludeSub10Key);
      var changed = false;
      if (savedLoading is bool && savedLoading != _excludeLoadingScreens) {
        _excludeLoadingScreens = savedLoading;
        changed = true;
      }
      if (savedSub10 is bool && savedSub10 != _excludeSub10Fps) {
        _excludeSub10Fps = savedSub10;
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  Future<void> setExcludeLoadingScreens(bool value) async {
    if (_excludeLoadingScreens == value) return;
    _excludeLoadingScreens = value;
    notifyListeners();
    try {
      final box = await Hive.openBox<dynamic>(_settingsBoxName);
      await box.put(_excludeLoadingKey, value);
    } catch (e) {
      debugPrint('Failed to save settings: $e');
    }
  }

  Future<void> setExcludeSub10Fps(bool value) async {
    if (_excludeSub10Fps == value) return;
    _excludeSub10Fps = value;
    notifyListeners();
    try {
      final box = await Hive.openBox<dynamic>(_settingsBoxName);
      await box.put(_excludeSub10Key, value);
    } catch (e) {
      debugPrint('Failed to save settings: $e');
    }
  }

  // -------------------------------------------------------------- session

  Future<bool> startSession({
    required String appName,
    required String packageName,
  }) async {
    if (_isMonitoring) return false;

    _resetSamples();
    _batteryStart = await ShizukuService.instance.getBatteryLevel();
    _batteryEnd = -1;
    _sessionDeviceInfo =
        await ShizukuService.instance.getDeviceInfo(refresh: true);
    final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
    _sessionId = sessionId;
    _appName = appName;
    _packageName = packageName;
    _startTime = DateTime.now();
    _pollCount = 0;
    _lastStorageSpeed = null;
    _lastRecoveredSession = null;

    await LiveCsvLogger.instance.startSession(
      sessionId: sessionId,
      appName: appName,
      packageName: packageName,
      startTime: _startTime!,
      batteryStart: _batteryStart,
      deviceInfo: _sessionDeviceInfo ?? ShizukuService.instance.cachedDeviceInfo,
    );

    // High-priority foreground service (keeps process alive) + floating overlay
    await _invokeBool('startMonitoring', {'appName': appName});

    _isMonitoring = true;
    notifyListeners();

    // First frame read + stats poll immediately (also warms up the storage
    // benchmark), then frames every 0.5 s and the other stats every 2 s
    await _pollFrames();
    await _poll();
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(framePollInterval, (_) => _pollFrames());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
    return true;
  }

  Future<void> pauseSession() async {
    if (!_isMonitoring || _isPaused) return;
    _isPaused = true;
    _pauseStartedAt = DateTime.now();
    _windowFrames.clear();
    notifyListeners();
    await LiveCsvLogger.instance.flushNow();
    final cur = _current;
    if (cur != null) {
      await OverlayService.instance.updateOverlay(cur, paused: true);
      await _updatePersistentNotification(cur, paused: true);
    }
  }

  Future<void> resumeSession() async {
    if (!_isMonitoring || !_isPaused) return;
    if (_pauseStartedAt != null) {
      _pausedDuration += DateTime.now().difference(_pauseStartedAt!);
      _pauseStartedAt = null;
    }
    _isPaused = false;
    _frameReset = true;
    _wasFilteredOrPaused = true;
    _windowFrames.clear();
    notifyListeners();
    await _pollFrames();
    await _poll();
  }

  Future<Session?> stopSession() async {
    if (!_isMonitoring) return null;

    _pollTimer?.cancel();
    _pollTimer = null;
    _frameTimer?.cancel();
    _frameTimer = null;

    if (_isPaused && _pauseStartedAt != null) {
      _pausedDuration += DateTime.now().difference(_pauseStartedAt!);
      _pauseStartedAt = null;
    } else if (!_isPaused) {
      // One final sample + battery reading when active
      await _pollFrames();
      await _poll();
    }

    _batteryEnd = await ShizukuService.instance.getBatteryLevel();
    await _invokeBool('stopMonitoring', const {});

    final batteryDrop =
        (_batteryStart >= 0 && _batteryEnd >= 0 && _batteryStart >= _batteryEnd)
            ? (_batteryStart - _batteryEnd).toDouble()
            : 0.0;

    // Auto-trim leading/trailing blank, 0 FPS, or filtered loading windows:
    // that is the game downloading maps/loading or the user leaving to tap Stop.
    var trimStart = 0;
    var trimEnd = _fpsSamples.length;
    if (_realFrames) {
      while (trimStart < trimEnd && _fpsSamples[trimStart] <= 0) {
        trimStart++;
      }
      while (trimEnd > trimStart && _fpsSamples[trimEnd - 1] <= 0) {
        trimEnd--;
      }
    }
    final fpsOut = _realFrames
        ? _fpsSamples.sublist(trimStart, trimEnd)
        : List<double>.of(_fallbackFpsSamples);
    final lowOut = _realFrames ? _lowSamples.sublist(trimStart, trimEnd) : null;
    final stabilityOut =
        _realFrames ? _stabilitySamples.sublist(trimStart, trimEnd) : null;
    final countOut =
        _realFrames ? _frameCountSamples.sublist(trimStart, trimEnd) : null;

    final info = _sessionDeviceInfo ?? ShizukuService.instance.cachedDeviceInfo;
    final pausedSecs = _pausedDuration.inSeconds;

    final session = Session(
      id: _sessionId ?? DateTime.now().microsecondsSinceEpoch.toString(),
      appName: _appName ?? 'Unknown',
      packageName: _packageName ?? '',
      startTime: _startTime ?? DateTime.now(),
      endTime: DateTime.now(),
      fpsSamples: fpsOut,
      cpuTempSamples: List<double>.of(_cpuTempSamples),
      gpuTempSamples: List<double>.of(_gpuTempSamples),
      freeRamSamples: List<double>.of(_freeRamSamples),
      cpuUsageSamples: List<double>.of(_cpuUsageSamples),
      gpuUsageSamples: List<double>.of(_gpuUsageSamples),
      storageSpeedSamples: List<double>.of(_storageSpeedSamples),
      batteryDropPercent: batteryDrop,
      lowFpsSamples: lowOut,
      frameTimeHist: _realFrames ? List<int>.of(_frameHist) : null,
      realFrameData: _realFrames,
      fpsStartPoll: _realFrames ? (_fpsStartPoll ?? 0) + trimStart : 0,
      batteryCurrentSamples: List<double>.of(_batteryCurrentSamples),
      powerWattsSamples: List<double>.of(_powerWattsSamples),
      deviceModel: info?.deviceModel,
      socName: info?.socName,
      totalRamMb: info?.totalRamMb,
      excludedSamples: _excludedSamples,
      pausedSeconds: pausedSecs,
      stabilitySamples: stabilityOut,
      frameCountSamples: countOut,
    );

    try {
      await AppDatabase.instance.saveSession(session);
    } catch (e) {
      debugPrint('Failed to persist session: $e');
    }

    await LiveCsvLogger.instance.finishSession();
    await NotificationService.instance.showSessionComplete(session);

    _isMonitoring = false;
    _isPaused = false;
    _startTime = null;
    _sessionId = null;
    notifyListeners();
    return session;
  }

  // ------------------------------------------------------------ polling

  Future<void> _poll() async {
    if (_isPaused) return;
    final pkg = _packageName;
    if (pkg == null) return;
    _pollCount++;

    // Benchmark storage only on the first sample and then every 5th (~10 s)
    final includeStorage = _pollCount == 1 || _pollCount % 5 == 0;

    try {
      final stats = await ShizukuService.instance
          .collectStats(pkg, includeStorage: includeStorage);

      if (stats.storageSpeed >= 0) {
        _lastStorageSpeed = stats.storageSpeed;
      }
      final merged = (_lastStorageSpeed != null && stats.storageSpeed < 0)
          ? stats.copyWith(storageSpeed: _lastStorageSpeed)
          : stats;

      // Frames collected since the previous poll -> real FPS + 1% low + stability
      final window = List<double>.of(_windowFrames);
      _windowFrames.clear();

      var stats0 = merged;
      double? low;
      double? stability;
      var frameCount = 0;
      double? fpsOverride;

      if (_realFrames) {
        var frames = window;
        final filterLoading = _excludeLoadingScreens;
        final filterSub10 = _excludeSub10Fps;
        final filterAny = filterLoading || filterSub10;

        if (filterAny) {
          final maxFrameMs =
              filterSub10 ? _maxSub10FrameMs : _maxGameplayFrameMs;
          final boundaryMs =
              filterSub10 ? _maxSub10FrameMs : _recoveryBoundaryFrameMs;
          frames = frames.where((ms) => ms <= maxFrameMs).toList();
          if (_wasFilteredOrPaused) {
            var skip = 0;
            while (skip < frames.length && frames[skip] > boundaryMs) {
              skip++;
            }
            if (skip > 0) frames = frames.sublist(skip);
          }
        }

        final measuredFps = FrameStats.fpsOf(frames);
        final minFps = filterSub10
            ? _sub10FpsThreshold
            : (filterLoading ? _loadingFpsThreshold : 0.0);
        final isFilteredWindow = filterAny &&
            (measuredFps == null || measuredFps < minFps);

        if (isFilteredWindow) {
          if (_hasSeenActiveFps) {
            _excludedSamples++;
          }
          _wasFilteredOrPaused = true;
          stats0 = merged.copyWith(fps: measuredFps ?? 0.0);
          fpsOverride = -1.0;
          low = -1.0;
          stability = -1.0;
          frameCount = 0;
        } else {
          _hasSeenActiveFps = true;
          _wasFilteredOrPaused = false;
          if (frames.isNotEmpty) {
            FrameStats.addAll(_frameHist, frames);
          }
          stats0 = merged.copyWith(fps: measuredFps ?? 0.0);
          low = FrameStats.lowFpsOfList(frames, 0.01);
          stability = FrameStats.stabilityOfList(frames);
          frameCount = frames.length;
        }
      } else {
        final filterSub10 = _excludeSub10Fps;
        final filterLoading = _excludeLoadingScreens;
        final minFps = filterSub10 ? _sub10FpsThreshold : 0.0;
        if ((filterLoading || filterSub10) && merged.fps <= minFps) {
          if (_hasSeenActiveFps) {
            _excludedSamples++;
          }
          fpsOverride = -1.0;
        } else if (merged.fps > 0) {
          _hasSeenActiveFps = true;
        }
      }

      _current = stats0;
      _record(
        stats0,
        real: _realFrames,
        fpsOverride: fpsOverride,
        low: low,
        stability: stability,
        frameCount: frameCount,
      );

      final batNow = (_pollCount % 5 == 0)
          ? await ShizukuService.instance.getBatteryLevel()
          : -1;
      if (batNow >= 0) _batteryEnd = batNow;

      LiveCsvLogger.instance.appendPollRow(
        pollIndex0: _pollCount - 1,
        fps: fpsOverride ?? stats0.fps,
        lowFps: low ?? -1.0,
        stabilityPct: stability ?? -1.0,
        cpuTemp: stats0.cpuTemp,
        gpuTemp: stats0.gpuTemp,
        freeRamMb: stats0.freeRamMb,
        cpuUsage: stats0.cpuUsage,
        gpuUsage: stats0.gpuUsage,
        storageSpeed: stats0.storageSpeed,
        batteryCurrentMa: stats0.batteryCurrentMa,
        powerWatts: stats0.batteryPowerWatts,
        fpsStartPoll: _fpsStartPoll,
        realFrameData: _realFrames,
        excludedSamples: _excludedSamples,
        pausedSeconds: _pausedDuration.inSeconds,
        batteryLast: _batteryEnd,
        frameHist: _frameHist,
      );

      await OverlayService.instance.updateOverlay(stats0, paused: _isPaused);
      await _updatePersistentNotification(stats0, paused: _isPaused);
    } catch (e) {
      debugPrint('Poll failed: $e');
    }
    notifyListeners();
  }

  Future<void> _pollFrames() async {
    if (_isPaused) return;
    final pkg = _packageName;
    if (pkg == null || _frameBusy) return;
    _frameBusy = true;
    try {
      final reset = _frameReset;
      _frameReset = false;
      final batch = await ShizukuService.instance.pollFrames(pkg, reset: reset);
      if (batch.valid) {
        _realFrames = true;
        if (batch.frameTimesMs.isNotEmpty) {
          _windowFrames.addAll(batch.frameTimesMs);
        }
      }
    } catch (e) {
      debugPrint('Frame poll failed: $e');
    } finally {
      _frameBusy = false;
    }
  }

  void _record(
    DeviceStats s, {
    required bool real,
    double? fpsOverride,
    double? low,
    double? stability,
    int frameCount = 0,
  }) {
    final recordedFps = fpsOverride ?? s.fps;
    if (real) {
      _fpsStartPoll ??= _pollCount - 1;
      _fpsSamples.add(recordedFps);
      _lowSamples.add(low ?? -1.0); // keeps lists aligned
      _stabilitySamples.add(stability ?? -1.0);
      _frameCountSamples.add(frameCount);
    } else if (recordedFps >= 0) {
      _fallbackFpsSamples.add(recordedFps);
    }

    // Keep all per-poll metric lists aligned to the 2 s poll timeline (-1 = unknown)
    _cpuTempSamples.add(s.cpuTemp);
    _gpuTempSamples.add(s.gpuTemp);
    _freeRamSamples.add(s.freeRamMb);
    _cpuUsageSamples.add(s.cpuUsage);
    _gpuUsageSamples.add(s.gpuUsage);
    _storageSpeedSamples.add(s.storageSpeed);
    _batteryCurrentSamples.add(s.batteryCurrentMa);
    _powerWattsSamples.add(s.batteryPowerWatts);
  }

  void _resetSamples() {
    _fpsSamples.clear();
    _lowSamples.clear();
    _stabilitySamples.clear();
    _frameCountSamples.clear();
    _fallbackFpsSamples.clear();
    _windowFrames.clear();
    _frameHist = FrameStats.emptyHistogram();
    _frameReset = true;
    _frameBusy = false;
    _realFrames = false;
    _fpsStartPoll = null;
    _isPaused = false;
    _pauseStartedAt = null;
    _pausedDuration = Duration.zero;
    _hasSeenActiveFps = false;
    _wasFilteredOrPaused = false;
    _excludedSamples = 0;
    _cpuTempSamples.clear();
    _gpuTempSamples.clear();
    _freeRamSamples.clear();
    _cpuUsageSamples.clear();
    _gpuUsageSamples.clear();
    _storageSpeedSamples.clear();
    _batteryCurrentSamples.clear();
    _powerWattsSamples.clear();
    _current = null;
  }

  Future<void> _updatePersistentNotification(
    DeviceStats s, {
    required bool paused,
  }) async {
    await _invokeBool('updateNotification', {
      'fps': s.fps,
      'cpuTemp': s.cpuTemp,
      'freeRamMb': s.freeRamMb,
      'elapsedSeconds': elapsed.inSeconds,
      'paused': paused,
    });
  }

  Future<bool> _invokeBool(String method, Map<String, dynamic> args) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
