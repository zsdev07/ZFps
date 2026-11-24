import 'package:flutter/material.dart';

import '../database/app_database.dart';
import '../models/device_info.dart';
import '../models/session.dart';
import '../models/session_summary.dart';
import '../services/export_service.dart';
import '../services/shizuku_service.dart';
import '../utils/csv_export.dart';
import '../utils/format_utils.dart';
import '../widgets/fps_graph.dart';
import '../widgets/report_share.dart';
import 'compare_screen.dart';

enum _OverlayMetric {
  cpuTemp,
  gpuTemp,
  freeRam,
  cpuUsage,
  gpuUsage,
  batteryCurrent,
  powerWatts,
}

/// History of saved sessions with expandable per-session stats.
class ReportScreen extends StatefulWidget {
  /// When set, the session with this id is expanded and highlighted on open.
  final String? focusSessionId;

  const ReportScreen({super.key, this.focusSessionId});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late List<Session> _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = AppDatabase.instance.getSessions();
  }

  void _reload() {
    setState(() => _sessions = AppDatabase.instance.getSessions());
  }

  void _openCompare() {
    if (_sessions.length < 2) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CompareScreen(sessions: _sessions)),
    );
  }

  Future<void> _deleteSession(Session session) async {
    await AppDatabase.instance.deleteSession(session.id);
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted session for ${session.appName}'),
        backgroundColor: const Color(0xFF1F2733),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _exportAll() async {
    final ok = await ExportService.instance.shareBytes(
      CsvExport.allSessions(
        _sessions,
        fallbackDevice: ShizukuService.instance.cachedDeviceInfo,
      ),
      fileName: CsvExport.allSessionsFileName(),
      mimeType: 'text/csv',
      title: 'FPS Monitor - all sessions',
    );
    if (!ok && mounted) _toast('Could not open the share sheet');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1F2733),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161C27),
        title: const Text('Clear all sessions?',
            style: TextStyle(color: Color(0xFFE5E7EB))),
        content: const Text(
          'This permanently deletes every saved performance report.',
          style: TextStyle(color: Color(0xFF8B94A7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8B94A7))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete all', style: TextStyle(color: Color(0xFFF87171))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AppDatabase.instance.clearAll();
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCompare = _sessions.length >= 2;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        foregroundColor: const Color(0xFFE5E7EB),
        elevation: 0,
        title: const Text('Performance reports', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: canCompare
                ? 'Compare two runs'
                : 'Need at least 2 reports to compare',
            icon: Icon(
              Icons.compare_arrows_rounded,
              color: canCompare
                  ? const Color(0xFF4ADE80)
                  : const Color(0xFF4B5568),
            ),
            onPressed: canCompare ? _openCompare : null,
          ),
          if (_sessions.isNotEmpty)
            IconButton(
              tooltip: 'Export all sessions (CSV)',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _exportAll,
            ),
          if (_sessions.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _sessions.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              color: const Color(0xFF4ADE80),
              onRefresh: () async => _reload(),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _sessions.length,
                itemBuilder: (context, index) => _SessionCard(
                  session: _sessions[index],
                  initiallyExpanded: _sessions[index].id == widget.focusSessionId,
                  onDelete: () => _deleteSession(_sessions[index]),
                ),
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFF161C27),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.insights_rounded,
                  size: 44, color: Color(0xFF3A4457)),
            ),
            const SizedBox(height: 18),
            const Text(
              'No sessions yet',
              style: TextStyle(
                color: Color(0xFFE5E7EB),
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Start monitoring a game and your FPS, temperatures,\n'
              'usage and battery reports will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF8B94A7), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionCard extends StatefulWidget {
  final Session session;
  final bool initiallyExpanded;
  final VoidCallback onDelete;

  const _SessionCard({
    required this.session,
    required this.initiallyExpanded,
    required this.onDelete,
  });

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  int? _trimStart;
  int? _trimEnd;
  final Set<_OverlayMetric> _activeMetrics = {};

  @override
  void didUpdateWidget(covariant _SessionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _trimStart = null;
      _trimEnd = null;
      _activeMetrics.clear();
    }
  }

  void _toggleMetric(_OverlayMetric m) {
    setState(() {
      if (!_activeMetrics.add(m)) {
        _activeMetrics.remove(m);
      }
    });
  }

  List<ChartOverlaySeries> _buildOverlays(SessionSummary view) {
    final session = widget.session;
    final list = <ChartOverlaySeries>[];

    void maybeAdd(
      _OverlayMetric m,
      String label,
      String unit,
      Color color,
      List<double> hwSamples,
      double minSpan,
      int decimals,
    ) {
      if (!_activeMetrics.contains(m)) return;
      final aligned = view.alignToFpsTimeline(hwSamples);
      if (aligned.any((e) => e >= 0)) {
        list.add(ChartOverlaySeries(
          label: label,
          unit: unit,
          color: color,
          values: aligned,
          minSpan: minSpan,
          decimals: decimals,
        ));
      }
    }

    maybeAdd(_OverlayMetric.cpuTemp, 'CPU °C', '°C', const Color(0xFFF87171),
        session.cpuTempSamples, 6.0, 1);
    maybeAdd(_OverlayMetric.gpuTemp, 'GPU °C', '°C', const Color(0xFFFB923C),
        session.gpuTempSamples, 6.0, 1);
    maybeAdd(_OverlayMetric.freeRam, 'Free RAM', ' MB', const Color(0xFF34D399),
        session.freeRamSamples, 120.0, 0);
    maybeAdd(_OverlayMetric.cpuUsage, 'CPU %', '%', const Color(0xFF60A5FA),
        session.cpuUsageSamples, 15.0, 0);
    maybeAdd(_OverlayMetric.gpuUsage, 'GPU %', '%', const Color(0xFFE879F9),
        session.gpuUsageSamples, 15.0, 0);
    maybeAdd(_OverlayMetric.batteryCurrent, 'Current', ' mA',
        const Color(0xFFFBBF24), session.batteryCurrents, 150.0, 0);
    maybeAdd(_OverlayMetric.powerWatts, 'Power', ' W', const Color(0xFFF472B6),
        session.powerWatts, 0.6, 2);

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final view = SessionSummary.fromSession(
      session,
      trimStart: _trimStart,
      trimEnd: _trimEnd,
    );
    final fpsColor = view.avgFps >= 50
        ? const Color(0xFF4ADE80)
        : view.avgFps >= 30
            ? const Color(0xFFFBBF24)
            : const Color(0xFFF87171);

    final stability = view.stabilityPercent;
    final stabilityColor = stability == null
        ? const Color(0xFF8B94A7)
        : (stability >= 90
            ? const Color(0xFF4ADE80)
            : (stability >= 75
                ? const Color(0xFFFBBF24)
                : const Color(0xFFF87171)));

    final overlays = _buildOverlays(view);
    final hasGraph = session.fpsSamples.where((e) => e >= 0).length >= 2;
    final startOffsetSec = (session.fpsStartPoll ?? 0) * 2;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161C27),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF232C3D)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Keep the ExpansionTile divider invisible for a cleaner card
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: widget.initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          iconColor: const Color(0xFF8B94A7),
          collapsedIconColor: const Color(0xFF8B94A7),
          title: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: fpsColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                alignment: Alignment.center,
                child: Text(
                  view.avgFps > 0 ? view.avgFps.toStringAsFixed(0) : '--',
                  style: TextStyle(
                    color: fpsColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFE5E7EB),
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${Fmt.dateTime(session.startTime)} • ${view.durationFormatted}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8B94A7)),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Share / export',
                icon: const Icon(Icons.ios_share_rounded,
                    color: Color(0xFF6B7484), size: 21),
                color: const Color(0xFF1F2733),
                onSelected: (value) {
                  if (value == 'image') {
                    showShareReportDialog(context, session, summary: view);
                  } else {
                    _exportSessionCsv(context, session, summary: view);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'image',
                    child: _MenuRow(Icons.image_outlined, 'Share report image'),
                  ),
                  PopupMenuItem(
                    value: 'csv',
                    child: _MenuRow(Icons.table_chart_outlined, 'Export samples (CSV)'),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Delete session',
                icon: const Icon(Icons.delete_outline, color: Color(0xFF6B7484)),
                onPressed: widget.onDelete,
              ),
            ],
          ),
          children: [
            const Divider(color: Color(0xFF232C3D), height: 1),
            const SizedBox(height: 12),
            if (_deviceHeader(session).isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2130),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF232C3D)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.smartphone_rounded,
                        size: 15, color: Color(0xFF8B94A7)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _deviceHeader(session),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFB9C2D0),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (stability != null) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: stabilityColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: stabilityColor.withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.waves_rounded, size: 17, color: stabilityColor),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Frame-time stability (±3 ms target)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFE5E7EB),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${stability.toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 14,
                        color: stabilityColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Avg FPS',
                    value: view.avgFps > 0 ? view.avgFps.toStringAsFixed(0) : '--',
                    accent: fpsColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'Max FPS',
                    value: view.maxFps > 0 ? view.maxFps.toStringAsFixed(0) : '--',
                    accent: const Color(0xFF60A5FA),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'Samples',
                    value: '${view.sampleCount}',
                    accent: const Color(0xFFA78BFA),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Min FPS',
                    value: view.minFps > 0 ? view.minFps.toStringAsFixed(0) : '--',
                    accent: const Color(0xFFF87171),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: '1% Low',
                    value: _fpsOrDash(view.onePercentLow),
                    accent: _zone(view.onePercentLow),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: '0.1% Low',
                    value: _fpsOrDash(view.pointOnePercentLow),
                    accent: _zone(view.pointOnePercentLow),
                  ),
                ),
              ],
            ),
            if (hasGraph) ...[
              const SizedBox(height: 12),
              _GraphCard(
                session: session,
                trimStart: _trimStart,
                trimEnd: _trimEnd,
                overlays: overlays,
                onClearOverlays: _activeMetrics.isEmpty
                    ? null
                    : () => setState(() => _activeMetrics.clear()),
              ),
            ],
            if (session.fpsSamples.length >= 4) ...[
              const SizedBox(height: 10),
              _TrimTimelineCard(
                startOffsetSeconds: startOffsetSec,
                totalSamples: session.fpsSamples.length,
                trimStart: _trimStart ?? 0,
                trimEnd: _trimEnd ?? session.fpsSamples.length - 1,
                onChanged: (s, e) => setState(() {
                  if (s <= 0 && e >= session.fpsSamples.length - 1) {
                    _trimStart = null;
                    _trimEnd = null;
                  } else {
                    _trimStart = s;
                    _trimEnd = e;
                  }
                }),
                onReset: () => setState(() {
                  _trimStart = null;
                  _trimEnd = null;
                }),
              ),
            ],
            if (session.realFrameData == false)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Frame data was not available on this device, so FPS is estimated '
                  'from the screen refresh rate and 1% low can\'t be calculated.',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFF8B94A7), height: 1.35),
                ),
              ),
            const SizedBox(height: 10),
            if (view.avgFrameTimeMs != null)
              _StatLine(
                icon: Icons.timer_outlined,
                label: 'Avg frame time',
                value: '${view.avgFrameTimeMs!.toStringAsFixed(1)} ms',
                accent: const Color(0xFF60A5FA),
              ),
            _StatLine(
              icon: Icons.battery_6_bar_outlined,
              label: 'Battery drop',
              value: '${session.batteryDropPercent.toStringAsFixed(0)}%',
              accent: const Color(0xFFFBBF24),
            ),
            _StatLine(
              icon: Icons.bolt_outlined,
              label: 'Battery current (avg / peak)',
              value:
                  '${Fmt.currentMa(view.avgBatteryCurrentMa)} / ${Fmt.currentMa(view.maxBatteryCurrentMa)}',
              accent: const Color(0xFFFBBF24),
              active: _activeMetrics.contains(_OverlayMetric.batteryCurrent),
              onTap: hasGraph && session.batteryCurrents.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.batteryCurrent)
                  : null,
            ),
            _StatLine(
              icon: Icons.power_outlined,
              label: 'Power draw (avg / peak)',
              value:
                  '${Fmt.watts(view.avgPowerWatts)} / ${Fmt.watts(view.maxPowerWatts)}',
              accent: const Color(0xFFF472B6),
              active: _activeMetrics.contains(_OverlayMetric.powerWatts),
              onTap: hasGraph && session.powerWatts.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.powerWatts)
                  : null,
            ),
            _StatLine(
              icon: Icons.memory_outlined,
              label: 'CPU usage (avg / peak)',
              value:
                  '${Fmt.percent(view.avgCpuUsage)} / ${Fmt.percent(view.maxCpuUsage)}',
              accent: const Color(0xFF60A5FA),
              active: _activeMetrics.contains(_OverlayMetric.cpuUsage),
              onTap: hasGraph && session.cpuUsageSamples.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.cpuUsage)
                  : null,
            ),
            _StatLine(
              icon: Icons.grid_view_outlined,
              label: 'GPU usage (avg / peak)',
              value:
                  '${Fmt.percent(view.avgGpuUsage)} / ${Fmt.percent(view.maxGpuUsage)}',
              accent: const Color(0xFFE879F9),
              active: _activeMetrics.contains(_OverlayMetric.gpuUsage),
              onTap: hasGraph && session.gpuUsageSamples.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.gpuUsage)
                  : null,
            ),
            _StatLine(
              icon: Icons.thermostat_outlined,
              label: 'CPU temperature (avg / peak)',
              value:
                  '${Fmt.temp(view.avgCpuTemp)} / ${Fmt.tempExact(view.maxCpuTemp)}',
              accent: const Color(0xFFF87171),
              active: _activeMetrics.contains(_OverlayMetric.cpuTemp),
              onTap: hasGraph && session.cpuTempSamples.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.cpuTemp)
                  : null,
            ),
            _StatLine(
              icon: Icons.thermostat_outlined,
              label: 'GPU temperature (avg / peak)',
              value:
                  '${Fmt.temp(view.avgGpuTemp)} / ${Fmt.tempExact(view.maxGpuTemp)}',
              accent: const Color(0xFFFB923C),
              active: _activeMetrics.contains(_OverlayMetric.gpuTemp),
              onTap: hasGraph && session.gpuTempSamples.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.gpuTemp)
                  : null,
            ),
            _StatLine(
              icon: Icons.sd_storage_outlined,
              label: 'Storage speed (avg)',
              value: Fmt.speed(view.avgStorageSpeed),
              accent: const Color(0xFF34D399),
            ),
            _StatLine(
              icon: Icons.storage_outlined,
              label: 'Free RAM (avg / lowest)',
              value:
                  '${Fmt.mb(view.avgFreeRam)} / ${Fmt.mb(view.minFreeRam)}',
              accent: const Color(0xFF34D399),
              active: _activeMetrics.contains(_OverlayMetric.freeRam),
              onTap: hasGraph && session.freeRamSamples.any((e) => e >= 0)
                  ? () => _toggleMetric(_OverlayMetric.freeRam)
                  : null,
            ),
            if (view.excludedCount > 0)
              _StatLine(
                icon: Icons.filter_alt_outlined,
                label: 'Loading spikes excluded',
                value: view.excludedCount == 1
                    ? '1 sample'
                    : '${view.excludedCount} samples',
                accent: const Color(0xFF60A5FA),
              ),
            if ((session.pausedSeconds ?? 0) > 0)
              _StatLine(
                icon: Icons.pause_circle_outline,
                label: 'Paused time (excluded)',
                value: Fmt.durationShort(Duration(seconds: session.pausedSeconds!)),
                accent: const Color(0xFFFBBF24),
              ),
            _StatLine(
              icon: Icons.schedule_outlined,
              label: view.isTrimmed ? 'Trimmed duration' : 'Duration',
              value: view.durationFormatted,
              accent: const Color(0xFF8B94A7),
            ),
            const SizedBox(height: 6),
            Text(
              session.packageName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xFF4B5568)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrimTimelineCard extends StatelessWidget {
  final int startOffsetSeconds;
  final int totalSamples;
  final int trimStart;
  final int trimEnd;
  final void Function(int start, int end) onChanged;
  final VoidCallback onReset;

  const _TrimTimelineCard({
    required this.startOffsetSeconds,
    required this.totalSamples,
    required this.trimStart,
    required this.trimEnd,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final isTrimmed = trimStart > 0 || trimEnd < totalSamples - 1;
    final startLabel =
        Fmt.durationHms(Duration(seconds: startOffsetSeconds + trimStart * 2));
    final endLabel =
        Fmt.durationHms(Duration(seconds: startOffsetSeconds + trimEnd * 2));

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2130),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF232C3D)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.content_cut_rounded,
                  size: 15, color: Color(0xFF60A5FA)),
              const SizedBox(width: 7),
              const Text(
                'Trim timeline',
                style: TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$startLabel – $endLabel',
                style: const TextStyle(
                  color: Color(0xFF8B94A7),
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                ),
              ),
              const Spacer(),
              if (isTrimmed)
                GestureDetector(
                  onTap: onReset,
                  child: const Text(
                    'Reset',
                    style: TextStyle(
                      color: Color(0xFF60A5FA),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: RangeSlider(
              values: RangeValues(trimStart.toDouble(), trimEnd.toDouble()),
              min: 0,
              max: (totalSamples - 1).toDouble(),
              divisions: totalSamples - 1,
              activeColor: const Color(0xFF60A5FA),
              inactiveColor: const Color(0xFF2B364A),
              onChanged: (values) {
                var s = values.start.round();
                var e = values.end.round();
                if (e - s < 1) {
                  if (s > 0) {
                    s = e - 1;
                  } else {
                    e = s + 1;
                  }
                }
                onChanged(s, e);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _MiniStat({required this.label, required this.value, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2130),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF232C3D)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF8B94A7)),
          ),
        ],
      ),
    );
  }
}

