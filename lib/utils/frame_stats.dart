/// Frame-time statistics (1% low, 0.1% low, average frame time, stability).
///
/// Frame times are kept in a compact histogram (0.25 ms bins, 0-250 ms) so a
/// whole session fits in ~1000 integers while the percentiles stay accurate.
class FrameStats {
  FrameStats._();

  static const double binMs = 0.25;
  static const int binCount = 1000; // covers 0 - 250 ms; slower frames land in the last bin
  static const double defaultStabilityToleranceMs = 3.0;

  static List<int> emptyHistogram() => List<int>.filled(binCount, 0);

  static void addAll(List<int> hist, Iterable<double> frameTimesMs) {
    for (final ms in frameTimesMs) {
      if (ms <= 0) continue;
      final i = (ms / binMs).floor();
      hist[i >= binCount ? binCount - 1 : i] += 1;
    }
  }

  static int totalFrames(List<int> hist) {
    var n = 0;
    for (final c in hist) {
      n += c;
    }
    return n;
  }

  /// Average frame time of the whole histogram, in ms.
  static double? avgFrameMs(List<int> hist) {
    final total = totalFrames(hist);
    if (total == 0) return null;
    var sum = 0.0;
    for (var i = 0; i < hist.length; i++) {
      sum += hist[i] * (i + 0.5) * binMs;
    }
    return sum / total;
  }

  /// Median frame time (50th percentile) from the histogram, in ms.
  static double? medianFrameMs(List<int> hist, {int minFrames = 10}) {
    final total = totalFrames(hist);
    if (total < minFrames) return null;
    final target = (total + 1) ~/ 2;
    var cum = 0;
    for (var i = 0; i < hist.length; i++) {
      cum += hist[i];
      if (cum >= target) {
        return (i + 0.5) * binMs;
      }
    }
    return null;
  }

  /// Frame-Time Stability Score (%): percentage of frames within +/- [toleranceMs]
  /// of the median (target) frame pacing.
  static double? stabilityPercent(
    List<int> hist, {
    double toleranceMs = defaultStabilityToleranceMs,
    int minFrames = 30,
  }) {
    final total = totalFrames(hist);
    if (total < minFrames) return null;
    final median = medianFrameMs(hist, minFrames: minFrames);
    if (median == null) return null;
    var stable = 0;
    for (var i = 0; i < hist.length; i++) {
      final c = hist[i];
      if (c == 0) continue;
      final ms = (i + 0.5) * binMs;
      if ((ms - median).abs() <= toleranceMs) {
        stable += c;
      }
    }
    return 100.0 * stable / total;
  }

  /// Frame-Time Stability Score (%) for a raw window of frame times.
  static double? stabilityOfList(
    List<double> frameTimesMs, {
    double toleranceMs = defaultStabilityToleranceMs,
    int minFrames = 10,
  }) {
    final valid = frameTimesMs.where((ms) => ms > 0).toList();
    final n = valid.length;
    if (n < minFrames) return null;
    valid.sort();
    final median = n.isOdd
        ? valid[n ~/ 2]
        : (valid[n ~/ 2 - 1] + valid[n ~/ 2]) / 2.0;
    var stable = 0;
    for (final ms in valid) {
      if ((ms - median).abs() <= toleranceMs) {
        stable++;
      }
    }
    return 100.0 * stable / n;
  }

  /// "X% low" = FPS equivalent of the average frame time of the slowest
  /// [fraction] of frames (0.01 -> 1% low, 0.001 -> 0.1% low).
  static double? lowFps(List<int> hist, double fraction, {int minFrames = 30}) {
    final total = totalFrames(hist);
    if (total < minFrames) return null;
    final need = (total * fraction).ceil().clamp(1, total).toInt();
    var remaining = need;
    var sumMs = 0.0;
    for (var i = hist.length - 1; i >= 0 && remaining > 0; i--) {
      final c = hist[i];
      if (c == 0) continue;
      final take = c < remaining ? c : remaining;
      sumMs += take * (i + 0.5) * binMs;
      remaining -= take;
    }
    final avgMs = sumMs / need;
    return avgMs > 0 ? 1000.0 / avgMs : null;
  }

  /// Average FPS of a list of frame times (frames / time they covered).
  static double? fpsOf(List<double> frameTimesMs, {int minFrames = 3}) {
    if (frameTimesMs.length < minFrames) return null;
    var sum = 0.0;
    for (final ms in frameTimesMs) {
      sum += ms;
    }
    return sum > 0 ? frameTimesMs.length * 1000.0 / sum : null;
  }

  /// Exact "X% low" for a short window of frame times.
  static double? lowFpsOfList(List<double> frameTimesMs, double fraction,
      {int minFrames = 10}) {
    final n = frameTimesMs.length;
    if (n < minFrames) return null;
    final sorted = List<double>.of(frameTimesMs)..sort((a, b) => b.compareTo(a));
    final need = (n * fraction).ceil().clamp(1, n).toInt();
    var sum = 0.0;
    for (var i = 0; i < need; i++) {
      sum += sorted[i];
    }
    final avg = sum / need;
    return avg > 0 ? 1000.0 / avg : null;
  }
}
