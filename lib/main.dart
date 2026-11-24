import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import 'database/app_database.dart';
import 'models/session.dart';
import 'screens/home_screen.dart';
import 'services/monitor_service.dart';
import 'services/notification_service.dart';
import 'services/shizuku_service.dart';

const MethodChannel _platform = MethodChannel('com.zsdev.fpsmonitor/channel');

/// Opens Hive using the app's private files dir, fetched from the Kotlin side.
/// (hive_flutter / path_provider is intentionally not used.)
Future<void> _initStorage() async {
  final dir = await _platform.invokeMethod<String>('getStorageDir');
  if (dir == null || dir.isEmpty) {
    throw StateError('Could not resolve storage directory');
  }
  Hive.init('$dir/hive');
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(SessionAdapter());
  }
  await Hive.openBox<Session>(AppDatabase.sessionBoxName);
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    Object? startupError;
    StackTrace? startupStack;

    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      await _initStorage();
      await MonitorService.instance.loadSettings();
      await MonitorService.instance.recoverInterruptedSession();
      await ShizukuService.instance.getDeviceInfo();
      await NotificationService.instance.init();
    } catch (e, st) {
      startupError = e;
      startupStack = st;
      debugPrint('FPS Monitor startup failed: $e\n$st');
    }

    if (startupError != null) {
      // Never leave the user on a black screen: show what went wrong.
      runApp(StartupErrorApp(error: startupError, stack: startupStack));
      return;
    }

    runApp(const FpsMonitorApp());
  }, (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
  });
}

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.stack});

  final Object error;
  final StackTrace? stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'FPS Monitor failed to start',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SelectableText('$error\n\n${stack ?? ''}'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FpsMonitorApp extends StatelessWidget {
  const FpsMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF0D1117);
    const scheme = ColorScheme.dark(
      primary: Color(0xFF4ADE80),
      onPrimary: Color(0xFF06280F),
      surface: Color(0xFF161C27),
      onSurface: Color(0xFFE5E7EB),
      error: Color(0xFFF87171),
    );

    return MaterialApp(
      title: 'FPS Monitor',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: scheme,
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1F2733),
          contentTextStyle: const TextStyle(color: Color(0xFFE5E7EB)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        dividerColor: const Color(0xFF232C3D),
        cardTheme: CardTheme(
          color: const Color(0xFF161C27),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
