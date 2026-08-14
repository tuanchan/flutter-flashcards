part of flutterflashcard_main;

class _SlideToastState extends State<_SlideToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 320),
      reverseDuration: Duration(milliseconds: 220),
    );
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    _controller.forward();
    Future.delayed(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted || _closed) return;
    _closed = true;
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final toastWidth = math.min(media.size.width - 24, 380.0);
    final bg = AppColors.border;
    final fg = AppColors.readableOn(bg);

    return Positioned(
      top: media.padding.top + 14,
      right: 12,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) {
          final value = _curve.value;
          return Opacity(
            opacity: value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset((1 - value) * 120, 0),
              child: child,
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            onTap: _dismiss,
            child: Container(
              width: toastWidth,
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: fg.withOpacity(0.18), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    offset: Offset(0, 8),
                    blurRadius: 22,
                  ),
                  BoxShadow(
                    color: AppColors.green.withOpacity(0.18),
                    offset: Offset(-4, 0),
                    blurRadius: 0,
                    spreadRadius: -1,
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      widget.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class MyApp extends StatefulWidget {
  MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}


class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppThemeController.instance,
      builder: (context, _, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: AppColors.activeIsDark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: AppColors.bg,
            fontFamily: 'Arial',
            snackBarTheme: SnackBarThemeData(
              backgroundColor: AppColors.border,
              contentTextStyle: TextStyle(
                color: AppColors.readableOn(AppColors.border),
                fontWeight: FontWeight.w800,
              ),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppColors.bg,
            fontFamily: 'Arial',
            snackBarTheme: SnackBarThemeData(
              backgroundColor: AppColors.border,
              contentTextStyle: TextStyle(
                color: AppColors.readableOn(AppColors.border),
                fontWeight: FontWeight.w800,
              ),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          home: AppThemeLoader(child: HomePage()),
          routes: {
            '/login-callback/': (context) => AppThemeLoader(child: HomePage()),
            '/login-callback': (context) => AppThemeLoader(child: HomePage()),
          },
          onGenerateRoute: (settings) {
            if (settings.name != null && settings.name!.contains('login-callback')) {
              return MaterialPageRoute(
                builder: (context) => AppThemeLoader(child: HomePage()),
                settings: settings,
              );
            }
            return null;
          },
          onUnknownRoute: (settings) {
            return MaterialPageRoute(
              builder: (context) => AppThemeLoader(child: HomePage()),
              settings: settings,
            );
          },
        );
      },
    );
  }
}


class AppThemeLoader extends StatefulWidget {
  final Widget child;
  AppThemeLoader({super.key, required this.child});

  @override
  State<AppThemeLoader> createState() => _AppThemeLoaderState();
}


class _AppThemeLoaderState extends State<AppThemeLoader>
    with WidgetsBindingObserver {
  bool loaded = false;
  bool _catchUpInFlight = false;
  DateTime? _lastCatchUpAt;
  String? _lastCatchUpOwnerId;
  DateTime? _backgroundedAt;
  Timer? _outboxRetryTimer;
  late final _authSubscription;

  Future<void> _retryOutboxSafely() async {
    if (!SupabaseConfig.isLoggedIn) return;
    try {
      await SupabaseSyncService.instance.retryPendingOutbox();
    } catch (error) {
      debugPrint('SYNC OUTBOX RETRY ERROR: $error');
    }
  }

  Future<void> _startSessionAndCatchUp({
    bool newLogin = false,
    bool fullSnapshot = true,
  }) async {
    if (_catchUpInFlight || !SupabaseConfig.isLoggedIn) return;
    _catchUpInFlight = true;
    try {
      await SupabaseSyncService.instance.beginAuthenticatedSession(
        newLogin: newLogin,
      );
      if (!SupabaseConfig.isLoggedIn) return;
      // Upload durable offline answers before reading the cloud snapshot.
      // If the network is still unavailable this safely leaves the markers in
      // SQLite so they can be retried before a later replacement download.
      await _retryOutboxSafely();
      if (!fullSnapshot) {
        // A Windows resume only needs the v2 delta missed while suspended.
        // Reopening the channel triggers sync_v2_changes_since; downloading
        // the full 60k-row account snapshot here blocks Realtime/UI updates.
        SupabaseSyncService.instance.restartRealtimeSync();
        await _retryOutboxSafely();
        return;
      }
      final ownerId = SupabaseConfig.currentUser?.id;
      if (!newLogin &&
          await SupabaseSyncService.instance.hasReusableLocalSnapshot()) {
        // beginAuthenticatedSession already opened Realtime. Its subscribed
        // callback applies sync_v2_changes_since, so a normal app start keeps
        // the existing local snapshot visible and catches up only the delta.
        _lastCatchUpAt = DateTime.now();
        _lastCatchUpOwnerId = ownerId;
        await _retryOutboxSafely();
        return;
      }
      final now = DateTime.now();
      final recentlyCaughtUp = ownerId != null &&
          ownerId == _lastCatchUpOwnerId &&
          _lastCatchUpAt != null &&
          now.difference(_lastCatchUpAt!) < const Duration(minutes: 5);
      if (recentlyCaughtUp) {
        await _retryOutboxSafely();
        return;
      }
      // Realtime only delivers events while this process is connected.
      // On startup/real resume, use the server snapshot as the source of truth
      // after durable local mutations have been uploaded above.
      final result = await SupabaseSyncService.instance.syncAll();
      if (!result.hasError) {
        _lastCatchUpAt = DateTime.now();
        _lastCatchUpOwnerId = ownerId;
      }
      // Replay once more for mutations created while catch-up was running.
      await _retryOutboxSafely();
    } catch (error) {
      debugPrint('STARTUP SYNC ERROR: $error');
    } finally {
      _catchUpInFlight = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _outboxRetryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_retryOutboxSafely()),
    );
    if (SupabaseConfig.isLoggedIn) {
      unawaited(_startSessionAndCatchUp());
    }
    // Listen for auth state changes (e.g., Google OAuth redirect callback)
    _authSubscription = SupabaseConfig.onAuthStateChange.listen((data) {
      final event = data.event;
      if (event == AuthChangeEvent.signedIn) {
        unawaited(_startSessionAndCatchUp(newLogin: true));
      } else if (event == AuthChangeEvent.tokenRefreshed) {
        // A channel opened from the restored (expired) desktop session keeps
        // using that JWT. Recreate it with the newly issued access token.
        SupabaseSyncService.instance.restartRealtimeSync();
        unawaited(_retryOutboxSafely());
      } else if (event == AuthChangeEvent.signedOut) {
        SupabaseSyncService.instance.endAuthenticatedSession();
      } else if (event == AuthChangeEvent.passwordRecovery) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showPasswordResetDialog(context);
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final backgroundedAt = _backgroundedAt;
      _backgroundedAt = null;
      // Windows can emit inactive/resumed while focus moves between windows.
      // Only a genuine background interval is eligible for catch-up; the
      // five-minute guard above still prevents repeated full snapshots.
      if (backgroundedAt != null &&
          DateTime.now().difference(backgroundedAt) >=
              const Duration(seconds: 30)) {
        unawaited(_startSessionAndCatchUp(fullSnapshot: false));
      } else {
        unawaited(SupabaseSyncService.instance.beginAuthenticatedSession());
        unawaited(_retryOutboxSafely());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!loaded) {
      loaded = true;
      AppColors.load(context: context).then((_) {
        if (mounted) AppThemeController.instance.bump();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outboxRetryTimer?.cancel();
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}


class HomePage extends StatefulWidget {
  HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}


class BackupManager {
  BackupManager._();

  static Future<String> exportToProjectAssets() async {
    final db = await AppDatabase.instance.database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');

    final dbPath = await getDatabasesPath();
    final dbFile = File(p.join(dbPath, 'list_card.db'));
    if (!await dbFile.exists()) {
      throw Exception('Không tìm thấy file database nguồn tại: ${dbFile.path}');
    }

    final projectAssetsDir = Directory(p.join(Directory.current.path, 'assets'));
    if (!await projectAssetsDir.exists()) {
      throw Exception('Không tìm thấy thư mục assets ở root project: ${projectAssetsDir.path}');
    }

    final targetFile = File(p.join(projectAssetsDir.path, 'list_card.db'));
    await dbFile.copy(targetFile.path);
    return 'Đã xuất database thành công sang:\n${targetFile.path}';
  }

  static Future<void> openDbFolder() async {
    final dbPath = await getDatabasesPath();
    await openFolderIfPossible(dbPath);
  }

  static Future<Directory> _backupRoot() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docDir.path}/flashcard_backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  static Future<String> exportAll() async {
    final db = await AppDatabase.instance.database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');

    final root = await _backupRoot();
    final backupDir = Directory('${root.path}/backup_${_stamp()}');
    await backupDir.create(recursive: true);

    final dbPath = await getDatabasesPath();
    final dbFile = File('$dbPath/list_card.db');
    if (await dbFile.exists()) {
      await dbFile.copy('${backupDir.path}/list_card.db');
    }

    final docDir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${docDir.path}/tts_cache');
    if (await audioDir.exists()) {
      await _copyDirectory(audioDir, Directory('${backupDir.path}/tts_cache'));
    }

    await File('${backupDir.path}/README.txt').writeAsString(
      'Flashcard backup\n'
      'Tao luc: ${DateTime.now().toIso8601String()}\n\n'
      'Muon giu du lieu khi app mat chung chi: copy ca thu muc Documents cua app, hoac giu thu muc flashcard_backups nay.\n'
      'Backup gom list_card.db va tts_cache audio.\n',
    );

    await db.insert('import_exports', {
      'type': 'export',
      'fileName': backupDir.uri.pathSegments.isNotEmpty
          ? backupDir.uri.pathSegments.last
          : 'backup',
      'filePath': backupDir.path,
      'format': 'folder',
      'courseId': null,
      'status': 'success',
      'message': 'Export toàn bộ học phần kèm audio',
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final zipFile = await zipBackupDirectory(backupDir);

    await db.insert('import_exports', {
      'type': 'export',
      'fileName': zipFile.uri.pathSegments.isNotEmpty
          ? zipFile.uri.pathSegments.last
          : 'backup.zip',
      'filePath': zipFile.path,
      'format': 'zip',
      'courseId': null,
      'status': 'success',
      'message': 'Export file zip toàn bộ học phần kèm audio',
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await shareBackupZip(zipFile);
    return zipFile.path;
  }

  static Future<File> zipBackupDirectory(Directory backupDir) async {
    final zipPath = '${backupDir.path}.zip';
    final zipFile = File(zipPath);
    if (await zipFile.exists()) {
      await zipFile.delete();
    }

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    encoder.addDirectory(backupDir, includeDirName: false);
    encoder.close();

    return zipFile;
  }

  static Future<void> shareBackupZip(File zipFile) async {
    if (kIsWeb) return;

    if (Platform.isIOS || Platform.isAndroid) {
      await Share.shareXFiles(
        [XFile(zipFile.path)],
        subject: 'FlashCard Backup',
        text: 'Backup FlashCard gồm toàn bộ học phần, database và audio.',
      );
      return;
    }

    await openFolderIfPossible(zipFile.parent.path);
  }

  static Future<void> openFolderIfPossible(String path) async {
    try {
      if (kIsWeb) return;
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  static Future<String> importLatest() async {
    final root = await _backupRoot();
    if (!await root.exists()) {
      throw Exception('Chưa có thư mục backup');
    }

    final backups = await root
        .list()
        .where(
          (e) =>
              e is Directory &&
              e.path.split(Platform.pathSeparator).last.startsWith('backup_'),
        )
        .cast<Directory>()
        .toList();

    if (backups.isEmpty) {
      throw Exception('Chưa có bản export nào để import');
    }

    backups.sort((a, b) => b.path.compareTo(a.path));
    final latest = backups.first;
    final sourceDb = File('${latest.path}/list_card.db');
    if (!await sourceDb.exists()) {
      throw Exception('Backup không có file list_card.db');
    }

    await AppDatabase.instance.close();
    final dbPath = await getDatabasesPath();
    await sourceDb.copy('$dbPath/list_card.db');

    final docDir = await getApplicationDocumentsDirectory();
    final targetAudio = Directory('${docDir.path}/tts_cache');
    if (await targetAudio.exists()) await targetAudio.delete(recursive: true);

    final sourceAudio = Directory('${latest.path}/tts_cache');
    if (await sourceAudio.exists()) {
      await _copyDirectory(sourceAudio, targetAudio);
    }

    final db = await AppDatabase.instance.database;
    await db.insert('import_exports', {
      'type': 'import',
      'fileName': latest.uri.pathSegments.isNotEmpty
          ? latest.uri.pathSegments.last
          : 'backup',
      'filePath': latest.path,
      'format': 'folder',
      'courseId': null,
      'status': 'success',
      'message': 'Import toàn bộ học phần kèm audio',
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await openFolderIfPossible(latest.path);
    return latest.path;
  }

  static Future<String> appDataPath() async {
    final docDir = await getApplicationDocumentsDirectory();
    return docDir.path;
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    if (!await target.exists()) await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final newPath = '${target.path}${Platform.pathSeparator}$name';
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }
}


class SettingsPage extends StatefulWidget {
  SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}
