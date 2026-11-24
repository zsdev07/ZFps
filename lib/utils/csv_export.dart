import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/device_info.dart';
import '../models/session.dart';
import '../models/session_summary.dart';
import '../utils/format_utils.dart';

/// Builds CSV exports of saved sessions.
///
/// * [allSessions]    device header + one summary row per session
/// * [sessionSamples] device header + the time series of a single session
///
/// Files are UTF-8 with a BOM so Excel opens game names with any characters.
class CsvExport {
  CsvExport._();

  /// Seconds between two samples (matches MonitorService.pollInterval).
  static const int stepSeconds = 2;

  // ------------------------------------------------------------ public API

  static Uint8List allSessions(
    List<Session> sessions, {
    DeviceInfo? fallbackDevice,
  }) {
    String? headerModel;
    String? headerSoc;
    double? headerRamMb;
    for (final s in sessions) {
      if ((s.deviceModel ?? '').isNotEmpty) {
        headerModel = s.deviceModel;
        headerSoc = s.socName;
        headerRamMb = s.totalRamMb;
        break;
      }
    }
    headerModel ??= fallbackDevice?.deviceModel;
    headerSoc ??= fallbackDevice?.socName;
    headerRamMb ??= fallbackDevice?.totalRamMb;

    final b = StringBuffer();
    if ((headerModel ?? '').isNotEmpty ||
        (headerSoc ?? '').isNotEmpty ||
        (headerRamMb ?? -1) > 0) {
      b
        ..writeln(_row(['device_model', headerModel ?? '']))
        ..writeln(_row(['chipset', headerSoc ?? '']))
        ..writeln(_row([
          'total_ram',
          (headerRamMb != null && headerRamMb > 0)
              ? DeviceInfo.formatRamDetailed(headerRamMb)
              : '',
        ]))
        ..writeln();
    }

    b.writeln(_row([
      'id',
      'app',
      'package',
      'device_model',
      'chipset',
      'total_ram_mb',
      'start_time_local',
      'end_time_local',
      'duration_s',
      'paused_s',
      'avg_fps',
      'min_fps',
      'max_fps',
      'one_percent_low_fps',
      'point1_percent_low_fps',
      'avg_frame_time_ms',
      'stability_pct',
      'avg_cpu_temp_c',
      'peak_cpu_temp_c',
      'avg_gpu_temp_c',
      'peak_gpu_temp_c',
      'avg_cpu_usage_pct',
      'max_cpu_usage_pct',
      'avg_gpu_usage_pct',
      'max_gpu_usage_pct',
      'avg_free_ram_mb',
      'lowest_free_ram_mb',
      'avg_storage_mb_s',
      'battery_drop_pct',
      'avg_battery_current_ma',
      'peak_battery_current_ma',
      'avg_power_w',
      'peak_power_w',
      'excluded_loading_samples',
      'fps_samples',
      'fps_source',
    ]));

    for (final s in sessions) {
      final model = s.deviceModel ?? fallbackDevice?.deviceModel ?? '';
      final soc = s.socName ?? fallbackDevice?.socName ?? '';
      final ramMb = s.totalRamMb ?? fallbackDevice?.totalRamMb;
      b.writeln(_row([
        s.id,
        s.appName,
        s.packageName,
        model,
        soc,
        _n(ramMb, 0),
        _ts(s.startTime),
        _ts(s.endTime),
        s.duration.inSeconds,
        s.pausedSeconds ?? 0,
        _pos(s.avgFps),
        _pos(s.minFps),
        _pos(s.maxFps),
        _n(s.onePercentLow),
        _n(s.pointOnePercentLow),
        _n(s.avgFrameTimeMs, 2),
        _n(s.stabilityPercent),
        _n(s.avgCpuTemp),
        _n(s.maxCpuTemp),
        _n(s.avgGpuTemp),
        _n(s.maxGpuTemp),
        _n(s.avgCpuUsage),
        _n(s.maxCpuUsage),
        _n(s.avgGpuUsage),
        _n(s.maxGpuUsage),
        _pos(s.avgFreeRam, 0),
        _n(s.minFreeRam, 0),
        _pos(s.avgStorageSpeed),
        _n(s.batteryDropPercent, 0),
        _n(s.avgBatteryCurrentMa, 0),
        _n(s.maxBatteryCurrentMa, 0),
        _n(s.avgPowerWatts, 2),
        _n(s.maxPowerWatts, 2),
        s.excludedSamples ?? 0,
        s.sampleCount,
        _source(s),
      ]));
    }
    return _encode(b.toString());
  }

