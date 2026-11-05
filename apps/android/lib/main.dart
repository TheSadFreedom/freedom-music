import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'data/app_paths.dart';
import 'data/database.dart';
import 'navigation/app_navigator.dart';
import 'screens/shell.dart';
import 'services/audio_handler.dart';
import 'services/library_service.dart';
import 'services/player_service.dart';
import 'services/settings_service.dart';
import 'services/storage_access.dart';
import 'theme/app_theme.dart';
import 'widgets/app_player_layer.dart';
import 'widgets/startup_splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final images = PaintingBinding.instance.imageCache;
  images.maximumSize = 200;
  images.maximumSizeBytes = 64 << 20;

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0E0E0C),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  runApp(const _BootApp());
}

class _BootApp extends StatefulWidget {
  const _BootApp();

  @override
  State<_BootApp> createState() => _BootAppState();
}

class _Ready {
  const _Ready({
    required this.settings,
    required this.library,
    required this.player,
  });

  final SettingsService settings;
  final LibraryService library;
  final PlayerService player;
}

class _BootAppState extends State<_BootApp> {
  _Ready? _ready;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    await Future<void>.delayed(Duration.zero);
    try {
      final settings = await SettingsService.create();
      final paths = await AppPaths.resolve();
      final db = await AppDatabase.open(paths);
      final library = LibraryService(paths: paths, db: db, settings: settings);
      final player = PlayerService(library, settings);
      library.unlockAudioForWrite = player.whileAudioUnlocked;
      await library.init();
      await player.restoreSession();
      if (!mounted) return;
      setState(() {
        _ready = _Ready(
          settings: settings,
          library: library,
          player: player,
        );
      });
      // Сначала UI и диалог разрешений, потом media-notification.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await StorageAccess.ensureNotifications();
        for (var i = 0; i < 24; i++) {
          if (await StorageAccess.hasNotifications()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await initAudioHandler(player);
        if (settings.playOnStartup) {
          unawaited(player.startOnLaunch());
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready == null) {
      return MaterialApp(
        title: 'Freedom Music',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: AppTheme.ink,
        ),
        home: StartupSplash(error: _error),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ready.settings),
        ChangeNotifierProvider.value(value: ready.library),
        ChangeNotifierProvider.value(value: ready.player),
      ],
      child: const FreedomMusicApp(),
    );
  }
}

class FreedomMusicApp extends StatelessWidget {
  const FreedomMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Freedom Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        return TooltipVisibility(
          visible: false,
          child: AppPlayerLayer(child: child ?? const SizedBox.shrink()),
        );
      },
      home: const AppShell(),
    );
  }
}