class _StatLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final bool active;
  final VoidCallback? onTap;

  const _StatLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.symmetric(
        vertical: 5,
        horizontal: onTap != null ? 6 : 0,
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: active
                    ? const Color(0xFFE5E7EB)
                    : const Color(0xFFB9C2D0),
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFE5E7EB),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.show_chart_rounded,
              size: 15,
              color: active ? accent : const Color(0xFF4B5568),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: active ? accent.withOpacity(0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: active
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: accent.withOpacity(0.45)),
                  )
                : null,
            child: content,
          ),
        ),
      ),
    );
  }
}

String _deviceHeader(Session s) {
  final fallback = ShizukuService.instance.cachedDeviceInfo;
  return DeviceInfo.formatSummary(
    s.deviceModel ?? fallback?.deviceModel,
    s.socName ?? fallback?.socName,
    s.totalRamMb ?? fallback?.totalRamMb,
  );
}

String _fpsOrDash(double? v) => v == null ? '--' : v.toStringAsFixed(0);

Color _zone(double? v) => v == null ? const Color(0xFF8B94A7) : fpsZoneColor(v);

/// "FPS over time" card with the interactive graph and optional metric overlays.
class _GraphCard extends StatelessWidget {
  final Session session;
  final int? trimStart;
  final int? trimEnd;
  final List<ChartOverlaySeries> overlays;
  final VoidCallback? onClearOverlays;

