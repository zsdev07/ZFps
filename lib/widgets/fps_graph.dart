import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/format_utils.dart';

const Color _green = Color(0xFF4ADE80);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _violet = Color(0xFFA78BFA);
const Color _grid = Color(0xFF232C3D);
const Color _dim = Color(0xFF8B94A7);
const Color _rightAxisDim = Color(0xFF7B879B);

/// 55+ green, 30-54 yellow, below 30 red (same colors as the overlay).
Color fpsZoneColor(double fps) {
  if (fps >= 55) return _green;
  if (fps >= 30) return _amber;
  return _red;
}

/// Optional secondary metric plotted on top of [FpsGraph] using the same
/// timeline. Negative values are treated as gaps/unknown.
class ChartOverlaySeries {
  final String label;
  final String unit;
  final Color color;
  final List<double> values;
  final double minSpan;
  final int decimals;

  const ChartOverlaySeries({
    required this.label,
    required this.unit,
    required this.color,
    required this.values,
    this.minSpan = 10.0,
    this.decimals = 0,
  });

  String formatValue(double v) =>
      v >= 0 ? '${v.toStringAsFixed(decimals)}$unit' : '--';
}

class _OverlayScale {
  final double minV;
  final double maxV;
  final double lo;
  final double hi;

  const _OverlayScale({
    required this.minV,
    required this.maxV,
    required this.lo,
    required this.hi,
  });

  double get denom => (hi - lo) > 0 ? (hi - lo) : 1.0;

  static _OverlayScale? compute(ChartOverlaySeries ov, int n) {
    final limit = math.min(n, ov.values.length);
    var minV = double.infinity;
    var maxV = -double.infinity;
    for (var i = 0; i < limit; i++) {
      final v = ov.values[i];
      if (v >= 0) {
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
    }
    if (!minV.isFinite || !maxV.isFinite) return null;

    final span = math.max(maxV - minV, ov.minSpan);
    final mid = (minV + maxV) / 2.0;
    var lo = math.max(0.0, mid - span * 0.58);
    var hi = lo + math.max(maxV - lo, span * 1.16);
    if (ov.unit == '%' && maxV <= 100.0) {
      hi = math.min(100.0, hi);
      if (hi - lo < ov.minSpan) {
        lo = math.max(0.0, hi - ov.minSpan);
      }
    }
    return _OverlayScale(minV: minV, maxV: maxV, lo: lo, hi: hi);
  }
}

/// FPS-over-time graph with a 1% low line, an average line, and optional
/// secondary metric overlay lines with a dedicated right-hand Y-axis scale.
/// Tap or drag on it to inspect exact values; double-tap to clear.
class FpsGraph extends StatefulWidget {
  /// FPS per poll.
  final List<double> fps;

  /// 1% low per poll (same length as [fps], negative = unknown). May be empty.
  final List<double> lows;

  /// Time between two samples.
  final Duration step;

  /// Timestamp of index 0 (used when leading blank polls were auto-trimmed).
  final Duration startOffset;

  /// Tap / drag to inspect points. Turn off for static images.
  final bool interactive;

  /// Optional inclusive sample indices highlighting the trimmed timeline.
  final int? trimStart;
  final int? trimEnd;

  /// Secondary metrics to plot on top of the FPS timeline.
  final List<ChartOverlaySeries> overlays;

  const FpsGraph({
    super.key,
    required this.fps,
    required this.lows,
    this.step = const Duration(seconds: 2),
    this.startOffset = Duration.zero,
    this.interactive = true,
    this.trimStart,
    this.trimEnd,
    this.overlays = const [],
  });

  @override
  State<FpsGraph> createState() => _FpsGraphState();
}

class _FpsGraphState extends State<FpsGraph> {
  static const double _padL = 30.0, _padT = 8.0, _padB = 20.0;

  double get _padR {
    if (widget.overlays.isEmpty) return 6.0;
    return widget.overlays.length == 1 ? 52.0 : 36.0;
  }

  int? _selected;

  bool get _hasLows =>
      widget.lows.length == widget.fps.length && widget.lows.any((e) => e >= 0);

  double get _avg {
    final maxIdx = math.max(0, widget.fps.length - 1);
    final s = (widget.trimStart ?? 0).clamp(0, maxIdx).toInt();
    final e = (widget.trimEnd ?? maxIdx).clamp(s, maxIdx).toInt();
    final v = <double>[];
    for (var i = s; i <= e && i < widget.fps.length; i++) {
      if (widget.fps[i] > 0) v.add(widget.fps[i]);
    }
    if (v.isEmpty) return 0;
    return v.reduce((a, b) => a + b) / v.length;
  }

