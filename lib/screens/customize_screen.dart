import 'package:flutter/material.dart';

import '../models/overlay_config.dart';
import '../services/overlay_service.dart';

const Color _bg = Color(0xFF0D1117);
const Color _card = Color(0xFF161C27);
const Color _border = Color(0xFF232C3D);
const Color _green = Color(0xFF4ADE80);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _text = Color(0xFFE5E7EB);
const Color _textDim = Color(0xFF8B94A7);

/// 55+ green (60 / 90 / 120...), 30-54 yellow, below 30 red. Same as the native overlay.
Color _fpsColor(double fps) {
  if (fps < 0) return _text;
  if (fps >= 55) return _green;
  if (fps >= 30) return _amber;
  return _red;
}

class CustomizeScreen extends StatefulWidget {
  const CustomizeScreen({super.key});

  @override
  State<CustomizeScreen> createState() => _CustomizeScreenState();
}

class _CustomizeScreenState extends State<CustomizeScreen> {
  OverlayConfig _cfg = const OverlayConfig();
  double _previewFps = 60;

  static const List<(String, OverlayConfig)> _presets = [
    ('Minimal', OverlayConfig.minimal),
    ('FPS + RAM', OverlayConfig.fpsRam),
    ('Standard', OverlayConfig.standard),
    ('Everything', OverlayConfig.everything),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await OverlayService.instance.getConfig();
    if (!mounted) return;
    setState(() => _cfg = c);
  }

  void _apply(OverlayConfig next, {bool save = true}) {
    setState(() => _cfg = next);
    if (save) OverlayService.instance.saveConfig(next);
  }