  const _GraphCard({
    required this.session,
    this.trimStart,
    this.trimEnd,
    this.overlays = const [],
    this.onClearOverlays,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2130),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF232C3D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'FPS over time',
                style: TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (onClearOverlays != null)
                GestureDetector(
                  onTap: onClearOverlays,
                  child: const Text(
                    'Clear overlays',
                    style: TextStyle(
                      color: Color(0xFF60A5FA),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                const Text(
                  'Tap stats below to overlay',
                  style: TextStyle(
                    color: Color(0xFF6B7484),
                    fontSize: 10,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          FpsGraph(
            fps: session.fpsSamples,
            lows: session.lows,
            startOffset: Duration(seconds: (session.fpsStartPoll ?? 0) * 2),
            trimStart: trimStart,
            trimEnd: trimEnd,
            overlays: overlays,
          ),
        ],
      ),
    );
  }
}

Future<void> _exportSessionCsv(
  BuildContext context,
  Session session, {
  SessionSummary? summary,
}) async {
  final ok = await ExportService.instance.shareBytes(
    CsvExport.sessionSamples(
      session,
      fallbackDevice: ShizukuService.instance.cachedDeviceInfo,
      summary: summary,
    ),
    fileName: '${CsvExport.baseName(session)}.csv',
    mimeType: 'text/csv',
    title: 'FPS samples - ${session.appName}',
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open the share sheet'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 19, color: const Color(0xFF8B94A7)),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Color(0xFFE5E7EB), fontSize: 14)),
      ],
    );
  }
}
