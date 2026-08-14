part of flutterflashcard_main;

extension StatisticsPageStatePart06Split03 on _StatisticsPageState {
  Widget _buildSrsCourseItem(
    _SrsEditorCourse course, {
    required VoidCallback onOpen,
  }) {
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: _dashPanel2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _dashBorder.withOpacity(0.72)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    course.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _dashText,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    '${course.cardCount} thẻ • đã ôn ${course.reviewedCount} • đến hạn ${course.dueCount} • ${course.languageCode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _dashMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 10),
            Icon(Icons.chevron_right_rounded, color: _dashText, size: 24),
          ],
        ),
      ),
    );
  }





  Widget _buildSrsEditorItem(
    _SrsEditorItem item,
    Future<void> Function() refresh,
  ) {
    final dateText = this._formatSrsDate(item.nextReviewAt);

    Widget miniButton(IconData icon, Future<void> Function() onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          await onTap();
          await refresh();
        },
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _dashPanel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _dashBorder),
          ),
          child: Icon(icon, color: _dashText, size: 18),
        ),
      );
    }

    Widget valuePill({
      required String text,
      required Color color,
    }) {
      return Container(
        height: 34,
        padding: EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _dashBorder),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _dashText,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      );
    }

    Widget calendarButton() {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          final now = DateTime.now();
          final current = DateTime.tryParse(item.nextReviewAt) ??
              DateTime(now.year, now.month, now.day);
          final picked = await showDatePicker(
            context: context,
            initialDate: current,
            firstDate: DateTime(now.year - 1),
            lastDate: DateTime(now.year + 3),
            builder: (ctx, child) {
              return Theme(
                data: Theme.of(ctx).copyWith(
                  colorScheme: ColorScheme.dark(
                    primary: _dashBlue,
                    surface: _dashPanel,
                    onSurface: _dashText,
                    onPrimary: Colors.white,
                  ),
                  dialogTheme: DialogThemeData(
                    backgroundColor: _dashPanel,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  textTheme: TextTheme(
                    bodyLarge: TextStyle(color: _dashText),
                    bodyMedium: TextStyle(color: _dashText),
                    titleSmall: TextStyle(color: _dashText),
                    labelLarge: TextStyle(color: _dashText),
                    headlineLarge: TextStyle(color: _dashText),
                  ),
                  inputDecorationTheme: InputDecorationTheme(
                    labelStyle: TextStyle(color: _dashMuted),
                    hintStyle: TextStyle(color: _dashMuted),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _dashBorder),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _dashBlue),
                    ),
                  ),
                  textButtonTheme: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      foregroundColor: _dashText,
                    ),
                  ),
                ),
                child: child!,
              );
            },
          );
          if (picked != null) {
            await this._setSrsDueDate(item, picked);
            await refresh();
          }
        },
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          child: Icon(
            Icons.calendar_month_rounded,
            color: _dashText,
            size: 20,
          ),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _dashPanel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _dashBorder.withOpacity(0.72)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.term,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _dashText,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          SizedBox(height: 3),
          Text(
            '${item.definition} • ${item.courseTitle}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _dashMuted, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 10),
          Column(
            children: [
              Row(
                children: [
                  miniButton(
                    Icons.remove_rounded,
                    () => this._changeSrsLevel(item, -1),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: valuePill(
                      text: 'L${item.level}',
                      color: _dashBlue,
                    ),
                  ),
                  SizedBox(width: 8),
                  miniButton(
                    Icons.add_rounded,
                    () => this._changeSrsLevel(item, 1),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  miniButton(
                    Icons.chevron_left_rounded,
                    () => this._shiftSrsDate(item, -1),
                  ),
                  SizedBox(width: 8),
                  Expanded(child: valuePill(text: dateText, color: _dashPanel)),
                  SizedBox(width: 8),
                  miniButton(
                    Icons.chevron_right_rounded,
                    () => this._shiftSrsDate(item, 1),
                  ),
                  SizedBox(width: 4),
                  calendarButton(),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }





  Future<void> _changeSrsLevel(_SrsEditorItem item, int delta) async {
    final nextLevel = (item.level + delta).clamp(0, 8).toInt();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final interval = ReviewScheduler.intervalDaysForLevel(nextLevel);
    await this._upsertSrsState(
      cardId: item.cardId,
      level: nextLevel,
      intervalDays: interval,
      nextReviewAt: nextLevel <= 0 ? now : today.add(getDuration(days: interval)),
    );
  }





  Future<void> _shiftSrsDate(_SrsEditorItem item, int days) async {
    final now = DateTime.now();
    final fallback = DateTime(now.year, now.month, now.day);
    final current = DateTime.tryParse(item.nextReviewAt) ?? fallback;
    final next = current.add(getDuration(days: days));
    final today = DateTime(now.year, now.month, now.day);
    final interval = math.max(0, next.difference(today).inDays);
    await this._upsertSrsState(
      cardId: item.cardId,
      level: item.level,
      intervalDays: interval,
      nextReviewAt: next,
    );
  }





  Future<void> _setSrsDueDate(_SrsEditorItem item, DateTime date) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final interval = math.max(0, target.difference(today).inDays);
    await this._upsertSrsState(
      cardId: item.cardId,
      level: item.level,
      intervalDays: interval,
      nextReviewAt: target,
    );
  }





  Future<void> _upsertSrsState({
    required int cardId,
    required int level,
    required int intervalDays,
    required DateTime nextReviewAt,
  }) async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    await this._upsertSrsStateOn(
      db,
      cardId: cardId,
      level: level,
      easeFactor: null,
      intervalDays: intervalDays,
      repetitionCount: null,
      correctCount: null,
      wrongCount: null,
      lastReviewedAt: null,
      nextReviewAt: nextReviewAt,
    );
    if (SupabaseConfig.isLoggedIn) {
      final syncResult = await SupabaseSyncService.instance
          .syncReviewStatesAfterStudy(cardIds: [cardId]);
      if (syncResult.hasError) {
        debugPrint('UPDATE SRS SYNC ERROR: ${syncResult.error}');
      }
    }
  }





  Future<void> _upsertSrsStateOn(
    DatabaseExecutor executor, {
    required int cardId,
    required int level,
    required double? easeFactor,
    required int intervalDays,
    required int? repetitionCount,
    required int? correctCount,
    required int? wrongCount,
    required String? lastReviewedAt,
    required DateTime nextReviewAt,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final rows = await executor.query(
      'review_states',
      where: 'cardId = ?',
      whereArgs: [cardId],
      limit: 1,
    );
    final previous = rows.isEmpty ? null : rows.first;
    final nextLevel = level.clamp(0, 8).toInt();
    final nextRepetition = repetitionCount ??
        math.max(_dbInt(previous?['repetitionCount']), nextLevel > 0 ? 1 : 0);

    final values = <String, Object?>{
      'cardId': cardId,
      'level': nextLevel,
      'easeFactor': easeFactor ?? _dbDouble(previous?['easeFactor'], 2.5),
      'intervalDays': math.max(0, intervalDays),
      'repetitionCount': nextRepetition,
      'correctCount': correctCount ?? _dbInt(previous?['correctCount']),
      'wrongCount': wrongCount ?? _dbInt(previous?['wrongCount']),
      'lastReviewedAt': lastReviewedAt ??
          previous?['lastReviewedAt']?.toString() ??
          (nextRepetition > 0 ? nowIso : null),
      'nextReviewAt': nextReviewAt.toIso8601String(),
      'updatedAt': nowIso,
    };

    if (rows.isEmpty) {
      values['createdAt'] = nowIso;
      await executor.insert('review_states', values);
    } else {
      await executor.update(
        'review_states',
        values,
        where: 'cardId = ?',
        whereArgs: [cardId],
      );
    }
  }





  Future<String> _exportSrsJson() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT
        ca.id AS cardId,
        c.id AS courseId,
        ca.term,
        ca.definition,
        ca.pronunciation,
        c.title AS courseTitle,
        c.languageCode,
        COALESCE(rs.level, 0) AS level,
        COALESCE(rs.easeFactor, 2.5) AS easeFactor,
        COALESCE(rs.intervalDays, 0) AS intervalDays,
        COALESCE(rs.repetitionCount, 0) AS repetitionCount,
        COALESCE(rs.correctCount, 0) AS correctCount,
        COALESCE(rs.wrongCount, 0) AS wrongCount,
        COALESCE(rs.lastReviewedAt, '') AS lastReviewedAt,
        COALESCE(rs.nextReviewAt, '') AS nextReviewAt
      FROM review_states rs
      INNER JOIN cards ca ON ca.id = rs.cardId
      INNER JOIN courses c ON c.id = ca.courseId
      WHERE ca.deletedAt IS NULL
        AND ca.isHidden = 0
        AND c.deletedAt IS NULL
      ORDER BY c.title ASC, ca.position ASC, ca.id ASC
    ''');
    final items = rows.map((row) => _SrsEditorItem.fromMap(row).toJson()).toList();
    final data = {
      'format': 'flutterflashcard.srs.v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'items': items,
    };
    final text = JsonEncoder.withIndent('  ').convert(data);
    await Clipboard.setData(ClipboardData(text: text));

    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docDir.path}/srs_exports');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/srs_${this._srsStamp()}.json');
    await file.writeAsString(text);

    await db.insert('import_exports', {
      'type': 'export',
      'fileName': file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'srs.json',
      'filePath': file.path,
      'format': 'json',
      'courseId': null,
      'status': 'success',
      'message': 'Export SRS JSON',
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'FlashCard SRS JSON',
        text: 'SRS JSON để import lại lịch ôn.',
      );
    }

    return 'Đã export ${items.length} SRS, đã copy JSON vào clipboard';
  }


}