  double get _yMax {
    var m = 0.0;
    for (final v in widget.fps) {
      if (v > m) m = v;
    }
    final top = math.max(30.0, (m * 1.08 / 10).ceil() * 10.0);
    return top;
  }

  void _select(double dx, double width) {
    final n = widget.fps.length;
    if (n < 2) return;
    final plotW = math.max(1.0, width - _padL - _padR);
    final t = math.min(1.0, math.max(0.0, (dx - _padL) / plotW));
    setState(() => _selected = (t * (n - 1)).round());
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.fps.length;
    if (n < 2) return const SizedBox.shrink();

    final sel = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 22),
          child: sel == null ? _legend(n) : _readout(sel),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 170,
          child: LayoutBuilder(
            builder: (context, c) {
              final graph = CustomPaint(
                size: Size(c.maxWidth, 170),
                painter: _GraphPainter(
                  fps: widget.fps,
                  lows: _hasLows ? widget.lows : const [],
                  avg: _avg,
                  yMax: _yMax,
                  selected: sel,
                  startOffset: widget.startOffset,
                  totalTime: widget.step * (n - 1),
                  padR: _padR,
                  trimStart: widget.trimStart,
                  trimEnd: widget.trimEnd,
                  overlays: widget.overlays,
                ),
              );
              if (!widget.interactive) return graph;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _select(d.localPosition.dx, c.maxWidth),
                onHorizontalDragStart: (d) => _select(d.localPosition.dx, c.maxWidth),
                onHorizontalDragUpdate: (d) => _select(d.localPosition.dx, c.maxWidth),
                onDoubleTap: () => setState(() => _selected = null),
                child: graph,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _legend(int n) {
    Widget dot(Color c, String t) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(t, style: const TextStyle(color: _dim, fontSize: 11)),
          ],
        );

    final items = <Widget>[
      dot(_green, 'FPS'),
      if (_hasLows) dot(_violet, '1% low'),
      dot(Colors.white54, 'avg ${_avg.toStringAsFixed(0)}'),
      for (final ov in widget.overlays)
        Builder(
          builder: (_) {
            final sc = _OverlayScale.compute(ov, n);
            final text = sc == null
                ? ov.label
                : '${ov.label} (${sc.minV.toStringAsFixed(ov.decimals)}–${ov.formatValue(sc.maxV)})';
            return dot(ov.color, text);
          },
        ),
    ];

    if (widget.overlays.isEmpty && widget.interactive) {
      return Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            items[i],
          ],
          const Spacer(),
          const Text('tap to inspect',
              style: TextStyle(color: Color(0xFF4B5568), fontSize: 10)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: items,
        ),
        if (widget.overlays.isNotEmpty && widget.interactive) ...[
          const SizedBox(height: 3),
          Text(
            widget.overlays.length == 1
                ? 'Right axis: ${widget.overlays.first.label} • scrub chart for exact values'
                : 'Right axis: normalized 0–100% per metric • scrub chart for exact values',
            style: const TextStyle(color: Color(0xFF6B7484), fontSize: 9.5),
          ),
        ],
      ],
    );
  }

  Widget _readout(int i) {
    final fps = widget.fps[i];
    final low = _hasLows ? widget.lows[i] : -1.0;
    final t = Fmt.durationHms(widget.startOffset + widget.step * i);

    Widget chip(String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.38)),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        );

    final parts = <Widget>[
      Text(
        t,
        style: const TextStyle(
          color: _dim,
          fontSize: 11.5,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
        ),
      ),
      if (fps < 0)
        chip('Loading excluded', const Color(0xFF60A5FA))
      else ...[
        chip('${fps.toStringAsFixed(0)} FPS', fpsZoneColor(fps)),
        if (low >= 0) chip('1% low ${low.toStringAsFixed(0)}', _violet),
      ],
      for (final ov in widget.overlays)
        if (i < ov.values.length && ov.values[i] >= 0)
          chip('${ov.label} ${ov.formatValue(ov.values[i])}', ov.color),
    ];

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
    );
  }
}

class _GraphPainter extends CustomPainter {
  final List<double> fps;
  final List<double> lows;
  final double avg;
  final double yMax;
  final int? selected;
  final Duration startOffset;
  final Duration totalTime;
  final double padR;
  final int? trimStart;
  final int? trimEnd;
  final List<ChartOverlaySeries> overlays;

