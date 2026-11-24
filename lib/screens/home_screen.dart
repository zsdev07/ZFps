import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/installed_app.dart';
import '../models/session.dart';
import '../services/monitor_service.dart';
import '../services/shizuku_service.dart';
import '../utils/format_utils.dart';
import '../widgets/stat_card.dart';
import 'app_selection_screen.dart';
import 'customize_screen.dart';
import 'report_screen.dart';
import 'settings_screen.dart';

const Color _bg = Color(0xFF0D1117);
const Color _card = Color(0xFF161C27);
const Color _cardAlt = Color(0xFF1A2130);
const Color _border = Color(0xFF232C3D);
const Color _green = Color(0xFF4ADE80);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _blue = Color(0xFF60A5FA);
const Color _violet = Color(0xFFA78BFA);
const Color _text = Color(0xFFE5E7EB);
const Color _textDim = Color(0xFF8B94A7);
const Color _textFaint = Color(0xFF6B7484);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ShizukuStatus _shizuku = const ShizukuStatus.offline();
  bool _overlayGranted = false;
  bool _batteryUnrestricted = true;
  bool _batteryChecked = false;
  bool _notificationsGranted = true;
  bool _skippedBatteryPrompt = false;
  bool _busy = false;
  InstalledApp? _selectedApp;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _refresh(silent: true);
    // Re-check permissions so toggling them in system settings reflects here
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final status = await ShizukuService.instance.checkShizuku();
    final overlay = await ShizukuService.instance.checkOverlayPermission();
    final battery =
        await ShizukuService.instance.isBatteryOptimizationIgnored();
    final notifications =
        await ShizukuService.instance.isNotificationPermissionGranted();
    if (!mounted) return;
    setState(() {
      _shizuku = status;
      _overlayGranted = overlay;
      _batteryUnrestricted = battery;
      _batteryChecked = true;
      _notificationsGranted = notifications;
    });
  }

  Future<void> _bindShizuku() async {
    await ShizukuService.instance.bindShizuku();
    // bindUserService is async; poll for a few seconds
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refresh();
      if (_shizuku.bound) break;
    }
  }

  Future<void> _requestOverlay() async {
    await ShizukuService.instance.requestOverlayPermission();
  }

  Future<void> _requestBatteryUnrestricted() async {
    await ShizukuService.instance.requestIgnoreBatteryOptimization();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refresh();
  }

  Future<void> _openBatterySettings() async {
    await ShizukuService.instance.openBatterySettings();
  }

  Future<void> _requestNotificationPermission() async {
    await ShizukuService.instance.requestNotificationPermission();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refresh();
  }

  Future<bool> _promptUnrestrictedBattery() async {
    final grant = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _border),
        ),
        title: const Row(
          children: [
            Icon(Icons.battery_saver_rounded, color: _amber, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Grant Unrestricted Battery?',
                style: TextStyle(
                  color: _text,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'OEM battery savers (like Funtouch OS) can kill background collectors '
          'when free RAM drops below 300 MB mid-match.\n\n'
          'Allowing Unrestricted Battery keeps the high-priority foreground '
          'service alive through full matches.',
          style: TextStyle(color: _textDim, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Start anyway',
                style: TextStyle(color: _textDim)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _amber,
              foregroundColor: const Color(0xFF2E2104),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Grant Unrestricted Battery',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    return grant == true;
  }

  Future<void> _pickApp() async {
    final app = await Navigator.of(context).push<InstalledApp>(
      MaterialPageRoute(builder: (_) => const AppSelectionScreen()),
    );
    if (app != null && mounted) {
      setState(() => _selectedApp = app);
    }
  }

  Future<void> _start() async {
    final monitor = MonitorService.instance;
    if (!_overlayGranted) {
      _showSnack('Grant "Display over other apps" first — the overlay is required.');
      return;
    }
    if (!_shizuku.isOperational) {
      _showSnack('Bind Shizuku first — it is required for hardware metrics.');
      await _refresh();
      return;
    }
    if (!_notificationsGranted) {
      await _requestNotificationPermission();
    }
    if (_batteryChecked && !_batteryUnrestricted && !_skippedBatteryPrompt) {
      final wantsGrant = await _promptUnrestrictedBattery();
      if (!mounted) return;
      if (wantsGrant) {
        await _requestBatteryUnrestricted();
        return;
      }
      _skippedBatteryPrompt = true;
    }
    if (_selectedApp == null) {
      await _pickApp();
      if (_selectedApp == null) return;
    }
    setState(() => _busy = true);
    final ok = await monitor.startSession(
      appName: _selectedApp!.name,
      packageName: _selectedApp!.packageName,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _showSnack(ok ? 'Monitoring ${_selectedApp!.name} — overlay is live' : 'Failed to start monitoring');
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    final session = await MonitorService.instance.stopSession();
    if (!mounted) return;
    setState(() => _busy = false);
    if (session != null) {
      _showSnack('Session complete — report saved');
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReportScreen(focusSessionId: session.id)),
      );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1F2733),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _copyAdbCommand() {
    Clipboard.setData(const ClipboardData(
      text: 'adb shell sh /sdcard/Shizuku/start.sh',
    ));
    _showSnack('ADB command copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final monitor = MonitorService.instance;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _green.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.speed_rounded, color: _green, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FPS Monitor',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: _text)),
                Text('Game performance, live',
                    style: TextStyle(fontSize: 10.5, color: _textDim)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Customize overlay',
            icon: const Icon(Icons.tune_rounded, color: _textDim),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CustomizeScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Performance reports',
            icon: const Icon(Icons.receipt_long_outlined, color: _textDim),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReportScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, color: _textDim),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: monitor,
        builder: (context, _) {
          return RefreshIndicator(
            color: _green,
            onRefresh: () => _refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              children: [
                if (monitor.lastRecoveredSession != null) ...[
                  _RecoveredBanner(
                    session: monitor.lastRecoveredSession!,
                    onView: () {
                      final id = monitor.lastRecoveredSession!.id;
                      monitor.clearRecoveredNotice();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReportScreen(focusSessionId: id),
                        ),
                      );
                    },
                    onDismiss: monitor.clearRecoveredNotice,
                  ),
                  const SizedBox(height: 12),
                ],
                _ShizukuCard(
                  status: _shizuku,
                  onBind: _bindShizuku,
                  onRefresh: _refresh,
                  onCopyAdb: _copyAdbCommand,
                ),
                const SizedBox(height: 12),
                _OverlayCard(
                  granted: _overlayGranted,
                  onGrant: _requestOverlay,
                  onRefresh: _refresh,
                ),
                if (_batteryChecked) ...[
                  const SizedBox(height: 12),
                  _BatteryCard(
                    batteryUnrestricted: _batteryUnrestricted,
                    notificationsGranted: _notificationsGranted,
                    onGrantBattery: _requestBatteryUnrestricted,
                    onOpenBatterySettings: _openBatterySettings,
                    onGrantNotification: _requestNotificationPermission,
                  ),
                ],
                const SizedBox(height: 12),
                _CustomizeCard(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CustomizeScreen()),
                  ),
                ),
                const SizedBox(height: 12),
                _TargetCard(
                  app: _selectedApp,
                  onTap: _pickApp,
                ),
                if (monitor.isMonitoring) ...[
                  const SizedBox(height: 14),
                  _LivePanel(monitor: monitor),
                ],
                const SizedBox(height: 18),
                _buildActionButton(monitor),
                const SizedBox(height: 10),
                const Text(
                  'Metrics collected via Shizuku • 2 s interval • Session data is stored on-device',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: _textFaint),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionButton(MonitorService monitor) {
    if (_busy) {
      return Container(
        height: 56,
        decoration: BoxDecoration(
          color: _cardAlt,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: _green),
        ),
      );
    }

    if (monitor.isMonitoring) {
      final paused = monitor.isPaused;
      return Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                onPressed: paused
                    ? () => monitor.resumeSession()
                    : () => monitor.pauseSession(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: paused ? _green : _amber,
                  foregroundColor: const Color(0xFF14181F),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                icon: Icon(
                  paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 24,
                ),
                label: Text(
                  paused ? 'RESUME' : 'PAUSE',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, letterSpacing: 1.0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _stop,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: const Color(0xFF210A0A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                icon: const Icon(Icons.stop_rounded, size: 24),
                label: const Text(
                  'STOP',
                  style: TextStyle(
                      fontWeight: FontWeight.w800, letterSpacing: 1.0),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final canStart = _overlayGranted && _shizuku.isOperational;
    return Column(
      children: [
        SizedBox(
          height: 56,
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: canStart ? _start : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: const Color(0xFF06280F),
              disabledBackgroundColor: _cardAlt,
              disabledForegroundColor: _textFaint,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
            ),
            icon: Icon(canStart ? Icons.play_arrow_rounded : Icons.lock_outline_rounded, size: 26),
            label: Text(
              _selectedApp == null ? 'SELECT APP TO MONITOR' : 'START MONITORING',
              style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.1),
            ),
          ),
        ),
        if (!canStart) ...[
          const SizedBox(height: 8),
          Text(
            !_overlayGranted && !_shizuku.isOperational
                ? 'Grant overlay permission and bind Shizuku to start'
                : !_overlayGranted
                    ? 'Grant "Display over other apps" to start'
                    : 'Bind Shizuku to start',
            style: const TextStyle(fontSize: 11, color: _amber),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ cards

class _ShizukuCard extends StatelessWidget {
  final ShizukuStatus status;
  final Future<void> Function() onBind;
  final Future<void> Function({bool silent}) onRefresh;
  final VoidCallback onCopyAdb;

  const _ShizukuCard({
    required this.status,
    required this.onBind,
    required this.onRefresh,
    required this.onCopyAdb,
  });

  @override
  Widget build(BuildContext context) {
    final ready = status.isOperational;
    final dotColor = ready ? _green : (status.running ? _amber : _red);
    final subtitle = !status.running
        ? 'Shizuku not detected on device'
        : status.preV11
            ? 'Detected (pre-v11) — please update Shizuku'
            : status.bound
                ? 'Running v${status.version} • service bound'
                : status.permissionGranted
                    ? 'Running v${status.version} • permission granted, binding…'
                    : 'Running v${status.version} • permission not granted';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: dotColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.hexagon_outlined, color: dotColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Shizuku',
                        style: TextStyle(
                            color: _text, fontWeight: FontWeight.w800, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 11, color: _textDim, height: 1.35)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Re-check',
                icon: const Icon(Icons.refresh_rounded, color: _textFaint, size: 20),
                onPressed: () => onRefresh(),
              ),
            ],
          ),
          if (!status.running) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF10151F),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1F2A3D)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: const Text(
                      'adb shell sh /sdcard/Shizuku/start.sh',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: Color(0xFF7DD3FC),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy ADB command',
                    icon: const Icon(Icons.copy_rounded, size: 17, color: _textDim),
                    onPressed: onCopyAdb,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Start Shizuku from a PC via ADB (or root), then relaunch this card state.',
              style: TextStyle(fontSize: 10, color: _textFaint),
            ),
          ] else if (!status.permissionGranted) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => onBind(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cardAlt,
                  foregroundColor: _text,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('Grant Shizuku permission',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              ),
            ),
          ] else if (!status.bound) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => onBind(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _text,
                  side: const BorderSide(color: _border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Bind Shizuku service',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OverlayCard extends StatelessWidget {
  final bool granted;
  final VoidCallback onGrant;
  final Future<void> Function({bool silent}) onRefresh;

  const _OverlayCard({
    required this.granted,
    required this.onGrant,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final accent = granted ? _green : _amber;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: granted ? _border : const Color(0xFF3D331F)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              granted ? Icons.layers_outlined : Icons.layers_clear_outlined,
              color: accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Display over other apps',
                    style: TextStyle(
                        color: _text, fontWeight: FontWeight.w800, fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  granted
                      ? 'Overlay permission granted'
                      : 'Required to float stats on top of your games',
                  style: const TextStyle(fontSize: 11, color: _textDim, height: 1.35),
                ),
                if (!granted) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 34,
                    child: ElevatedButton.icon(
                      onPressed: onGrant,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _amber,
                        foregroundColor: const Color(0xFF2E2104),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 15),
                      label: const Text('Grant permission',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (granted)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.check_circle_rounded, color: _green, size: 26),
            ),
        ],
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  final InstalledApp? app;
  final VoidCallback onTap;

  const _TargetCard({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    Widget leading;
    if (app != null && app!.icon.isNotEmpty) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          Uint8List.fromList(app!.icon),
          width: 46,
          height: 46,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackIcon(),
        ),
      );
    } else {
      leading = _fallbackIcon();
    }

    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('MONITORING TARGET',
                        style: TextStyle(
                            fontSize: 9.5,
                            letterSpacing: 1.1,
                            color: _textFaint,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                      app?.name ?? 'No app selected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: _text, fontWeight: FontWeight.w700, fontSize: 14.5),
                    ),
                    Text(
                      app?.packageName ?? 'Tap to choose a game or app',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _textDim),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    app == null ? 'Select' : 'Change',
                    style: const TextStyle(
                        color: _green, fontWeight: FontWeight.w800, fontSize: 12.5),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right_rounded, color: _green),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallbackIcon() => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: _cardAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.sports_esports_outlined, color: _violet, size: 24),
      );
}

class _LivePanel extends StatelessWidget {
  final MonitorService monitor;

  const _LivePanel({required this.monitor});

  @override
  Widget build(BuildContext context) {
    final s = monitor.current;
    final paused = monitor.isPaused;
    final fps = s?.fps ?? -1;
    final fpsColor = paused
        ? _amber
        : fps < 0
            ? _textDim
            : fps >= 50
                ? _green
                : fps >= 30
                    ? _amber
                    : _red;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF131B29), Color(0xFF101620)],
        ),
        border: Border.all(color: const Color(0xFF273449)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: paused ? _amber : _red,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(paused ? 'PAUSED' : 'LIVE',
                  style: TextStyle(
                      color: paused ? _amber : _red,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      fontSize: 11)),
              if (monitor.liveStability != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (monitor.liveStability! >= 90
                            ? _green
                            : (monitor.liveStability! >= 75 ? _amber : _red))
                        .withOpacity(0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Stability ${monitor.liveStability!.toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: monitor.liveStability! >= 90
                          ? _green
                          : (monitor.liveStability! >= 75 ? _amber : _red),
                    ),
                  ),
                ),
              ],
              const Spacer(),
              const Icon(Icons.timer_outlined, size: 15, color: _textDim),
              const SizedBox(width: 5),
              Text(Fmt.durationHms(monitor.elapsed),
                  style: const TextStyle(
                      color: _textDim,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                paused ? 'II' : (s == null ? '--' : Fmt.fps(fps)),
                style: TextStyle(
                  fontSize: 72,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  color: fpsColor,
                  letterSpacing: -2,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10, left: 8),
                child: Text(paused ? 'PAUSED' : 'FPS',
                    style: const TextStyle(
                        color: _textDim, fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ],
          ),
          if (monitor.excludedSamples > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${monitor.excludedSamples} loading spike${monitor.excludedSamples == 1 ? '' : 's'} excluded',
              style: const TextStyle(fontSize: 11, color: _blue),
            ),
          ],
          if (monitor.csvFlushedRows > 0) ...[
            const SizedBox(height: 4),
            Text(
              'CSV auto-saved • ${monitor.csvFlushedRows} row${monitor.csvFlushedRows == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 10.5, color: _textDim),
            ),
          ],
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6,
            children: [
              StatCard(
                icon: Icons.thermostat_outlined,
                label: 'CPU TEMP',
                value: Fmt.temp(s?.cpuTemp ?? -1),
                accent: _red,
              ),
              StatCard(
                icon: Icons.thermostat_outlined,
                label: 'GPU TEMP',
                value: Fmt.temp(s?.gpuTemp ?? -1),
                accent: const Color(0xFFFB923C),
              ),
              StatCard(
                icon: Icons.memory_outlined,
                label: 'CPU USAGE',
                value: Fmt.percent(s?.cpuUsage ?? -1),
                accent: _blue,
              ),
              StatCard(
                icon: Icons.grid_view_outlined,
                label: 'GPU USAGE',
                value: Fmt.percent(s?.gpuUsage ?? -1),
                accent: _violet,
              ),
              StatCard(
                icon: Icons.storage_outlined,
                label: 'FREE RAM',
                value: Fmt.mb(s?.freeRamMb ?? -1),
                accent: _green,
              ),
              StatCard(
                icon: Icons.sd_storage_outlined,
                label: 'STORAGE',
                value: Fmt.speed(s?.storageSpeed ?? -1),
                accent: const Color(0xFF34D399),
              ),
              StatCard(
                icon: Icons.bolt_outlined,
                label: 'BATTERY mA',
                value: Fmt.currentMa(s?.batteryCurrentMa ?? -1),
                accent: _amber,
              ),
              StatCard(
                icon: Icons.power_outlined,
                label: 'POWER DRAW',
                value: Fmt.watts(s?.batteryPowerWatts ?? -1),
                accent: const Color(0xFFFB923C),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shortcut card that opens the overlay customization screen.
class _CustomizeCard extends StatelessWidget {
  final VoidCallback onTap;

  const _CustomizeCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _violet.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.tune_rounded, color: _violet, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Customize overlay',
                        style: TextStyle(
                            color: _text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 2),
                    Text('Choose stats, transparency and size',
                        style: TextStyle(color: _textDim, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _textDim),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatteryCard extends StatelessWidget {
  final bool batteryUnrestricted;
  final bool notificationsGranted;
  final VoidCallback onGrantBattery;
  final VoidCallback onOpenBatterySettings;
  final VoidCallback onGrantNotification;

  const _BatteryCard({
    required this.batteryUnrestricted,
    required this.notificationsGranted,
    required this.onGrantBattery,
    required this.onOpenBatterySettings,
    required this.onGrantNotification,
  });

  @override
  Widget build(BuildContext context) {
    final allReady = batteryUnrestricted && notificationsGranted;
    final accent = allReady ? _green : _amber;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: allReady ? _border : const Color(0xFF3D331F),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              allReady
                  ? Icons.shield_outlined
                  : Icons.battery_alert_outlined,
              color: accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  batteryUnrestricted
                      ? (notificationsGranted
                          ? 'Background protection active'
                          : 'Persistent notification disabled')
                      : 'Unrestricted battery',
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  batteryUnrestricted
                      ? (notificationsGranted
                          ? 'High-priority foreground service & 6 s CSV auto-save active'
                          : 'Allow notifications to pin the live foreground service')
                      : 'Prevents Funtouch OS / Android from killing monitoring when free RAM drops < 300 MB',
                  style: const TextStyle(
                    fontSize: 11,
                    color: _textDim,
                    height: 1.35,
                  ),
                ),
                if (!batteryUnrestricted) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      SizedBox(
                        height: 34,
                        child: ElevatedButton.icon(
                          onPressed: onGrantBattery,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _amber,
                            foregroundColor: const Color(0xFF2E2104),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.battery_saver_rounded, size: 15),
                          label: const Text(
                            'Grant Unrestricted Battery',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 34,
                        child: OutlinedButton(
                          onPressed: onOpenBatterySettings,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _textDim,
                            side: const BorderSide(color: _border),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'App info',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (!notificationsGranted) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 34,
                    child: ElevatedButton.icon(
                      onPressed: onGrantNotification,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _amber,
                        foregroundColor: const Color(0xFF2E2104),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: const Icon(
                        Icons.notifications_active_outlined,
                        size: 15,
                      ),
                      label: const Text(
                        'Allow notifications',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (allReady)
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 8),
              child: Icon(Icons.check_circle_rounded, color: _green, size: 26),
            ),
        ],
      ),
    );
  }
}

class _RecoveredBanner extends StatelessWidget {
  final Session session;
  final VoidCallback onView;
  final VoidCallback onDismiss;

  const _RecoveredBanner({
    required this.session,
    required this.onView,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF132234),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _blue.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.restore_rounded, color: _blue, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Interrupted session recovered',
                  style: TextStyle(
                    color: _text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${session.appName} • ${session.durationFormatted} restored from auto-saved CSV',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onView,
            child: const Text(
              'View',
              style: TextStyle(color: _green, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: _textDim, size: 18),
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