  /// Applies a toggle, but never lets the user switch off the last visible stat.
  void _toggle(OverlayConfig next) {
    if (!next.hasAnyStat) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keep at least one stat switched on')),
      );
      return;
    }
    _apply(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = _cfg;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('Customize overlay',
            style: TextStyle(fontWeight: FontWeight.w800, color: _text)),
        actions: [
          TextButton(
            onPressed: () => _apply(OverlayConfig.standard),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _preview(c),
          const SizedBox(height: 16),
          _section('Quick presets', [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _presets)
                    ChoiceChip(
                      label: Text(p.$1),
                      selected: c.sameLayoutAs(p.$2),
                      onSelected: (_) =>
                          _apply(p.$2.copyWith(textScale: c.textScale)),
                    ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          _section('Show on overlay', [
            _switch('FPS', 'Big coloured frame-rate number', c.showFps,
                (v) => _toggle(c.copyWith(showFps: v))),
            _switch('"FPS" label', 'Show the word next to the number',
                c.showFpsLabel, (v) => _toggle(c.copyWith(showFpsLabel: v)),
                enabled: c.showFps),
            _switch('CPU temperature', null, c.showCpuTemp,
                (v) => _toggle(c.copyWith(showCpuTemp: v))),
            _switch('GPU temperature', null, c.showGpuTemp,
                (v) => _toggle(c.copyWith(showGpuTemp: v))),
            _switch('Free RAM', null, c.showRam,
                (v) => _toggle(c.copyWith(showRam: v))),
            _switch('CPU usage', null, c.showCpuUsage,
                (v) => _toggle(c.copyWith(showCpuUsage: v))),
            _switch('GPU usage', null, c.showGpuUsage,
                (v) => _toggle(c.copyWith(showGpuUsage: v))),
            _switch('Power draw', 'Battery current (mA) and wattage', c.showPower,
                (v) => _toggle(c.copyWith(showPower: v))),
          ]),
          const SizedBox(height: 14),
          _section('Appearance', [
            _slider(
              'Background',
              c.bgOpacity == 0 ? 'Transparent' : '${c.bgOpacity}%',
              c.bgOpacity.toDouble(),
              0,
              100,
              (v) => _apply(c.copyWith(bgOpacity: v.round()), save: false),
              (v) => _apply(c.copyWith(bgOpacity: v.round())),
            ),
            _slider(
              'Text size',
              '${(c.textScale * 100).round()}%',
              c.textScale,
              0.7,
              1.6,
              (v) => _apply(c.copyWith(textScale: v), save: false),
              (v) => _apply(c.copyWith(textScale: v)),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.fromLTRB(6, 14, 6, 0),
            child: Text(
              'Tip: drag the overlay anywhere on screen while playing. '
              'Changes apply instantly if the overlay is running.',
              style: TextStyle(color: _textDim, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- preview

  Widget _preview(OverlayConfig c) {
    return Container(
      height: 190,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B3F5E), Color(0xFF0B1320)],
        ),
      ),
      child: Stack(
        children: [
          const Positioned(
            left: 14,
            top: 12,
            child: Text('Live preview',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _OverlayPreview(cfg: c, fps: _previewFps),
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final f in const [120, 60, 45, 25])
                    ChoiceChip(
                      label: Text('$f'),
                      visualDensity: VisualDensity.compact,
                      selected: _previewFps == f.toDouble(),
                      onSelected: (_) =>
                          setState(() => _previewFps = f.toDouble()),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- pieces

  Widget _section(String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(title,
                style: const TextStyle(
                    color: _textDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4)),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _switch(String title, String? sub, bool value, ValueChanged<bool> onChanged,
      {bool enabled = true}) {
    return SwitchListTile(
      dense: true,
      title: Text(title,
          style: TextStyle(color: enabled ? _text : _textDim, fontSize: 15)),
      subtitle: sub == null
          ? null
          : Text(sub, style: const TextStyle(color: _textDim, fontSize: 12)),
      value: value,
      activeColor: _green,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _slider(String label, String valueText, double value, double min, double max,
      ValueChanged<double> onChanged, ValueChanged<double> onChangeEnd) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(color: _text, fontSize: 15)),
              const Spacer(),
              Text(valueText, style: const TextStyle(color: _textDim, fontSize: 13)),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            activeColor: _green,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

/// Flutter replica of the native overlay, used for the live preview.
class _OverlayPreview extends StatelessWidget {
  final OverlayConfig cfg;
  final double fps;

  const _OverlayPreview({required this.cfg, required this.fps});

  @override
  Widget build(BuildContext context) {
    final onlyFps = cfg.onlyFps;
    final showFps = cfg.showFps || onlyFps;
    final transparent = cfg.bgOpacity <= 0;
    final alpha = cfg.bgOpacity / 100.0;
    final scale = cfg.textScale;
    final shadows = cfg.bgOpacity < 40
        ? const [Shadow(blurRadius: 4, color: Colors.black, offset: Offset(0, 1))]
        : null;

    TextStyle small(Color color) =>
        TextStyle(color: color, fontSize: 11 * scale, shadows: shadows);

    final fpsValue = fps.toInt().toString();
    final temps = [
      if (cfg.showCpuTemp) 'CPU 52°',
      if (cfg.showGpuTemp) 'GPU 48°',
    ].join('  ');
    final usage = [
      if (cfg.showCpuUsage) 'CPU 35%',
      if (cfg.showGpuUsage) 'GPU 41%',
    ].join('  ');

    return Container(
      constraints: BoxConstraints(minWidth: (transparent || onlyFps) ? 48 : 132, minHeight: 40),
      padding: EdgeInsets.symmetric(
        horizontal: transparent ? 6 : 14,
        vertical: transparent ? 2 : 8,
      ),
      decoration: transparent
          ? null
          : BoxDecoration(
              color: const Color(0xFF12161D).withOpacity(alpha),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFF3A4457).withOpacity(alpha * 0.75)),
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            onlyFps ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          if (showFps)
            Text(
              cfg.showFpsLabel ? '$fpsValue FPS' : fpsValue,
              style: TextStyle(
                color: _fpsColor(fps),
                fontSize: (onlyFps ? 28 : 21) * scale,
                fontWeight: FontWeight.w800,
                shadows: shadows,
              ),
            ),
          if (temps.isNotEmpty) Text(temps, style: small(_text)),
          if (usage.isNotEmpty) Text(usage, style: small(const Color(0xFFC7CCD6))),
          if (cfg.showRam) Text('RAM 1843 MB free', style: small(const Color(0xFF9CA3AF))),
          if (cfg.showPower) Text('840 mA  3.25 W', style: small(const Color(0xFFFBBF24))),
        ],
      ),
    );
  }
}