  _GraphPainter({
    required this.fps,
    required this.lows,
    required this.avg,
    required this.yMax,
    required this.selected,
    required this.startOffset,
    required this.totalTime,
    required this.padR,
    this.trimStart,
    this.trimEnd,
    this.overlays = const [],
  });

  static const double _l = 30, _t = 8, _b = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_l, _t, size.width - padR, size.height - _b);
    final n = fps.length;

    double yOf(double v) =>
        plot.bottom - plot.height * math.min(1.0, math.max(0.0, v / yMax));
    double xOf(int i) => plot.left + plot.width * (n <= 1 ? 0 : i / (n - 1));

    // Grid + left FPS y-labels
    final gridPaint = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = plot.bottom - plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(canvas, (yMax * i / 4).round().toString(), Offset(plot.left - 5, y),
          alignRight: true, size: 9.5);
    }

    // Time labels
    _text(canvas, Fmt.durationHms(startOffset), Offset(plot.left, plot.bottom + 4),
        size: 9.5, top: true);
    _text(
        canvas,
        Fmt.durationHms(startOffset + totalTime),
        Offset(plot.right, plot.bottom + 4),
        alignRight: true,
        size: 9.5,
        top: true);
    if (n > 8) {
      _text(
          canvas,
          Fmt.durationHms(startOffset + totalTime ~/ 2),
          Offset(plot.left + plot.width / 2, plot.bottom + 4),
          center: true,
          size: 9.5,
          top: true);
    }

    // Area under the FPS line (break cleanly across excluded loading gaps)
    final areaPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_green.withOpacity(0.26), _green.withOpacity(0.0)],
      ).createShader(plot);
    var runStart = -1;
    for (var i = 0; i <= n; i++) {
      final valid = i < n && fps[i] >= 0;
      if (valid && runStart < 0) {
        runStart = i;
      } else if (!valid && runStart >= 0) {
        final runEnd = i - 1;
        if (runEnd > runStart) {
          final area = Path()..moveTo(xOf(runStart), plot.bottom);
          for (var k = runStart; k <= runEnd; k++) {
            area.lineTo(xOf(k), yOf(fps[k]));
          }
          area
            ..lineTo(xOf(runEnd), plot.bottom)
            ..close();
          canvas.drawPath(area, areaPaint);
        }
        runStart = -1;
      }
    }

    // Average line (dashed)
    if (avg > 0) {
      final y = yOf(avg);
      _dashed(
          canvas,
          Offset(plot.left, y),
          Offset(plot.right, y),
          Paint()
            ..color = Colors.white54
            ..strokeWidth = 1);
    }

    // 1% low line
    if (lows.isNotEmpty) {
      final p = Paint()
        ..color = _violet
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < n; i++) {
        if (lows[i] < 0 || lows[i - 1] < 0) continue;
        canvas.drawLine(
            Offset(xOf(i - 1), yOf(lows[i - 1])), Offset(xOf(i), yOf(lows[i])), p);
      }
    }

    // Secondary overlay metric lines + dedicated right-hand secondary Y-axis
    final scales = <_OverlayScale?>[];
    for (var ovIdx = 0; ovIdx < overlays.length; ovIdx++) {
      final ov = overlays[ovIdx];
      final sc = _OverlayScale.compute(ov, n);
      scales.add(sc);
      if (sc == null) continue;

      final vals = ov.values;
      final limit = math.min(n, vals.length);
      double yOv(double v) =>
          plot.bottom -
          plot.height * math.min(1.0, math.max(0.0, (v - sc.lo) / sc.denom));

      final ovPaint = Paint()
        ..color = ov.color.withOpacity(0.92)
        ..strokeWidth = 1.65
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < limit; i++) {
        if (vals[i] < 0 || vals[i - 1] < 0) continue;
        canvas.drawLine(
            Offset(xOf(i - 1), yOv(vals[i - 1])), Offset(xOf(i), yOv(vals[i])), ovPaint);
      }
      for (var i = 0; i < limit; i++) {
        if (vals[i] < 0) continue;
        final prevBad = i == 0 || vals[i - 1] < 0;
        final nextBad = i == limit - 1 || vals[i + 1] < 0;
        if (prevBad && nextBad) {
          canvas.drawCircle(
              Offset(xOf(i), yOv(vals[i])), 2.0, Paint()..color = ov.color);
        }
      }
    }

    if (overlays.isNotEmpty) {
      final singleScale = overlays.length == 1 ? scales.first : null;
      final axisColor = overlays.length == 1
          ? overlays.first.color.withOpacity(0.40)
          : _grid;
      canvas.drawLine(
        Offset(plot.right, plot.top),
        Offset(plot.right, plot.bottom),
        Paint()
          ..color = axisColor
          ..strokeWidth = 1,
      );

      for (var i = 0; i <= 4; i++) {
        final y = plot.bottom - plot.height * i / 4;
        if (singleScale != null) {
          final tickVal = singleScale.lo + singleScale.denom * (i / 4.0);
          final ov = overlays.first;
          _text(
            canvas,
            ov.formatValue(tickVal),
            Offset(plot.right + 5, y),
            size: 8.8,
            color: ov.color.withOpacity(0.92),
          );
        } else {
          _text(
            canvas,
            '${i * 25}%',
            Offset(plot.right + 5, y),
            size: 8.8,
            color: _rightAxisDim,
          );
        }
      }
    }

    // FPS line, colored by zone (skip excluded < 0 gaps)
    final line = Paint()
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < n; i++) {
      if (fps[i] < 0 || fps[i - 1] < 0) continue;
      line.color = fpsZoneColor((fps[i] + fps[i - 1]) / 2);
      canvas.drawLine(
          Offset(xOf(i - 1), yOf(fps[i - 1])), Offset(xOf(i), yOf(fps[i])), line);
    }
    for (var i = 0; i < n; i++) {
      if (fps[i] < 0) continue;
      final prevBad = i == 0 || fps[i - 1] < 0;
      final nextBad = i == n - 1 || fps[i + 1] < 0;
      if (prevBad && nextBad) {
        canvas.drawCircle(
            Offset(xOf(i), yOf(fps[i])), 2.2, Paint()..color = fpsZoneColor(fps[i]));
      }
    }

    // Selection marker
    final s = selected;
    if (s != null && s >= 0 && s < n) {
      final x = xOf(s);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = Colors.white30
          ..strokeWidth = 1,
      );
      for (var ovIdx = 0; ovIdx < overlays.length; ovIdx++) {
        final ov = overlays[ovIdx];
        final sc = scales[ovIdx];
        if (sc == null || s >= ov.values.length || ov.values[s] < 0) continue;
        final y = plot.bottom -
            plot.height *
                math.min(1.0, math.max(0.0, (ov.values[s] - sc.lo) / sc.denom));
        canvas.drawCircle(Offset(x, y), 4.0, Paint()..color = ov.color);
        canvas.drawCircle(
          Offset(x, y),
          4.0,
          Paint()
            ..color = const Color(0xFF0D1117)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
      if (fps[s] >= 0) {
        canvas.drawCircle(
            Offset(x, yOf(fps[s])), 4.5, Paint()..color = fpsZoneColor(fps[s]));
        canvas.drawCircle(
          Offset(x, yOf(fps[s])),
          4.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        if (lows.isNotEmpty && lows[s] >= 0) {
          canvas.drawCircle(
              Offset(x, yOf(lows[s])), 3.5, Paint()..color = _violet);
        }
      }
    }

    // Dim trimmed-out sections when a timeline trim is active
    final ts = trimStart;
    final te = trimEnd;
    if (ts != null && te != null && (ts > 0 || te < n - 1)) {
      final dimPaint = Paint()..color = const Color(0x990D1117);
      final guidePaint = Paint()
        ..color = const Color(0xFF60A5FA)
        ..strokeWidth = 1.5;
      if (ts > 0) {
        final xStart = xOf(ts);
        canvas.drawRect(
            Rect.fromLTRB(plot.left, plot.top, xStart, plot.bottom), dimPaint);
        canvas.drawLine(
            Offset(xStart, plot.top), Offset(xStart, plot.bottom), guidePaint);
      }
      if (te < n - 1) {
        final xEnd = xOf(te);
        canvas.drawRect(
            Rect.fromLTRB(xEnd, plot.top, plot.right, plot.bottom), dimPaint);
        canvas.drawLine(
            Offset(xEnd, plot.top), Offset(xEnd, plot.bottom), guidePaint);
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 5.0, gap = 4.0;
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d += dash + gap;
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    bool alignRight = false,
    bool center = false,
    bool top = false,
    double size = 10,
    Color color = _dim,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    final dy = top ? at.dy : at.dy - tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.selected != selected ||
      old.fps != fps ||
      old.lows != lows ||
      old.avg != avg ||
      old.yMax != yMax ||
      old.startOffset != startOffset ||
      old.padR != padR ||
      old.trimStart != trimStart ||
      old.trimEnd != trimEnd ||
      old.overlays != overlays;
}
