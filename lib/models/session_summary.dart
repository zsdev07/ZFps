import 'dart:math' as math;

import 'session.dart';

/// Read-only view of a [Session] over either the full timeline or a user-trimmed
/// sample range `[trimStart, trimEnd]` (indexed into [Session.fpsSamples]).
class SessionSummary {
  final Session session;
  final int trimStart;
  final int trimEnd;
  final bool isTrimmed;

  const SessionSummary._({
    required this.session,
    required this.trimStart,
    required this.trimEnd,
    required this.isTrimmed,
  });

  factory SessionSummary.fromSession(
    Session session, {
    int? trimStart,
    int? trimEnd,
  }) {
    final n = session.fpsSamples.length;
    if (n < 2 || trimStart == null || trimEnd == null) {
      return SessionSummary._(
        session: session,
        trimStart: 0,
        trimEnd: n > 0 ? n - 1 : 0,
        isTrimmed: false,
      );
    }
    final s = trimStart.clamp(0, n - 1).toInt();
    final e = trimEnd.clamp(s, n - 1).toInt();
    final trimmed = s > 0 || e < n - 1;
    return SessionSummary._(
      session: session,
      trimStart: s,
      trimEnd: e,
      isTrimmed: trimmed,
    );
  }

  List<double> get fpsSamples => isTrimmed
      ? session.fpsSamples.sublist(trimStart, trimEnd + 1)
      : session.fpsSamples;

  List<double> get lowSamples {
    final lows = session.lows;
    if (!isTrimmed || lows.isEmpty) return lows;
    if (trimStart >= lows.length) return const <double>[];
    return lows.sublist(trimStart, math.min(trimEnd + 1, lows.length));
  }

  int get hwStart => (session.fpsStartPoll ?? 0) + trimStart;
  int get hwEnd => (session.fpsStartPoll ?? 0) + trimEnd;

  /// Exact timestamp (seconds from session start) of the first & last sample
  /// in this view, matching CSV `time_s` and graph axis timestamps.
  int get startSeconds => hwStart * 2;
  int get endSeconds => hwEnd * 2;

  List<double> _hwSlice(List<double> xs) {
    if (!isTrimmed) return xs;
    if (xs.isEmpty || hwStart >= xs.length) return const <double>[];
    final s = math.max(0, hwStart);
    final e = math.min(xs.length, hwEnd + 1);
    if (e <= s) return const <double>[];
    return xs.sublist(s, e);
  }

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

  static List<double> _pos(List<double> xs) => xs.where((e) => e > 0).toList();

  double get avgFps => isTrimmed ? _avg(_pos(fpsSamples)) : session.avgFps;
  double get maxFps => isTrimmed ? _max(_pos(fpsSamples)) : session.maxFps;
  double get minFps => isTrimmed ? _min(_pos(fpsSamples)) : session.minFps;

  int get sampleCount => isTrimmed
      ? fpsSamples.where((e) => e >= 0).length
      : session.sampleCount;

  int get excludedCount => isTrimmed
      ? fpsSamples.where((e) => e < 0).length
      : (session.excludedSamples ?? 0);

  Duration get duration {
    if (!isTrimmed) return session.duration;
    // Match exact elapsed time between startSeconds and endSeconds.
    final secs = math.max(0, endSeconds - startSeconds);
    return Duration(seconds: secs);
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

  double? get onePercentLow {
    if (!isTrimmed) return session.onePercentLow;
    if (session.realFrameData != true) return null;
    final valid = lowSamples.where((e) => e > 0).toList()..sort();
    if (valid.length < 3) return null;
    final take = math.max(1, (valid.length * 0.10).ceil());
    var sum = 0.0;
    for (var i = 0; i < take; i++) {
      sum += valid[i];
    }
    return sum / take;
  }

  double? get pointOnePercentLow {
    if (!isTrimmed) return session.pointOnePercentLow;
    if (session.realFrameData != true) return null;
    final valid = lowSamples.where((e) => e > 0).toList()..sort();
    if (valid.length < 5) return null;
    return valid.first;
  }

  double? get avgFrameTimeMs {
    if (!isTrimmed) return session.avgFrameTimeMs;
    final avg = avgFps;
    if (session.realFrameData != true || avg <= 0) return null;
    return 1000.0 / avg;
  }

  double? get stabilityPercent {
    if (!isTrimmed) return session.stabilityPercent;
    final st = session.stabilities;
    if (st.isEmpty || trimStart >= st.length) return null;
    final end = math.min(st.length, trimEnd + 1);
    final counts = session.frameCounts;
    var weightedSum = 0.0;
    var totalWeight = 0;
    var plainSum = 0.0;
    var plainCount = 0;
    for (var i = trimStart; i < end; i++) {
      final v = st[i];
      if (v < 0) continue;
      plainSum += v;
      plainCount++;
      if (i < counts.length && counts[i] > 0) {
        weightedSum += v * counts[i];
        totalWeight += counts[i];
      }
    }
    if (totalWeight > 0) return weightedSum / totalWeight;
    return plainCount > 0 ? plainSum / plainCount : null;
  }

  double get avgCpuTemp {
    final s = _hwSlice(session.cpuTempSamples);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxCpuTemp {
    final s = _hwSlice(session.cpuTempSamples);
    return _hasData(s) ? _max(s) : -1;
  }

  double get avgGpuTemp {
    final s = _hwSlice(session.gpuTempSamples);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxGpuTemp {
    final s = _hwSlice(session.gpuTempSamples);
    return _hasData(s) ? _max(s) : -1;
  }

  double get avgFreeRam {
    final s = _hwSlice(session.freeRamSamples);
    return _hasData(s) ? _avg(s) : 0;
  }

  double get minFreeRam {
    final s = _hwSlice(session.freeRamSamples);
    return _hasData(s) ? _min(s) : -1;
  }

  double get avgCpuUsage {
    final s = _hwSlice(session.cpuUsageSamples);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxCpuUsage {
    final s = _hwSlice(session.cpuUsageSamples);
    return _hasData(s) ? _max(s) : -1;
  }

  double get avgGpuUsage {
    final s = _hwSlice(session.gpuUsageSamples);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxGpuUsage {
    final s = _hwSlice(session.gpuUsageSamples);
    return _hasData(s) ? _max(s) : -1;
  }

  double get avgStorageSpeed {
    final s = _hwSlice(session.storageSpeedSamples);
    return _hasData(s) ? _avg(s) : 0;
  }

  double get avgBatteryCurrentMa {
    final s = _hwSlice(session.batteryCurrents);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxBatteryCurrentMa {
    final s = _hwSlice(session.batteryCurrents);
    return _hasData(s) ? _max(s) : -1;
  }

  double get avgPowerWatts {
    final s = _hwSlice(session.powerWatts);
    return _hasData(s) ? _avg(s) : -1;
  }

  double get maxPowerWatts {
    final s = _hwSlice(session.powerWatts);
    return _hasData(s) ? _max(s) : -1;
  }

  /// Aligns a hardware sample list (indexed from poll 0) onto [Session.fpsSamples].
  List<double> alignToFpsTimeline(List<double> hwSamples) {
    final n = session.fpsSamples.length;
    final offset = session.fpsStartPoll ?? 0;
    return List<double>.generate(n, (j) {
      final idx = offset + j;
      return (idx >= 0 && idx < hwSamples.length) ? hwSamples[idx] : -1.0;
    });
  }
}
