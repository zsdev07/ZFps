/// How the floating overlay looks and what it shows.
///
/// Stored natively (SharedPreferences) so the overlay service can read it
/// without a Flutter engine; this class is just the Dart view of it.
class OverlayConfig {
  final bool showFps;
  final bool showFpsLabel;
  final bool showCpuTemp;
  final bool showGpuTemp;
  final bool showRam;
  final bool showCpuUsage;
  final bool showGpuUsage;
  final bool showPower;

  /// 0 = fully transparent, 100 = solid dark card.
  final int bgOpacity;

  /// Text size multiplier (0.7 - 1.6).
  final double textScale;

  const OverlayConfig({
    this.showFps = true,
    this.showFpsLabel = true,
    this.showCpuTemp = true,
    this.showGpuTemp = true,
    this.showRam = true,
    this.showCpuUsage = false,
    this.showGpuUsage = false,
    this.showPower = false,
    this.bgOpacity = 90,
    this.textScale = 1.0,
  });

  // ------------------------------------------------------------ presets

  /// Just a big coloured FPS number floating on the game, no background.
  static const OverlayConfig minimal = OverlayConfig(
    showFps: true,
    showFpsLabel: false,
    showCpuTemp: false,
    showGpuTemp: false,
    showRam: false,
    bgOpacity: 0,
  );

  static const OverlayConfig fpsRam = OverlayConfig(
    showFps: true,
    showFpsLabel: true,
    showCpuTemp: false,
    showGpuTemp: false,
    showRam: true,
    bgOpacity: 35,
  );

  static const OverlayConfig standard = OverlayConfig();

  static const OverlayConfig everything = OverlayConfig(
    showCpuUsage: true,
    showGpuUsage: true,
    showPower: true,
  );

  // ------------------------------------------------------------ helpers

  bool get hasOtherStats =>
      showCpuTemp ||
      showGpuTemp ||
      showRam ||
      showCpuUsage ||
      showGpuUsage ||
      showPower;

  /// At least one line must stay on, otherwise the bar would be empty.
  bool get hasAnyStat => showFps || hasOtherStats;

  /// True when only the FPS number is visible.
  bool get onlyFps => !hasOtherStats; // FPS is forced on when nothing else is

  /// Same set of visible stats (ignores background / size).
  bool sameLayoutAs(OverlayConfig o) =>
      showFps == o.showFps &&
      showFpsLabel == o.showFpsLabel &&
      showCpuTemp == o.showCpuTemp &&
      showGpuTemp == o.showGpuTemp &&
      showRam == o.showRam &&
      showCpuUsage == o.showCpuUsage &&
      showGpuUsage == o.showGpuUsage &&
      showPower == o.showPower;

  OverlayConfig copyWith({
    bool? showFps,
    bool? showFpsLabel,
    bool? showCpuTemp,
    bool? showGpuTemp,
    bool? showRam,
    bool? showCpuUsage,
    bool? showGpuUsage,
    bool? showPower,
    int? bgOpacity,
    double? textScale,
  }) {
    return OverlayConfig(
      showFps: showFps ?? this.showFps,
      showFpsLabel: showFpsLabel ?? this.showFpsLabel,
      showCpuTemp: showCpuTemp ?? this.showCpuTemp,
      showGpuTemp: showGpuTemp ?? this.showGpuTemp,
      showRam: showRam ?? this.showRam,
      showCpuUsage: showCpuUsage ?? this.showCpuUsage,
      showGpuUsage: showGpuUsage ?? this.showGpuUsage,
      showPower: showPower ?? this.showPower,
      bgOpacity: bgOpacity ?? this.bgOpacity,
      textScale: textScale ?? this.textScale,
    );
  }

  Map<String, dynamic> toMap() => {
        'showFps': showFps,
        'showFpsLabel': showFpsLabel,
        'showCpuTemp': showCpuTemp,
        'showGpuTemp': showGpuTemp,
        'showRam': showRam,
        'showCpuUsage': showCpuUsage,
        'showGpuUsage': showGpuUsage,
        'showPower': showPower,
        'bgOpacity': bgOpacity,
        'textScale': textScale,
      };

  factory OverlayConfig.fromMap(Map<dynamic, dynamic> m) {
    const d = OverlayConfig();
    bool b(String k, bool def) => m[k] is bool ? m[k] as bool : def;
    final opacity = m['bgOpacity'];
    final scale = m['textScale'];
    return OverlayConfig(
      showFps: b('showFps', d.showFps),
      showFpsLabel: b('showFpsLabel', d.showFpsLabel),
      showCpuTemp: b('showCpuTemp', d.showCpuTemp),
      showGpuTemp: b('showGpuTemp', d.showGpuTemp),
      showRam: b('showRam', d.showRam),
      showCpuUsage: b('showCpuUsage', d.showCpuUsage),
      showGpuUsage: b('showGpuUsage', d.showGpuUsage),
      showPower: b('showPower', d.showPower),
      bgOpacity: opacity is num ? opacity.toInt().clamp(0, 100).toInt() : d.bgOpacity,
      textScale: scale is num ? scale.toDouble().clamp(0.6, 2.0).toDouble() : d.textScale,
    );
  }
}
