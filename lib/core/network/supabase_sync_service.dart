import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart';
import '../database/app_database.dart';
import 'server_log_service.dart';
import 'supabase_config.dart';

enum _SyncOperation { pullReplace, merge, livePush }

class _SyncCancelled implements Exception {}

class _OutboxTicket {
  const _OutboxTicket(this.kind, this.entityId, this.token);

  final String kind;
  final String entityId;
  final String token;
}

class _TargetedOutboxRow {
  _TargetedOutboxRow(Map<String, Object?> row)
      : kind = row['kind']?.toString() ?? '',
        entityId = row['entityId']?.toString() ?? '',
        table = row['tableName']?.toString() ?? '',
        operation = row['operation']?.toString() ?? 'upsert',
        remoteId = row['remoteId']?.toString(),
        mutationId = row['mutationId']?.toString() ?? '',
        baseRevision = (row['baseRevision'] as num?)?.toInt() ?? 0,
        payload = row['payload']?.toString(),
        token = row['updatedAt']?.toString() ?? '',
        attempts = (row['attempts'] as num?)?.toInt() ?? 0;

  final String kind;
  final String entityId;
  final String table;
  final String operation;
  final String? remoteId;
  final String mutationId;
  final int baseRevision;
  final String? payload;
  final String token;
  final int attempts;
}

/// Keeps background synchronization paused while a card-learning screen is
/// alive. The lease is idempotent so page disposal and async cleanup can both
/// safely attempt to release it.
class LearningSyncPause {
  LearningSyncPause._(this._service);

  final SupabaseSyncService _service;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _service._releaseLearningSyncPause();
  }
}

/// Describes only the rows touched by one realtime batch. UI pages can use
/// these IDs to refresh their current view from SQLite without starting a
/// full account sync.
class RealtimeDataChange {
  RealtimeDataChange({
    required Set<String> tables,
    required Set<int> courseIds,
    required Set<int> cardIds,
  })  : tables = Set.unmodifiable(tables),
        courseIds = Set.unmodifiable(courseIds),
        cardIds = Set.unmodifiable(cardIds);

  final Set<String> tables;
  final Set<int> courseIds;
  final Set<int> cardIds;
}

/// Service to synchronize local SQLite data with Supabase when user logs in.
/// Uses a "last-write-wins" merge strategy based on updatedAt timestamps.
class SupabaseSyncService {
  SupabaseSyncService._();

  static final SupabaseSyncService instance = SupabaseSyncService._();

  bool _isSyncing = false;
  bool _cancelSyncRequested = false;
  String? _lastSyncError;
  Future<SyncResult>? _activeSync;
  final StreamController<SyncResult> _syncCompletedController =
      StreamController<SyncResult>.broadcast();
  // Keep this controller void-typed so an existing singleton remains valid
  // across Flutter hot reloads. The typed payload is exposed separately.
  final StreamController<void> _remoteDataChangedController =
      StreamController<void>.broadcast();
  RealtimeDataChange? _lastRealtimeDataChange;
  final Map<String, String> _topicRemoteIdByLocal = {};
  final Map<String, String> _courseRemoteIdByLocal = {};
  final Map<String, String> _cardRemoteIdByLocal = {};
  final Map<String, int> _topicLocalIdByRemote = {};
  final Map<String, int> _courseLocalIdByRemote = {};
  final Map<String, int> _cardLocalIdByRemote = {};
  final Map<String, List<Map<String, dynamic>>> _prefetchedRemoteRows = {};
  String _localDeviceId = '';
  _SyncOperation _operation = _SyncOperation.pullReplace;
  String? _sessionOwnerId;
  String? _livePushCursorAt;
  String? _livePushCutoffAt;
  String? _identityOwnerId;
  RealtimeChannel? _realtimeChannel;
  Timer? _realtimeMergeDebounce;
  final Map<String, PostgresChangePayload> _realtimePendingChanges = {};
  Future<void> _studySyncTail = Future<void>.value();
  bool _isPushingStudyData = false;
  bool _studyPushCanOverlapLearning = false;
  bool _outboxRetryInFlight = false;
  int _generalPushRequestsInFlight = 0;
  int _learningSyncPauseCount = 0;
  _SyncOperation? _deferredSyncOperation;
  bool _resumingDeferredWork = false;

  bool get isSyncing => _isSyncing;
  bool get isSyncCancellationRequested => _cancelSyncRequested;
  String? get lastSyncError => _lastSyncError;
  Future<SyncResult>? get activeSync => _activeSync;
  Stream<SyncResult> get syncCompleted => _syncCompletedController.stream;
  Stream<void> get remoteDataChanged => _remoteDataChangedController.stream;
  RealtimeDataChange? get lastRealtimeDataChange => _lastRealtimeDataChange;
  bool get isLearningSyncPaused => _learningSyncPauseCount > 0;

  LearningSyncPause pauseSyncWhileLearning() {
    _learningSyncPauseCount++;
    _realtimeMergeDebounce?.cancel();
    _realtimeMergeDebounce = null;
    final shouldCancelCurrentWork =
        !_isPushingStudyData || !_studyPushCanOverlapLearning;
    if (_isSyncing && shouldCancelCurrentWork) {
      if (_activeSync != null && _operation != _SyncOperation.livePush) {
        _deferFullSync(_operation);
      }
      cancelActiveSync();
    } else if (_isPushingStudyData && !_studyPushCanOverlapLearning) {
      _cancelSyncRequested = true;
    }
    return LearningSyncPause._(this);
  }

  void _deferFullSync(_SyncOperation operation) {
    // Merge preserves local rows, so retain it if overlapping requests arrive.
    if (_deferredSyncOperation != _SyncOperation.merge) {
      _deferredSyncOperation = operation;
    }
  }

  void _releaseLearningSyncPause() {
    if (_learningSyncPauseCount == 0) return;
    _learningSyncPauseCount--;
    if (_learningSyncPauseCount == 0) {
      unawaited(_resumeDeferredWorkAfterLearning());
    }
  }

  Future<void> _resumeDeferredWorkAfterLearning() async {
    if (_resumingDeferredWork || isLearningSyncPaused) return;
    _resumingDeferredWork = true;
    try {
      if (_isPushingStudyData) await _studySyncTail;
      // Durable local mutations, especially SRS answers, must reach the
      // server before any deferred pull is allowed to replace local SQLite.
      await retryPendingOutbox();
      if (isLearningSyncPaused) return;
      if (await _hasPendingOutbox()) return;

      final operation = _deferredSyncOperation;
      _deferredSyncOperation = null;
      if (operation != null && SupabaseConfig.isLoggedIn) {
        await _startManualSync(operation);
      }
      if (!isLearningSyncPaused && _realtimePendingChanges.isNotEmpty) {
        _scheduleRealtimeApply();
      }
    } catch (error) {
      debugPrint('RESUME SYNC AFTER LEARNING ERROR: $error');
    } finally {
      _resumingDeferredWork = false;
    }
  }

