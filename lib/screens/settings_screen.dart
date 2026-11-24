import 'dart:io';

import 'package:flutter/material.dart';

import '../models/device_info.dart';
import '../services/export_service.dart';
import '../services/live_csv_logger.dart';
import '../services/monitor_service.dart';
import '../services/shizuku_service.dart';
import '../utils/format_utils.dart';

const Color _bg = Color(0xFF0D1117);
const Color _card = Color(0xFF161C27);
const Color _border = Color(0xFF232C3D);
const Color _green = Color(0xFF4ADE80);
const Color _blue = Color(0xFF60A5FA);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _text = Color(0xFFE5E7EB);
const Color _textDim = Color(0xFF8B94A7);

/// App-wide monitoring, background reliability & filtering preferences.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DeviceInfo? _deviceInfo;
  bool _batteryUnrestricted = false;
  bool _notificationsGranted = true;
  List<LiveCsvFileInfo> _autosavedCsvs = const [];

  @override
  void initState() {
    super.initState();
    _deviceInfo = ShizukuService.instance.cachedDeviceInfo;
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    final info = await ShizukuService.instance.getDeviceInfo(refresh: true);
    final battery =
        await ShizukuService.instance.isBatteryOptimizationIgnored();
    final notify =
        await ShizukuService.instance.isNotificationPermissionGranted();
    final csvs = await LiveCsvLogger.instance.listAutosavedCsvs();
    if (!mounted) return;
    setState(() {
      if (info != null) _deviceInfo = info;
      _batteryUnrestricted = battery;
      _notificationsGranted = notify;
      _autosavedCsvs = csvs;
    });
  }

  Future<void> _grantBattery() async {
    await ShizukuService.instance.requestIgnoreBatteryOptimization();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refreshAll();
  }

  Future<void> _grantNotification() async {
    await ShizukuService.instance.requestNotificationPermission();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refreshAll();
  }

  Future<void> _openAutosavedCsvSheet() async {
    await _refreshAll();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.save_outlined, color: _blue, size: 19),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Auto-saved incremental CSVs',
                            style: TextStyle(
                              color: _text,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          _autosavedCsvs.length == 1
                              ? '1 file'
                              : '${_autosavedCsvs.length} files',
                          style: const TextStyle(color: _textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: _border, height: 1),
                  if (_autosavedCsvs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No auto-saved CSV files yet. Rows are flushed every 6 seconds while monitoring.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _textDim, fontSize: 12.5),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _autosavedCsvs.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: _border, height: 1),
                        itemBuilder: (_, i) {
                          final item = _autosavedCsvs[i];
                          final kb = (item.sizeBytes / 1024.0).toStringAsFixed(1);
                          return ListTile(
                            title: Text(
                              item.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _text,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${Fmt.dateTime(item.modified)} • $kb KB',
                              style: const TextStyle(
                                  color: _textDim, fontSize: 11.5),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Share CSV',
                                  icon: const Icon(Icons.ios_share_rounded,
                                      color: _green, size: 20),
                                  onPressed: () async {
                                    try {
                                      final bytes =
                                          await File(item.path).readAsBytes();
                                      await ExportService.instance.shareBytes(
                                        bytes,
                                        fileName: item.fileName,
                                        mimeType: 'text/csv',
                                        title: item.fileName,
                                      );
                                    } catch (_) {}
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Delete',
                                  icon: const Icon(Icons.delete_outline,
                                      color: _red, size: 20),
                                  onPressed: () async {
                                    final ok = await LiveCsvLogger.instance
                                        .deleteAutosavedCsv(item.path);
                                    if (!ok) return;
                                    final updated = await LiveCsvLogger.instance
                                        .listAutosavedCsvs();
                                    if (!mounted) return;
                                    setState(() => _autosavedCsvs = updated);
                                    setSheetState(() {});
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final monitor = MonitorService.instance;
    final info = _deviceInfo;
    final csvCountLabel = _autosavedCsvs.length == 1
        ? '1 file'
        : '${_autosavedCsvs.length} files';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w800, color: _text),
        ),
      ),
      body: ListenableBuilder(
        listenable: monitor,
        builder: (context, _) {
          return RefreshIndicator(
            color: _green,
            onRefresh: _refreshAll,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: [
                _section(
                  'FPS & Spike Filtering',
                  [
                    _switchTile(
                      icon: Icons.filter_alt_outlined,
                      accent: _blue,
                      title: 'Exclude loading screens',
                      subtitle:
                          'Filter 0 FPS, < 5 FPS windows & > 500 ms stalls from 1% / 0.1% lows',
                      value: monitor.excludeLoadingScreens,
                      onChanged: (v) => monitor.setExcludeLoadingScreens(v),
                    ),
                    const Divider(
                        color: _border, height: 1, indent: 16, endIndent: 16),
                    _switchTile(
                      icon: Icons.auto_fix_high_outlined,
                      accent: _amber,
                      title: 'Exclude < 10 FPS spikes',
                      subtitle:
                          'Filter < 10 FPS transition spikes (e.g. map downloads, TDM round reloads)',
                      value: monitor.excludeSub10Fps,
                      onChanged: (v) => monitor.setExcludeSub10Fps(v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _section(
                  'Background Reliability & Recovery',
                  [
                    _actionTile(
                      icon: Icons.battery_saver_rounded,
                      accent: _batteryUnrestricted ? _green : _amber,
                      title: 'Unrestricted battery',
                      subtitle: _batteryUnrestricted
                          ? 'Unrestricted — collector protected when free RAM drops < 300 MB'
                          : 'Restricted — tap to grant Unrestricted Battery for Funtouch OS / OEM ROMs',
                      badgeText: _batteryUnrestricted ? 'Granted' : 'Grant',
                      badgeColor: _batteryUnrestricted ? _green : _amber,
                      onTap: _batteryUnrestricted
                          ? () => ShizukuService.instance.openBatterySettings()
                          : _grantBattery,
                    ),
                    const Divider(
                        color: _border, height: 1, indent: 16, endIndent: 16),
                    _actionTile(
                      icon: Icons.notifications_active_outlined,
                      accent: _notificationsGranted ? _green : _amber,
                      title: 'Persistent notification',
                      subtitle:
                          'Keeps the high-priority foreground service pinned during matches',
                      badgeText: _notificationsGranted ? 'Enabled' : 'Allow',
                      badgeColor: _notificationsGranted ? _green : _amber,
                      onTap: _grantNotification,
                    ),
                    const Divider(
                        color: _border, height: 1, indent: 16, endIndent: 16),
                    _actionTile(
                      icon: Icons.save_outlined,
                      accent: _blue,
                      title: 'Incremental CSV flushing (every 6 s)',
                      subtitle:
                          'Flushes rows continuously so game crashes or reboots lose zero session data',
                      badgeText: csvCountLabel,
                      badgeColor: _blue,
                      onTap: _openAutosavedCsvSheet,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _section(
                  'Device Metadata Header',
                  [
                    _infoRow('Device model', info?.deviceModel ?? '--'),
                    const Divider(
                        color: _border, height: 1, indent: 16, endIndent: 16),
                    _infoRow('Chipset (SoC)', info?.socName ?? '--'),
                    const Divider(
                        color: _border, height: 1, indent: 16, endIndent: 16),
                    _infoRow(
                      'Total RAM',
                      info != null && info.totalRamMb > 0
                          ? info.ramDetailed
                          : '--',
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(6, 14, 6, 0),
                  child: Text(
                    'Tip: Leading and trailing loading screens are auto-trimmed when a session ends. '
                    'On Vivo / iQOO Funtouch OS, you can also verify "Allow high background power usage" under App info.',
                    style: TextStyle(
                        color: _textDim, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

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
            child: Text(
              title,
              style: const TextStyle(
                color: _textDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: _textDim,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            activeColor: _green,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: _textDim,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: badgeColor.withOpacity(0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  color: badgeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: _textDim, fontSize: 13),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