  static Uint8List sessionSamples(
    Session s, {
    DeviceInfo? fallbackDevice,
    SessionSummary? summary,
  }) {
    final model = s.deviceModel ?? fallbackDevice?.deviceModel ?? '';
    final soc = s.socName ?? fallbackDevice?.socName ?? '';
    final ramMb = s.totalRamMb ?? fallbackDevice?.totalRamMb;
    final ramText =
        (ramMb != null && ramMb > 0) ? DeviceInfo.formatRamDetailed(ramMb) : '';

    // FPS samples only start once the game's frames show up; the other metrics
    // are recorded from the first poll, so shift FPS by that offset.
    final start = s.fpsStartPoll ?? 0;
    final lows = s.lows;
    final stabilities = s.stabilities;
    final currents = s.batteryCurrents;
    final watts = s.powerWatts;
    final totalRows = [
      start + s.fpsSamples.length,
      s.cpuTempSamples.length,
      s.gpuTempSamples.length,
      s.freeRamSamples.length,
      s.cpuUsageSamples.length,
      s.gpuUsageSamples.length,
      s.storageSpeedSamples.length,
      currents.length,
      watts.length,
    ].reduce(math.max);

    final trimmed = summary != null && summary.isTrimmed;
    final rowFrom = trimmed ? math.max(0, summary.hwStart) : 0;
    final rowTo = trimmed
        ? math.min(totalRows - 1, summary.hwEnd)
        : (totalRows - 1);

    final effective = summary ?? SessionSummary.fromSession(s);

    final b = StringBuffer()
      ..writeln(_row(['device_model', model]))
      ..writeln(_row(['chipset', soc]))
      ..writeln(_row(['total_ram', ramText]))
      ..writeln(_row(['app', s.appName]))
      ..writeln(_row(['package', s.packageName]))
      ..writeln(_row(['start_time_local', _ts(s.startTime)]))
      ..writeln(_row(['duration_s', effective.duration.inSeconds]))
      ..writeln(_row(['stability_pct', _n(effective.stabilityPercent)]));

    if (trimmed) {
      b.writeln(_row([
        'trimmed_window',
        '${Fmt.durationHms(Duration(seconds: summary.startSeconds))} - '
            '${Fmt.durationHms(Duration(seconds: summary.endSeconds))}',
      ]));
    }

    b
      ..writeln()
      ..writeln(_row([
        'sample',
        'time_s',
        'fps',
        'one_percent_low_fps',
        'stability_pct',
        'cpu_temp_c',
        'gpu_temp_c',
        'free_ram_mb',
        'cpu_usage_pct',
        'gpu_usage_pct',
        'storage_mb_s',
        'battery_current_ma',
        'power_w',
      ]));

    for (var i = rowFrom; i <= rowTo; i++) {
      final j = i - start;
      final hasFps = j >= 0 && j < s.fpsSamples.length;
      b.writeln(_row([
        i + 1,
        i * stepSeconds,
        hasFps ? _n(s.fpsSamples[j]) : '',
        (hasFps && j < lows.length) ? _n(lows[j]) : '',
        (hasFps && j < stabilities.length) ? _n(stabilities[j]) : '',
        _at(s.cpuTempSamples, i),
        _at(s.gpuTempSamples, i),
        _at(s.freeRamSamples, i, 0),
        _at(s.cpuUsageSamples, i),
        _at(s.gpuUsageSamples, i),
        _at(s.storageSpeedSamples, i),
        _at(currents, i, 0),
        _at(watts, i, 2),
      ]));
    }
    return _encode(b.toString());
  }

  /// "FPS-Monitor_<game>_<yyyyMMdd-HHmm>" (no extension) for file names.
  static String baseName(Session s) {
    final t = s.startTime.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
    var slug = s.appName
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'session';
    if (slug.length > 40) slug = slug.substring(0, 40);
    return 'FPS-Monitor_${slug}_$stamp';
  }

  static String allSessionsFileName() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'FPS-Monitor_all-sessions_${t.year}${two(t.month)}${two(t.day)}.csv';
  }

  // ------------------------------------------------------------ helpers

  static Uint8List _encode(String csv) =>
      Uint8List.fromList(utf8.encode('\uFEFF$csv'));

  static String _cell(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    if (s.contains(',') ||
        s.contains('"') ||
        s.contains('\n') ||
        s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String _row(List<Object?> cells) => cells.map(_cell).join(',');

  /// Number with [digits] decimals; empty when unknown (null or negative).
  static String _n(double? v, [int digits = 1]) =>
      (v == null || v < 0) ? '' : v.toStringAsFixed(digits);

  /// Like [_n] but also treats 0 as "no data" (used for averages of empty lists).
  static String _pos(double v, [int digits = 1]) =>
      v > 0 ? v.toStringAsFixed(digits) : '';

  static String _at(List<double> list, int i, [int digits = 1]) =>
      i < list.length ? _n(list[i], digits) : '';

  static String _ts(DateTime t) =>
      t.toLocal().toIso8601String().split('.').first;

  static String _source(Session s) {
    switch (s.realFrameData) {
      case true:
        return 'real_frames';
      case false:
        return 'refresh_rate_estimate';
      default:
        return 'unknown_legacy';
    }
  }
}