  SyncResult _learningDeferredResult() => SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'Đang học hoặc kiểm tra thẻ; đồng bộ đã được hoãn',
      );

  Future<_OutboxTicket> _enqueueOutbox(String kind, String entityId) async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'sync_outbox',
      {
        'kind': kind,
        'entityId': entityId,
        'createdAt': now,
        'updatedAt': now,
        'attempts': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'sync_outbox',
      {'updatedAt': now},
      where: 'kind = ? AND entityId = ?',
      whereArgs: [kind, entityId],
    );
    return _OutboxTicket(kind, entityId, now);
  }

  Future<void> _completeOutbox(
    Iterable<_OutboxTicket> entries,
  ) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      for (final entry in entries) {
        await txn.delete(
          'sync_outbox',
          where: 'kind = ? AND entityId = ? AND updatedAt = ?',
          whereArgs: [entry.kind, entry.entityId, entry.token],
        );
      }
    });
  }

  Future<void> _failOutbox(
    Iterable<_OutboxTicket> entries,
    Object error,
  ) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      for (final entry in entries) {
        await txn.rawUpdate(
          'UPDATE sync_outbox '
          'SET attempts = attempts + 1, updatedAt = ?, lastError = ? '
          'WHERE kind = ? AND entityId = ? AND updatedAt = ?',
          [
            now,
            error.toString(),
            entry.kind,
            entry.entityId,
            entry.token,
          ],
        );
      }
    });
  }

  /// Local SRS rows covered by an outbox marker are authoritative until their
  /// upload is acknowledged. Timestamps alone are not sufficient here because
  /// a device clock can be behind the server, especially after offline study.
  Future<Set<int>> _pendingReviewCardIds(Database db) async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final rows = await db.rawQuery('''
      SELECT CAST(entityId AS INTEGER) AS cardId
      FROM sync_outbox
      WHERE kind IN ('review_card', 'delete_review_card')
        AND TRIM(entityId) <> ''

      UNION

      SELECT CASE
        WHEN pending.operation = 'review' THEN CAST(pending.entityId AS INTEGER)
        ELSE rs.cardId
      END AS cardId
      FROM sync_outbox pending
      LEFT JOIN review_states rs
        ON rs.id = CAST(pending.entityId AS INTEGER)
      WHERE pending.tableName = 'review_states'
        AND pending.status IN ('pending', 'conflict')

      UNION

      SELECT DISTINCT sr.cardId AS cardId
      FROM sync_outbox pending
      INNER JOIN study_results sr
        ON sr.sessionId = CAST(pending.entityId AS INTEGER)
      WHERE pending.kind = 'review_session'

      UNION

      SELECT rs.cardId AS cardId
      FROM review_states rs
      WHERE EXISTS (
        SELECT 1 FROM sync_outbox WHERE kind = 'review_all'
      )
    ''');
    return rows
        .map((row) => _localInt(row['cardId']))
        .whereType<int>()
        .where((id) => id > 0)
        .toSet();
  }

  Future<bool> _hasPendingOutbox() async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'sync_outbox',
      columns: const ['kind'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Pull-only replacement. No local rows are uploaded by this action.
  Future<SyncResult> syncAll() =>
      _startManualSync(_SyncOperation.pullReplace);

  Future<SyncResult> mergeAll() => _startManualSync(_SyncOperation.merge);

  Future<SyncResult> _startManualSync(_SyncOperation operation) async {
    if (isLearningSyncPaused) {
      _deferFullSync(operation);
      return _learningDeferredResult();
    }
    final active = _activeSync;
    if (active != null) await active;
    if (await _hasPendingOutbox()) {
      _deferFullSync(operation);
      if (!_resumingDeferredWork) {
        unawaited(_resumeDeferredWorkAfterLearning());
      }
      return SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'Còn thay đổi local đang chờ tải lên; đã hoãn đồng bộ',
      );
    }
    return _startSync(operation);
  }

  Future<SyncResult> _startSync(
    _SyncOperation operation, {
    bool bypassStudyPushWait = false,
    bool allowWhileLearning = false,
  }) {
    if (isLearningSyncPaused && !allowWhileLearning) {
      if (operation != _SyncOperation.livePush) _deferFullSync(operation);
      return Future.value(_learningDeferredResult());
    }
    final active = _activeSync;
    if (active != null) return active;
    if (_isPushingStudyData && !bypassStudyPushWait) {
      return _studySyncTail.then(
        (_) => _startSync(
          operation,
          bypassStudyPushWait: bypassStudyPushWait,
          allowWhileLearning: allowWhileLearning,
        ),
      );
    }
    if (!SupabaseConfig.isLoggedIn) {
      return Future.value(
        SyncResult(pushed: 0, pulled: 0, error: 'Chưa đăng nhập'),
      );
    }

    _operation = operation;
    _cancelSyncRequested = false;
    final future = _syncAllOnce();
    _activeSync = future;
    future.then(_syncCompletedController.add);
    return future;
  }

  void cancelActiveSync() {
    if (!_isSyncing) return;
    _cancelSyncRequested = true;
    _realtimeMergeDebounce?.cancel();
    _realtimeMergeDebounce = null;
  }

  void _throwIfSyncCancelled() {
    if (_cancelSyncRequested) throw _SyncCancelled();
  }

  /// Drains row-scoped mutations created atomically by SQLite CRUD triggers.
  /// Full livePush remains available only as an explicit recovery path.
  Future<SyncResult> syncPendingChanges() async {
    if (!SupabaseConfig.isLoggedIn) {
      return SyncResult(pushed: 0, pulled: 0, error: 'Chưa đăng nhập');
    }
    try {
      await beginAuthenticatedSession();
      return await _drainTargetedOutbox();
    } catch (error) {
      return SyncResult(pushed: 0, pulled: 0, error: error.toString());
    }
  }

  Future<SyncResult> pushTopicMutation(int localId) =>
      _pushTargetedEntity('topics', localId);

  Future<SyncResult> pushCourseMutation(int localId) =>
      _pushTargetedEntity('courses', localId);

  Future<SyncResult> pushCardMutation(int localId) =>
      _pushTargetedEntity('cards', localId);

  Future<SyncResult> pushCardExampleMutation(int localId) =>
      _pushTargetedEntity('card_examples', localId);

  Future<SyncResult> pushReviewStateMutation(int localCardId) async {
    if (!SupabaseConfig.isLoggedIn) {
      return SyncResult(pushed: 0, pulled: 0, error: 'Chưa đăng nhập');
    }
    await beginAuthenticatedSession();
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'review_states',
      columns: const ['id'],
      where: 'cardId = ?',
      whereArgs: [localCardId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'Không tìm thấy review_state cho card $localCardId',
      );
    }
    return _drainTargetedOutbox(
      table: 'review_states',
      entityId: '${rows.first['id']}',
    );
  }

  Future<SyncResult> _pushTargetedEntity(String table, int localId) async {
    if (!SupabaseConfig.isLoggedIn) {
      return SyncResult(pushed: 0, pulled: 0, error: 'Chưa đăng nhập');
    }
    await beginAuthenticatedSession();
    return _drainTargetedOutbox(table: table, entityId: '$localId');
  }

  Future<SyncResult> _pushGeneralOutboxEntries(
    List<_OutboxTicket> entries, {
    bool allowWhileLearning = false,
    bool isStudyDependency = false,
  }) async {
    try {
      if (isLearningSyncPaused && !allowWhileLearning) {
        return SyncResult(
          pushed: 0,
          pulled: 0,
          logs: const ['Thay đổi local đang chờ hết phiên học'],
        );
      }
      final active = _activeSync;
      if (active != null) await active;
      if (!SupabaseConfig.isLoggedIn) {
        return SyncResult(
          pushed: 0,
          pulled: 0,
          error: 'Đã đăng xuất trước khi đồng bộ',
        );
      }
      await beginAuthenticatedSession();
      final result = await _startSync(
        _SyncOperation.livePush,
        bypassStudyPushWait: isStudyDependency,
        allowWhileLearning: allowWhileLearning,
      );
      if (result.hasError) {
        await _failOutbox(entries, result.error!);
      } else {
        await _completeOutbox(entries);
      }
      return result;
    } catch (error) {
      await _failOutbox(entries, error);
      rethrow;
    }
  }

  /// Pushes the complete SRS state after a study session finishes. Card IDs
  /// are resolved against Supabase first, matching the desktop sync flow.
  Future<SyncResult> syncReviewStatesAfterStudy({
    int? sessionId,
    Iterable<int>? cardIds,
  }) async {
    if (!SupabaseConfig.isLoggedIn) {
      return SyncResult(pushed: 0, pulled: 0, error: 'Chưa đăng nhập');
    }
    final completer = Completer<SyncResult>();
    _studySyncTail = _studySyncTail.then((_) async {
      try {
        // Each answer already created an immutable SRS event in the same
        // SQLite transaction. Drain those RPC mutations now; do not upload a
        // full review_states snapshot or scan unrelated tables.
        final reviewResult = await _drainTargetedOutbox(
          table: 'review_states',
        );
        final sessionResult = sessionId == null
            ? SyncResult(pushed: 0, pulled: 0)
            : await _pushStudySessionAndResults(sessionId);
        final combinedErrors = [reviewResult.error, sessionResult.error]
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
        completer.complete(SyncResult(
          pushed: reviewResult.pushed + sessionResult.pushed,
          pulled: 0,
          error: combinedErrors.isEmpty ? null : combinedErrors.join(' | '),
        ));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }).catchError((_) {});
    return completer.future;
  }

  Future<SyncResult> _pushStudySessionAndResults(int sessionId) async {
    try {
      final db = await AppDatabase.instance.database;
      final sessions = await db.query(
        'study_sessions',
        where: 'id = ?',
        whereArgs: [sessionId],
        limit: 1,
      );
      if (sessions.isEmpty) {
        return SyncResult(pushed: 0, pulled: 0);
      }
      final ownerId = SupabaseConfig.currentUser!.id;
      final session = sessions.first;
      final courseId = _localInt(session['courseId']);
      if (courseId == null) throw StateError('Study session thiếu courseId');
      final remoteCourseId = await _ensureTargetedRemoteId(
        db,
        'courses',
        courseId,
      );
      final sessionPayload = _studySessionLocalToRemote(session, ownerId)
        ..['course_id'] = remoteCourseId;
      await SupabaseConfig.client.from('study_sessions').upsert(
        [sessionPayload],
        onConflict: 'id',
      );

      final resultRows = await db.query(
        'study_results',
        where: 'sessionId = ?',
        whereArgs: [sessionId],
      );
      final resultPayload = <Map<String, dynamic>>[];
      for (final row in resultRows) {
        final cardId = _localInt(row['cardId']);
        if (cardId == null) continue;
        final remoteCardId = await _ensureTargetedRemoteId(db, 'cards', cardId);
        resultPayload.add(
          _studyResultLocalToRemote(row, ownerId)
            ..['card_id'] = remoteCardId,
        );
      }
      if (resultPayload.isNotEmpty) {
        await SupabaseConfig.client.from('study_results').upsert(
          resultPayload,
          onConflict: 'id',
        );
      }
      await db.delete(
        'sync_outbox',
        where: 'kind = ? AND entityId = ?',
        whereArgs: ['review_session', '$sessionId'],
      );
      return SyncResult(
        pushed: 1 + resultPayload.length,
        pulled: 0,
      );
    } catch (error) {
      return SyncResult(pushed: 0, pulled: 0, error: error.toString());
    }
  }

  Future<SyncResult> _drainTargetedOutbox({
    String? table,
    String? entityId,
  }) async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final where = <String>[
      'tableName IS NOT NULL',
      "status = 'pending'",
      '(nextAttemptAt IS NULL OR nextAttemptAt <= ?)',
      if (table != null) 'tableName = ?',
      if (entityId != null) "(entityId = ? OR entityId LIKE ?)",
    ];
    final args = <Object?>[
      now,
      if (table != null) table,
      if (entityId != null) entityId,
      if (entityId != null) '$entityId:%',
    ];
    final rows = await db.query(
      'sync_outbox',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'createdAt ASC',
      limit: 200,
    );
    if (rows.isEmpty) return SyncResult(pushed: 0, pulled: 0);

    var pushed = 0;
    final errors = <String>[];
    for (final raw in rows) {
      final entry = _TargetedOutboxRow(raw);
      try {
        await _pushTargetedOutboxRow(db, entry);
        pushed++;
      } catch (error) {
        errors.add('${entry.table}/${entry.entityId}: $error');
        await _failTargetedOutbox(db, entry, error);
      }
    }
    return SyncResult(
      pushed: pushed,
      pulled: 0,
      error: errors.isEmpty ? null : errors.take(3).join(' | '),
    );
  }

  Future<void> _pushTargetedOutboxRow(
    Database db,
    _TargetedOutboxRow entry,
  ) async {
    if (entry.mutationId.isEmpty) {
      throw StateError('Mutation v2 thiếu mutation_id');
    }
    await _ensureLocalDeviceId(db);
    final payload = entry.payload == null || entry.payload!.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(entry.payload!) as Map);

    Map<String, Object?>? localRow;
    final localIdText = entry.entityId.split(':').first;
    final localId = int.tryParse(localIdText);
    if (entry.operation != 'delete' && localId != null) {
      final rows = entry.table == 'review_states' && entry.operation == 'review'
          ? await db.query(
              'review_states',
              where: 'cardId = ?',
              whereArgs: [payload['cardId'] ?? localId],
              limit: 1,
            )
          : await db.query(
              entry.table,
              where: 'id = ?',
              whereArgs: [localId],
              limit: 1,
            );
      if (rows.isNotEmpty) localRow = rows.first;
      if (localRow == null && entry.operation != 'review') {
        // The row was created then removed before it reached the server. A
        // missing insert has no server-side effect and is safe to acknowledge.
        await _completeTargetedOutbox(db, entry);
        return;
      }
    }

    dynamic response;
    if (entry.operation == 'review') {
      final cardId = _localInt(payload['cardId']);
      if (cardId == null) throw StateError('Review mutation thiếu cardId');
      final remoteCardId = await _ensureTargetedRemoteId(db, 'cards', cardId);
      response = await SupabaseConfig.client.rpc(
        'apply_srs_review_v2',
        params: {
          'p_card_id': remoteCardId,
          'p_rating': payload['rating']?.toString() ?? 'Good',
          'p_reviewed_at': payload['reviewedAt'],
          'p_mutation_id': entry.mutationId,
          'p_device_id': _localDeviceId,
          'p_base_revision': entry.baseRevision,
        },
      );
    } else {
      final mutationPayload = entry.operation == 'delete'
          ? payload
          : await _targetedPayload(db, entry.table, localRow!);
      final remoteId = entry.remoteId?.isNotEmpty == true
          ? entry.remoteId
          : localRow?['remoteId']?.toString().isNotEmpty == true
              ? localRow!['remoteId']!.toString()
              : localId == null
                  ? null
                  : _uuidFromLocalId(localId, _namespaceForTable(entry.table));
      response = await SupabaseConfig.client.rpc(
        'apply_sync_v2_mutation',
        params: {
          'p_table': entry.table,
          'p_entity_id': remoteId,
          'p_operation': entry.operation,
          'p_payload': mutationPayload,
          'p_mutation_id': entry.mutationId,
          'p_device_id': _localDeviceId,
          'p_base_revision': entry.baseRevision,
        },
      );
    }

    final result = response is Map
        ? Map<String, dynamic>.from(response)
        : throw StateError('RPC sync v2 không trả JSON object');
    final serverRowValue = result['row'];
    if (serverRowValue is Map && localId != null) {
      await _applyTargetedServerAck(
        db,
        entry,
        localId,
        Map<String, dynamic>.from(serverRowValue),
        payload,
      );
    }
    await _completeTargetedOutbox(db, entry);
  }

  Future<Map<String, dynamic>> _targetedPayload(
    Database db,
    String table,
    Map<String, Object?> row,
  ) async {
    final ownerId = SupabaseConfig.currentUser!.id;
    late final Map<String, dynamic> result;
    switch (table) {
      case 'topics':
        result = _topicLocalToRemote(row, ownerId);
        break;
      case 'courses':
        final topicId = _localInt(row['topicId']);
        final remoteTopicId = topicId == null
            ? null
            : await _ensureTargetedRemoteId(db, 'topics', topicId);
        result = _courseLocalToRemote(row, ownerId)
          ..['topic_id'] = remoteTopicId;
        break;
      case 'cards':
        final courseId = _localInt(row['courseId']);
        if (courseId == null) throw StateError('Card thiếu courseId');
        final remoteCourseId = await _ensureTargetedRemoteId(
          db,
          'courses',
          courseId,
        );
        result = _cardLocalToRemote(row, ownerId)
          ..['course_id'] = remoteCourseId;
        break;
      case 'card_examples':
        final cardId = _localInt(row['cardId']);
        if (cardId == null) throw StateError('Example thiếu cardId');
        final remoteCardId = await _ensureTargetedRemoteId(db, 'cards', cardId);
        result = _cardExampleLocalToRemote(row, ownerId)
          ..['card_id'] = remoteCardId;
        break;
      case 'review_states':
        final cardId = _localInt(row['cardId']);
        if (cardId == null) throw StateError('Review state thiếu cardId');
        final remoteCardId = await _ensureTargetedRemoteId(db, 'cards', cardId);
        result = _reviewStateLocalToRemote(row, ownerId)
          ..['card_id'] = remoteCardId;
        break;
      default:
        throw StateError('Bảng targeted không được hỗ trợ: $table');
    }
    return result
      ..remove('id')
      ..remove('owner_id')
      ..remove('revision')
      ..remove('updated_at')
      ..remove('last_device_id')
      ..remove('last_mutation_id');
  }

  Future<String> _ensureTargetedRemoteId(
    Database db,
    String table,
    int localId,
  ) async {
    final rows = await db.query(
      table,
      columns: const ['remoteId', 'serverRevision'],
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('$table/$localId không tồn tại local');
    final saved = rows.first['remoteId']?.toString() ?? '';
    final revision = _localInt(rows.first['serverRevision']) ?? 0;
    if (saved.isNotEmpty && revision > 0) return saved;

    final pending = await db.query(
      'sync_outbox',
      where: 'tableName = ? AND entityId = ?',
      whereArgs: [table, '$localId'],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (pending.isNotEmpty) {
      if (pending.first['status'] != 'pending') {
        throw StateError(
          'Dependency $table/$localId đang ở trạng thái '
          '${pending.first['status']}: ${pending.first['lastError']}',
        );
      }
      await _pushTargetedOutboxRow(db, _TargetedOutboxRow(pending.first));
      final refreshed = await db.query(
        table,
        columns: const ['remoteId'],
        where: 'id = ?',
        whereArgs: [localId],
        limit: 1,
      );
      final remoteId = refreshed.first['remoteId']?.toString() ?? '';
      if (remoteId.isNotEmpty) return remoteId;
    }

    final remoteId = saved.isNotEmpty
        ? saved
        : _uuidFromLocalId(localId, _namespaceForTable(table));
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      'sync_outbox',
      {
        'kind': 'v2:$table',
        'entityId': '$localId',
        'tableName': table,
        'operation': 'upsert',
        'remoteId': remoteId,
        'mutationId': _newMutationId(),
        'baseRevision': revision,
        'createdAt': now,
        'updatedAt': now,
        'nextAttemptAt': now,
        'attempts': 0,
        'status': 'pending',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final dependency = await db.query(
      'sync_outbox',
      where: 'kind = ? AND entityId = ?',
      whereArgs: ['v2:$table', '$localId'],
      limit: 1,
    );
    await _pushTargetedOutboxRow(db, _TargetedOutboxRow(dependency.first));
    final refreshed = await db.query(
      table,
      columns: const ['remoteId'],
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return refreshed.first['remoteId']?.toString() ?? remoteId;
  }

  String _newMutationId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int length) => bytes
        .skip(start)
        .take(length)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-'
        '${hex(8, 2)}-${hex(10, 6)}';
  }

  String _namespaceForTable(String table) => switch (table) {
        'topics' => 'topic',
        'courses' => 'course',
        'cards' => 'card',
        'card_examples' => 'card_example',
        'review_states' => 'review_state',
        _ => table,
      };

  Future<void> _applyTargetedServerAck(
    Database db,
    _TargetedOutboxRow entry,
    int localId,
    Map<String, dynamic> remote,
    Map<String, dynamic> requestPayload,
  ) async {
    await db.transaction((txn) async {
      final current = await txn.query(
        'sync_outbox',
        columns: const ['mutationId'],
        where: 'kind = ? AND entityId = ?',
        whereArgs: [entry.kind, entry.entityId],
        limit: 1,
      );
      if (current.isEmpty || current.first['mutationId'] != entry.mutationId) {
        return;
      }
      await AppDatabase.instance.suppressSyncOutbox(txn);
      try {
        final metadata = <String, Object?>{
          'remoteId': remote['id']?.toString(),
          'serverRevision': _localInt(remote['revision']) ?? 0,
          'lastDeviceId': remote['last_device_id']?.toString(),
          'lastMutationId': remote['last_mutation_id']?.toString(),
          'updatedAt': _remoteTimestampToLocalIso(remote['updated_at']),
        };
        if (entry.operation == 'review') {
          final cardId = _localInt(requestPayload['cardId']) ?? localId;
          final reviewData = _reviewStateRemoteToLocal(remote)
            ..remove('id')
            ..['cardId'] = cardId
            ..['remoteId'] = metadata['remoteId']
            ..['serverRevision'] = metadata['serverRevision']
            ..['lastDeviceId'] = metadata['lastDeviceId']
            ..['lastMutationId'] = metadata['lastMutationId'];
          await txn.update(
            'review_states',
            reviewData,
            where: 'cardId = ?',
            whereArgs: [cardId],
          );
        } else if (entry.operation != 'delete') {
          await txn.update(
            entry.table,
            metadata,
            where: 'id = ?',
            whereArgs: [localId],
          );
        }
      } finally {
        await AppDatabase.instance.resumeSyncOutbox(txn);
      }
    });
    final remoteId = remote['id']?.toString();
    if (remoteId != null && remoteId.isNotEmpty) {
      if (entry.table == 'topics') {
        _topicRemoteIdByLocal['$localId'] = remoteId;
        _topicLocalIdByRemote[remoteId] = localId;
      } else if (entry.table == 'courses') {
        _courseRemoteIdByLocal['$localId'] = remoteId;
        _courseLocalIdByRemote[remoteId] = localId;
      } else if (entry.table == 'cards') {
        _cardRemoteIdByLocal['$localId'] = remoteId;
        _cardLocalIdByRemote[remoteId] = localId;
      }
    }
  }

  Future<void> _completeTargetedOutbox(
    Database db,
    _TargetedOutboxRow entry,
  ) async {
    await db.delete(
      'sync_outbox',
      where: 'kind = ? AND entityId = ? AND mutationId = ?',
      whereArgs: [entry.kind, entry.entityId, entry.mutationId],
    );
  }

  Future<void> _failTargetedOutbox(
    Database db,
    _TargetedOutboxRow entry,
    Object error,
  ) async {
    final text = error.toString();
    if (text.toLowerCase().contains('sync conflict')) {
      if (entry.operation == 'review' &&
          await _rebaseReviewMutation(db, entry, text)) {
        return;
      }
      Map<String, dynamic>? remote;
      final remoteId = entry.remoteId;
      if (remoteId != null && remoteId.isNotEmpty) {
        try {
          remote = await SupabaseConfig.client
              .from(entry.table)
              .select()
              .eq('id', remoteId)
              .maybeSingle();
        } catch (_) {}
      }
      await db.update(
        'sync_outbox',
        {
          'status': 'conflict',
          'lastError': text,
          if (remote != null)
            'payload': jsonEncode({'conflict_remote': remote}),
        },
        where: 'kind = ? AND entityId = ? AND mutationId = ?',
        whereArgs: [entry.kind, entry.entityId, entry.mutationId],
      );
      await ServerLogService.write('sync_v2.conflict', details: {
        'table': entry.table,
        'entityId': entry.entityId,
        'baseRevision': entry.baseRevision,
      });
      return;
    }

    final attempts = entry.attempts + 1;
    final dead = attempts >= 8;
    final delaySeconds = math.min(300, math.pow(2, attempts).toInt());
    await db.update(
      'sync_outbox',
      {
        'attempts': attempts,
        'status': dead ? 'dead' : 'pending',
        'lastError': text,
        'updatedAt': DateTime.now().toIso8601String(),
        'nextAttemptAt': DateTime.now()
            .add(Duration(seconds: delaySeconds))
            .toUtc()
            .toIso8601String(),
      },
      where: 'kind = ? AND entityId = ? AND mutationId = ?',
      whereArgs: [entry.kind, entry.entityId, entry.mutationId],
    );
    if (dead) {
      await ServerLogService.write('sync_v2.dead_letter', details: {
        'table': entry.table,
        'entityId': entry.entityId,
        'attempts': attempts,
        'error': text,
      });
    }
  }

  Future<bool> _rebaseReviewMutation(
    Database db,
    _TargetedOutboxRow entry,
    String error,
  ) async {
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(entry.payload ?? '{}') as Map,
      );
      final cardId = _localInt(payload['cardId']);
      if (cardId == null) return false;
      final remoteCardId = await _ensureTargetedRemoteId(db, 'cards', cardId);
      final remote = await SupabaseConfig.client
          .from('review_states')
          .select('revision')
          .eq('card_id', remoteCardId)
          .maybeSingle();
      final revision = _localInt(remote?['revision']) ?? 0;
      await db.update(
        'sync_outbox',
        {
          'baseRevision': revision,
          'status': 'pending',
          'nextAttemptAt': DateTime.now().toUtc().toIso8601String(),
          'lastError': 'Đã rebase SRS từ revision $revision: $error',
        },
        where: 'kind = ? AND entityId = ? AND mutationId = ?',
        whereArgs: [entry.kind, entry.entityId, entry.mutationId],
      );
      await ServerLogService.write('sync_v2.review_rebased', details: {
        'cardId': cardId,
        'baseRevision': revision,
        'mutationId': entry.mutationId,
      });
      return true;
    } catch (rebaseError) {
      await ServerLogService.write('sync_v2.review_rebase_failed', details: {
        'entityId': entry.entityId,
        'error': rebaseError,
      });
      return false;
    }
  }

  /// Retries durable local mutations without changing merge/LWW behavior.
  Future<SyncResult?> retryPendingOutbox() async {
    if (_outboxRetryInFlight ||
        _generalPushRequestsInFlight > 0 ||
        _activeSync != null ||
        _isPushingStudyData ||
        !SupabaseConfig.isLoggedIn) {
      return null;
    }
    // Set this before the first await. Realtime subscription and the periodic
    // timer can otherwise both enter and replay the same outbox snapshot.
    _outboxRetryInFlight = true;
    SyncResult? lastResult;
    try {
      await AppDatabase.instance.ensureSyncOutboxTable();
      final db = await AppDatabase.instance.database;
      final rows = await db.query('sync_outbox', orderBy: 'createdAt ASC');
      if (rows.isEmpty) return null;
      final targetedRows = rows
          .where((row) => row['tableName']?.toString().isNotEmpty == true)
          .toList(growable: false);
      if (targetedRows.isNotEmpty) {
        lastResult = await _drainTargetedOutbox();
      }
      if (isLearningSyncPaused) return lastResult;

      List<_OutboxTicket> ticketsFor(String kind) => rows
          .where((row) => row['kind'] == kind)
          .map(
            (row) => _OutboxTicket(
              kind,
              row['entityId']?.toString() ?? '',
              row['updatedAt']?.toString() ?? '',
            ),
          )
          .toList();

      final generalTickets = ticketsFor('general');
      if (generalTickets.isNotEmpty) {
        // Replay the existing marker directly. Calling syncPendingChanges()
        // here would touch the marker's token and schedule another livePush.
        lastResult = await _pushGeneralOutboxEntries(generalTickets);
      }

      final cardIds = rows
          .where((row) => row['kind'] == 'review_card')
          .map((row) => int.tryParse(row['entityId']?.toString() ?? ''))
          .whereType<int>()
          .toSet();
      if (cardIds.isNotEmpty) {
        final tickets = ticketsFor('review_card');
        try {
          // Compatibility cleanup for pre-v2 markers. New answers already have
          // immutable review mutations and never create review_card tickets.
          lastResult = await _drainTargetedOutbox(table: 'review_states');
          if (lastResult.hasError) {
            await _failOutbox(tickets, lastResult.error!);
          } else {
            await _completeOutbox(tickets);
          }
        } catch (error) {
          await _failOutbox(tickets, error);
          rethrow;
        }
      }

      final sessionIds = rows
          .where((row) => row['kind'] == 'review_session')
          .map((row) => int.tryParse(row['entityId']?.toString() ?? ''))
          .whereType<int>();
      for (final sessionId in sessionIds) {
        final tickets = ticketsFor('review_session')
            .where((ticket) => ticket.entityId == '$sessionId')
            .toList();
        try {
          lastResult = await _pushStudySessionAndResults(sessionId);
          if (lastResult.hasError) {
            await _failOutbox(tickets, lastResult.error!);
          } else {
            await _completeOutbox(tickets);
          }
        } catch (error) {
          await _failOutbox(tickets, error);
          rethrow;
        }
      }

      if (rows.any((row) => row['kind'] == 'review_all')) {
        final tickets = ticketsFor('review_all');
        try {
          lastResult = await _drainTargetedOutbox(table: 'review_states');
          if (lastResult.hasError) {
            await _failOutbox(tickets, lastResult.error!);
          } else {
            await _completeOutbox(tickets);
          }
        } catch (error) {
          await _failOutbox(tickets, error);
          rethrow;
        }
      }

      final deletedReviewCardIds = rows
          .where((row) => row['kind'] == 'delete_review_card')
          .map((row) => int.tryParse(row['entityId']?.toString() ?? ''))
          .whereType<int>()
          .toSet();
      if (isLearningSyncPaused) return lastResult;
      if (deletedReviewCardIds.isNotEmpty) {
        await deleteRemoteReviewStatesForCards(deletedReviewCardIds);
      }
      return lastResult;
    } finally {
      _outboxRetryInFlight = false;
      if (!isLearningSyncPaused &&
          !_resumingDeferredWork &&
          (_deferredSyncOperation != null ||
              _realtimePendingChanges.isNotEmpty)) {
        unawaited(_resumeDeferredWorkAfterLearning());
      }
    }
  }

  Future<SyncResult> _syncReviewStatesAfterStudyOnce({
    int? sessionId,
    Set<int>? cardIds,
    bool allowWhileLearning = false,
  }) async {
    if (isLearningSyncPaused && !allowWhileLearning) {
      return _learningDeferredResult();
    }
    final active = _activeSync;
    if (active != null) await active;
    if (isLearningSyncPaused && !allowWhileLearning) {
      return _learningDeferredResult();
    }
    if (!SupabaseConfig.isLoggedIn) {
      return SyncResult(pushed: 0, pulled: 0, error: 'ChÆ°a Ä‘Äƒng nháº­p');
    }

    try {
      await ServerLogService.write('study_sync.start', details: {
        'sessionId': sessionId,
        'requestedCards': cardIds?.length ?? 'from-session',
      });
      // Push newly created topics/courses/cards first. Otherwise an SRS row can
      // be skipped because its card does not exist on Supabase yet.
      _studyPushCanOverlapLearning = allowWhileLearning;
      _isPushingStudyData = true;
      // This is the one permitted sync while the learning pause is held: it
      // creates any missing parent rows required by the just-finished SRS
      // upload. It never pulls/replaces local learning state.
      _generalPushRequestsInFlight++;
      late final SyncResult dependencySync;
      try {
        final dependencyEntry = await _enqueueOutbox('general', '');
        dependencySync = await _pushGeneralOutboxEntries(
          [dependencyEntry],
          allowWhileLearning: allowWhileLearning,
          isStudyDependency: true,
        );
      } finally {
        _generalPushRequestsInFlight--;
      }
      if (isLearningSyncPaused && !allowWhileLearning) {
        _isPushingStudyData = false;
        _studyPushCanOverlapLearning = false;
        _cancelSyncRequested = false;
        return _learningDeferredResult();
      }
      await ServerLogService.write('study_sync.dependencies', details: {
        'sessionId': sessionId,
        'pushed': dependencySync.pushed,
        'pulled': dependencySync.pulled,
        'error': dependencySync.error,
      });
      final db = await AppDatabase.instance.database;
      final ownerId = SupabaseConfig.currentUser!.id;
      final targetCardIds = <int>{...?cardIds};
      if (sessionId != null) {
        final resultCards = await db.query(
          'study_results',
          columns: ['cardId'],
          where: 'sessionId = ?',
          whereArgs: [sessionId],
        );
        targetCardIds.addAll(
          resultCards
              .map((row) => _localInt(row['cardId']))
              .whereType<int>(),
        );
      }
      final hasExplicitTargets = sessionId != null || cardIds != null;
      final targetWhere = targetCardIds.isEmpty
          ? (hasExplicitTargets ? ' AND 1 = 0' : '')
          : ' AND rs.cardId IN (${List.filled(targetCardIds.length, '?').join(',')})';
      // A manually assigned due date is valid even at SRS level 0, so push
      // every local review state instead of filtering only progressed cards.
      final localStates = await db.rawQuery('''
        SELECT rs.*
        FROM review_states rs
        INNER JOIN cards ca ON ca.id = rs.cardId
        INNER JOIN courses c ON c.id = ca.courseId
        WHERE ca.deletedAt IS NULL
          AND c.deletedAt IS NULL
          AND COALESCE(c.hasLocalNameConflict, 0) = 0
$targetWhere
      ''', targetCardIds.toList());
      await ServerLogService.write('study_sync.local_scope', details: {
        'sessionId': sessionId,
        'cards': targetCardIds.length,
        'srsRows': localStates.length,
      });
      final payload = <Map<String, dynamic>>[];
      final skippedCardIds = <int>[];
      final failedRemoteCardIds = <String>[];
      final missingScheduleCardIds = <String>{};
      final timestamp = DateTime.now().toUtc().toIso8601String();

      for (final state in localStates) {
        final cardId = _localInt(state['cardId']);
        if (cardId == null) continue;
        final mappedRemoteCardId = _cardRemoteIdByLocal['$cardId'];
        final remoteCardId = mappedRemoteCardId?.isNotEmpty == true
            ? mappedRemoteCardId
            : await findRemoteCardId(cardId);
        if (remoteCardId == null || remoteCardId.isEmpty) {
          skippedCardIds.add(cardId);
          continue;
        }

        final row = _reviewStateLocalToRemote(state, ownerId)
          ..remove('id')
          ..['card_id'] = remoteCardId
          ..['updated_at'] = timestamp;
        payload.add(row);
      }

      for (var start = 0; start < payload.length; start += 200) {
        if (isLearningSyncPaused && !allowWhileLearning) {
          throw StateError('Đồng bộ SRS tự động đã được hoãn đến hết phiên học');
        }
        final end = math.min(start + 200, payload.length);
        final chunk = payload.sublist(start, end);
        try {
          final savedRows = await SupabaseConfig.client
              .from('review_states')
              .upsert(chunk, onConflict: 'owner_id,card_id')
              .select('card_id,next_review_at,interval_days');
          if (savedRows.length != chunk.length) {
            throw StateError(
              'Server chỉ trả về ${savedRows.length}/${chunk.length} SRS',
            );
          }
          missingScheduleCardIds.addAll(
            savedRows
                .where((row) {
                  final value = row['next_review_at']?.toString() ?? '';
                  return value.isEmpty;
                })
                .map((row) => row['card_id']?.toString())
                .whereType<String>(),
          );
        } catch (_) {
          // One stale foreign key must not prevent every valid SRS state in
          // the same batch from reaching Supabase.
          for (final row in chunk) {
            try {
              final savedRows = await SupabaseConfig.client
                  .from('review_states')
                  .upsert([row], onConflict: 'owner_id,card_id')
                  .select('card_id,next_review_at,interval_days');
              if (savedRows.length != 1) {
                throw StateError('Server không xác nhận SRS vừa lưu');
              }
              final savedSchedule =
                  savedRows.first['next_review_at']?.toString() ?? '';
              if (savedSchedule.isEmpty) {
                missingScheduleCardIds.add(row['card_id'].toString());
              }
            } catch (_) {
              failedRemoteCardIds.add(row['card_id']?.toString() ?? '?');
            }
          }
        }
      }
      await ServerLogService.write('study_sync.srs_uploaded', details: {
        'sessionId': sessionId,
        'payload': payload.length,
        'skippedCards': skippedCardIds.length,
        'failedCards': failedRemoteCardIds.length,
      });

      // Some existing server rows can acknowledge the conflict update while
      // still returning an empty schedule. Apply those SRS fields explicitly
      // before the final read-back verification.
      for (final cardId in missingScheduleCardIds) {
        final source = payload.where((row) => row['card_id'] == cardId);
        if (source.isEmpty) continue;
        final row = source.first;
        await SupabaseConfig.client
            .from('review_states')
            .update({
              'level': row['level'],
              'ease_factor': row['ease_factor'],
              'interval_days': row['interval_days'],
              'repetition_count': row['repetition_count'],
              'correct_count': row['correct_count'],
              'wrong_count': row['wrong_count'],
              'last_reviewed_at': row['last_reviewed_at'],
              'next_review_at': row['next_review_at'],
              'updated_at': timestamp,
            })
            .eq('owner_id', ownerId)
            .eq('card_id', cardId);
      }

      final expectedScheduleCount = payload.where((row) {
        final nextReviewAt = row['next_review_at']?.toString() ?? '';
        return nextReviewAt.isNotEmpty;
      }).length;
      var verifiedStateCount = 0;
      var verifiedMatchingStateCount = 0;
      var verifiedScheduleCount = 0;
      final expectedStateByCardId = <String, Map<String, dynamic>>{
        for (final row in payload)
          if (row['card_id'] != null) row['card_id'].toString(): row,
      };
      bool sameTimestamp(Object? left, Object? right) {
        final leftText = left?.toString() ?? '';
        final rightText = right?.toString() ?? '';
        if (leftText.isEmpty || rightText.isEmpty) {
          return leftText.isEmpty && rightText.isEmpty;
        }
        final leftTime = DateTime.tryParse(leftText);
        final rightTime = DateTime.tryParse(rightText);
        if (leftTime != null && rightTime != null) {
          return leftTime.isAtSameMomentAs(rightTime);
        }
        return leftText == rightText;
      }
      double numberValue(Object? value) {
        if (value is num) return value.toDouble();
        return double.tryParse(value?.toString() ?? '') ?? 0;
      }
      final remoteCardIds = payload
          .map((row) => row['card_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList();
      for (var start = 0; start < remoteCardIds.length; start += 200) {
        final end = math.min(start + 200, remoteCardIds.length);
        final rows = await SupabaseConfig.client
            .from('review_states')
            .select(
              'card_id,level,ease_factor,interval_days,repetition_count,'
              'correct_count,wrong_count,last_reviewed_at,next_review_at',
            )
            .eq('owner_id', ownerId)
            .inFilter('card_id', remoteCardIds.sublist(start, end));
        verifiedStateCount += rows.length;
        verifiedMatchingStateCount += rows.where((remote) {
          final expected = expectedStateByCardId[remote['card_id']?.toString()];
          if (expected == null) return false;
          return _localInt(remote['level']) == _localInt(expected['level']) &&
              (numberValue(remote['ease_factor']) -
                          numberValue(expected['ease_factor']))
                      .abs() <
                  0.000001 &&
              _localInt(remote['interval_days']) ==
                  _localInt(expected['interval_days']) &&
              _localInt(remote['repetition_count']) ==
                  _localInt(expected['repetition_count']) &&
              _localInt(remote['correct_count']) ==
                  _localInt(expected['correct_count']) &&
              _localInt(remote['wrong_count']) ==
                  _localInt(expected['wrong_count']) &&
              sameTimestamp(
                remote['last_reviewed_at'],
                expected['last_reviewed_at'],
              ) &&
              sameTimestamp(remote['next_review_at'], expected['next_review_at']);
        }).length;
        verifiedScheduleCount += rows.where((row) {
          final nextReviewAt = row['next_review_at']?.toString() ?? '';
          return nextReviewAt.isNotEmpty;
        }).length;
      }
      var verifiedStudyResultCount = 0;
      var expectedStudyResultCount = 0;
      String? studyDataError;
      if (sessionId != null) {
        final verification = await _pushAndVerifyStudySession(
          db: db,
          ownerId: ownerId,
          localSessionId: sessionId,
        );
        expectedStudyResultCount = verification.expected;
        verifiedStudyResultCount = verification.verified;
        studyDataError = verification.error;
      }

      final errors = <String>[
        if (dependencySync.hasError)
          'Lỗi đồng bộ dữ liệu cha: ${dependencySync.error}',
        if (skippedCardIds.isNotEmpty)
          'Không tìm thấy ${skippedCardIds.length} thẻ trên server',
        if (failedRemoteCardIds.isNotEmpty)
          'Không đẩy được SRS của ${failedRemoteCardIds.length} thẻ',
        if (verifiedStateCount != payload.length - failedRemoteCardIds.length)
          'Server chỉ lưu $verifiedStateCount/${payload.length - failedRemoteCardIds.length} SRS',
        if (verifiedScheduleCount != expectedScheduleCount)
          'Server chỉ xác nhận $verifiedScheduleCount/$expectedScheduleCount lịch ôn',
      ];
      if (verifiedMatchingStateCount != verifiedStateCount) {
        errors.add(
          'Server chỉ khớp $verifiedMatchingStateCount/'
          '$verifiedStateCount giá trị SRS',
        );
      }
      if (studyDataError != null) errors.add(studyDataError);
      if (verifiedStudyResultCount != expectedStudyResultCount) {
        errors.add(
          'Server chỉ xác nhận $verifiedStudyResultCount/'
          '$expectedStudyResultCount kết quả học',
        );
      }
      print(
        'SRS SERVER RESULT: states=$verifiedStateCount/${payload.length}, '
        'scheduled=$verifiedScheduleCount/$expectedScheduleCount, '
        'skippedCards=${skippedCardIds.length}',
      );
      await ServerLogService.write('study_sync.finish', details: {
        'sessionId': sessionId,
        'srs': '$verifiedStateCount/${payload.length}',
        'srsValues': '$verifiedMatchingStateCount/$verifiedStateCount',
        'schedules': '$verifiedScheduleCount/$expectedScheduleCount',
        'studyResults': '$verifiedStudyResultCount/$expectedStudyResultCount',
        'error': errors.isEmpty ? null : errors.join(' | '),
      });
      _isPushingStudyData = false;
      _studyPushCanOverlapLearning = false;
      _cancelSyncRequested = false;
      return SyncResult(
        pushed: verifiedStateCount + verifiedStudyResultCount,
        pulled: 0,
        error: errors.isEmpty ? null : errors.join(' | '),
        logs: [
          'SRS: server xác nhận $verifiedStateCount/${payload.length} trạng thái',
          'Lịch ôn: server xác nhận $verifiedScheduleCount/$expectedScheduleCount ngày',
        ],
      );
    } catch (error) {
      _isPushingStudyData = false;
      _studyPushCanOverlapLearning = false;
      _cancelSyncRequested = false;
      await ServerLogService.write('study_sync.error', details: {
        'sessionId': sessionId,
        'error': error,
      });
      return SyncResult(pushed: 0, pulled: 0, error: error.toString());
    }
  }

  Future<({int expected, int verified, String? error})>
      _pushAndVerifyStudySession({
    required Database db,
    required String ownerId,
    required int localSessionId,
  }) async {
    final sessions = await db.query(
      'study_sessions',
      where: 'id = ?',
      whereArgs: [localSessionId],
      limit: 1,
    );
    if (sessions.isEmpty) {
      return (expected: 0, verified: 0, error: 'Không tìm thấy phiên học local');
    }

    final session = sessions.first;
    final localCourseId = _localInt(session['courseId']);
    final mappedRemoteCourseId = localCourseId == null
        ? null
        : _courseRemoteIdByLocal['$localCourseId'];
    final remoteCourseId = mappedRemoteCourseId?.isNotEmpty == true
        ? mappedRemoteCourseId
        : (localCourseId == null
              ? null
              : await findRemoteCourseId(localCourseId));
    if (remoteCourseId == null || remoteCourseId.isEmpty) {
      return (
        expected: 0,
        verified: 0,
        error: 'Không tìm thấy học phần của phiên học trên server',
      );
    }

    final remoteSessionId = _uuidFromLocalId(localSessionId, 'study_session');
    final sessionPayload = _studySessionLocalToRemote(session, ownerId)
      ..['id'] = remoteSessionId
      ..['course_id'] = remoteCourseId
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await SupabaseConfig.client
        .from('study_sessions')
        .upsert([sessionPayload], onConflict: 'id');

    final localResults = await db.query(
      'study_results',
      where: 'sessionId = ?',
      whereArgs: [localSessionId],
      orderBy: 'id ASC',
    );
    final sessionAnsweredCount =
        (_localInt(session['correctCount']) ?? 0) +
        (_localInt(session['wrongCount']) ?? 0);
    final payload = <Map<String, dynamic>>[];
    final unmappedCardIds = <int>[];
    for (final result in localResults) {
      final localCardId = _localInt(result['cardId']);
      if (localCardId == null) continue;
      final mappedRemoteCardId = _cardRemoteIdByLocal['$localCardId'];
      final remoteCardId = mappedRemoteCardId?.isNotEmpty == true
          ? mappedRemoteCardId
          : await findRemoteCardId(localCardId);
      if (remoteCardId == null || remoteCardId.isEmpty) {
        unmappedCardIds.add(localCardId);
        continue;
      }
      payload.add(
        _studyResultLocalToRemote(result, ownerId)
          ..['session_id'] = remoteSessionId
          ..['card_id'] = remoteCardId,
      );
    }
    await ServerLogService.write('study_sync.results_prepared', details: {
      'sessionId': localSessionId,
      'sessionTotalCards': session['totalCards'],
      'sessionAnswered': sessionAnsweredCount,
      'localResults': localResults.length,
      'payload': payload.length,
      'unmappedCards': unmappedCardIds.length,
    });

    for (var start = 0; start < payload.length; start += 200) {
      final end = math.min(start + 200, payload.length);
      await SupabaseConfig.client
          .from('study_results')
          .upsert(payload.sublist(start, end), onConflict: 'id');
    }
    var verifiedRows = await SupabaseConfig.client
        .from('study_results')
        .select('id')
        .eq('owner_id', ownerId)
        .eq('session_id', remoteSessionId);
    // Remove only stale extras after every current local result has been
    // accepted. This keeps an undone answer from inflating the learned count.
    final expectedRemoteIds = payload
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();
    final staleRemoteIds = verifiedRows
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .where((id) => !expectedRemoteIds.contains(id))
        .toList();
    if (unmappedCardIds.isEmpty && staleRemoteIds.isNotEmpty) {
      await SupabaseConfig.client
          .from('study_results')
          .delete()
          .eq('owner_id', ownerId)
          .eq('session_id', remoteSessionId)
          .inFilter('id', staleRemoteIds);
      verifiedRows = await SupabaseConfig.client
          .from('study_results')
          .select('id')
          .eq('owner_id', ownerId)
          .eq('session_id', remoteSessionId);
    }
    await ServerLogService.write('study_sync.results_verified', details: {
      'sessionId': localSessionId,
      'expected': localResults.length,
      'verified': verifiedRows.length,
      'removedStale': staleRemoteIds.length,
    });
    final resultErrors = <String>[
      if (sessionAnsweredCount != localResults.length)
        'Phiên ghi nhận $sessionAnsweredCount câu trả lời nhưng local chỉ có '
            '${localResults.length} kết quả',
      if (unmappedCardIds.isNotEmpty)
        'Thiếu ánh xạ server của ${unmappedCardIds.length} thẻ đã học',
    ];
    return (
      expected: localResults.length,
      verified: verifiedRows.length,
      error: resultErrors.isEmpty ? null : resultErrors.join(' | '),
    );
  }

  Future<void> beginAuthenticatedSession({bool newLogin = false}) async {
    final session = SupabaseConfig.client.auth.currentSession;
    final expiresAt = session?.expiresAt;
    if (expiresAt != null) {
      final refreshBefore =
          DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/
              1000;
      if (expiresAt <= refreshBefore) {
        try {
          await SupabaseConfig.client.auth.refreshSession();
          await ServerLogService.write('auth.session_refreshed', details: {
            'reason': 'expired-before-realtime-subscribe',
          });
        } catch (error) {
          await ServerLogService.write('auth.session_refresh_error', details: {
            'reason': 'expired-before-realtime-subscribe',
            'error': error,
          });
          rethrow;
        }
      }
    }

    final user = SupabaseConfig.currentUser;
    if (user == null) return;
    if (!newLogin &&
        _sessionOwnerId == user.id &&
        _livePushCursorAt?.isNotEmpty == true) {
      if (_identityOwnerId != user.id) {
        final db = await AppDatabase.instance.database;
        await AppDatabase.instance.ensureSyncOutboxTable();
        await _ensureLocalDeviceId(db);
        await _prepareIdentityMaps(db, SupabaseConfig.client, user.id);
        _identityOwnerId = user.id;
      }
      startRealtimeSync();
      return;
    }
    if (newLogin || _sessionOwnerId != user.id) {
      _identityOwnerId = null;
    }

    final db = await AppDatabase.instance.database;
    await AppDatabase.instance.ensureSyncOutboxTable();
    await _ensureLocalDeviceId(db);
    final boundOwnerRows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync.localBoundOwnerId'],
      limit: 1,
    );
    final previousOwner = boundOwnerRows.isEmpty
        ? ''
        : boundOwnerRows.first['value']?.toString() ?? '';
    if (previousOwner.isNotEmpty && previousOwner != user.id) {
      // Pending mutations belong to the previous account and must never be
      // replayed into a newly authenticated account.
      await db.delete('sync_outbox');
    }
    final key = 'sync.livePushCursor.v2.${user.id}';
    String? startedAt;
    if (!newLogin) {
      final rows = await db.query(
        'app_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      startedAt = rows.isEmpty ? null : rows.first['value']?.toString();
    }
    startedAt ??= DateTime.now().toIso8601String();
    _sessionOwnerId = user.id;
    _livePushCursorAt = startedAt;
    await _setLocalSetting(db, key, startedAt);
    await _setLocalSetting(db, 'sync.localBoundOwnerId', user.id);
    await _prepareIdentityMaps(db, SupabaseConfig.client, user.id);
    _identityOwnerId = user.id;
    startRealtimeSync();
  }

  void endAuthenticatedSession() {
    stopRealtimeSync();
    _sessionOwnerId = null;
    _livePushCursorAt = null;
    _identityOwnerId = null;
    _deferredSyncOperation = null;
  }

  /// Rebuilds the channel so Realtime uses the latest access token.
  ///
  /// Supabase can restore an expired persisted session before its asynchronous
  /// token refresh completes. A channel created in that window remains in an
  /// errored state even after Auth receives the new token.
  void restartRealtimeSync() {
    if (!SupabaseConfig.isLoggedIn) return;
    stopRealtimeSync();
    startRealtimeSync();
  }

  /// Listens to server-side changes and merges them into the local SQLite
  /// database after a short debounce window.
  void startRealtimeSync() {
    final user = SupabaseConfig.currentUser;
    if (user == null || _realtimeChannel != null) return;

    void onChange(PostgresChangePayload change) => _queueRealtimeChange(change);

    var channel = SupabaseConfig.client.channel('account-sync:${user.id}');
    for (final table in const [
      'topics',
      'courses',
      'cards',
      'review_states',
      'card_examples',
    ]) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'owner_id',
          value: user.id,
        ),
        callback: onChange,
      );
    }
    _realtimeChannel = channel;
    channel.subscribe((status, error) {
      unawaited(ServerLogService.write('realtime.subscription', details: {
        'status': status,
        'error': error,
      }));
      if (status == RealtimeSubscribeStatus.channelError) {
        print('REALTIME SUBSCRIPTION ERROR: $error');
      } else if (status == RealtimeSubscribeStatus.subscribed) {
        // A successful subscription also means the network is reachable
        // again. Replay the server delta missed while disconnected before
        // retrying local mutations.
        unawaited(_catchUpAfterRealtimeReconnect());
      }
    });
  }

  Future<void> _catchUpAfterRealtimeReconnect() async {
    if (!SupabaseConfig.isLoggedIn || _isSyncing) return;
    final db = await AppDatabase.instance.database;
    final user = SupabaseConfig.currentUser!;
    final key = 'sync.deltaCursor.v2.${user.id}';
    final saved = await db.query(
      'app_settings',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    final cursor = saved.isEmpty
        ? DateTime.now().subtract(const Duration(minutes: 5)).toUtc()
        : (DateTime.tryParse(saved.first['value']?.toString() ?? '') ??
                DateTime.now().subtract(const Duration(minutes: 5)))
            .subtract(const Duration(seconds: 5))
            .toUtc();
    final upperCursor = DateTime.now().toUtc();
    _isSyncing = true;
    final previousOperation = _operation;
    _operation = _SyncOperation.pullReplace;
    try {
      final response = await SupabaseConfig.client.rpc(
        'sync_v2_changes_since',
        params: {'p_since': cursor.toIso8601String()},
      );
      final items = response is List ? response : const [];
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final item in items) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final table = map['table_name']?.toString() ?? '';
        final row = map['row_data'];
        if (row is Map) {
          grouped
              .putIfAbsent(table, () => <Map<String, dynamic>>[])
              .add(Map<String, dynamic>.from(row));
        }
      }
      for (final table in const [
        'topics',
        'courses',
        'cards',
        'card_examples',
        'review_states',
      ]) {
        final rows = grouped[table];
        if (rows == null || rows.isEmpty) continue;
        await _applyDeltaRows(db, user.id, table, rows);
      }
      await _setLocalSetting(db, key, upperCursor.toIso8601String());
    } catch (error) {
      await ServerLogService.write('sync_v2.delta_error', details: {
        'cursor': cursor.toIso8601String(),
        'error': error,
      });
    } finally {
      _operation = previousOperation;
      _isSyncing = false;
    }
    await retryPendingOutbox();
  }

  Future<void> _applyDeltaRows(
    Database db,
    String ownerId,
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    final client = SupabaseConfig.client;
    switch (table) {
      case 'topics':
        await _syncTable(
          db: db, client: client, ownerId: ownerId,
          localTable: table, remoteTable: table, idColumn: 'id',
          localToRemote: _topicLocalToRemote,
          remoteToLocal: _topicRemoteToLocal,
          remoteRowsOverride: rows,
        );
        break;
      case 'courses':
        await _syncTable(
          db: db, client: client, ownerId: ownerId,
          localTable: table, remoteTable: table, idColumn: 'id',
          localToRemote: _courseLocalToRemote,
          remoteToLocal: _courseRemoteToLocal,
          remoteRowsOverride: rows,
        );
        break;
      case 'cards':
        await _syncTable(
          db: db, client: client, ownerId: ownerId,
          localTable: table, remoteTable: table, idColumn: 'id',
          localToRemote: _cardLocalToRemote,
          remoteToLocal: _cardRemoteToLocal,
          remoteRowsOverride: rows,
        );
        break;
      case 'card_examples':
        await _syncTable(
          db: db, client: client, ownerId: ownerId,
          localTable: table, remoteTable: table, idColumn: 'id',
          localToRemote: _cardExampleLocalToRemote,
          remoteToLocal: _cardExampleRemoteToLocal,
          remoteRowsOverride: rows,
        );
        break;
      case 'review_states':
        await _syncTable(
          db: db, client: client, ownerId: ownerId,
          localTable: table, remoteTable: table, idColumn: 'id',
          remoteConflictColumns: 'owner_id,card_id',
          localConflictColumns: const ['cardId'],
          localToRemote: _reviewStateLocalToRemote,
          remoteToLocal: _reviewStateRemoteToLocal,
          remoteRowsOverride: rows,
        );
        break;
    }
  }

  void stopRealtimeSync() {
    _realtimeMergeDebounce?.cancel();
    _realtimeMergeDebounce = null;
    _realtimePendingChanges.clear();
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    if (channel != null) {
      unawaited(ServerLogService.write('realtime.stopped'));
      unawaited(SupabaseConfig.client.removeChannel(channel));
    }
  }

  void _queueRealtimeChange(PostgresChangePayload change) {
    final row = change.newRecord.isNotEmpty ? change.newRecord : change.oldRecord;
    final id = row['id']?.toString() ?? row['key']?.toString() ?? '';
    final queueKey = '${change.table}:$id';
    unawaited(ServerLogService.write('realtime.received', details: {
      'table': change.table,
      'event': change.eventType,
      'id': id.isEmpty ? '-' : id,
      'updatedAt': row['updated_at'],
      'deleted': change.eventType == PostgresChangeEvent.delete ||
          row['deleted_at'] != null,
      'duringSync': _isSyncing,
      'duringStudySync': _isPushingStudyData,
      'pendingBefore': _realtimePendingChanges.length,
    }));
    if (id.isEmpty) {
      unawaited(ServerLogService.write('realtime.ignored', details: {
        'table': change.table,
        'event': change.eventType,
        'reason': 'missing-id',
      }));
      return;
    }
    _realtimePendingChanges[queueKey] = change;
    _scheduleRealtimeApply();
  }

  void _scheduleRealtimeApply({
    Duration delay = const Duration(milliseconds: 150),
  }) {
    if (_realtimeMergeDebounce?.isActive ?? false) return;
    _realtimeMergeDebounce = Timer(delay, () async {
      _realtimeMergeDebounce = null;
      if (!SupabaseConfig.isLoggedIn) return;
      if (_isSyncing || _isPushingStudyData) {
        await ServerLogService.write('realtime.deferred', details: {
          'syncing': _isSyncing,
          'studySyncing': _isPushingStudyData,
          'pending': _realtimePendingChanges.length,
        });
        _scheduleRealtimeApply(delay: const Duration(milliseconds: 250));
        return;
      }
      await _queueRealtimeChanges();
    });
  }

  // A Realtime channel created before a hot reload can retain a callback that
  // referenced this old method. Reconnect it once so subsequent events use
  // the current row-level callback instead of crashing with a method lookup.
  void _queueRealtimeMerge() {
    stopRealtimeSync();
    startRealtimeSync();
  }

  Future<void> _queueRealtimeChanges() async {
    if (!SupabaseConfig.isLoggedIn || _realtimePendingChanges.isEmpty) {
      return;
    }
    if (_isSyncing || _isPushingStudyData) {
      _scheduleRealtimeApply(delay: const Duration(milliseconds: 250));
      return;
    }
    final changes = _realtimePendingChanges.values.toList()
      ..sort((a, b) => _realtimeTableOrder(a.table).compareTo(_realtimeTableOrder(b.table)));
    _realtimePendingChanges.clear();

    _isSyncing = true;
    await ServerLogService.write('realtime.batch_start', details: {
      'events': changes.length,
      'tables': changes.map((change) => change.table).toSet().join(','),
    });
    try {
      var changed = false;
      final changesByTable = <String, List<PostgresChangePayload>>{};
      for (final change in changes) {
        changesByTable.putIfAbsent(change.table, () => []).add(change);
      }
      final tables = changesByTable.keys.toList()
        ..sort((a, b) => _realtimeTableOrder(a).compareTo(_realtimeTableOrder(b)));
      for (final table in tables) {
        changed = await _applyRealtimeChanges(changesByTable[table]!) || changed;
      }
      if (changed) {
        final notification = _describeRealtimeChanges(changes);
        _lastRealtimeDataChange = notification;
        _remoteDataChangedController.add(null);
        await ServerLogService.write('realtime.ui_notified', details: {
          'tables': notification.tables.join(','),
          'courseIds': notification.courseIds.length,
          'cardIds': notification.cardIds.length,
        });
      }
      await ServerLogService.write('realtime.batch_finish', details: {
        'events': changes.length,
        'tables': tables.join(','),
        'changed': changed,
        'pendingAfter': _realtimePendingChanges.length,
      });
    } catch (error) {
      print('REALTIME APPLY ERROR: $error');
      for (final change in changes) {
        final row = change.newRecord.isNotEmpty
            ? change.newRecord
            : change.oldRecord;
        final id = row['id']?.toString() ?? row['key']?.toString() ?? '';
        if (id.isNotEmpty) {
          _realtimePendingChanges['${change.table}:$id'] = change;
        }
      }
      await ServerLogService.write('realtime.batch_error', details: {
        'events': changes.length,
        'error': error,
        'pendingAfter': _realtimePendingChanges.length,
      });
    } finally {
      if (_cancelSyncRequested && isLearningSyncPaused) {
        for (final change in changes) {
          final row = change.newRecord.isNotEmpty
              ? change.newRecord
              : change.oldRecord;
          final id = row['id']?.toString() ?? row['key']?.toString() ?? '';
          if (id.isNotEmpty) {
            _realtimePendingChanges['${change.table}:$id'] = change;
          }
        }
        _cancelSyncRequested = false;
      }
      _isSyncing = false;
      if (_realtimePendingChanges.isNotEmpty) {
        _scheduleRealtimeApply();
      }
    }
  }

  RealtimeDataChange _describeRealtimeChanges(
    Iterable<PostgresChangePayload> changes,
  ) {
    final tables = <String>{};
    final courseIds = <int>{};
    final cardIds = <int>{};
    for (final change in changes) {
      tables.add(change.table);
      final row = change.newRecord.isNotEmpty
          ? change.newRecord
          : change.oldRecord;
      final remoteId = row['id']?.toString();
      final remoteCourseId = row['course_id']?.toString();
      final remoteCardId = row['card_id']?.toString();
      if (change.table == 'courses' && remoteId != null) {
        courseIds.add(
          _courseLocalIdByRemote[remoteId] ?? _stableLocalId(remoteId),
        );
      }
      if (change.table == 'cards' && remoteId != null) {
        cardIds.add(_cardLocalIdByRemote[remoteId] ?? _stableLocalId(remoteId));
      }
      if (remoteCourseId != null && remoteCourseId.isNotEmpty) {
        courseIds.add(
          _courseLocalIdByRemote[remoteCourseId] ??
              _stableLocalId(remoteCourseId),
        );
      }
      if (remoteCardId != null && remoteCardId.isNotEmpty) {
        cardIds.add(
          _cardLocalIdByRemote[remoteCardId] ?? _stableLocalId(remoteCardId),
        );
      }
    }
    return RealtimeDataChange(
      tables: tables,
      courseIds: courseIds,
      cardIds: cardIds,
    );
  }

  int _realtimeTableOrder(String table) => switch (table) {
        'topics' => 0,
        'courses' => 1,
        'cards' => 2,
        'card_examples' => 3,
        'review_states' => 4,
        _ => 99,
      };

  /// Realtime delivers the changed row itself. Apply only that row; do not
  /// call mergeAll(), which would re-query every synchronized table.
  Future<bool> _applyRealtimeChanges(
    List<PostgresChangePayload> changes,
  ) async {
    if (changes.isEmpty) return false;
    final table = changes.first.table;
    const supportedTables = {
      'topics',
      'courses',
      'cards',
      'card_examples',
      'review_states',
    };
    if (!supportedTables.contains(table)) {
      await ServerLogService.write('realtime.ignored', details: {
        'table': table,
        'events': changes.length,
        'reason': 'unsupported-table',
      });
      return false;
    }
    await ServerLogService.write('realtime.apply_start', details: {
      'table': table,
      'events': changes.length,
    });
    final db = await AppDatabase.instance.database;
    final rows = <Map<String, dynamic>>[];
    var changed = false;
    var deleted = 0;
    var skipped = 0;
    final replacedRemoteIds = <String>{};
    final pendingReviewCardIds = table == 'review_states'
        ? await _pendingReviewCardIds(db)
        : const <int>{};

    // Some server editors save a card edit as INSERT(new id) + soft-delete
    // (old id). Reuse the old local card ID when both rows occupy the same
    // course/position so review states and study history keep their FK target.
    if (table == 'cards') {
      final insertedChanges = changes.where(
        (change) => change.eventType == PostgresChangeEvent.insert &&
            change.newRecord['deleted_at'] == null,
      ).toList(growable: false);
      final usedInsertedRemoteIds = <String>{};
      for (final deletedChange in changes.where((change) {
        final source = change.newRecord.isNotEmpty
            ? change.newRecord
            : change.oldRecord;
        return change.eventType == PostgresChangeEvent.delete ||
            source['deleted_at'] != null;
      })) {
        final deletedSource = deletedChange.newRecord.isNotEmpty
            ? deletedChange.newRecord
            : deletedChange.oldRecord;
        final oldRemoteId = deletedSource['id']?.toString() ?? '';
        if (oldRemoteId.isEmpty) continue;
        final oldLocalId = _cardLocalIdByRemote[oldRemoteId] ??
            _stableLocalId(oldRemoteId);
        final oldLocalRows = await db.query(
          'cards',
          columns: ['id', 'courseId', 'position'],
          where: 'id = ?',
          whereArgs: [oldLocalId],
          limit: 1,
        );
        if (oldLocalRows.isEmpty) continue;
        final oldLocal = oldLocalRows.first;

        for (final insertedChange in insertedChanges) {
          final inserted = insertedChange.newRecord;
          final newRemoteId = inserted['id']?.toString() ?? '';
          if (newRemoteId.isEmpty ||
              usedInsertedRemoteIds.contains(newRemoteId)) {
            continue;
          }
          final insertedCourseId =
              _courseLocalIdByRemote[inserted['course_id']?.toString()] ??
              _stableLocalId(inserted['course_id']);
          final sameCourse = insertedCourseId ==
              _localInt(oldLocal['courseId']);
          final samePosition = _localInt(inserted['position']) ==
              _localInt(oldLocal['position']);
          if (!sameCourse || !samePosition) continue;

          _cardLocalIdByRemote.remove(oldRemoteId);
          _cardLocalIdByRemote[newRemoteId] = oldLocalId;
          _cardRemoteIdByLocal['$oldLocalId'] = newRemoteId;
          replacedRemoteIds.add(oldRemoteId);
          usedInsertedRemoteIds.add(newRemoteId);
          await ServerLogService.write('realtime.replaced', details: {
            'table': table,
            'oldRemoteId': oldRemoteId,
            'newRemoteId': newRemoteId,
            'localId': oldLocalId,
            'position': oldLocal['position'],
          });
          break;
        }
      }
    }

    for (final change in changes) {
      final source = change.newRecord.isNotEmpty
          ? change.newRecord
          : change.oldRecord;
      final remote = Map<String, dynamic>.from(source);
      final remoteId = remote['id']?.toString();
      if (remoteId == null || remoteId.isEmpty) {
        skipped++;
        continue;
      }
      if (await _shouldSkipRealtimeRow(db, table, remote)) {
        skipped++;
        continue;
      }

      if (change.eventType == PostgresChangeEvent.delete ||
          remote['deleted_at'] != null) {
        if (replacedRemoteIds.contains(remoteId)) {
          changed = true;
          continue;
        }
        final localId = switch (table) {
          'topics' => _topicLocalIdByRemote[remoteId] ?? _stableLocalId(remoteId),
          'courses' => _courseLocalIdByRemote[remoteId] ?? _stableLocalId(remoteId),
          'cards' => _cardLocalIdByRemote[remoteId] ?? _stableLocalId(remoteId),
          _ => _stableLocalId(remoteId),
        };
        if (table == 'review_states') {
          final remoteCardId = remote['card_id']?.toString();
          final localCardId = remoteCardId == null
              ? null
              : (_cardLocalIdByRemote[remoteCardId] ??
                  _stableLocalId(remoteCardId));
          if (localCardId != null) {
            if (pendingReviewCardIds.contains(localCardId)) {
              skipped++;
              await ServerLogService.write(
                'realtime.review_delete_deferred',
                details: {
                  'remoteId': remoteId,
                  'cardId': localCardId,
                  'reason': 'pending-local-review',
                },
              );
              continue;
            }
            await _deleteRemoteAppliedRow(
              db,
              table,
              where: 'cardId = ?',
              whereArgs: [localCardId],
            );
          }
        } else {
          await _deleteRemoteAppliedRow(
            db,
            table,
            where: 'id = ?',
            whereArgs: [localId],
          );
        }
        if (table == 'topics') {
          _topicLocalIdByRemote.remove(remoteId);
          if (_topicRemoteIdByLocal['$localId'] == remoteId) {
            _topicRemoteIdByLocal.remove('$localId');
          }
        } else if (table == 'courses') {
          _courseLocalIdByRemote.remove(remoteId);
          if (_courseRemoteIdByLocal['$localId'] == remoteId) {
            _courseRemoteIdByLocal.remove('$localId');
          }
        } else if (table == 'cards') {
          _cardLocalIdByRemote.remove(remoteId);
          if (_cardRemoteIdByLocal['$localId'] == remoteId) {
            _cardRemoteIdByLocal.remove('$localId');
          }
        }
        deleted++;
        changed = true;
        await ServerLogService.write('realtime.deleted', details: {
          'table': table,
          'remoteId': remoteId,
          'localId': localId,
        });
        continue;
      }

      if (table == 'topics') {
        _topicLocalIdByRemote.putIfAbsent(remoteId, () => _stableLocalId(remoteId));
      } else if (table == 'courses') {
        _courseLocalIdByRemote.putIfAbsent(remoteId, () => _stableLocalId(remoteId));
      } else if (table == 'cards') {
        _cardLocalIdByRemote.putIfAbsent(remoteId, () => _stableLocalId(remoteId));
      }
      rows.add(remote);
    }
    if (rows.isEmpty) {
      await ServerLogService.write('realtime.apply_finish', details: {
        'table': table,
        'events': changes.length,
        'rows': 0,
        'deleted': deleted,
        'replaced': replacedRemoteIds.length,
        'skipped': skipped,
        'pulled': 0,
        'changed': changed,
        'error': null,
      });
      return changed;
    }

    final previousOperation = _operation;
    _operation = _SyncOperation.merge;
    try {
      final ownerId = SupabaseConfig.currentUser!.id;
      final client = SupabaseConfig.client;
      SyncResult? result;
      switch (table) {
        case 'topics':
          result = await _syncTable(
            db: db, client: client, ownerId: ownerId, localTable: 'topics',
            remoteTable: 'topics', idColumn: 'id',
            localToRemote: _topicLocalToRemote, remoteToLocal: _topicRemoteToLocal,
            remoteRowsOverride: rows,
          );
          break;
        case 'courses':
          result = await _syncTable(
            db: db, client: client, ownerId: ownerId, localTable: 'courses',
            remoteTable: 'courses', idColumn: 'id',
            localToRemote: _courseLocalToRemote, remoteToLocal: _courseRemoteToLocal,
            remoteRowsOverride: rows,
          );
          break;
        case 'cards':
          result = await _syncTable(
            db: db, client: client, ownerId: ownerId, localTable: 'cards',
            remoteTable: 'cards', idColumn: 'id',
            localToRemote: _cardLocalToRemote, remoteToLocal: _cardRemoteToLocal,
            remoteRowsOverride: rows,
          );
          break;
        case 'card_examples':
          result = await _syncTable(
            db: db, client: client, ownerId: ownerId, localTable: 'card_examples',
            remoteTable: 'card_examples', idColumn: 'id',
            localToRemote: _cardExampleLocalToRemote,
            remoteToLocal: _cardExampleRemoteToLocal,
            remoteRowsOverride: rows,
          );
          break;
        case 'review_states':
          result = await _syncTable(
            db: db, client: client, ownerId: ownerId, localTable: 'review_states',
            remoteTable: 'review_states', idColumn: 'id',
            remoteConflictColumns: 'owner_id,card_id',
            localConflictColumns: const ['cardId'],
            localToRemote: _reviewStateLocalToRemote,
            remoteToLocal: _reviewStateRemoteToLocal,
            remoteRowsOverride: rows,
          );
          break;
      }
      await ServerLogService.write('realtime.apply_finish', details: {
        'table': table,
        'events': changes.length,
        'rows': rows.length,
        'deleted': deleted,
        'replaced': replacedRemoteIds.length,
        'skipped': skipped,
        'pushed': result?.pushed ?? 0,
        'pulled': result?.pulled ?? 0,
        'changed': true,
        'error': result?.error,
      });
      return true;
    } finally {
      _operation = previousOperation;
    }
  }

  Future<bool> _shouldSkipRealtimeRow(
    Database db,
    String table,
    Map<String, dynamic> remote,
  ) async {
    final ownerId = remote['owner_id']?.toString();
    if (ownerId != null &&
        ownerId.isNotEmpty &&
        ownerId != SupabaseConfig.currentUser?.id) {
      return true;
    }
    await _ensureLocalDeviceId(db);
    final remoteId = remote['id']?.toString() ?? '';
    if (remoteId.isEmpty) return true;
    final remoteRevision = _localInt(remote['revision']) ?? 0;
    var localRows = await db.query(
      table,
      columns: const [
        'id',
        'serverRevision',
        'lastDeviceId',
        'lastMutationId',
      ] + (table == 'review_states' ? const ['cardId'] : const []),
      where: 'remoteId = ?',
      whereArgs: [remoteId],
      limit: 1,
    );
    int? reviewCardId;
    if (localRows.isEmpty && table == 'review_states') {
      final remoteCardId = remote['card_id']?.toString() ?? '';
      if (remoteCardId.isNotEmpty) {
        reviewCardId = _cardLocalIdByRemote[remoteCardId];
        if (reviewCardId == null) {
          final cards = await db.query(
            'cards',
            columns: const ['id'],
            where: 'remoteId = ?',
            whereArgs: [remoteCardId],
            limit: 1,
          );
          if (cards.isNotEmpty) reviewCardId = _localInt(cards.first['id']);
        }
        if (reviewCardId != null) {
          localRows = await db.query(
            'review_states',
            columns: const [
              'id',
              'serverRevision',
              'lastDeviceId',
              'lastMutationId',
              'cardId',
            ],
            where: 'cardId = ?',
            whereArgs: [reviewCardId],
            limit: 1,
          );
        }
      }
    }
    if (localRows.isEmpty) return false;
    final local = localRows.first;
    reviewCardId ??= _localInt(local['cardId']);
    final localRevision = _localInt(local['serverRevision']) ?? 0;
    final mutationId = remote['last_mutation_id']?.toString() ?? '';
    final deviceId = remote['last_device_id']?.toString() ?? '';
    if (mutationId.isNotEmpty &&
        deviceId == _localDeviceId &&
        local['lastMutationId']?.toString() == mutationId) {
      await ServerLogService.write('realtime.self_echo_ignored', details: {
        'table': table,
        'id': remoteId,
        'revision': remoteRevision,
      });
      return true;
    }
    if (remoteRevision > 0 && remoteRevision <= localRevision) return true;

    final localEntityId = local['id'].toString();
    final pendingEntityId = reviewCardId?.toString() ?? localEntityId;
    final pendingWhere = table == 'review_states'
        ? "tableName = ? AND (entityId = ? OR entityId = ? OR entityId LIKE ?) "
            "AND status = 'pending'"
        : "tableName = ? AND entityId = ? AND status = 'pending'";
    final pendingArgs = table == 'review_states'
        ? <Object?>[
            table,
            localEntityId,
            pendingEntityId,
            '$pendingEntityId:%',
          ]
        : <Object?>[table, localEntityId];
    final pending = await db.query(
      'sync_outbox',
      columns: const ['mutationId'],
      where: pendingWhere,
      whereArgs: pendingArgs,
      limit: 1,
    );
    if (pending.isNotEmpty) {
      await db.update(
        'sync_outbox',
        {
          'status': 'conflict',
          'lastError': 'Remote revision $remoteRevision arrived while local mutation was pending',
          'payload': jsonEncode({'conflict_remote': remote}),
        },
        where: pendingWhere,
        whereArgs: pendingArgs,
      );
      await ServerLogService.write('realtime.conflict_deferred', details: {
        'table': table,
        'id': remoteId,
        'revision': remoteRevision,
      });
      return true;
    }
    return false;
  }

  Future<void> _deleteRemoteAppliedRow(
    Database db,
    String table, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    await db.transaction((txn) async {
      await AppDatabase.instance.suppressSyncOutbox(txn);
      try {
        await txn.delete(table, where: where, whereArgs: whereArgs);
      } finally {
        await AppDatabase.instance.resumeSyncOutbox(txn);
      }
    });
  }

  Future<SyncResult> _syncAllOnce() async {

    _isSyncing = true;
    _lastSyncError = null;
    await ServerLogService.write('sync.start', details: {
      'operation': _operation.name,
    });

    try {
      _prefetchedRemoteRows.clear();
      final ownerId = SupabaseConfig.currentUser!.id;
      final db = await AppDatabase.instance.database;
      final client = SupabaseConfig.client;

      // Apply topic repairs before IDs and foreign keys are mapped for sync.
      await AppDatabase.instance.ensureTopicSchema();

      int pushed = 0;
      int pulled = 0;
      final syncErrors = <String>[];
      final syncLogs = <String>[
        switch (_operation) {
          _SyncOperation.pullReplace => 'Chế độ: tải xuống và thay thế local',
          _SyncOperation.merge => 'Chế độ: merge cloud + local',
          _SyncOperation.livePush => 'Chế độ: cập nhật thay đổi sau đăng nhập',
        },
      ];

      await _ensureLocalDeviceId(db);
      await beginAuthenticatedSession();
      _throwIfSyncCancelled();

      if (_operation != _SyncOperation.livePush) {
        // Download every table successfully before touching local data.
        await _prefetchAccountSnapshot(client, ownerId);
        _throwIfSyncCancelled();
        if (_operation == _SyncOperation.pullReplace) {
          await _clearLocalAccountData(db);
        } else {
          await _markLocalMergeConflicts(db);
        }
      }
      // Refresh on every pass. Pull/cleanup may change local IDs while a hot
      // reload keeps this singleton alive, making cached parent IDs stale and
      // causing foreign-key failures for study sessions and SRS.
      await _prepareIdentityMaps(db, client, ownerId);
      _identityOwnerId = ownerId;

      // A live push uses a bounded window. Advancing the lower cursor only
      // after a fully successful pass prevents old sessions/results from being
      // uploaded again while preserving changes made during an active sync.
      _livePushCutoffAt = _operation == _SyncOperation.livePush
          ? DateTime.now().toIso8601String()
          : null;
      final lastSyncAt = _operation == _SyncOperation.livePush
          ? _livePushCursorAt
          : null;

      void collectError(String table, SyncResult result) {
        syncLogs.add(
          '$table: đẩy ${result.pushed}, tải ${result.pulled}'
          '${result.hasError ? ' — ${result.error}' : ''}',
        );
        if (result.hasError) syncErrors.add('$table: ${result.error}');
        unawaited(ServerLogService.write('sync.table', details: {
          'operation': _operation.name,
          'table': table,
          'pushed': result.pushed,
          'pulled': result.pulled,
          'error': result.error,
        }));
      }

      // 1. Sync topics
      final topicResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'topics',
        remoteTable: 'topics',
        idColumn: 'id',
        localToRemote: _topicLocalToRemote,
        remoteToLocal: _topicRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += topicResult.pushed;
      pulled += topicResult.pulled;
      collectError('topics', topicResult);

      // 2. Sync courses
      final courseResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'courses',
        remoteTable: 'courses',
        idColumn: 'id',
        localToRemote: _courseLocalToRemote,
        remoteToLocal: _courseRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += courseResult.pushed;
      pulled += courseResult.pulled;
      collectError('courses', courseResult);

      // 3. Sync cards
      final cardResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'cards',
        remoteTable: 'cards',
        idColumn: 'id',
        localToRemote: _cardLocalToRemote,
        remoteToLocal: _cardRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += cardResult.pushed;
      pulled += cardResult.pulled;
      collectError('cards', cardResult);

      // 4. Sync card_examples
      final exampleResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'card_examples',
        remoteTable: 'card_examples',
        idColumn: 'id',
        localToRemote: _cardExampleLocalToRemote,
        remoteToLocal: _cardExampleRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += exampleResult.pushed;
      pulled += exampleResult.pulled;
      collectError('card_examples', exampleResult);

      // 5. Sync review_states
      final reviewResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'review_states',
        remoteTable: 'review_states',
        idColumn: 'id',
        remoteConflictColumns: 'owner_id,card_id',
        localConflictColumns: const ['cardId'],
        localToRemote: _reviewStateLocalToRemote,
        remoteToLocal: _reviewStateRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += reviewResult.pushed;
      pulled += reviewResult.pulled;
      collectError('review_states', reviewResult);

      // 6. Sync study_sessions
      final sessionResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'study_sessions',
        remoteTable: 'study_sessions',
        idColumn: 'id',
        localToRemote: _studySessionLocalToRemote,
        remoteToLocal: _studySessionRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += sessionResult.pushed;
      pulled += sessionResult.pulled;
      collectError('study_sessions', sessionResult);

      // 7. Sync study_results
      final studyResultResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'study_results',
        remoteTable: 'study_results',
        idColumn: 'id',
        localToRemote: _studyResultLocalToRemote,
        remoteToLocal: _studyResultRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += studyResultResult.pushed;
      pulled += studyResultResult.pulled;
      collectError('study_results', studyResultResult);

      // 8. Sync review_sentence_questions
      final questionResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'review_sentence_questions',
        remoteTable: 'review_sentence_questions',
        idColumn: 'id',
        remoteConflictColumns:
            'owner_id,course_id,card_id,language_code,direction',
        localConflictColumns: const [
          'courseId',
          'cardId',
          'languageCode',
          'direction',
        ],
        localToRemote: _questionLocalToRemote,
        remoteToLocal: _questionRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += questionResult.pushed;
      pulled += questionResult.pulled;
      collectError('review_sentence_questions', questionResult);

      // 10. Sync app_settings
      final appSettingsResult = await _syncTable(
        db: db,
        client: client,
        ownerId: ownerId,
        localTable: 'app_settings',
        remoteTable: 'app_settings',
        idColumn: 'key',
        remoteConflictColumns: 'owner_id,key',
        localToRemote: _appSettingLocalToRemote,
        remoteToLocal: _appSettingRemoteToLocal,
        lastSyncAt: lastSyncAt,
      );
      pushed += appSettingsResult.pushed;
      pulled += appSettingsResult.pulled;
      collectError('app_settings', appSettingsResult);

      if (_operation != _SyncOperation.livePush) {
        final now = DateTime.now().toIso8601String();
        await _setLocalSetting(db, 'sync.lastSyncAt', now);
      } else if (syncErrors.isEmpty && _livePushCutoffAt != null) {
        _livePushCursorAt = _livePushCutoffAt;
        await _setLocalSetting(
          db,
          'sync.livePushCursor.v2.$ownerId',
          _livePushCutoffAt!,
        );
        await ServerLogService.write('sync.cursor', details: {
          'operation': _operation.name,
          'lastPushAt': _livePushCutoffAt,
        });
      }

      await ServerLogService.write('sync.finish', details: {
        'operation': _operation.name,
        'pushed': pushed,
        'pulled': pulled,
        'errors': syncErrors.length,
      });
      return SyncResult(
        pushed: pushed,
        pulled: pulled,
        pulledCourses: courseResult.pulled,
        pulledCards: cardResult.pulled,
        logs: syncLogs,
        error: syncErrors.isEmpty ? null : syncErrors.join(' | '),
      );
    } on _SyncCancelled {
      await ServerLogService.write('sync.cancelled', details: {
        'operation': _operation.name,
      });
      return SyncResult(
        pushed: 0,
        pulled: 0,
        error: 'ÄÃ£ dừng Ä‘ồng bộ',
      );
    } catch (e) {
      _lastSyncError = e.toString();
      await ServerLogService.write('sync.error', details: {
        'operation': _operation.name,
        'error': e,
      });
      return SyncResult(pushed: 0, pulled: 0, error: e.toString());
    } finally {
      _prefetchedRemoteRows.clear();
      _livePushCutoffAt = null;
      _isSyncing = false;
      _activeSync = null;
    }
  }

  /// Shared table worker. The active operation decides whether this pass is
  /// upload-only (session mutations) or download-only (replace/merge).
  Future<SyncResult> _syncTable({
    required Database db,
    required SupabaseClient client,
    required String ownerId,
    required String localTable,
    required String remoteTable,
    required String idColumn,
    String? remoteConflictColumns,
    List<String>? localConflictColumns,
    required Map<String, dynamic> Function(
      Map<String, Object?> localRow,
      String ownerId,
    ) localToRemote,
    required Map<String, Object?> Function(
      Map<String, dynamic> remoteRow,
    ) remoteToLocal,
    String? lastSyncAt,
    List<Map<String, dynamic>>? remoteRowsOverride,
  }) async {
    int pushed = 0;
    int pulled = 0;
    final errors = <String>[];

    try {
      _throwIfSyncCancelled();
      var remoteRows = remoteRowsOverride ?? (_operation == _SyncOperation.livePush
          ? <Map<String, dynamic>>[]
          : await _fetchAllRemoteRows(
              client: client,
              table: remoteTable,
              ownerId: ownerId,
              lastSyncAt: lastSyncAt,
            ));
      final remoteById = <String, Map<String, dynamic>>{
        for (final row in remoteRows)
          if (row[idColumn] != null) row[idColumn].toString(): row,
      };
      final remoteConflictColumnList = remoteConflictColumns
          ?.split(',')
          .map((column) => column.trim())
          .where((column) => column.isNotEmpty)
          .toList(growable: false);
      final remoteByConflict = <String, Map<String, dynamic>>{
        if (remoteConflictColumnList != null)
          for (final row in remoteRows)
            _syncConflictKey(row, remoteConflictColumnList): row,
      };

      // --- PUSH local → Supabase ---
      final Map<String, String> localTimestampColumns = {
        'topics': 'COALESCE(updatedAt, createdAt)',
        'courses': 'COALESCE(updatedAt, createdAt)',
        'cards': 'COALESCE(updatedAt, createdAt)',
        'card_examples': 'COALESCE(updatedAt, createdAt)',
        'review_states': 'COALESCE(updatedAt, createdAt)',
        'study_sessions': 'startedAt',
        'study_results': 'reviewedAt',
        'review_sentence_questions': 'COALESCE(updatedAt, createdAt)',
        'app_settings': 'updatedAt',
      };

      List<Map<String, Object?>> queriedLocalRows;
      final timeCol = localTimestampColumns[localTable];
      if (lastSyncAt != null &&
          lastSyncAt.isNotEmpty &&
          timeCol != null) {
        final parsed = DateTime.tryParse(lastSyncAt);
        if (parsed != null) {
          final safetyTime = _operation == _SyncOperation.livePush
              ? parsed.toIso8601String()
              : parsed.subtract(const Duration(minutes: 5)).toIso8601String();
          final upperTime = _operation == _SyncOperation.livePush
              ? _livePushCutoffAt
              : null;
          queriedLocalRows = await db.query(
            localTable,
            where: upperTime == null
                ? '$timeCol > ?'
                : '$timeCol > ? AND $timeCol <= ?',
            whereArgs: upperTime == null
                ? [safetyTime]
                : [safetyTime, upperTime],
          );
        } else {
          queriedLocalRows = await db.query(localTable);
        }
      } else {
        queriedLocalRows = await db.query(localTable);
      }

      var localRows = localTable == 'app_settings'
          ? queriedLocalRows
              .where((row) => !_isLocalOnlySetting(row['key']))
              .toList(growable: false)
          : queriedLocalRows;
      if (_operation == _SyncOperation.livePush) {
        localRows = await _filterPushableLocalRows(db, localTable, localRows);
        // SRS is pushed only by syncReviewStatesAfterStudy(), where each
        // local card is resolved to its actual server card ID first.
        if (localTable == 'review_states') {
          localRows = const <Map<String, Object?>>[];
        }
      } else {
        localRows = const <Map<String, Object?>>[];
      }
      final toPush = <Map<String, dynamic>>[];
      for (final row in localRows) {
        try {
          final remoteData = localToRemote(row, ownerId);
          final remoteId = remoteData[idColumn]?.toString();
          final existingRemote = (remoteId == null
                  ? null
                  : remoteById[remoteId]) ??
              (remoteConflictColumnList == null
                  ? null
                  : remoteByConflict[
                      _syncConflictKey(
                        remoteData,
                        remoteConflictColumnList,
                      )
                    ]);
          if (existingRemote != null &&
              !_localRowIsNewer(remoteData, existingRemote)) {
            continue;
          }
          toPush.add(remoteData);
        } catch (e) {
          errors.add('prepare push row ${row[idColumn]}: $e');
          print('SYNC PREPARE PUSH ERROR ($localTable row ${row[idColumn]}): $e');
        }
      }

      if (toPush.isNotEmpty) {
        const chunkSize = 200;
        for (var i = 0; i < toPush.length; i += chunkSize) {
          _throwIfSyncCancelled();
          final chunk = toPush.sublist(
            i,
            math.min(i + chunkSize, toPush.length),
          );
          try {
            await client.from(remoteTable).upsert(
              chunk,
              onConflict: remoteConflictColumns ?? idColumn,
            );
            pushed += chunk.length;
          } catch (batchError) {
            print(
              'SYNC PUSH BATCH ERROR ($localTable), retrying rows: '
              '$batchError',
            );
            // PostgREST applies a batch atomically. Retry its rows separately
            // so one stale foreign key cannot block every valid session/result.
            for (final remoteData in chunk) {
              try {
                await client.from(remoteTable).upsert(
                  [remoteData],
                  onConflict: remoteConflictColumns ?? idColumn,
                );
                pushed++;
              } catch (rowError) {
                final rowId = remoteData[idColumn]?.toString() ?? '?';
                errors.add('push row $rowId: $rowError');
                print(
                  'SYNC PUSH ROW ERROR ($localTable row $rowId): $rowError',
                );
              }
            }
          }
        }
        if (pushed > 0) {
          _prefetchedRemoteRows.remove(remoteTable);
        }
      }

      if (_operation == _SyncOperation.livePush) {
        final error = errors.isEmpty ? null : errors.join(' || ');
        return SyncResult(pushed: pushed, pulled: 0, error: error);
      }

      // --- PULL Supabase → local ---
      remoteRows = remoteRowsOverride ?? await _fetchAllRemoteRows(
        client: client,
        table: remoteTable,
        ownerId: ownerId,
        lastSyncAt: lastSyncAt,
      );

      final existingTopicIds = <int>{};
      final deletedTopicIds = <int>{};
      if (localTable == 'courses') {
        final rows = await db.query('topics', columns: ['id', 'deletedAt']);
        for (final r in rows) {
          final id = r['id'] as int?;
          if (id != null) {
            existingTopicIds.add(id);
            if (r['deletedAt'] != null) deletedTopicIds.add(id);
          }
        }
      }

      final existingCardIds = <int>{};
      final deletedCardIds = <int>{};
      if (localTable == 'review_states' ||
          localTable == 'card_examples' ||
          localTable == 'review_sentence_questions' ||
          localTable == 'study_results') {
        final rows = await db.query('cards', columns: ['id', 'deletedAt']);
        for (final r in rows) {
          final id = r['id'] as int?;
          if (id != null) {
            existingCardIds.add(id);
            if (r['deletedAt'] != null) {
              deletedCardIds.add(id);
            }
          }
        }
      }

      final existingCourseIds = <int>{};
      final deletedCourseIds = <int>{};
      if (localTable == 'cards' ||
          localTable == 'study_sessions' ||
          localTable == 'review_sentence_questions') {
        final rows = await db.query('courses', columns: ['id', 'deletedAt']);
        for (final r in rows) {
          final id = r['id'] as int?;
          if (id != null) {
            existingCourseIds.add(id);
            if (r['deletedAt'] != null) {
              deletedCourseIds.add(id);
            }
          }
        }
      }

      final existingSessionIds = <int>{};
      if (localTable == 'study_results') {
        final rows = await db.query('study_sessions', columns: ['id']);
        for (final r in rows) {
          final id = r['id'] as int?;
          if (id != null) existingSessionIds.add(id);
        }
      }

      final remoteIdsToDelete = <String>[];
      final pendingReviewCardIds = localTable == 'review_states'
          ? await _pendingReviewCardIds(db)
          : const <int>{};

      // --- Build memory cache of local rows to avoid O(N) database queries ---
      final columnsToFetch = <String>{idColumn};
      if (localConflictColumns != null) {
        columnsToFetch.addAll(localConflictColumns);
      }
      final timeColName = localTable == 'study_sessions'
          ? 'startedAt'
          : (localTable == 'study_results' ? 'reviewedAt' : 'updatedAt');
      columnsToFetch.add(timeColName);

      final allLocalList = await db.query(
        localTable,
        columns: columnsToFetch.toList(),
      );

      final localById = <String, Map<String, Object?>>{
        for (final row in allLocalList)
          if (row[idColumn] != null) row[idColumn].toString(): row,
      };

      final localByConflict = <String, Map<String, Object?>>{
        if (localConflictColumns != null && localConflictColumns.isNotEmpty)
          for (final row in allLocalList)
            _syncConflictKey(row, localConflictColumns): row,
      };

      await db.transaction((txn) async {
        await AppDatabase.instance.suppressSyncOutbox(txn);
        try {
          for (final remote in remoteRows) {
          _throwIfSyncCancelled();
          if (_operation == _SyncOperation.merge &&
              remote['deleted_at'] != null) {
            continue;
          }
          if (localTable == 'app_settings' &&
              _isLocalOnlySetting(remote['key'])) {
            continue;
          }
          try {
            final localData = remoteToLocal(remote);
            final localId = localData[idColumn];
            if (localTable == 'review_states') {
              final cardId = _localInt(localData['cardId']);
              if (cardId != null && pendingReviewCardIds.contains(cardId)) {
                // The matching local update has not reached the server yet.
                // Keep it intact; the durable outbox retry will upload it.
                continue;
              }
            }

            // Check for orphaned/deleted parent records to prevent pulling data
            // for soft-deleted/deleted cards or courses.
            if (localTable == 'courses') {
              final topicId = localData['topicId'];
              if (topicId != null &&
                  (!existingTopicIds.contains(topicId) ||
                      deletedTopicIds.contains(topicId))) {
                // Keep an active orphaned course usable instead of violating
                // SQLite's topic foreign key. It will appear as "Chủ đề khác".
                localData['topicId'] = null;
              }
            }

            if (localTable == 'cards') {
              final courseId = localData['courseId'];
              if (courseId == null ||
                  !existingCourseIds.contains(courseId) ||
                  deletedCourseIds.contains(courseId)) {
                // The server may retain active child rows after their course
                // was tombstoned. Ignore them instead of failing the snapshot.
                continue;
              }
            }

            if (localTable == 'review_states' ||
                localTable == 'card_examples' ||
                localTable == 'review_sentence_questions' ||
                localTable == 'study_results') {
              final cardId = localData['cardId'];
              if (cardId != null) {
                final isDeletedOrMissing =
                    !existingCardIds.contains(cardId) ||
                    deletedCardIds.contains(cardId);
                if (isDeletedOrMissing) {
                  await txn.delete(
                    localTable,
                    where: 'cardId = ?',
                    whereArgs: [cardId],
                  );
                  final rId = remote['id']?.toString();
                  if (rId != null) remoteIdsToDelete.add(rId);
                  continue;
                }
              }
            }

            if (localTable == 'study_sessions' ||
                localTable == 'review_sentence_questions') {
              final courseId = localData['courseId'];
              if (courseId != null) {
                final isDeletedOrMissing =
                    !existingCourseIds.contains(courseId) ||
                    deletedCourseIds.contains(courseId);
                if (isDeletedOrMissing) {
                  await txn.delete(
                    localTable,
                    where: 'courseId = ?',
                    whereArgs: [courseId],
                  );
                  final rId = remote['id']?.toString();
                  if (rId != null) remoteIdsToDelete.add(rId);
                  continue;
                }
              }
            }

            if (localTable == 'study_results') {
              final sessionId = localData['sessionId'];
              if (sessionId != null) {
                if (!existingSessionIds.contains(sessionId)) {
                  await txn.delete(
                    'study_results',
                    where: 'sessionId = ?',
                    whereArgs: [sessionId],
                  );
                  final rId = remote['id']?.toString();
                  if (rId != null) remoteIdsToDelete.add(rId);
                  continue;
                }
              }
            }

            // Find existing local row using memory maps instead of txn.query
            Map<String, Object?>? existingRow;
            final localIdStr = localId?.toString();
            if (localIdStr != null) {
              existingRow = localById[localIdStr];
            }
            if (existingRow == null &&
                localConflictColumns != null &&
                localConflictColumns.isNotEmpty) {
              existingRow = localByConflict[_syncConflictKey(localData, localConflictColumns)];
            }

            if (existingRow == null) {
              // A tombstone only matters when this device still has the row it
              // deletes. Do not import historical deleted rows as new local
              // data on every login.
              if (remote.containsKey('deleted_at') &&
                  remote['deleted_at'] != null) {
                continue;
              }
              await txn.insert(
                localTable,
                localData,
                conflictAlgorithm: ConflictAlgorithm.abort,
              );
              // Update memory cache
              if (localIdStr != null) {
                localById[localIdStr] = localData;
              }
              if (localConflictColumns != null && localConflictColumns.isNotEmpty) {
                localByConflict[_syncConflictKey(localData, localConflictColumns)] = localData;
              }
              pulled++;
            } else {
              // Compare updatedAt: remote wins if newer
              final localUpdated = existingRow[timeColName]?.toString() ?? '';
              final remoteUpdated = remote['updated_at']?.toString() ?? '';
              if (_isRemoteNewer(remoteUpdated, localUpdated)) {
                // When the natural key matches but IDs differ between devices,
                // preserve the existing SQLite ID. Replacing it would create a
                // new remote UUID on the next push and repeat the conflict.
                final mergedData = Map<String, Object?>.from(localData)
                  ..[idColumn] = existingRow[idColumn];
                await txn.update(
                  localTable,
                  mergedData,
                  where: '$idColumn = ?',
                  whereArgs: [existingRow[idColumn]],
                );
                // Update memory cache
                if (localIdStr != null) {
                  localById[localIdStr] = mergedData;
                }
                if (localConflictColumns != null && localConflictColumns.isNotEmpty) {
                  localByConflict[_syncConflictKey(mergedData, localConflictColumns)] = mergedData;
                }
                pulled++;
              }
            }
          } catch (e) {
            errors.add('pull row ${remote['id'] ?? remote['key']}: $e');
            print('SYNC PULL ERROR ($localTable): $e');
          }
          }
        } finally {
          await AppDatabase.instance.resumeSyncOutbox(txn);
        }
      });
    } catch (e) {
      errors.add('table: $e');
      print('SYNC TABLE ERROR ($localTable): $e');
    }

    final error = errors.isEmpty
        ? null
        : '${errors.length} lỗi; ${errors.take(3).join(' || ')}';
    print(
      'SYNC TABLE RESULT ($localTable): pushed=$pushed, '
      'pulled=$pulled, errors=${errors.length}',
    );
    return SyncResult(pushed: pushed, pulled: pulled, error: error);
  }

  // ========== Mappers: local (camelCase) ↔ remote (snake_case) ==========

  Map<String, dynamic> _topicLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    final localTopicId = _localInt(row['id']);
    final savedRemoteId = row['remoteId']?.toString() ?? '';
    final remoteTopicId = savedRemoteId.isNotEmpty
        ? savedRemoteId
        : _remoteIdFor(_topicRemoteIdByLocal, localTopicId, 'topic');
    if (localTopicId != null) {
      _topicLocalIdByRemote.putIfAbsent(
        remoteTopicId,
        () => localTopicId,
      );
    }
    return {
      'id': remoteTopicId,
      'owner_id': ownerId,
      'name': row['name'],
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'] ?? row['createdAt'],
      'deleted_at': row['deletedAt'],
    };
  }

  Map<String, Object?> _topicRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _topicLocalIdByRemote[row['id']?.toString()] ??
          _stableLocalId(row['id']),
      'name': row['name'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'deletedAt': row['deleted_at'],
      'remoteId': row['id'],
      'serverRevision': row['revision'] ?? 0,
      'lastDeviceId': row['last_device_id'],
      'lastMutationId': row['last_mutation_id'],
    };
  }

  Map<String, dynamic> _courseLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    final localCourseId = _localInt(row['id']);
    final savedRemoteId = row['remoteId']?.toString() ?? '';
    final remoteCourseId = savedRemoteId.isNotEmpty
        ? savedRemoteId
        : _remoteIdFor(_courseRemoteIdByLocal, localCourseId, 'course');
    if (localCourseId != null) {
      _courseLocalIdByRemote.putIfAbsent(
        remoteCourseId,
        () => localCourseId,
      );
    }
    return {
      'id': remoteCourseId,
      'owner_id': ownerId,
      'topic_id': row['topicId'] != null
          ? _remoteIdFor(_topicRemoteIdByLocal, row['topicId'], 'topic')
          : null,
      'title': row['title'],
      'description': row['description'],
      'language_id': row['languageId'],
      'language_name': row['languageName'],
      'language_code': row['languageCode'],
      'card_count': row['cardCount'] ?? 0,
      'is_favorite': (row['isFavorite'] == 1),
      'is_archived': (row['isArchived'] == 1),
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'] ?? row['createdAt'],
      'deleted_at': row['deletedAt'],
    };
  }

  Map<String, Object?> _courseRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _courseLocalIdByRemote[row['id']?.toString()] ??
          _stableLocalId(row['id']),
      'topicId': row['topic_id'] != null
          ? (_topicLocalIdByRemote[row['topic_id'].toString()] ??
                _stableLocalId(row['topic_id']))
          : null,
      'title': row['title'],
      'description': row['description'],
      'languageId': row['language_id'],
      'languageName': row['language_name'],
      'languageCode': row['language_code'],
      'cardCount': row['card_count'] ?? 0,
      'isFavorite': row['is_favorite'] == true ? 1 : 0,
      'isArchived': row['is_archived'] == true ? 1 : 0,
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'deletedAt': row['deleted_at'],
      'syncOrigin': 'remote',
      'hasLocalNameConflict': 0,
      'remoteId': row['id'],
      'serverRevision': row['revision'] ?? 0,
      'lastDeviceId': row['last_device_id'],
      'lastMutationId': row['last_mutation_id'],
    };
  }

  Map<String, dynamic> _cardLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    final localCourseId = row['courseId'];
    final remoteCourseId = _remoteIdFor(
      _courseRemoteIdByLocal,
      localCourseId,
      'course',
    );
    final localCardId = _localInt(row['id']);
    final savedRemoteId = row['remoteId']?.toString() ?? '';
    final remoteCardId = savedRemoteId.isNotEmpty
        ? savedRemoteId
        : _remoteIdFor(_cardRemoteIdByLocal, localCardId, 'card');
    if (localCardId != null) {
      _cardLocalIdByRemote.putIfAbsent(remoteCardId, () => localCardId);
    }
    return {
      'id': remoteCardId,
      'owner_id': ownerId,
      'course_id': remoteCourseId,
      'term': row['term'],
      'definition': row['definition'],
      'pronunciation': row['pronunciation'],
      'raw_text': row['rawText'],
      'input_format': row['inputFormat'],
      'extra_meaning': row['extraMeaning'],
      'note': row['note'],
      'image_path': row['imagePath'],
      'audio_path': row['audioPath'],
      'position': row['position'] ?? 0,
      'is_favorite': (row['isFavorite'] == 1),
      'is_hidden': (row['isHidden'] == 1),
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'] ?? row['createdAt'],
      'deleted_at': row['deletedAt'],
    };
  }

  Map<String, Object?> _cardRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _cardLocalIdByRemote[row['id']?.toString()] ??
          _stableLocalId(row['id']),
      'courseId': _courseLocalIdByRemote[row['course_id']?.toString()] ??
          _stableLocalId(row['course_id']),
      'term': row['term'],
      'definition': row['definition'],
      'pronunciation': row['pronunciation'],
      'rawText': row['raw_text'],
      'inputFormat': row['input_format'],
      'extraMeaning': row['extra_meaning'],
      'note': row['note'],
      'imagePath': row['image_path'],
      'audioPath': row['audio_path'],
      'position': row['position'] ?? 0,
      'isFavorite': row['is_favorite'] == true ? 1 : 0,
      'isHidden': row['is_hidden'] == true ? 1 : 0,
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'deletedAt': row['deleted_at'],
      'remoteId': row['id'],
      'serverRevision': row['revision'] ?? 0,
      'lastDeviceId': row['last_device_id'],
      'lastMutationId': row['last_mutation_id'],
    };
  }

  Map<String, dynamic> _cardExampleLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'id': row['remoteId']?.toString().isNotEmpty == true
          ? row['remoteId']
          : _uuidFromLocalId(row['id'], 'card_example'),
      'owner_id': ownerId,
      'card_id': _remoteIdFor(_cardRemoteIdByLocal, row['cardId'], 'card'),
      'example_text': row['exampleText'],
      'pronunciation': row['pronunciation'],
      'meaning': row['meaning'],
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'] ?? row['createdAt'],
      'deleted_at': row['deletedAt'],
    };
  }

  Map<String, Object?> _cardExampleRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _stableLocalId(row['id']),
      'cardId': _cardLocalIdByRemote[row['card_id']?.toString()] ??
          _stableLocalId(row['card_id']),
      'exampleText': row['example_text'],
      'pronunciation': row['pronunciation'],
      'meaning': row['meaning'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'deletedAt': row['deleted_at'],
      'remoteId': row['id'],
      'serverRevision': row['revision'] ?? 0,
      'lastDeviceId': row['last_device_id'],
      'lastMutationId': row['last_mutation_id'],
    };
  }

  Map<String, dynamic> _reviewStateLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'id': row['remoteId']?.toString().isNotEmpty == true
          ? row['remoteId']
          : _uuidFromLocalId(row['id'], 'review_state'),
      'owner_id': ownerId,
      'card_id': _remoteIdFor(_cardRemoteIdByLocal, row['cardId'], 'card'),
      'level': row['level'] ?? 0,
      'ease_factor': row['easeFactor'] ?? 2.5,
      'interval_days': row['intervalDays'] ?? 0,
      'repetition_count': row['repetitionCount'] ?? 0,
      'correct_count': row['correctCount'] ?? 0,
      'wrong_count': row['wrongCount'] ?? 0,
      'last_reviewed_at': _localTimestampToRemoteIso(row['lastReviewedAt']),
      'next_review_at': _localTimestampToRemoteIso(row['nextReviewAt']),
      'created_at': _localTimestampToRemoteIso(row['createdAt']),
      'updated_at': _localTimestampToRemoteIso(
        row['updatedAt'] ?? row['createdAt'],
      ),
      'deleted_at': _localTimestampToRemoteIso(row['deletedAt']),
    };
  }

  Map<String, Object?> _reviewStateRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _stableLocalId(row['id']),
      'cardId': _cardLocalIdByRemote[row['card_id']?.toString()] ??
          _stableLocalId(row['card_id']),
      'level': row['level'] ?? 0,
      'easeFactor': row['ease_factor'] ?? 2.5,
      'intervalDays': row['interval_days'] ?? 0,
      'repetitionCount': row['repetition_count'] ?? 0,
      'correctCount': row['correct_count'] ?? 0,
      'wrongCount': row['wrong_count'] ?? 0,
      'lastReviewedAt': _remoteTimestampToLocalIso(row['last_reviewed_at']),
      'nextReviewAt': _remoteTimestampToLocalIso(row['next_review_at']),
      'createdAt': _remoteTimestampToLocalIso(row['created_at']),
      'updatedAt': _remoteTimestampToLocalIso(row['updated_at']),
      'deletedAt': _remoteTimestampToLocalIso(row['deleted_at']),
      'remoteId': row['id'],
      'serverRevision': row['revision'] ?? 0,
      'lastDeviceId': row['last_device_id'],
      'lastMutationId': row['last_mutation_id'],
    };
  }

  Map<String, dynamic> _studySessionLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'id': _uuidFromLocalId(row['id'], 'study_session'),
      'owner_id': ownerId,
      'course_id': _remoteIdFor(
        _courseRemoteIdByLocal,
        row['courseId'],
        'course',
      ),
      'mode': row['mode'],
      'total_cards': row['totalCards'] ?? 0,
      'correct_count': row['correctCount'] ?? 0,
      'wrong_count': row['wrongCount'] ?? 0,
      'started_at': row['startedAt'],
      'ended_at': row['endedAt'],
      'updated_at': row['endedAt'] ?? row['startedAt'],
    };
  }

  Map<String, Object?> _studySessionRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _stableLocalId(row['id']),
      'courseId': _courseLocalIdByRemote[row['course_id']?.toString()] ??
          _stableLocalId(row['course_id']),
      'mode': row['mode'],
      'totalCards': row['total_cards'] ?? 0,
      'correctCount': row['correct_count'] ?? 0,
      'wrongCount': row['wrong_count'] ?? 0,
      'startedAt': row['started_at'],
      'endedAt': row['ended_at'],
    };
  }

  Map<String, dynamic> _studyResultLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'id': _uuidFromLocalId(row['id'], 'study_result'),
      'owner_id': ownerId,
      'session_id': _uuidFromLocalId(row['sessionId'], 'study_session'),
      'card_id': _remoteIdFor(_cardRemoteIdByLocal, row['cardId'], 'card'),
      'answer_text': row['answerText'],
      'is_correct': (row['isCorrect'] == 1),
      'response_time_ms': row['responseTimeMs'],
      'reviewed_at': row['reviewedAt'],
      'updated_at': row['reviewedAt'],
    };
  }

  Map<String, Object?> _studyResultRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _stableLocalId(row['id']),
      'sessionId': _stableLocalId(row['session_id']),
      'cardId': _cardLocalIdByRemote[row['card_id']?.toString()] ??
          _stableLocalId(row['card_id']),
      'answerText': row['answer_text'],
      'isCorrect': row['is_correct'] == true ? 1 : 0,
      'responseTimeMs': row['response_time_ms'],
      'reviewedAt': row['reviewed_at'],
    };
  }

  Map<String, dynamic> _questionLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'id': _uuidFromLocalId(row['id'], 'question'),
      'owner_id': ownerId,
      'course_id': _remoteIdFor(
        _courseRemoteIdByLocal,
        row['courseId'],
        'course',
      ),
      'card_id': _remoteIdFor(_cardRemoteIdByLocal, row['cardId'], 'card'),
      'language_code': row['languageCode'],
      'direction': row['direction'],
      'source_term': row['sourceTerm'],
      'source_definition': row['sourceDefinition'],
      'question': row['question'],
      'answer': row['answer'],
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'] ?? row['createdAt'],
    };
  }

  Map<String, Object?> _questionRemoteToLocal(Map<String, dynamic> row) {
    return {
      'id': _stableLocalId(row['id']),
      'courseId': _courseLocalIdByRemote[row['course_id']?.toString()] ??
          _stableLocalId(row['course_id']),
      'cardId': _cardLocalIdByRemote[row['card_id']?.toString()] ??
          _stableLocalId(row['card_id']),
      'languageCode': row['language_code'],
      'direction': row['direction'],
      'sourceTerm': row['source_term'],
      'sourceDefinition': row['source_definition'],
      'question': row['question'],
      'answer': row['answer'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    };
  }

  Map<String, dynamic> _appSettingLocalToRemote(
    Map<String, Object?> row,
    String ownerId,
  ) {
    return {
      'key': row['key'],
      'owner_id': ownerId,
      'value': row['value'],
      'updated_at': row['updatedAt'] ?? DateTime.now().toIso8601String(),
    };
  }

  Map<String, Object?> _appSettingRemoteToLocal(Map<String, dynamic> row) {
    return {
      'key': row['key'],
      'value': row['value'],
      'updatedAt': row['updated_at'],
    };
  }

  // ========== Helpers ==========

  static const _snapshotTables = <String>[
    'topics',
    'courses',
    'cards',
    'card_examples',
    'review_states',
    'study_sessions',
    'study_results',
    'review_sentence_questions',
    'app_settings',
  ];

  Future<void> _prefetchAccountSnapshot(
    SupabaseClient client,
    String ownerId,
  ) async {
    for (final table in _snapshotTables) {
      try {
        await _fetchAllRemoteRows(
          client: client,
          table: table,
          ownerId: ownerId,
        );
      } catch (error) {
        throw StateError('Không tải được bảng $table: $error');
      }
    }
  }

  Future<void> _clearLocalAccountData(Database db) async {
    const deletionOrder = <String>[
      'study_results',
      'review_sentence_questions',
      'review_states',
      'study_sessions',
      'card_examples',
      'course_tags',
      'import_exports',
      'cards',
      'courses',
      'topics',
    ];
    await db.transaction((txn) async {
      for (final table in deletionOrder) {
        await txn.delete(table);
      }
      final settings = await txn.query('app_settings', columns: ['key']);
      for (final row in settings) {
        final key = row['key']?.toString() ?? '';
        if (!_isLocalOnlySetting(key)) {
          await txn.delete('app_settings', where: 'key = ?', whereArgs: [key]);
        }
      }
    });
  }

  Future<void> _markLocalMergeConflicts(Database db) async {
    final remoteTitles = (_prefetchedRemoteRows['courses'] ?? const [])
        .where((row) => row['deleted_at'] == null)
        .map((row) => _normalizeIdentity(row['title']))
        .where((title) => title.isNotEmpty)
        .toSet();
    final localRows = await db.query(
      'courses',
      columns: ['id', 'title', 'syncOrigin'],
      where: 'deletedAt IS NULL',
    );
    await db.transaction((txn) async {
      for (final row in localRows) {
        final isCloud = row['syncOrigin']?.toString() == 'remote';
        final conflict = !isCloud &&
            remoteTitles.contains(_normalizeIdentity(row['title']));
        await txn.update(
          'courses',
          {
            'syncOrigin': isCloud ? 'remote' : 'local',
            'hasLocalNameConflict': conflict ? 1 : 0,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
  }

  Future<List<Map<String, Object?>>> _filterPushableLocalRows(
    Database db,
    String localTable,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty || localTable == 'topics' || localTable == 'app_settings') {
      return rows;
    }
    var eligibleRows = rows;
    if (localTable == 'study_sessions') {
      final sessionsWithResults = (await db.query(
        'study_results',
        distinct: true,
        columns: ['sessionId'],
      ))
          .map((row) => _localInt(row['sessionId']))
          .whereType<int>()
          .toSet();
      eligibleRows = rows.where((row) {
        final correct = _localInt(row['correctCount']) ?? 0;
        final wrong = _localInt(row['wrongCount']) ?? 0;
        return correct + wrong > 0 ||
            sessionsWithResults.contains(_localInt(row['id']));
      }).toList(growable: false);
    }
    if (eligibleRows.isEmpty) return eligibleRows;

    final conflictCourses = (await db.query(
      'courses',
      columns: ['id'],
      where: 'COALESCE(hasLocalNameConflict, 0) = 1',
    ))
        .map((row) => row['id'] as int?)
        .whereType<int>()
        .toSet();
    if (conflictCourses.isEmpty) return eligibleRows;

    final placeholders = List.filled(conflictCourses.length, '?').join(',');
    final conflictCards = (await db.query(
      'cards',
      columns: ['id'],
      where: 'courseId IN ($placeholders)',
      whereArgs: conflictCourses.toList(),
    ))
        .map((row) => row['id'] as int?)
        .whereType<int>()
        .toSet();
    final conflictSessions = (await db.query(
      'study_sessions',
      columns: ['id'],
      where: 'courseId IN ($placeholders)',
      whereArgs: conflictCourses.toList(),
    ))
        .map((row) => row['id'] as int?)
        .whereType<int>()
        .toSet();

    bool pushable(Map<String, Object?> row) {
      switch (localTable) {
        case 'courses':
          return !conflictCourses.contains(row['id']);
        case 'cards':
        case 'study_sessions':
          return !conflictCourses.contains(row['courseId']);
        case 'card_examples':
        case 'review_states':
          return !conflictCards.contains(row['cardId']);
        case 'study_results':
          return !conflictCards.contains(row['cardId']) &&
              !conflictSessions.contains(row['sessionId']);
        case 'review_sentence_questions':
          return !conflictCourses.contains(row['courseId']) &&
              !conflictCards.contains(row['cardId']);
        default:
          return true;
      }
    }

    return eligibleRows.where(pushable).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchAllRemoteRows({
    required SupabaseClient client,
    required String table,
    required String ownerId,
    String? lastSyncAt,
  }) async {
    final useIncremental = lastSyncAt != null &&
        lastSyncAt.isNotEmpty &&
        table != 'topics' &&
        table != 'courses' &&
        table != 'cards';

    final cacheKey = useIncremental ? '$table:$lastSyncAt' : table;
    if (_prefetchedRemoteRows.containsKey(cacheKey)) {
      return _prefetchedRemoteRows[cacheKey]!;
    }
    const pageSize = 500;
    final rows = <Map<String, dynamic>>[];
    var offset = 0;

    String? filterTimestamp;
    if (useIncremental) {
      final parsed = DateTime.tryParse(lastSyncAt);
      if (parsed != null) {
        filterTimestamp = parsed
            .subtract(const Duration(minutes: 5))
            .toUtc()
            .toIso8601String();
      }
    }

    while (true) {
      _throwIfSyncCancelled();
      dynamic query = client.from(table).select().eq('owner_id', ownerId);
      if (filterTimestamp != null) {
        query = query.gt('updated_at', filterTimestamp);
      }
      final response = await query
          .order(table == 'app_settings' ? 'key' : 'id')
          .range(offset, offset + pageSize - 1);
      final page = List<Map<String, dynamic>>.from(response);
      rows.addAll(page);
      if (page.length < pageSize) break;
      offset += pageSize;
    }

    _prefetchedRemoteRows[cacheKey] = rows;
    return rows;
  }

  Future<void> _ensureLocalDeviceId(Database db) async {
    const key = 'sync.localDeviceId';
    final existing = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    final saved = existing.isEmpty
        ? ''
        : existing.first['value']?.toString().trim() ?? '';
    if (saved.isNotEmpty) {
      _localDeviceId = saved;
      return;
    }

    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int length) => bytes
        .skip(start)
        .take(length)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    _localDeviceId = '${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-'
        '${hex(8, 2)}-${hex(10, 6)}';
    await db.insert(
      'app_settings',
      {
        'key': key,
        'value': _localDeviceId,
        'updatedAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  bool _isLocalOnlySetting(Object? keyValue) {
    final key = keyValue?.toString() ?? '';
    return key == 'sync.localDeviceId' ||
        key == 'sync.localBoundOwnerId' ||
        key == 'sync.lastSyncAt' ||
        key == 'gemini.apiKey' ||
        key.startsWith('sync.sessionStartedAt.') ||
        key.startsWith('sync.livePushCursor.') ||
        key.startsWith('sync.deltaCursor.') ||
        key.startsWith('sync.migration.') ||
        key.startsWith('sync.offlineDeleteRecovery');
  }

  String _syncConflictKey(
    Map<String, Object?> row,
    List<String> columns,
  ) {
    return columns.map((column) {
      final value = row[column]?.toString() ?? '';
      return '${value.length}:$value';
    }).join('|');
  }

  Future<void> _prepareLocalOwner(Database db, String ownerId) async {
    const key = 'sync.localBoundOwnerId';
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    final previousOwner =
        rows.isEmpty ? '' : rows.first['value']?.toString() ?? '';
    if (previousOwner == ownerId) return;

    if (previousOwner.isNotEmpty) {
      final tableRows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = tableRows
          .map((row) => row['name']?.toString())
          .whereType<String>()
          .toSet();
      const deletionOrder = [
        'study_results',
        'review_sentence_questions',
        'review_states',
        'study_sessions',
        'card_examples',
        'course_tags',
        'import_exports',
        'cards',
        'courses',
        'topics',
      ];
      await db.transaction((txn) async {
        for (final table in deletionOrder) {
          if (tables.contains(table)) await txn.delete(table);
        }
        final settingRows = await txn.query('app_settings', columns: ['key']);
        for (final setting in settingRows) {
          final settingKey = setting['key']?.toString() ?? '';
          if (!_isLocalOnlySetting(settingKey) || settingKey == 'sync.lastSyncAt') {
            await txn.delete(
              'app_settings',
              where: 'key = ?',
              whereArgs: [settingKey],
            );
          }
        }
      });
    }

    await _setLocalSetting(db, key, ownerId);
  }

  Future<void> _cleanupCrossAccountTombstones(
    Database db,
    SupabaseClient client,
    String ownerId,
  ) async {
    final markerKey = 'sync.migration.crossAccountCleanup.$ownerId';
    final marker = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [markerKey],
      limit: 1,
    );
    if (marker.isNotEmpty) return;

    try {
      // These historical tombstones were copied while the same SQLite file
      // was reused by another account. Remove children before parents.
      await client
          .from('cards')
          .delete()
          .eq('owner_id', ownerId)
          .filter('deleted_at', 'not.is', null);
      await client
          .from('courses')
          .delete()
          .eq('owner_id', ownerId)
          .filter('deleted_at', 'not.is', null);
      await client
          .from('topics')
          .delete()
          .eq('owner_id', ownerId)
          .filter('deleted_at', 'not.is', null);

      await db.delete('cards', where: 'deletedAt IS NOT NULL');
      await db.delete('courses', where: 'deletedAt IS NOT NULL');
      await db.delete('topics', where: 'deletedAt IS NOT NULL');
      await _setLocalSetting(db, markerKey, 'done');
    } catch (error) {
      print('SYNC CLEANUP cross-account tombstones ERROR: $error');
    }
  }

  Future<void> _removeRemoteBundledImportMetadata(
    SupabaseClient client,
    String ownerId,
  ) async {
    try {
      await client
          .from('import_exports')
          .delete()
          .eq('owner_id', ownerId)
          .or(
            'file_path.like.assets/TOEIC/%,file_path.like.assets/TOCFL/%',
          );
    } catch (error) {
      // Metadata cleanup must not make the learning-data sync fail.
      print('SYNC CLEANUP import_exports ERROR: $error');
    }
  }

  Future<void> _removeBundledVocabulary(
    Database db,
    SupabaseClient client,
    String ownerId,
  ) async {
    const bundledDescriptionFilter =
        'description.like.%assets/TOEIC/%,description.like.%assets/TOCFL/%';

    try {
      // Cards and their dependent learning rows are removed by the remote
      // course foreign-key cascade.
      await client
          .from('courses')
          .delete()
          .eq('owner_id', ownerId)
          .or(bundledDescriptionFilter);

      final activeCourses = await client
          .from('courses')
          .select('topic_id')
          .eq('owner_id', ownerId)
          .filter('deleted_at', 'is', null);
      final usedTopicIds = List<Map<String, dynamic>>.from(activeCourses)
          .map((row) => row['topic_id']?.toString())
          .whereType<String>()
          .toSet();
      final remoteTopics = await client
          .from('topics')
          .select('id,name,deleted_at')
          .eq('owner_id', ownerId);
      const bundledTopicNames = {
        'chủ đề khác',
        'toeic',
        'tiếng trung b1',
      };
      for (final topic in List<Map<String, dynamic>>.from(remoteTopics)) {
        final topicId = topic['id']?.toString();
        final name = _normalizeIdentity(topic['name']);
        if (topicId != null &&
            !usedTopicIds.contains(topicId) &&
            bundledTopicNames.contains(name)) {
          await client
              .from('topics')
              .delete()
              .eq('owner_id', ownerId)
              .eq('id', topicId);
        }
      }
    } catch (error) {
      print('SYNC CLEANUP bundled remote data ERROR: $error');
    }

    // Older app versions stored bundled assets as local tombstones. They are
    // not user data and must not be pushed back on the next sync.
    await db.transaction((txn) async {
      await txn.rawDelete(
        '''
        DELETE FROM cards
        WHERE courseId IN (
          SELECT id FROM courses
          WHERE description LIKE ? OR description LIKE ?
        )
        ''',
        ['%assets/TOEIC/%', '%assets/TOCFL/%'],
      );
      await txn.rawDelete(
        '''
        DELETE FROM courses
        WHERE description LIKE ? OR description LIKE ?
        ''',
        ['%assets/TOEIC/%', '%assets/TOCFL/%'],
      );
      await txn.rawDelete(
        '''
        DELETE FROM topics
        WHERE lower(trim(name)) IN (?, ?, ?)
          AND NOT EXISTS (
            SELECT 1 FROM courses c WHERE c.topicId = topics.id
          )
        ''',
        ['chủ đề khác', 'toeic', 'tiếng trung b1'],
      );
    });
  }

  Future<void> _prepareIdentityMaps(
    Database db,
    SupabaseClient client,
    String ownerId,
  ) async {
    _topicRemoteIdByLocal.clear();
    _courseRemoteIdByLocal.clear();
    _cardRemoteIdByLocal.clear();
    _topicLocalIdByRemote.clear();
    _courseLocalIdByRemote.clear();
    _cardLocalIdByRemote.clear();

    final remoteTopics = await _fetchAllRemoteRows(
      client: client,
      table: 'topics',
      ownerId: ownerId,
    );
    final remoteCourses = await _fetchAllRemoteRows(
      client: client,
      table: 'courses',
      ownerId: ownerId,
    );
    final remoteCards = await _fetchAllRemoteRows(
      client: client,
      table: 'cards',
      ownerId: ownerId,
    );

    final activeTopicByName = <String, Map<String, dynamic>>{};
    final deletedTopicByName = <String, Map<String, dynamic>>{};
    final topicByPulledLocalId = <String, Map<String, dynamic>>{};
    for (final remote in remoteTopics) {
      topicByPulledLocalId['${_stableLocalId(remote['id'])}'] = remote;
      final identity = _normalizeIdentity(remote['name']);
      if (remote['deleted_at'] == null) {
        activeTopicByName[identity] = remote;
      } else {
        deletedTopicByName[identity] = remote;
      }
    }
    final localTopics = await db.query('topics', orderBy: 'id ASC');
    for (final local in localTopics) {
      final localId = _localInt(local['id']);
      if (localId == null) continue;
      final identity = _normalizeIdentity(local['name']);
      var remote = topicByPulledLocalId['$localId'] ??
          (local['deletedAt'] == null
              ? activeTopicByName[identity] ?? deletedTopicByName[identity]
              : deletedTopicByName[identity] ?? activeTopicByName[identity]);
      final remoteId = remote?['id']?.toString() ??
          _uuidFromLocalId(localId, 'topic');
      _topicRemoteIdByLocal['$localId'] = remoteId;
      _topicLocalIdByRemote.putIfAbsent(remoteId, () => localId);
    }
    final usedTopicLocalIds = localTopics
        .map((row) => _localInt(row['id']))
        .whereType<int>()
        .toSet();
    for (final remote in remoteTopics) {
      final remoteId = remote['id']?.toString();
      if (remoteId == null || _topicLocalIdByRemote.containsKey(remoteId)) {
        continue;
      }
      final localId = _availableLocalId(remoteId, usedTopicLocalIds);
      _topicLocalIdByRemote[remoteId] = localId;
      usedTopicLocalIds.add(localId);
    }

    final activeCourseByTitle = <String, Map<String, dynamic>>{};
    final deletedCourseByTitle = <String, Map<String, dynamic>>{};
    final courseByPulledLocalId = <String, Map<String, dynamic>>{};
    for (final remote in remoteCourses) {
      courseByPulledLocalId['${_stableLocalId(remote['id'])}'] = remote;
      final identity = _normalizeIdentity(remote['title']);
      if (remote['deleted_at'] == null) {
        activeCourseByTitle[identity] = remote;
      } else {
        deletedCourseByTitle[identity] = remote;
      }
    }
    final localCourses = await db.query('courses', orderBy: 'id ASC');
    for (final local in localCourses) {
      final localId = _localInt(local['id']);
      if (localId == null) continue;
      final identity = _normalizeIdentity(local['title']);
      final preserveLocalCopy =
          (local['hasLocalNameConflict'] as int? ?? 0) == 1 ||
              (_operation == _SyncOperation.merge &&
                  local['syncOrigin']?.toString() != 'remote');
      var remote = preserveLocalCopy
          ? null
          : courseByPulledLocalId['$localId'] ??
              (local['deletedAt'] == null
                  ? activeCourseByTitle[identity] ??
                      deletedCourseByTitle[identity]
                  : deletedCourseByTitle[identity] ??
                      activeCourseByTitle[identity]);
      final remoteId = remote?['id']?.toString() ??
          _uuidFromLocalId(localId, 'course');
      _courseRemoteIdByLocal['$localId'] = remoteId;
      _courseLocalIdByRemote.putIfAbsent(remoteId, () => localId);
    }
    final usedCourseLocalIds = localCourses
        .map((row) => _localInt(row['id']))
        .whereType<int>()
        .toSet();
    for (final remote in remoteCourses) {
      final remoteId = remote['id']?.toString();
      if (remoteId == null || _courseLocalIdByRemote.containsKey(remoteId)) {
        continue;
      }
      final localId = _availableLocalId(remoteId, usedCourseLocalIds);
      _courseLocalIdByRemote[remoteId] = localId;
      usedCourseLocalIds.add(localId);
    }

    final activeCardByContent = <String, Map<String, dynamic>>{};
    final deletedCardByContent = <String, Map<String, dynamic>>{};
    final cardByPulledLocalId = <String, Map<String, dynamic>>{};
    for (final remote in remoteCards) {
      cardByPulledLocalId['${_stableLocalId(remote['id'])}'] = remote;
      final identity = _remoteCardIdentity(remote);
      if (remote['deleted_at'] == null) {
        activeCardByContent[identity] = remote;
      } else {
        deletedCardByContent[identity] = remote;
      }
    }
    final localCards = await db.query('cards', orderBy: 'id ASC');
    for (final local in localCards) {
      final localId = _localInt(local['id']);
      if (localId == null) continue;
      final remoteCourseId = _remoteIdFor(
        _courseRemoteIdByLocal,
        local['courseId'],
        'course',
      );
      final identity = _cardIdentity(
        remoteCourseId,
        local['position'],
        local['term'],
        local['definition'],
      );
      var remote = cardByPulledLocalId['$localId'] ??
          (local['deletedAt'] == null
              ? activeCardByContent[identity] ?? deletedCardByContent[identity]
              : deletedCardByContent[identity] ?? activeCardByContent[identity]);
      final remoteId = remote?['id']?.toString() ??
          _uuidFromLocalId(localId, 'card');
      _cardRemoteIdByLocal['$localId'] = remoteId;
      _cardLocalIdByRemote.putIfAbsent(remoteId, () => localId);
    }
    final usedCardLocalIds = localCards
        .map((row) => _localInt(row['id']))
        .whereType<int>()
        .toSet();
    for (final remote in remoteCards) {
      final remoteId = remote['id']?.toString();
      if (remoteId == null || _cardLocalIdByRemote.containsKey(remoteId)) {
        continue;
      }
      final localId = _availableLocalId(remoteId, usedCardLocalIds);
      _cardLocalIdByRemote[remoteId] = localId;
      usedCardLocalIds.add(localId);
    }

    // Persist identity and revision mappings so ordinary row mutations never
    // need to rebuild or fetch the full topics/courses/cards catalog.
    await db.transaction((txn) async {
      await AppDatabase.instance.suppressSyncOutbox(txn);
      try {
        Future<void> persist(
          String table,
          Map<String, int> localByRemote,
          List<Map<String, dynamic>> remoteRows,
        ) async {
          final remoteById = <String, Map<String, dynamic>>{
            for (final row in remoteRows)
              if (row['id'] != null) row['id'].toString(): row,
          };
          for (final entry in localByRemote.entries) {
            final remote = remoteById[entry.key];
            await txn.update(
              table,
              {
                'remoteId': entry.key,
                if (remote != null) ...{
                  'serverRevision': _localInt(remote['revision']) ?? 0,
                  'lastDeviceId': remote['last_device_id'],
                  'lastMutationId': remote['last_mutation_id'],
                },
              },
              where: 'id = ?',
              whereArgs: [entry.value],
            );
          }
        }

        await persist('topics', _topicLocalIdByRemote, remoteTopics);
        await persist('courses', _courseLocalIdByRemote, remoteCourses);
        await persist('cards', _cardLocalIdByRemote, remoteCards);
      } finally {
        await AppDatabase.instance.resumeSyncOutbox(txn);
      }
    });
  }

  int _availableLocalId(String remoteId, Set<int> usedIds) {
    var candidate = _stableLocalId(remoteId);
    if (candidate == 0) candidate = 1;
    while (usedIds.contains(candidate)) {
      candidate = (candidate + 1) & 0x7fffffff;
      if (candidate == 0) candidate = 1;
    }
    return candidate;
  }

  String _remoteIdFor(
    Map<String, String> identities,
    Object? localId,
    String namespace,
  ) {
    final key = localId?.toString() ?? '';
    return identities.putIfAbsent(
      key,
      () => _uuidFromLocalId(localId, namespace),
    );
  }

  int? _localInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  int _stableLocalId(Object? value) {
    final candidate = _stableHash32(value?.toString() ?? '') & 0x7fffffff;
    return candidate == 0 ? 1 : candidate;
  }

  int _stableHash32(String value) {
    var hash = 0x811c9dc5;
    for (final byte in value.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  bool _isRemoteNewer(String remoteValue, String localValue) {
    if (remoteValue.isEmpty) return false;
    if (localValue.isEmpty) return true;
    final remote = _parseSyncTimestamp(remoteValue);
    final local = _parseSyncTimestamp(localValue);
    if (remote != null && local != null) return remote.isAfter(local);
    return remoteValue.compareTo(localValue) > 0;
  }

  bool _localRowIsNewer(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final localValue =
        (local['updated_at'] ?? local['created_at'])?.toString() ?? '';
    final remoteValue =
        (remote['updated_at'] ?? remote['created_at'])?.toString() ?? '';
    if (localValue.isEmpty) return false;
    if (remoteValue.isEmpty) return true;

    final localTime = _parseSyncTimestamp(localValue);
    final remoteTime = _parseSyncTimestamp(remoteValue);
    if (localTime != null && remoteTime != null) {
      return localTime.isAfter(remoteTime);
    }
    return localValue.compareTo(remoteValue) > 0;
  }

  DateTime? _parseSyncTimestamp(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    // App-generated SQLite values have no offset and represent device-local
    // time. DateTime.parse handles those as local; explicit server offsets are
    // honored, then both sides are compared as UTC instants.
    return DateTime.tryParse(text)?.toUtc();
  }

  String? _remoteTimestampToLocalIso(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    return parsed?.toLocal().toIso8601String() ?? text;
  }

  String? _localTimestampToRemoteIso(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    return parsed?.toUtc().toIso8601String() ?? text;
  }

  String _normalizeIdentity(Object? value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }

  String _remoteCardIdentity(Map<String, dynamic> row) {
    return _cardIdentity(
      row['course_id'],
      row['position'],
      row['term'],
      row['definition'],
    );
  }

  String _cardIdentity(
    Object? courseId,
    Object? position,
    Object? term,
    Object? definition,
  ) {
    return '${courseId ?? ''}|${position ?? 0}|'
        '${_normalizeIdentity(term)}|${_normalizeIdentity(definition)}';
  }

  /// Deterministic UUID v5-like from integer local ID + namespace.
  /// This ensures the same local row always maps to the same remote UUID.
  String _uuidFromLocalId(Object? localId, String namespace) {
    final id = localId?.toString() ?? '0';
    final device = _localDeviceId.isEmpty ? 'legacy' : _localDeviceId;
    final seed = '$device:$namespace:$id';
    // Simple deterministic "UUID" from hash – sufficient for personal sync
    final hash = _stableHash32(seed);
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return '00000000-0000-4000-8000-$hex${hex.substring(0, 4)}';
  }

  Future<String> getRemoteCardId(int localCardId) async {
    final db = await AppDatabase.instance.database;
    await _ensureLocalDeviceId(db);
    final rows = await db.query(
      'cards',
      columns: const ['remoteId'],
      where: 'id = ?',
      whereArgs: [localCardId],
      limit: 1,
    );
    final saved = rows.isEmpty ? '' : rows.first['remoteId']?.toString() ?? '';
    return saved.isNotEmpty
        ? saved
        : _uuidFromLocalId(localCardId, 'card');
  }

  Future<void> deleteRemoteReviewStatesForCards(
    Iterable<int> localCardIds,
  ) async {
    if (!SupabaseConfig.isLoggedIn) return;
    await _drainTargetedOutbox(table: 'review_states');
  }

  Future<void> deleteRemoteCourseChildren(int localCourseId) async {
    // The course tombstone RPC marks cards, examples and review states in one
    // server transaction. Never physically delete children ahead of its ack.
  }

  Future<void> markRemoteCoursesDeleted(
    Iterable<int> localCourseIds, {
    required String deletedAt,
  }) async {
    if (!SupabaseConfig.isLoggedIn) return;
    for (final localCourseId in localCourseIds.toSet()) {
      await _drainTargetedOutbox(
        table: 'courses',
        entityId: '$localCourseId',
      );
    }
  }

  Future<void> deleteRemoteCardChildren(int localCardId) async {
    // The card tombstone RPC owns child tombstones. This compatibility method
    // intentionally performs no physical DELETE.
  }

  Future<String?> findRemoteCardId(int localCardId) async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query(
        'cards',
        where: 'id = ?',
        whereArgs: [localCardId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final card = rows.first;
      final term = card['term']?.toString() ?? '';
      final definition = card['definition']?.toString() ?? '';
      final position = card['position'] ?? 0;
      final localCourseId = _localInt(card['courseId']);

      final ownerId = SupabaseConfig.currentUser?.id;
      if (ownerId == null) return null;
      final remoteCourseId = localCourseId == null
          ? null
          : await findRemoteCourseId(localCourseId);

      dynamic query = SupabaseConfig.client
          .from('cards')
          .select('id')
          .eq('owner_id', ownerId)
          .eq('term', term)
          .eq('definition', definition)
          .eq('position', position);
      if (remoteCourseId != null) {
        query = query.eq('course_id', remoteCourseId);
      }
      final response = await query.limit(1);

      if (response.isNotEmpty) {
        return response.first['id']?.toString();
      }
    } catch (e) {
      print('findRemoteCardId error: $e');
    }
    return getRemoteCardId(localCardId);
  }

  Future<String> getRemoteCourseId(int localCourseId) async {
    final db = await AppDatabase.instance.database;
    await _ensureLocalDeviceId(db);
    return _uuidFromLocalId(localCourseId, 'course');
  }

  Future<String?> findRemoteCourseId(int localCourseId) async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query(
        'courses',
        where: 'id = ?',
        whereArgs: [localCourseId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final course = rows.first;
      final title = course['title']?.toString() ?? '';

      final ownerId = SupabaseConfig.currentUser?.id;
      if (ownerId == null) return null;

      final response = await SupabaseConfig.client
          .from('courses')
          .select('id')
          .eq('owner_id', ownerId)
          .eq('title', title)
          .limit(1);

      if (response.isNotEmpty) {
        return response.first['id']?.toString();
      }
    } catch (e) {
      print('findRemoteCourseId error: $e');
    }
    return getRemoteCourseId(localCourseId);
  }

  Future<void> _setLocalSetting(Database db, String key, String value) async {
    await db.insert(
      'app_settings',
      {'key': key, 'value': value, 'updatedAt': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}


class SyncResult {
  final int pushed;
  final int pulled;
  final int pulledCourses;
  final int pulledCards;
  final String? error;
  final List<String> logs;

  SyncResult({
    required this.pushed,
    required this.pulled,
    this.pulledCourses = 0,
    this.pulledCards = 0,
    this.error,
    this.logs = const [],
  });

  bool get hasError => error != null;
  int get total => pushed + pulled;
  String get downloadSummary =>
      'Hoàn tất • Tải về $pulledCourses học phần • $pulledCards thẻ';

  @override
  String toString() {
    if (hasError) return 'Lỗi đồng bộ: $error';
    return 'Đồng bộ: đẩy lên $pushed, tải về $pulled';
  }
}
