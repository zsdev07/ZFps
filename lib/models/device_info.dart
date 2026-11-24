/// Hardware metadata (model, chipset, total RAM) attached to reports & CSVs.
class DeviceInfo {
  final String deviceModel;
  final String socName;
  final double totalRamMb;

  const DeviceInfo({
    required this.deviceModel,
    required this.socName,
    required this.totalRamMb,
  });

  factory DeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    final model = (map['deviceModel'] as String?)?.trim() ?? '';
    final soc = (map['socName'] as String?)?.trim() ?? '';
    final ram = map['totalRamMb'];
    return DeviceInfo(
      deviceModel: model.isEmpty ? 'Android Device' : model,
      socName: soc.isEmpty ? 'Unknown SoC' : soc,
      totalRamMb: ram is num ? ram.toDouble() : -1.0,
    );
  }

  /// Friendly RAM label, e.g. "8 GB" or "10.0 GB" when non-standard.
  String get ramLabel => formatRamLabel(totalRamMb);

  /// Detailed RAM label for CSV metadata, e.g. "8 GB (7580 MB)".
  String get ramDetailed => formatRamDetailed(totalRamMb);

  /// Compact one-line summary for report headers and share cards.
  String get summaryLine => formatSummary(deviceModel, socName, totalRamMb);

  static int? advertisedRamGb(double totalMb) {
    if (totalMb <= 0) return null;
    final gb = totalMb / 1024.0;
    const tiers = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32];
    for (final t in tiers) {
      if (gb <= t && gb >= t * 0.72) return t;
    }
    return null;
  }

  static String formatRamLabel(double totalMb) {
    if (totalMb <= 0) return '--';
    final tier = advertisedRamGb(totalMb);
    if (tier != null) return '$tier GB RAM';
    return '${(totalMb / 1024.0).toStringAsFixed(1)} GB RAM';
  }

  static String formatRamDetailed(double totalMb) {
    if (totalMb <= 0) return '';
    final tier = advertisedRamGb(totalMb);
    final mb = totalMb.round();
    if (tier != null) return '$tier GB ($mb MB)';
    return '${(totalMb / 1024.0).toStringAsFixed(1)} GB ($mb MB)';
  }

  static String formatSummary(String? model, String? soc, double? totalMb) {
    final parts = <String>[];
    if (model != null && model.trim().isNotEmpty) parts.add(model.trim());
    if (soc != null && soc.trim().isNotEmpty) parts.add(soc.trim());
    if (totalMb != null && totalMb > 0) parts.add(formatRamLabel(totalMb));
    return parts.join('  •  ');
  }
}
