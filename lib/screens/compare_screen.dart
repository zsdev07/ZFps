import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/device_info.dart';
import '../models/session.dart';
import '../services/export_service.dart';
import '../services/shizuku_service.dart';
import '../utils/format_utils.dart';
import '../widgets/fps_graph.dart';

const Color _bg = Color(0xFF0D1117);
const Color _card = Color(0xFF161C27);
const Color _cardAlt = Color(0xFF111826);
const Color _border = Color(0xFF232C3D);
const Color _green = Color(0xFF4ADE80);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _blue = Color(0xFF60A5FA);
const Color _text = Color(0xFFE5E7EB);
const Color _dim = Color(0xFF8B94A7);

enum _Polarity { higherBetter, lowerBetter, neutral }

/// Side-by-side comparison of two saved performance sessions (Run A vs Run B).
class CompareScreen extends StatefulWidget {
  final List<Session> sessions;

  const CompareScreen({super.key, required this.sessions});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final GlobalKey _captureKey = GlobalKey();
  late int _indexA;
  late int _indexB;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _indexB = 0;
    _indexA = widget.sessions.length > 1 ? 1 : 0;
  }

  Session get _runA => widget.sessions[_indexA];
  Session get _runB => widget.sessions[_indexB];

  void _swap() {
    setState(() {
      final tmp = _indexA;
      _indexA = _indexB;
      _indexB = tmp;
    });
  }

  Future<void> _pickRun({required bool isA}) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Text(
                      isA ? 'Select Run A (baseline)' : 'Select Run B (compare)',
                      style: const TextStyle(
                        color: _text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: _border, height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.sessions.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: _border, height: 1),
                  itemBuilder: (_, i) {
                    final s = widget.sessions[i];
                    final selected = i == (isA ? _indexA : _indexB);
                    return ListTile(
                      onTap: () => Navigator.pop(ctx, i),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: (s.avgFps > 0
                                  ? fpsZoneColor(s.avgFps)
                                  : _dim)
                              .withOpacity(0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          s.avgFps > 0 ? s.avgFps.toStringAsFixed(0) : '--',
                          style: TextStyle(
                            color:
                                s.avgFps > 0 ? fpsZoneColor(s.avgFps) : _dim,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(
                        s.appName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: _text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${Fmt.dateTime(s.startTime)} • ${s.durationFormatted}'
                        '${(s.deviceModel ?? '').isNotEmpty ? ' • ${s.deviceModel}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _dim, fontSize: 11.5),
                      ),
                      trailing: selected
                          ? Icon(Icons.check_circle_rounded,
                              color: isA ? _blue : _green)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (isA) {
        _indexA = chosen;
      } else {
        _indexB = chosen;
      }
    });
  }

  Future<void> _shareComparison() async {
    setState(() => _sharing = true);
    try {
      final boundary =
          _captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not encode image');

      final ok = await ExportService.instance.shareBytes(
        data.buffer.asUint8List(),
        fileName: 'FPS-Monitor_compare_${_runA.id}_${_runB.id}.png',
        mimeType: 'image/png',
        title: 'FPS comparison - ${_runA.appName} vs ${_runB.appName}',
      );
      if (!ok && mounted) {
        _toast('Could not open the share sheet');
      }
    } catch (e) {
      if (mounted) _toast('Could not share comparison: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF1F2733),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = _runA;
    final b = _runB;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        elevation: 0,
        title: const Text(
          'Compare runs',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Swap Run A & Run B',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: _swap,
          ),
          IconButton(
            tooltip: 'Share comparison image',
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _green,
                    ),
                  )
                : const Icon(Icons.ios_share_rounded),
            onPressed: _sharing ? null : _shareComparison,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        child: RepaintBoundary(
          key: _captureKey,
          child: Container(
            color: _bg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Side-by-side summary cards
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _RunSummaryCard(
                        tag: 'RUN A',
                        accent: _blue,
                        session: a,
                        onTap: () => _pickRun(isA: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _RunSummaryCard(
                        tag: 'RUN B',
                        accent: _green,
                        session: b,
                        onTap: () => _pickRun(isA: false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Delta breakdown card (Run B vs Run A)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.compare_arrows_rounded,
                              size: 16, color: _green),
                          SizedBox(width: 7),
                          Text(
                            'Run B vs Run A deltas',
                            style: TextStyle(
                              color: _text,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _CompareRow(
                        label: 'Avg FPS',
                        valA: a.avgFps > 0 ? a.avgFps : null,
                        valB: b.avgFps > 0 ? b.avgFps : null,
                        decimals: 1,
                        unit: '',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: '1% Low',
                        valA: a.onePercentLow,
                        valB: b.onePercentLow,
                        decimals: 0,
                        unit: '',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: '0.1% Low',
                        valA: a.pointOnePercentLow,
                        valB: b.pointOnePercentLow,
                        decimals: 0,
                        unit: '',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: 'Stability',
                        valA: a.stabilityPercent,
                        valB: b.stabilityPercent,
                        decimals: 0,
                        unit: '%',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: 'Avg frame time',
                        valA: a.avgFrameTimeMs,
                        valB: b.avgFrameTimeMs,
                        decimals: 1,
                        unit: ' ms',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'CPU temp (avg)',
                        valA: a.avgCpuTemp >= 0 ? a.avgCpuTemp : null,
                        valB: b.avgCpuTemp >= 0 ? b.avgCpuTemp : null,
                        decimals: 1,
                        unit: '°C',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'CPU temp (peak)',
                        valA: a.maxCpuTemp >= 0 ? a.maxCpuTemp : null,
                        valB: b.maxCpuTemp >= 0 ? b.maxCpuTemp : null,
                        decimals: 1,
                        unit: '°C',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'GPU temp (avg)',
                        valA: a.avgGpuTemp >= 0 ? a.avgGpuTemp : null,
                        valB: b.avgGpuTemp >= 0 ? b.avgGpuTemp : null,
                        decimals: 1,
                        unit: '°C',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'GPU temp (peak)',
                        valA: a.maxGpuTemp >= 0 ? a.maxGpuTemp : null,
                        valB: b.maxGpuTemp >= 0 ? b.maxGpuTemp : null,
                        decimals: 1,
                        unit: '°C',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'Power draw (avg)',
                        valA: a.avgPowerWatts >= 0 ? a.avgPowerWatts : null,
                        valB: b.avgPowerWatts >= 0 ? b.avgPowerWatts : null,
                        decimals: 2,
                        unit: ' W',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'Power draw (peak)',
                        valA: a.maxPowerWatts >= 0 ? a.maxPowerWatts : null,
                        valB: b.maxPowerWatts >= 0 ? b.maxPowerWatts : null,
                        decimals: 2,
                        unit: ' W',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'Battery current',
                        valA: a.avgBatteryCurrentMa >= 0
                            ? a.avgBatteryCurrentMa
                            : null,
                        valB: b.avgBatteryCurrentMa >= 0
                            ? b.avgBatteryCurrentMa
                            : null,
                        decimals: 0,
                        unit: ' mA',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'Battery drop',
                        valA: a.batteryDropPercent,
                        valB: b.batteryDropPercent,
                        decimals: 0,
                        unit: '%',
                        polarity: _Polarity.lowerBetter,
                      ),
                      _CompareRow(
                        label: 'Free RAM (avg)',
                        valA: a.avgFreeRam > 0 ? a.avgFreeRam : null,
                        valB: b.avgFreeRam > 0 ? b.avgFreeRam : null,
                        decimals: 0,
                        unit: ' MB',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: 'Free RAM (lowest)',
                        valA: a.minFreeRam >= 0 ? a.minFreeRam : null,
                        valB: b.minFreeRam >= 0 ? b.minFreeRam : null,
                        decimals: 0,
                        unit: ' MB',
                        polarity: _Polarity.higherBetter,
                      ),
                      _CompareRow(
                        label: 'CPU usage (avg)',
                        valA: a.avgCpuUsage >= 0 ? a.avgCpuUsage : null,
                        valB: b.avgCpuUsage >= 0 ? b.avgCpuUsage : null,
                        decimals: 0,
                        unit: '%',
                        polarity: _Polarity.neutral,
                      ),
                      _CompareRow(
                        label: 'GPU usage (avg)',
                        valA: a.avgGpuUsage >= 0 ? a.avgGpuUsage : null,
                        valB: b.avgGpuUsage >= 0 ? b.avgGpuUsage : null,
                        decimals: 0,
                        unit: '%',
                        polarity: _Polarity.neutral,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RunSummaryCard extends StatelessWidget {
  final String tag;
  final Color accent;
  final Session session;
  final VoidCallback onTap;

  const _RunSummaryCard({
    required this.tag,
    required this.accent,
    required this.session,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = ShizukuService.instance.cachedDeviceInfo;
    final deviceLine = DeviceInfo.formatSummary(
      session.deviceModel ?? fallback?.deviceModel,
      session.socName ?? fallback?.socName,
      session.totalRamMb ?? fallback?.totalRamMb,
    );
    final stability = session.stabilityPercent;
    final fpsColor =
        session.avgFps > 0 ? fpsZoneColor(session.avgFps) : _dim;

    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        color: accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.unfold_more_rounded,
                      size: 16, color: _dim),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                session.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${Fmt.dateTime(session.startTime)} • ${session.durationFormatted}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _dim, fontSize: 10),
              ),
              if (deviceLine.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  deviceLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB9C2D0),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: _cardAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _MiniNum(
                          label: 'AVG',
                          value: session.avgFps > 0
                              ? session.avgFps.toStringAsFixed(0)
                              : '--',
                          color: fpsColor,
                        ),
                        _MiniNum(
                          label: '1% LOW',
                          value: session.onePercentLow != null
                              ? session.onePercentLow!.toStringAsFixed(0)
                              : '--',
                          color: session.onePercentLow != null
                              ? fpsZoneColor(session.onePercentLow!)
                              : _dim,
                        ),
                        _MiniNum(
                          label: 'STAB',
                          value: stability != null
                              ? '${stability.toStringAsFixed(0)}%'
                              : '--',
                          color: stability == null
                              ? _dim
                              : (stability >= 90
                                  ? _green
                                  : (stability >= 75 ? _amber : _red)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Divider(color: _border, height: 1),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'CPU ${Fmt.temp(session.avgCpuTemp)}',
                          style: const TextStyle(
                              color: _dim,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600),
                        ),
                        Text(
                          Fmt.watts(session.avgPowerWatts),
                          style: const TextStyle(
                              color: _text,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniNum extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniNum({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: _dim,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _CompareRow extends StatelessWidget {
  final String label;
  final double? valA;
  final double? valB;
  final int decimals;
  final String unit;
  final _Polarity polarity;

  const _CompareRow({
    required this.label,
    required this.valA,
    required this.valB,
    required this.decimals,
    required this.unit,
    required this.polarity,
  });

  String _fmt(double? v) =>
      v == null ? '--' : '${v.toStringAsFixed(decimals)}$unit';

  @override
  Widget build(BuildContext context) {
    final a = valA;
    final b = valB;
    String deltaText = '--';
    Color deltaColor = _dim;

    if (a != null && b != null) {
      final d = b - a;
      final threshold = decimals == 0 ? 0.5 : (decimals == 1 ? 0.05 : 0.005);
      if (d.abs() < threshold) {
        deltaText = '0$unit';
        deltaColor = _dim;
      } else {
        final sign = d > 0 ? '+' : '';
        deltaText = '$sign${d.toStringAsFixed(decimals)}$unit';
        switch (polarity) {
          case _Polarity.higherBetter:
            deltaColor = d > 0 ? _green : _red;
            break;
          case _Polarity.lowerBetter:
            deltaColor = d < 0 ? _green : _red;
            break;
          case _Polarity.neutral:
            deltaColor = _blue;
            break;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB9C2D0),
                    fontSize: 11.5,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  _fmt(a),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: _blue,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 68,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: deltaColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    deltaText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: deltaColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  _fmt(b),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: _green,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Divider(color: Color(0xFF1F2736), height: 1),
        ],
      ),
    );
  }
}
