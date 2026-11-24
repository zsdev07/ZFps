import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../database/app_database.dart';
import '../models/device_info.dart';
import '../models/session.dart';

/// Metadata for an autosaved incremental CSV file kept under `<filesDir>/live_csv/`.
class LiveCsvFileInfo {
  final String path;
  final String fileName;
  final DateTime modified;
  final int sizeBytes;

  const LiveCsvFileInfo({
    required this.path,
    required this.fileName,
    required this.modified,
    required this.sizeBytes,
  });
}

/// Flushes per-poll telemetry rows to persistent flash storage every ~6 s
/// (`flushEveryPolls = 3` at a 2 s poll interval) so a game crash, OOM kill,
/// or forced OS reboot loses at most a few seconds of data.
///
/// If a session ends abnormally without [finishSession], [recoverInterrupted]
/// reads the flushed CSV rows and recovery metadata on next app launch and
/// restores the session into [AppDatabase].
class LiveCsvLogger {
  LiveCsvLogger._();
  static final LiveCsvLogger instance = LiveCsvLogger._();

  static const MethodChannel _channel =
      MethodChannel('com.zsdev.fpsmonitor/channel');

  /// Flush buffered rows to storage every 3 polls (= 6 s, within 5-10 s).
  static const int flushEveryPolls = 3;
  static const int stepSeconds = 2;
  static const int _maxKeptFiles = 12;

  String? _dirPath;
  File? _csvFile;
  File? _metaFile;
  File? _metaTmpFile;

  final List<String> _pendingLines = [];
  Map<String, dynamic>? _meta;
  int _pollsSinceFlush = 0;
  int _flushedRowCount = 0;
  DateTime? _lastFlushAt;
  Future<void> _writeChain = Future<void>.value();

  int get flushedRowCount => _flushedRowCount;
  DateTime? get lastFlushAt => _lastFlushAt;
  String? get activeCsvPath => _csvFile?.path;

