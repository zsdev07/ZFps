/// Shared formatting helpers.
class Fmt {
  Fmt._();

  static String temp(double v) => v >= 0 ? '${v.toStringAsFixed(0)}°C' : '--';

  static String tempExact(double v) => v >= 0 ? '${v.toStringAsFixed(1)}°C' : '--';

  static String percent(double v) => v >= 0 ? '${v.toStringAsFixed(0)}%' : '--';

  static String mb(double v) => v >= 0 ? '${v.toStringAsFixed(0)} MB' : '--';

  static String fps(double v) => v >= 0 ? v.toStringAsFixed(0) : '--';

  static String speed(double v) =>
      v >= 0 ? '${v.toStringAsFixed(1)} MB/s' : '--';

  static String ramFree(double v) => v >= 0 ? '${v.toStringAsFixed(0)} MB free' : '-- MB';

  static String currentMa(double v) =>
      v >= 0 ? '${v.toStringAsFixed(0)} mA' : '--';

  static String watts(double v) =>
      v >= 0 ? '${v.toStringAsFixed(2)} W' : '--';

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String dateTime(DateTime t) {
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${_months[local.month - 1]} ${local.year}, $hh:$mm';
  }

  static String durationShort(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  static String durationHms(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
