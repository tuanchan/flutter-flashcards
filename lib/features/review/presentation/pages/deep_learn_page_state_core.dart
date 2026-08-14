part of flutterflashcard_main;

enum _DeepLearnQuestionType { multipleChoice, written, flashcard }

/// Chế độ hỏi ngôn ngữ:
/// - [both]       : xen kẽ ngẫu nhiên hỏi từ vựng hoặc nghĩa (mặc định)
/// - [termOnly]   : luôn hỏi từ vựng (prompt = thuật ngữ, answer = định nghĩa)
/// - [definitionOnly]: luôn hỏi nghĩa  (prompt = định nghĩa, answer = thuật ngữ)
enum _DeepLearnLanguageMode { both, termOnly, definitionOnly }

class _DeepLearnQuestion {
  final StudyCardItem card;
  final _DeepLearnQuestionType type;
  final bool promptIsDefinition;
  final List<String> choices;
  bool flipped;
  bool locked;

  _DeepLearnQuestion({
    required this.card,
    required this.type,
    required this.promptIsDefinition,
    this.choices = const [],
    this.flipped = false,
    this.locked = false,
  });

  String get prompt => promptIsDefinition ? card.definition : card.term;
  String get answer => promptIsDefinition ? card.term : card.definition;
  String get promptLabel => promptIsDefinition ? 'Định nghĩa' : 'Thuật ngữ';
}

class _DeepLearnFeedback {
  final bool correct;
  final String answer;
  final String pickedValue;
  final String message;
  final bool skipped;

  const _DeepLearnFeedback({
    required this.correct,
    required this.answer,
    required this.pickedValue,
    required this.message,
    this.skipped = false,
  });
}

class _DeepLearnPageState extends State<DeepLearnPage> {
  static const int _requiredCorrect = 2;
  static const int _requeueMinGap = 2;
  static const int _windowsAudioWarmupMs = 100;
  static const int _correctSoundDurationMs = 1000;
  static const List<String> _correctMessages = [
    'Xuất sắc!',
    'Bạn sẽ làm được!',
    'Chính xác!',
    'Tuyệt vời!',
    'Làm tốt lắm!',
    'Quá ổn!',
    'Tiếp tục phát huy nhé!',
  ];

  final math.Random _random = math.Random();
  final TextEditingController _answerController = TextEditingController();
  final FlutterTts _tts = FlutterTts();
  AudioPlayer? _correctPlayer;

  List<StudyCardItem> _cards = [];
  final Map<int, int> _remainingCorrect = {};
  final List<int> _queue = [];
  final Set<int> _mastered = {};
  final Map<int, int> _wrongMap = {};
  final Set<int> _starred = {};
  _DeepLearnQuestion? _current;
  _DeepLearnFeedback? _feedback;

  bool _isLoading = true;
  bool _settingsOpen = false;
  bool _multipleChoice = true;
  bool _written = true;
  bool _flashcard = false;
  bool _correctSoundEnabled = true;
  bool _completed = false;
  bool _didRequestSrsSync = false;
  Future<SyncResult>? _srsSyncFuture;
  Future<void> _reviewWriteTail = Future<void>.value();
  late final LearningSyncPause _learningSyncPause;
  _DeepLearnLanguageMode _languageMode = _DeepLearnLanguageMode.both;
  bool _correctSoundReady = false;
  Future<void>? _correctSoundPreparation;
  File? _windowsCorrectSoundFile;
  Process? _windowsSoundProcess;
  String _storageKey = '';

  int get _total => _cards.length * _requiredCorrect;
  int get _correct => _remainingCorrect.values.fold<int>(
        0,
        (sum, remaining) =>
            sum + _requiredCorrect - remaining.clamp(0, _requiredCorrect).toInt(),
      );

  @override
  void initState() {
    super.initState();
    _learningSyncPause =
        SupabaseSyncService.instance.pauseSyncWhileLearning();
    if (kIsWeb || !Platform.isWindows) _correctPlayer = AudioPlayer();
    _load();
  }

  @override
  void reassemble() {
    super.reassemble();
    if (!kIsWeb && Platform.isWindows) {
      // Hot reload keeps the old State instance. Remove any AudioPlayer that
      // existed before the Windows-specific implementation was installed.
      _correctPlayer = null;
      _correctSoundReady = false;
      _windowsCorrectSoundFile = null;
      _correctSoundPreparation = null;
      _disposeWindowsSoundPlayer();
      if (_correctSoundEnabled) _prepareCorrectSound();
    }
  }