  Future<Directory?> _ensureDir() async {
    try {
      var base = _dirPath;
      if (base == null || base.isEmpty) {
        base = await _channel.invokeMethod<String>('getStorageDir');
        _dirPath = base;
      }
      if (base == null || base.isEmpty) return null;
      final dir = Directory('$base/live_csv');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (e) {
      debugPrint('LiveCsvLogger _ensureDir failed: $e');
      return null;
    }
  }

  /// Starts a new live CSV file and writes its UTF-8 BOM + header immediately.
  Future<void> startSession({
    required String sessionId,
    required String appName,
    required String packageName,
    required DateTime startTime,
    required int batteryStart,
    DeviceInfo? deviceInfo,
  }) async {
    await _writeChain;
    _pendingLines.clear();
    _pollsSinceFlush = 0;
    _flushedRowCount = 0;
    _lastFlushAt = null;
    _csvFile = null;
    _meta = null;

    final dir = await _ensureDir();
    if (dir == null) return;

    final baseName = _buildFileName(appName, startTime);
    var csvFile = File('${dir.path}/$baseName.csv');
    if (await csvFile.exists()) {
      csvFile = File('${dir.path}/${baseName}_${sessionId.substring(0, sessionId.length.clamp(0, 6).toInt())}.csv');
    }
    _csvFile = csvFile;
    _metaFile = File('${dir.path}/active_session.json');
    _metaTmpFile = File('${dir.path}/active_session.json.tmp');

    final model = deviceInfo?.deviceModel ?? '';
    final soc = deviceInfo?.socName ?? '';
    final ramText = (deviceInfo != null && deviceInfo.totalRamMb > 0)
        ? DeviceInfo.formatRamDetailed(deviceInfo.totalRamMb)
        : '';

    final header = StringBuffer()
      ..writeln(_row(['device_model', model]))
      ..writeln(_row(['chipset', soc]))
      ..writeln(_row(['total_ram', ramText]))
      ..writeln(_row(['app', appName]))
      ..writeln(_row(['package', packageName]))
      ..writeln(_row(['start_time_local', _ts(startTime)]))
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

    _meta = <String, dynamic>{
      'id': sessionId,
      'appName': appName,
      'packageName': packageName,
      'startTimeMs': startTime.millisecondsSinceEpoch,
      'lastTimeMs': startTime.millisecondsSinceEpoch,
      'csvPath': csvFile.path,
      'batteryStart': batteryStart,
      'batteryLast': batteryStart,
      'fpsStartPoll': null,
      'realFrameData': false,
      'excludedSamples': 0,
      'pausedSeconds': 0,
      'deviceModel': deviceInfo?.deviceModel,
      'socName': deviceInfo?.socName,
      'totalRamMb': deviceInfo?.totalRamMb,
      'frameHist': <int>[],
    };

    _enqueue(() async {
      final sink = csvFile.openWrite(mode: FileMode.write, encoding: utf8);
      sink.write('\uFEFF${header.toString()}');
      await sink.flush();
      await sink.close();
      await _writeMetaAtomic();
      _lastFlushAt = DateTime.now();
    });
    await _writeChain;
  }

  /// Buffers one 2 s poll row and flushes to storage every [flushEveryPolls]
  /// polls (~6 seconds).
  void appendPollRow({
    required int pollIndex0,
    required double fps,
    required double lowFps,
    required double stabilityPct,
    required double cpuTemp,
    required double gpuTemp,
    required double freeRamMb,
    required double cpuUsage,
    required double gpuUsage,
    required double storageSpeed,
    required double batteryCurrentMa,
    required double powerWatts,
    required int? fpsStartPoll,
    required bool realFrameData,
    required int excludedSamples,
    required int pausedSeconds,
    required int batteryLast,
    required List<int> frameHist,
  }) {
    if (_csvFile == null || _meta == null) return;

    _pendingLines.add(_row([
      pollIndex0 + 1,
      pollIndex0 * stepSeconds,
      _n(fps),
      _n(lowFps),
      _n(stabilityPct),
      _n(cpuTemp),
      _n(gpuTemp),
      _n(freeRamMb, 0),
      _n(cpuUsage),
      _n(gpuUsage),
      _n(storageSpeed),
      _n(batteryCurrentMa, 0),
      _n(powerWatts, 2),
    ]));

    _meta!['lastTimeMs'] = DateTime.now().millisecondsSinceEpoch;
    _meta!['fpsStartPoll'] = fpsStartPoll;
    _meta!['realFrameData'] = realFrameData;
    _meta!['excludedSamples'] = excludedSamples;
    _meta!['pausedSeconds'] = pausedSeconds;
    if (batteryLast >= 0) {
      _meta!['batteryLast'] = batteryLast;
    }
    if (realFrameData) {
      _meta!['frameHist'] = List<int>.of(frameHist);
    }

    _pollsSinceFlush++;
    if (_pollsSinceFlush >= flushEveryPolls) {
      _pollsSinceFlush = 0;
      flushNow();
    }
  }

  /// Forces an immediate incremental flush of all buffered rows and metadata.
  Future<void> flushNow() {
    final csv = _csvFile;
    if (csv == null) return _writeChain;
    if (_pendingLines.isEmpty && _meta == null) return _writeChain;

    final lines = List<String>.of(_pendingLines);
    _pendingLines.clear();
    _pollsSinceFlush = 0;

    return _enqueue(() async {
      if (lines.isNotEmpty) {
        final sink = csv.openWrite(mode: FileMode.append, encoding: utf8);
        for (final line in lines) {
          sink.writeln(line);
        }
        await sink.flush();
        await sink.close();
        _flushedRowCount += lines.length;
      }
      await _writeMetaAtomic();
      _lastFlushAt = DateTime.now();
    });
  }

  /// Flushes remaining rows, removes the crash-recovery marker, and prunes
  /// old autosaved CSVs.
  Future<void> finishSession() async {
    await flushNow();
    await _enqueue(() async {
      await _deleteRecoveryMeta();
      await _pruneOldCsvs();
    });
    _csvFile = null;
    _meta = null;
    _pendingLines.clear();
    _pollsSinceFlush = 0;
  }

  /// Checks at app startup whether a previous session ended abnormally (e.g.
  /// game crash or forced reboot) and reconstructs it into [AppDatabase]
  /// from the flushed CSV + metadata.
  Future<Session?> recoverInterrupted() async {
    try {
      final dir = await _ensureDir();
      if (dir == null) return null;
      final metaFile = File('${dir.path}/active_session.json');
      if (!await metaFile.exists()) return null;

      final rawMeta = await metaFile.readAsString();
      final decoded = jsonDecode(rawMeta);
      if (decoded is! Map<String, dynamic>) {
        await _deleteRecoveryFiles(dir);
        return null;
      }

      final csvPath = decoded['csvPath'] as String?;
      if (csvPath == null || csvPath.isEmpty) {
        await _deleteRecoveryFiles(dir);
        return null;
      }
      final csvFile = File(csvPath);
      if (!await csvFile.exists()) {
        await _deleteRecoveryFiles(dir);
        return null;
      }

      final session = await _parseSessionFromCsv(csvFile, decoded);
      await _deleteRecoveryFiles(dir);
      if (session == null) return null;

      await AppDatabase.instance.saveSession(session);
      await _pruneOldCsvs();
      return session;
    } catch (e) {
      debugPrint('Interrupted session recovery failed: $e');
      return null;
    }
  }

  /// Lists autosaved incremental CSV files on disk, newest first.
  Future<List<LiveCsvFileInfo>> listAutosavedCsvs() async {
    final dir = await _ensureDir();
    if (dir == null) return const [];
    final out = <LiveCsvFileInfo>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.csv')) {
        try {
          final stat = await entity.stat();
          final name = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : entity.path.split('/').last;
          out.add(LiveCsvFileInfo(
            path: entity.path,
            fileName: name,
            modified: stat.modified,
            sizeBytes: stat.size,
          ));
        } catch (_) {}
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<bool> deleteAutosavedCsv(String path) async {
    try {
      if (_csvFile?.path == path) return false;
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------- internals

  Future<void> _enqueue(Future<void> Function() task) {
    _writeChain = _writeChain.then((_) async {
      try {
        await task();
      } catch (e) {
        debugPrint('LiveCsvLogger I/O error: $e');
      }
    });
    return _writeChain;
  }

  Future<void> _writeMetaAtomic() async {
    final meta = _meta;
    final metaFile = _metaFile;
    final tmpFile = _metaTmpFile;
    if (meta == null || metaFile == null || tmpFile == null) return;
    await tmpFile.writeAsString(jsonEncode(meta), flush: true);
    await tmpFile.rename(metaFile.path);
  }

  Future<void> _deleteRecoveryMeta() async {
    try {
      if (_metaFile != null && await _metaFile!.exists()) {
        await _metaFile!.delete();
      }
      if (_metaTmpFile != null && await _metaTmpFile!.exists()) {
        await _metaTmpFile!.delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteRecoveryFiles(Directory dir) async {
    try {
      final meta = File('${dir.path}/active_session.json');
      if (await meta.exists()) await meta.delete();
      final tmp = File('${dir.path}/active_session.json.tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  Future<void> _pruneOldCsvs() async {
    final files = await listAutosavedCsvs();
    if (files.length <= _maxKeptFiles) return;
    for (var i = _maxKeptFiles; i < files.length; i++) {
      await deleteAutosavedCsv(files[i].path);
    }
  }

  Future<Session?> _parseSessionFromCsv(
    File csvFile,
    Map<String, dynamic> meta,
  ) async {
    var content = await csvFile.readAsString(encoding: utf8);
    if (content.startsWith('\uFEFF')) {
      content = content.substring(1);
    }
    final lines = const LineSplitter().convert(content);
    var headerIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('sample,time_s,')) {
        headerIdx = i;
        break;
      }
    }
    if (headerIdx < 0) return null;

    final rawFps = <double>[];
    final rawLow = <double>[];
    final rawStability = <double>[];
    final cpuTemps = <double>[];
    final gpuTemps = <double>[];
    final freeRams = <double>[];
    final cpuUsages = <double>[];
    final gpuUsages = <double>[];
    final storageSpeeds = <double>[];
    final currents = <double>[];
    final watts = <double>[];

    double col(List<String> cells, int idx) {
      if (idx >= cells.length) return -1.0;
      final s = cells[idx].trim();
      if (s.isEmpty) return -1.0;
      return double.tryParse(s) ?? -1.0;
    }

    for (var i = headerIdx + 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final cells = _parseCsvLine(line);
      if (cells.length < 3) continue;
      rawFps.add(col(cells, 2));
      rawLow.add(col(cells, 3));
      rawStability.add(col(cells, 4));
      cpuTemps.add(col(cells, 5));
      gpuTemps.add(col(cells, 6));
      freeRams.add(col(cells, 7));
      cpuUsages.add(col(cells, 8));
      gpuUsages.add(col(cells, 9));
      storageSpeeds.add(col(cells, 10));
      currents.add(col(cells, 11));
      watts.add(col(cells, 12));
    }

    final totalRows = cpuTemps.length;
    if (totalRows == 0) return null;

    final realFrameData = meta['realFrameData'] == true;
    var fpsStartPoll = (meta['fpsStartPoll'] as num?)?.toInt() ?? 0;
    if (fpsStartPoll < 0 || fpsStartPoll >= totalRows) fpsStartPoll = 0;

    List<double> fpsOut;
    List<double>? lowOut;
    List<double>? stabilityOut;

    if (realFrameData) {
      final subFps = rawFps.sublist(fpsStartPoll);
      final subLow = rawLow.sublist(fpsStartPoll);
      final subStab = rawStability.sublist(fpsStartPoll);
      var trimStart = 0;
      var trimEnd = subFps.length;
      while (trimStart < trimEnd && subFps[trimStart] <= 0) {
        trimStart++;
      }
      while (trimEnd > trimStart && subFps[trimEnd - 1] <= 0) {
        trimEnd--;
      }
      fpsOut = subFps.sublist(trimStart, trimEnd);
      lowOut = subLow.sublist(trimStart, trimEnd);
      stabilityOut = subStab.sublist(trimStart, trimEnd);
      fpsStartPoll += trimStart;
    } else {
      fpsOut = rawFps.where((e) => e >= 0).toList();
      lowOut = null;
      stabilityOut = null;
    }

    final startMs = (meta['startTimeMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final lastMs = (meta['lastTimeMs'] as num?)?.toInt() ??
        (startMs + totalRows * stepSeconds * 1000);
    final batStart = (meta['batteryStart'] as num?)?.toInt() ?? -1;
    final batLast = (meta['batteryLast'] as num?)?.toInt() ?? -1;
    final batteryDrop = (batStart >= 0 && batLast >= 0 && batStart >= batLast)
        ? (batStart - batLast).toDouble()
        : 0.0;

    final histRaw = meta['frameHist'];
    final frameHist = (realFrameData && histRaw is List && histRaw.isNotEmpty)
        ? histRaw.whereType<num>().map((e) => e.toInt()).toList()
        : null;

    return Session(
      id: (meta['id'] as String?) ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      appName: (meta['appName'] as String?) ?? 'Recovered Session',
      packageName: (meta['packageName'] as String?) ?? '',
      startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
      endTime: DateTime.fromMillisecondsSinceEpoch(lastMs),
      fpsSamples: fpsOut,
      cpuTempSamples: cpuTemps,
      gpuTempSamples: gpuTemps,
      freeRamSamples: freeRams,
      cpuUsageSamples: cpuUsages,
      gpuUsageSamples: gpuUsages,
      storageSpeedSamples: storageSpeeds,
      batteryDropPercent: batteryDrop,
      lowFpsSamples: lowOut,
      frameTimeHist: frameHist,
      realFrameData: realFrameData,
      fpsStartPoll: realFrameData ? fpsStartPoll : 0,
      batteryCurrentSamples: currents,
      powerWattsSamples: watts,
      deviceModel: meta['deviceModel'] as String?,
      socName: meta['socName'] as String?,
      totalRamMb: (meta['totalRamMb'] as num?)?.toDouble(),
      excludedSamples: (meta['excludedSamples'] as num?)?.toInt(),
      pausedSeconds: (meta['pausedSeconds'] as num?)?.toInt(),
      stabilitySamples: stabilityOut,
    );
  }

  static List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final cur = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            cur.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cur.write(ch);
        }
      } else {
        if (ch == '"') {
          inQuotes = true;
        } else if (ch == ',') {
          result.add(cur.toString());
          cur.clear();
        } else {
          cur.write(ch);
        }
      }
    }
    result.add(cur.toString());
    return result;
  }

  static String _buildFileName(String appName, DateTime startTime) {
    final t = startTime.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
    var slug = appName
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'session';
    if (slug.length > 40) slug = slug.substring(0, 40);
    return 'FPS-Monitor_${slug}_$stamp';
  }

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

  static String _n(double? v, [int digits = 1]) =>
      (v == null || v < 0) ? '' : v.toStringAsFixed(digits);

  static String _ts(DateTime t) =>
      t.toLocal().toIso8601String().split('.').first;
}
