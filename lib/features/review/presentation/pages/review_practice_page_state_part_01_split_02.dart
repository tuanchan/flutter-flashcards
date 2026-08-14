part of flutterflashcard_main;

extension ReviewPracticePageStatePart01Split02 on _ReviewPracticePageState {
  Future<void> _finishStudySession() {
    final active = _studySessionFinishFuture;
    if (active != null) return active;
    final future = this._finishStudySessionOnce();
    _studySessionFinishFuture = future;
    return future.whenComplete(() {
      if (identical(_studySessionFinishFuture, future)) {
        _studySessionFinishFuture = null;
      }
    });
  }





  Future<void> _finishStudySessionOnce() async {
    final sessionId = _studySessionId;
    if (sessionId == null || _studySessionFinished) return;
    _studySessionFinished = true;

    try {
      // An answer can still be committing while the user closes the screen.
      // Never count/delete the session until every previously accepted answer
      // has finished its atomic SQLite write.
      await _studyWriteTail;
      final db = await AppDatabase.instance.database;
      final summaryRows = await db.rawQuery(
        '''
        SELECT
          COUNT(*) AS totalCount,
          COALESCE(SUM(CASE WHEN isCorrect = 1 THEN 1 ELSE 0 END), 0)
            AS correctCount
        FROM study_results
        WHERE sessionId = ?
        ''',
        [sessionId],
      );
      final resultCount = _dbInt(summaryRows.first['totalCount']);
      final correctCount = _dbInt(summaryRows.first['correctCount']);
      if (resultCount == 0) {
        await AppDatabase.instance.ensureSyncOutboxTable();
        await db.transaction((txn) async {
          await txn.delete(
            'study_sessions',
            where: 'id = ?',
            whereArgs: [sessionId],
          );
          await txn.delete(
            'sync_outbox',
            where: 'kind = ? AND entityId = ?',
            whereArgs: ['review_session', '$sessionId'],
          );
        });
        _studySessionId = null;
        return;
      }
      await AppDatabase.instance.ensureSyncOutboxTable();
      await db.transaction((txn) async {
        await txn.update(
          'study_sessions',
          {
            'correctCount': correctCount,
            'wrongCount': resultCount - correctCount,
            'endedAt': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
        await AppDatabase.instance.enqueueSyncOutbox(
          txn,
          kind: 'review_session',
          entityId: sessionId,
        );
      });
      if (SupabaseConfig.isLoggedIn) {
        await SupabaseSyncService.instance.syncReviewStatesAfterStudy(
          sessionId: sessionId,
        );
      }
    } catch (e) {
      _studySessionFinished = false;
      debugPrint('FINISH REVIEW SESSION ERROR: $e');
    }
  }





  Future<void> _recordStudyResult({
    required StudyCardItem card,
    required String answerText,
    required bool isCorrect,
  }) {
    final sessionId = _studySessionId;
    if (sessionId == null ||
        _studySessionFinished ||
        _recordedResultCardIds.contains(card.id)) {
      return Future<void>.value();
    }

    final now = DateTime.now();
    final startedAt = _cardStartedAtMap[card.id] ?? _essayQuestionStartedAt;
    final responseMs = now
        .difference(startedAt)
        .inMilliseconds
        .clamp(0, 2147483647);

    // Reserve synchronously so rapid taps cannot queue the same card twice.
    _recordedResultCardIds.add(card.id);
    final operation = _studyWriteTail.then((_) async {
      try {
        await AppDatabase.instance.ensureSyncOutboxTable();
        final db = await AppDatabase.instance.database;
        await db.transaction((txn) async {
          await txn.insert('study_results', {
            'sessionId': sessionId,
            'cardId': card.id,
            'answerText': answerText,
            'isCorrect': isCorrect ? 1 : 0,
            'responseTimeMs': responseMs,
            'reviewedAt': now.toIso8601String(),
          });

          final rows = await txn.query(
            'review_states',
            where: 'cardId = ?',
            whereArgs: [card.id],
            limit: 1,
          );
          final previousState = rows.isEmpty
              ? null
              : Map<String, Object?>.from(rows.first);
          final nextState = ReviewScheduler.nextState(
            cardId: card.id,
            previous: previousState,
            isCorrect: isCorrect,
            now: now,
          );
          if (rows.isEmpty) {
            await txn.insert('review_states', nextState);
          } else {
            await txn.update(
              'review_states',
              nextState,
              where: 'cardId = ?',
              whereArgs: [card.id],
            );
          }
          await AppDatabase.instance.enqueueReviewMutation(
            txn,
            cardId: card.id,
            rating: isCorrect ? 'Good' : 'Again',
            reviewedAt: now,
            baseRevision: (previousState?['serverRevision'] as num?)?.toInt(),
          );

          final sessionSummary = await txn.rawQuery(
            '''
            SELECT
              COUNT(*) AS totalCount,
              COALESCE(SUM(CASE WHEN isCorrect = 1 THEN 1 ELSE 0 END), 0)
                AS correctCount
            FROM study_results
            WHERE sessionId = ?
            ''',
            [sessionId],
          );
          final answeredCount = _dbInt(sessionSummary.first['totalCount']);
          final correctCount = _dbInt(sessionSummary.first['correctCount']);
          await txn.update(
            'study_sessions',
            {
              'correctCount': correctCount,
              'wrongCount': answeredCount - correctCount,
            },
            where: 'id = ?',
            whereArgs: [sessionId],
          );

          await AppDatabase.instance.enqueueSyncOutbox(
            txn,
            kind: 'review_session',
            entityId: sessionId,
            queuedAt: now,
          );
        });
      } catch (e) {
        _recordedResultCardIds.remove(card.id);
        debugPrint('INSERT REVIEW RESULT ERROR: $e');
      }
    });
    _studyWriteTail = operation;
    return operation;
  }

}