  @override
  void dispose() {
    final saveFuture = _saveState();
    unawaited(_releaseLearningPauseAfterPendingWrites(saveFuture));
    _answerController.dispose();
    _tts.stop();
    _correctPlayer?.dispose();
    _disposeWindowsSoundPlayer();
    super.dispose();
  }

  Future<void> _releaseLearningPauseAfterPendingWrites(
    Future<void> saveFuture,
  ) async {
    try {
      await _reviewWriteTail;
      await saveFuture;
      final srsSyncFuture = _srsSyncFuture;
      if (srsSyncFuture != null) await srsSyncFuture;
    } catch (error) {
      debugPrint('DEEP LEARN FINAL SYNC ERROR: $error');
    } finally {
      _learningSyncPause.release();
    }
  }

  Future<void> _load() async {
    try {
      final db = await AppDatabase.instance.database;
      List<Map<String, Object?>> rows;
      
      if (widget.cardIds != null && widget.cardIds!.isNotEmpty) {
        final placeholders = List.filled(widget.cardIds!.length, '?').join(',');
        rows = await db.rawQuery(
          '''
          SELECT * FROM cards
          WHERE courseId = ?
            AND deletedAt IS NULL
            AND isHidden = 0
            AND id IN ($placeholders)
          ORDER BY position ASC, id ASC
          ''',
          [widget.courseId, ...widget.cardIds!],
        );
      } else if (widget.dueOnly) {
        final now = DateTime.now();
        final tomorrowStart = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(const Duration(days: 1));
        rows = await db.rawQuery(
          '''
          SELECT ca.* FROM cards ca
          INNER JOIN courses c ON c.id = ca.courseId
          INNER JOIN review_states rs ON rs.cardId = ca.id
          WHERE ca.deletedAt IS NULL
            AND ca.isHidden = 0
            AND c.deletedAt IS NULL
            AND COALESCE(rs.repetitionCount, 0) > 0
            AND rs.nextReviewAt IS NOT NULL
            AND rs.nextReviewAt < ?
            AND ca.courseId = ?
          ORDER BY rs.nextReviewAt ASC, ca.position ASC, ca.id ASC
        ''',
          [tomorrowStart.toIso8601String(), widget.courseId],
        );
      } else {
        rows = await db.query(
          'cards',
          where: 'courseId = ? AND deletedAt IS NULL AND isHidden = 0',
          whereArgs: [widget.courseId],
          orderBy: 'position ASC, id ASC',
        );
      }

      final cards = rows.map(StudyCardItem.fromMap).where((card) {
        return card.term.trim().isNotEmpty && card.definition.trim().isNotEmpty;
      }).toList();
      if (!mounted) return;
      _cards = cards;
      _storageKey = _buildStorageKey(cards);
      await _loadGlobalSettings();
      if (_correctSoundEnabled) unawaited(_prepareCorrectSound());
      
      final isAdhocOrDue = widget.dueOnly || (widget.cardIds != null && widget.cardIds!.isNotEmpty);
      final restored = isAdhocOrDue ? false : await _restoreState();
      if (!restored) _createState(cards);
      _normalizeQueue();
      setState(() => _isLoading = false);
      if (_cards.isNotEmpty) _renderNextQuestion();
    } catch (error) {
      debugPrint('LOAD DEEP LEARN ERROR: $error');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _buildStorageKey(List<StudyCardItem> cards) {
    var hash = 0;
    final signature = cards
        .map((card) => '${card.id}:${card.term}:${card.definition}:${card.pronunciation}')
        .join('|');
    for (final unit in signature.codeUnits) {
      hash = ((hash << 5) - hash + unit) & 0x7fffffff;
    }
    return 'deepLearn.v2.${widget.courseId}.$hash';
  }

  Future<void> _loadGlobalSettings() async {
    _multipleChoice =
        await AppSettingsStore.getBool('deepLearn.multipleChoice') ?? true;
    _written = await AppSettingsStore.getBool('deepLearn.written') ?? true;
    _flashcard = await AppSettingsStore.getBool('deepLearn.flashcard') ?? false;
    _correctSoundEnabled =
        await AppSettingsStore.getBool('deepLearn.correctSoundEnabled') ?? true;
    final langModeRaw =
        await AppSettingsStore.getString('deepLearn.languageMode');
    _languageMode = _parseLangMode(langModeRaw);
    if (!_multipleChoice && !_written && !_flashcard) _multipleChoice = true;
  }

  static _DeepLearnLanguageMode _parseLangMode(String? raw) {
    switch (raw) {
      case 'termOnly':
        return _DeepLearnLanguageMode.termOnly;
      case 'definitionOnly':
        return _DeepLearnLanguageMode.definitionOnly;
      default:
        return _DeepLearnLanguageMode.both;
    }
  }

  static String _langModeToString(_DeepLearnLanguageMode mode) {
    switch (mode) {
      case _DeepLearnLanguageMode.termOnly:
        return 'termOnly';
      case _DeepLearnLanguageMode.definitionOnly:
        return 'definitionOnly';
      case _DeepLearnLanguageMode.both:
        return 'both';
    }
  }

  void _createState(List<StudyCardItem> cards) {
    _remainingCorrect
      ..clear()
      ..addEntries(cards.map((card) => MapEntry(card.id, _requiredCorrect)));
    _queue
      ..clear()
      ..addAll(cards.map((card) => card.id))
      ..shuffle(_random);
    _mastered.clear();
    _wrongMap.clear();
    _starred
      ..clear()
      ..addAll(cards.where((card) => card.isFavorite).map((card) => card.id));
    _completed = false;
    _didRequestSrsSync = false;
  }

  Future<bool> _restoreState() async {
    final raw = await AppSettingsStore.getString(_storageKey);
    if (raw == null || raw.isEmpty) return false;
    try {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      final validIds = _cards.map((card) => card.id).toSet();
      final savedRemaining = Map<String, dynamic>.from(saved['cards'] as Map? ?? const {});
      _remainingCorrect.clear();
      for (final card in _cards) {
        final value = (savedRemaining['${card.id}'] as num?)?.toInt() ?? _requiredCorrect;
        _remainingCorrect[card.id] = value.clamp(0, _requiredCorrect).toInt();
      }
      _queue
        ..clear()
        ..addAll((saved['queue'] as List? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where((id) => validIds.contains(id) && (_remainingCorrect[id] ?? 0) > 0));
      _mastered
        ..clear()
        ..addAll((saved['mastered'] as List? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where(validIds.contains));
      _wrongMap.clear();
      final wrong = Map<String, dynamic>.from(saved['wrongMap'] as Map? ?? const {});
      for (final entry in wrong.entries) {
        final id = int.tryParse(entry.key);
        if (id != null && validIds.contains(id)) {
          _wrongMap[id] = math.max(1, (entry.value as num?)?.toInt() ?? 1);
        }
      }
      _starred
        ..clear()
        ..addAll((saved['starred'] as List? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where(validIds.contains));
      final settings = Map<String, dynamic>.from(saved['settings'] as Map? ?? const {});
      _multipleChoice = settings['mc'] != false;
      _written = settings['write'] != false;
      _flashcard = settings['flash'] == true;
      _languageMode = _parseLangMode(settings['langMode'] as String?);
      if (!_multipleChoice && !_written && !_flashcard) _multipleChoice = true;
      _completed = _correct >= _total && _total > 0;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveState() async {
    if (_storageKey.isEmpty || _cards.isEmpty) return;
    await AppSettingsStore.setString(
      _storageKey,
      jsonEncode({
        'cards': _remainingCorrect.map((key, value) => MapEntry('$key', value)),
        'queue': _queue,
        'mastered': _mastered.toList(),
        'wrongMap': _wrongMap.map((key, value) => MapEntry('$key', value)),
        'starred': _starred.toList(),
        'settings': {'mc': _multipleChoice, 'write': _written, 'flash': _flashcard, 'langMode': _langModeToString(_languageMode)},
      }),
    );
  }

  void _normalizeQueue() {
    final active = _cards
        .where((card) => (_remainingCorrect[card.id] ?? 0) > 0)
        .map((card) => card.id)
        .toSet();
    _queue.removeWhere((id) => !active.contains(id));
    for (final id in active) {
      if (!_queue.contains(id)) _queue.add(id);
    }
    _mastered.removeWhere(active.contains);
    for (final card in _cards) {
      if (!active.contains(card.id)) _mastered.add(card.id);
    }
  }

  void _renderNextQuestion() {
    _normalizeQueue();
    _saveState();
    if (_correct >= _total || _queue.isEmpty) {
      setState(() {
        _completed = true;
        _current = null;
        _feedback = null;
      });
      _syncSrsAfterCompletion();
      return;
    }
    if (_queue.length > 1 && _current != null && _queue.first == _current!.card.id) {
      _queue.add(_queue.removeAt(0));
    }
    final id = _queue.removeAt(0);
    final card = _cards.firstWhere((item) => item.id == id);
    final types = <_DeepLearnQuestionType>[
      if (_multipleChoice) _DeepLearnQuestionType.multipleChoice,
      if (_written) _DeepLearnQuestionType.written,
      if (_flashcard) _DeepLearnQuestionType.flashcard,
    ];
    final type = types[_random.nextInt(types.length)];
    final promptIsDefinition = switch (_languageMode) {
      _DeepLearnLanguageMode.both => _random.nextBool(),
      // Nghĩa: hiện định nghĩa → trả lời là thuật ngữ
      _DeepLearnLanguageMode.definitionOnly => true,
      // Từ vựng: hiện thuật ngữ → trả lời là định nghĩa
      _DeepLearnLanguageMode.termOnly => false,
    };
    final question = _DeepLearnQuestion(
      card: card,
      type: type,
      promptIsDefinition: promptIsDefinition,
      choices: type == _DeepLearnQuestionType.multipleChoice
          ? _buildChoices(card, promptIsDefinition)
          : const [],
    );
    _answerController.clear();
    setState(() {
      _current = question;
      _feedback = null;
    });
  }

  List<String> _buildChoices(StudyCardItem correctCard, bool promptIsDefinition) {
    String answerOf(StudyCardItem card) => promptIsDefinition ? card.term : card.definition;
    final answer = answerOf(correctCard);
    final seen = <String>{answer.trim().toLowerCase()};
    final others = List<StudyCardItem>.from(_cards)..shuffle(_random);
    final choices = <String>[answer];
    for (final card in others) {
      if (card.id == correctCard.id) continue;
      final value = answerOf(card).trim();
      final key = value.toLowerCase();
      if (value.isNotEmpty && seen.add(key)) choices.add(value);
      if (choices.length == 4) break;
    }
    choices.shuffle(_random);
    return choices;
  }

  bool _isAnswerCorrect(String value, String answer) {
    final raw = value.trim();
    if (raw.isEmpty) return false;
    final accepted = answer.split(RegExp(r'[/,;]')).map((item) => item.trim()).where((item) => item.isNotEmpty);
    return accepted.any((item) => _normalizeAnswer(raw, item) == _normalizeAnswer(item, item));
  }

  String _normalizeAnswer(String value, String expected) {
    final hasCjk = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]').hasMatch('$value$expected');
    if (hasCjk) return value.trim();
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  void _submitChoice(String value) {
    final question = _current;
    if (question == null || question.locked) return;
    question.locked = true;
    if (_isChoiceCorrect(value, question.answer)) {
      _passCurrent(value);
    } else {
      _missCurrent(pickedValue: value);
    }
  }

  bool _isChoiceCorrect(String value, String answer) {
    return _normalizeAnswer(value, answer) == _normalizeAnswer(answer, answer);
  }

  void _submitWritten() {
    final question = _current;
    if (question == null || question.locked) return;
    question.locked = true;
    if (_isAnswerCorrect(_answerController.text, question.answer)) {
      _passCurrent(_answerController.text);
    } else {
      _missCurrent(pickedValue: _answerController.text);
    }
  }

  void _passCurrent([String pickedValue = '']) {
    final future = _passCurrentOnce(pickedValue);
    _reviewWriteTail = future;
    unawaited(future);
  }

  Future<void> _passCurrentOnce([String pickedValue = '']) async {
    final question = _current;
    if (question == null) return;
    question.locked = true;
    final remaining = _remainingCorrect[question.card.id] ?? 0;
    if (remaining <= 0) {
      _renderNextQuestion();
      return;
    }
    _remainingCorrect[question.card.id] = remaining - 1;
    if (remaining - 1 <= 0) {
      _mastered.add(question.card.id);
      _queue.removeWhere((id) => id == question.card.id);
    } else {
      _enqueue(question.card.id, _requeueMinGap + _random.nextInt(2));
    }
    await _applyCorrectReview(question.card.id);
    // Do not reveal/advance after an accepted answer until its resumable queue
    // snapshot is durably stored. dispose() cannot be awaited if the app is
    // killed immediately afterwards.
    await _saveState();
    if (_correct >= _total) {
      _renderNextQuestion();
      return;
    }
    setState(() {
      _feedback = _DeepLearnFeedback(
        correct: true,
        answer: question.answer,
        pickedValue: pickedValue.isEmpty ? question.answer : pickedValue,
        message: _correctMessages[_random.nextInt(_correctMessages.length)],
      );
    });
    _playCorrectAndContinue(question);
  }

  Future<void> _prepareCorrectSound() {
    if (_correctSoundReady) return Future<void>.value();
    final pending = _correctSoundPreparation;
    if (pending != null) return pending;
    final preparation = _loadCorrectSound();
    _correctSoundPreparation = preparation;
    return preparation;
  }

  Future<void> _loadCorrectSound() async {
    try {
      if (!kIsWeb && Platform.isWindows) {
        final data = await rootBundle.load('assets/audios/traloidung.mp3');
        final directory = await getTemporaryDirectory();
        final file = File(p.join(directory.path, 'traloidung.mp3'));
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (!await file.exists() || await file.length() != bytes.length) {
          await file.writeAsBytes(bytes, flush: true);
        }
        _windowsCorrectSoundFile = file;
        await _startWindowsSoundPlayer(file);
      } else {
        final player = _correctPlayer ??= AudioPlayer();
        await player.setAsset('assets/audios/traloidung.mp3');
      }
      _correctSoundReady = true;
    } catch (error) {
      _correctSoundReady = false;
      debugPrint('PREPARE DEEP LEARN SOUND ERROR: $error');
    } finally {
      _correctSoundPreparation = null;
    }
  }

  Future<void> _playCorrectAndContinue(_DeepLearnQuestion answeredQuestion) async {
    if (!_correctSoundEnabled) {
      await Future<void>.delayed(
        const Duration(milliseconds: _correctSoundDurationMs),
      );
      if (mounted &&
          identical(_current, answeredQuestion) &&
          _feedback?.correct == true) {
        _continueFeedback();
      }
      return;
    }

    try {
      if (!_correctSoundReady) {
        await _prepareCorrectSound().timeout(const Duration(seconds: 3));
      }
      if (!_correctSoundReady) throw StateError('Correct sound is unavailable');

      if (!kIsWeb && Platform.isWindows) {
        await _playCorrectSoundOnWindows();
      } else {
        final player = _correctPlayer;
        if (player == null) throw StateError('Correct audio player is unavailable');
        await player.pause();
        await player.seek(Duration.zero);
        player.play().catchError((error) {
          debugPrint('PLAY DEEP LEARN SOUND ERROR: $error');
        });
        await Future<void>.delayed(
          const Duration(milliseconds: _correctSoundDurationMs),
        );
        await player.pause();
        await player.seek(Duration.zero);
      }
    } catch (error) {
      debugPrint('DEEP LEARN CORRECT SOUND ERROR: $error');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (mounted &&
        identical(_current, answeredQuestion) &&
        _feedback?.correct == true) {
      _continueFeedback();
    }
  }

  Future<void> _playCorrectSoundOnWindows() async {
    final file = _windowsCorrectSoundFile;
    if (file == null || !await file.exists()) {
      throw StateError('Windows correct sound file is unavailable');
    }

    var process = _windowsSoundProcess;
    if (process == null) {
      await _startWindowsSoundPlayer(file);
      process = _windowsSoundProcess;
    }
    if (process == null) {
      throw StateError('Windows sound player is unavailable');
    }

    process.stdin.writeln('PLAY');
    await process.stdin.flush();
    await Future<void>.delayed(
      const Duration(milliseconds: _correctSoundDurationMs),
    );
    process.stdin.writeln('STOP');
    await process.stdin.flush();
  }

  Future<void> _startWindowsSoundPlayer(File file) async {
    _disposeWindowsSoundPlayer();

    final escapedPath = file.path.replaceAll("'", "''");
    final script =
        "Add-Type -AssemblyName PresentationCore; "
        "\$player = New-Object System.Windows.Media.MediaPlayer; "
        "\$player.Open([Uri]'$escapedPath'); "
        "\$player.Volume = 1.0; "
        "Start-Sleep -Milliseconds $_windowsAudioWarmupMs; "
        "[Console]::Out.WriteLine('READY'); "
        "[Console]::Out.Flush(); "
        "while (\$true) { "
        "\$command = [Console]::In.ReadLine(); "
        "if (\$null -eq \$command -or \$command -eq 'EXIT') { break }; "
        "if (\$command -eq 'PLAY') { "
        "\$player.Stop(); "
        "\$player.Position = [TimeSpan]::Zero; "
        "\$player.Play(); "
        "}; "
        "if (\$command -eq 'STOP') { \$player.Stop() } }; "
        "\$player.Close()";

    final process = await Process.start(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Sta',
        '-WindowStyle',
        'Hidden',
        '-Command',
        script,
      ],
    );
    final output = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final ready = await output.moveNext().timeout(const Duration(seconds: 5));
    if (!ready || output.current.trim() != 'READY') {
      process.kill();
      await output.cancel();
      throw StateError('Windows sound player failed to initialize');
    }
    await output.cancel();
    _windowsSoundProcess = process;
  }

  void _disposeWindowsSoundPlayer() {
    final process = _windowsSoundProcess;
    if (process != null) {
      try {
        process.stdin.writeln('EXIT');
        process.stdin.close();
      } catch (_) {}
      process.kill();
    }
    _windowsSoundProcess = null;
  }

  void _missCurrent({bool skipped = false, String pickedValue = ''}) {
    final question = _current;
    if (question == null) return;
    question.locked = true;
    _wrongMap[question.card.id] = (_wrongMap[question.card.id] ?? 0) + 1;
    _enqueue(question.card.id, _requeueMinGap + _random.nextInt(2));
    _saveState();
    setState(() {
      _feedback = _DeepLearnFeedback(
        correct: false,
        answer: question.answer,
        pickedValue: pickedValue,
        skipped: skipped,
        message: question.type == _DeepLearnQuestionType.multipleChoice && !skipped
            ? 'Chưa đúng, hãy cố gắng nhé!'
            : 'Đáp án đúng',
      );
    });
  }

  void _enqueue(int cardId, int gap) {
    if ((_remainingCorrect[cardId] ?? 0) <= 0) return;
    _queue.removeWhere((id) => id == cardId);
    _queue.insert(gap.clamp(0, _queue.length).toInt(), cardId);
  }

  void _continueFeedback() {
    if (_feedback == null) return;
    _feedback = null;
    _renderNextQuestion();
  }

  Future<void> _applyCorrectReview(int cardId) async {
    try {
      await AppDatabase.instance.ensureSyncOutboxTable();
      final db = await AppDatabase.instance.database;
      final now = DateTime.now();
      await db.transaction((txn) async {
        final rows = await txn.query(
          'review_states',
          where: 'cardId = ?',
          whereArgs: [cardId],
          limit: 1,
        );
        final previous = rows.isEmpty
            ? null
            : Map<String, Object?>.from(rows.first);
        final next = ReviewScheduler.nextState(
          cardId: cardId,
          previous: previous,
          isCorrect: true,
          now: now,
        );
        if (rows.isEmpty) {
          await txn.insert('review_states', next);
        } else {
          await txn.update(
            'review_states',
            next,
            where: 'cardId = ?',
            whereArgs: [cardId],
          );
        }
        await AppDatabase.instance.enqueueReviewMutation(
          txn,
          cardId: cardId,
          rating: 'Good',
          reviewedAt: now,
          baseRevision: (previous?['serverRevision'] as num?)?.toInt(),
        );
      });
    } catch (error) {
      debugPrint('DEEP LEARN REVIEW ERROR: $error');
    }
  }

  void _syncSrsAfterCompletion() {
    if (_didRequestSrsSync || !SupabaseConfig.isLoggedIn) return;
    _didRequestSrsSync = true;
    final future = SupabaseSyncService.instance.syncReviewStatesAfterStudy(
      cardIds: _mastered,
    );
    _srsSyncFuture = future;
    unawaited(future);
  }

  Future<void> _toggleStar() async {
    final question = _current;
    if (question == null) return;
    final next = !_starred.contains(question.card.id);
    setState(() {
      if (next) {
        _starred.add(question.card.id);
      } else {
        _starred.remove(question.card.id);
      }
      final index = _cards.indexWhere((card) => card.id == question.card.id);
      if (index >= 0) _cards[index] = _cards[index].copyWith(isFavorite: next);
    });
    final db = await AppDatabase.instance.database;
    await db.update(
      'cards',
      {
        'isFavorite': next ? 1 : 0,
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [question.card.id],
    );
    if (SupabaseConfig.isLoggedIn) {
      unawaited(SupabaseSyncService.instance.syncPendingChanges());
    }
    await _saveState();
  }

  Future<void> _speakVocabulary() async {
    final question = _current;
    if (question == null) return;
    final text = question.card.term.trim();
    if (text.isEmpty) return;
    final cjk = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]').hasMatch(text);
    try {
      await _tts.stop();
      await _tts.setLanguage(
        cjk
            ? 'zh-TW'
            : (widget.courseLanguageCode.isEmpty
                ? 'en-US'
                : widget.courseLanguageCode),
      );
      await _tts.speak(text);
    } catch (error) {
      debugPrint('PLAY DEEP LEARN VOCABULARY TTS ERROR: $error');
    }
  }

  Future<void> _toggleCorrectSound() async {
    final enabled = !_correctSoundEnabled;
    setState(() => _correctSoundEnabled = enabled);
    await AppSettingsStore.setBool(
      'deepLearn.correctSoundEnabled',
      enabled,
    );
    if (enabled) {
      unawaited(_prepareCorrectSound());
      return;
    }

    try {
      if (!kIsWeb && Platform.isWindows) {
        final process = _windowsSoundProcess;
        if (process != null) {
          process.stdin.writeln('STOP');
          await process.stdin.flush();
        }
      } else {
        await _correctPlayer?.pause();
        await _correctPlayer?.seek(Duration.zero);
      }
    } catch (error) {
      debugPrint('STOP DEEP LEARN SOUND ERROR: $error');
    }
  }

  void _toggleType(_DeepLearnQuestionType type) {
    final enabled = [_multipleChoice, _written, _flashcard].where((value) => value).length;
    final currentlyEnabled = switch (type) {
      _DeepLearnQuestionType.multipleChoice => _multipleChoice,
      _DeepLearnQuestionType.written => _written,
      _DeepLearnQuestionType.flashcard => _flashcard,
    };
    if (currentlyEnabled && enabled <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Không thể tắt tất cả loại câu hỏi.')));
      return;
    }
    setState(() {
      switch (type) {
        case _DeepLearnQuestionType.multipleChoice:
          _multipleChoice = !_multipleChoice;
          break;
        case _DeepLearnQuestionType.written:
          _written = !_written;
          break;
        case _DeepLearnQuestionType.flashcard:
          _flashcard = !_flashcard;
          break;
      }
    });
    AppSettingsStore.setBool('deepLearn.multipleChoice', _multipleChoice);
    AppSettingsStore.setBool('deepLearn.written', _written);
    AppSettingsStore.setBool('deepLearn.flashcard', _flashcard);
    _saveState();
  }

  void _setLanguageMode(_DeepLearnLanguageMode mode) {
    if (_languageMode == mode) return;
    setState(() => _languageMode = mode);
    AppSettingsStore.setString('deepLearn.languageMode', _langModeToString(mode));
    _saveState();
  }

  Future<void> _reset({List<StudyCardItem>? onlyCards}) async {
    if (_storageKey.isNotEmpty) await AppSettingsStore.setString(_storageKey, '');
    final cards = onlyCards ?? _cards;
    setState(() {
      _cards = cards;
      _storageKey = _buildStorageKey(cards);
      _createState(cards);
      _settingsOpen = false;
    });
    await _saveState();
    _renderNextQuestion();
  }

  @override
  Widget build(BuildContext context) => _buildDeepLearnPage(context);
}
