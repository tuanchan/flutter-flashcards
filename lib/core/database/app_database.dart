import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static Database? _database;
  bool _syncOutboxReady = false;
  Future<void>? _vocabularyReminderSchemaCheck;

  Future<Database> get database async {
    if (_database != null) return _database!;

    _database = await _initDatabase();
    return _database!;
  }

  /// Restores schedules for legacy or merged SRS rows that have a level but
  /// no due date. A positive SRS level must always have a review schedule.
  Future<int> repairIncompleteReviewSchedules() async {
    await ensureSyncOutboxTable();
    final db = await database;
    final rows = await db.query(
      'review_states',
      columns: ['id', 'cardId', 'level', 'intervalDays'],
      where: 'COALESCE(level, 0) > 0 AND '
          "(nextReviewAt IS NULL OR TRIM(nextReviewAt) = '')",
    );
    if (rows.isEmpty) return 0;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final nowIso = now.toIso8601String();

    int defaultIntervalForLevel(int level) {
      const intervals = [1, 2, 4, 7, 15, 30, 60, 120];
      if (level <= 0) return 0;
      if (level <= intervals.length) return intervals[level - 1];
      return intervals.last;
    }

    await db.transaction((txn) async {
      for (final row in rows) {
        final level = (row['level'] as num?)?.toInt() ?? 0;
        final storedInterval = (row['intervalDays'] as num?)?.toInt() ?? 0;
        final interval = storedInterval > 0
            ? storedInterval
            : defaultIntervalForLevel(level);
        await txn.update(
          'review_states',
          {
            'intervalDays': interval,
            'nextReviewAt': today.add(Duration(days: interval)).toIso8601String(),
            'updatedAt': nowIso,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
    return rows.length;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'list_card.db');

    print("DATABASE PATH: $path");

    // Check if database file already exists locally
    final exists = await databaseExists(path);
    if (!exists) {
      try {
        print("Copying pre-populated database from assets/list_card.db...");
        final data = await rootBundle.load('assets/list_card.db');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

        // Ensure the directory exists
        final parentDir = Directory(dirname(path));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        await File(path).writeAsBytes(bytes, flush: true);
        print("Database loaded from assets successfully.");
      } catch (e) {
        print("No pre-seeded database found in assets, or failed to copy: $e");
      }
    }

    return await openDatabase(
      path,
      version: 8,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE languages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        nativeName TEXT,
        code TEXT NOT NULL UNIQUE,
        ttsCode TEXT,
        scriptType TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE topics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        deletedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE courses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topicId INTEGER,
        title TEXT NOT NULL,
        description TEXT,
        languageId INTEGER,
        languageName TEXT,
        languageCode TEXT NOT NULL,
        cardCount INTEGER DEFAULT 0,
        isFavorite INTEGER DEFAULT 0,
        isArchived INTEGER DEFAULT 0,
        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        deletedAt TEXT,
        syncOrigin TEXT NOT NULL DEFAULT 'local',
        hasLocalNameConflict INTEGER NOT NULL DEFAULT 0,

        FOREIGN KEY (topicId) REFERENCES topics(id) ON DELETE SET NULL,
        FOREIGN KEY (languageId) REFERENCES languages(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        courseId INTEGER NOT NULL,

        term TEXT NOT NULL,
        definition TEXT NOT NULL,
        pronunciation TEXT,

        rawText TEXT,
        inputFormat TEXT,

        extraMeaning TEXT,
        note TEXT,
        imagePath TEXT,
        audioPath TEXT,

        position INTEGER DEFAULT 0,
        isFavorite INTEGER DEFAULT 0,
        isHidden INTEGER DEFAULT 0,

        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        deletedAt TEXT,

        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE card_examples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cardId INTEGER NOT NULL,

        exampleText TEXT NOT NULL,
        pronunciation TEXT,
        meaning TEXT,

        createdAt TEXT NOT NULL,
        updatedAt TEXT,

        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        color TEXT,
        createdAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE course_tags (
        courseId INTEGER NOT NULL,
        tagId INTEGER NOT NULL,

        PRIMARY KEY (courseId, tagId),

        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE review_states (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cardId INTEGER NOT NULL UNIQUE,

        level INTEGER DEFAULT 0,
        easeFactor REAL DEFAULT 2.5,
        intervalDays INTEGER DEFAULT 0,
        repetitionCount INTEGER DEFAULT 0,

        correctCount INTEGER DEFAULT 0,
        wrongCount INTEGER DEFAULT 0,

        lastReviewedAt TEXT,
        nextReviewAt TEXT,

        createdAt TEXT NOT NULL,
        updatedAt TEXT,

        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE study_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        courseId INTEGER NOT NULL,

        mode TEXT NOT NULL,
        totalCards INTEGER DEFAULT 0,
        correctCount INTEGER DEFAULT 0,
        wrongCount INTEGER DEFAULT 0,

        startedAt TEXT NOT NULL,
        endedAt TEXT,

        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE study_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sessionId INTEGER NOT NULL,
        cardId INTEGER NOT NULL,

        answerText TEXT,
        isCorrect INTEGER NOT NULL,
        responseTimeMs INTEGER,

        reviewedAt TEXT NOT NULL,

        FOREIGN KEY (sessionId) REFERENCES study_sessions(id) ON DELETE CASCADE,
        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');

    await _createReviewSentenceQuestionsTable(db);

    await db.execute('''
      CREATE TABLE import_exports (
        id INTEGER PRIMARY KEY AUTOINCREMENT,

        type TEXT NOT NULL,
        fileName TEXT,
        filePath TEXT,
        format TEXT NOT NULL,

        courseId INTEGER,
        status TEXT NOT NULL,
        message TEXT,

        createdAt TEXT NOT NULL,

        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updatedAt TEXT
      )
    ''');

    await _createSyncV2Schema(db);
    await _createVocabularyReminderTables(db);

    await _createIndexes(db);
    await _insertDefaultLanguages(db);
    await _insertDefaultSettings(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createReviewSentenceQuestionsTable(db);
    }
    if (oldVersion < 3) {
      await _ensureTopicSchema(db);
    }
    if (oldVersion < 4) {
      await _ensureCourseSyncMetadata(db);
    }
    if (oldVersion < 5) {
      await _createSyncOutboxTable(db);
    }
    if (oldVersion < 6) {
      await _createVocabularyReminderTables(db);
    }
    if (oldVersion < 7) {
      await _createVocabularyReminderTables(db);
    }
    if (oldVersion < 8) {
      await _createSyncV2Schema(db);
    }
  }

  Future<void> ensureVocabularyReminderSchema() async {
    final runningCheck = _vocabularyReminderSchemaCheck;
    if (runningCheck != null) return runningCheck;
    // Always verify additive columns. During Flutter hot reload the database
    // connection and this singleton survive while new code may already write
    // fields introduced by a newer schema.
    final check = () async {
      final db = await database;
      await _createVocabularyReminderTables(db);
    }();
    _vocabularyReminderSchemaCheck = check;
    try {
      await check;
    } finally {
      if (identical(_vocabularyReminderSchemaCheck, check)) {
        _vocabularyReminderSchemaCheck = null;
      }
    }
  }

  Future<void> _createVocabularyReminderTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vocabulary_reminder_configs (
        courseId INTEGER PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 0,
        intervalMinutes REAL NOT NULL DEFAULT 0.5,
        notificationsPerDay INTEGER NOT NULL DEFAULT 8,
        startHour INTEGER NOT NULL DEFAULT 8,
        startMinute INTEGER NOT NULL DEFAULT 0,
        endHour INTEGER NOT NULL DEFAULT 22,
        endMinute INTEGER NOT NULL DEFAULT 0,
        includePronunciation INTEGER NOT NULL DEFAULT 1,
        includeDefinition INTEGER NOT NULL DEFAULT 1,
        skipSrsMastered INTEGER NOT NULL DEFAULT 1,
        randomOrder INTEGER NOT NULL DEFAULT 1,
        soundEnabled INTEGER NOT NULL DEFAULT 1,
        showInForeground INTEGER NOT NULL DEFAULT 0,
        updatedAt TEXT NOT NULL,
        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE
      )
    ''');
    final configColumns = await db.rawQuery(
      'PRAGMA table_info(vocabulary_reminder_configs)',
    );
    final configColumnNames = configColumns
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
    if (!configColumnNames.contains('showInForeground')) {
      await db.execute(
        'ALTER TABLE vocabulary_reminder_configs '
        'ADD COLUMN showInForeground INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!configColumnNames.contains('startMinute')) {
      await db.execute(
        'ALTER TABLE vocabulary_reminder_configs '
        'ADD COLUMN startMinute INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!configColumnNames.contains('endMinute')) {
      await db.execute(
        'ALTER TABLE vocabulary_reminder_configs '
        'ADD COLUMN endMinute INTEGER NOT NULL DEFAULT 0',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vocabulary_reminder_states (
        cardId INTEGER PRIMARY KEY,
        courseId INTEGER NOT NULL,
        learned INTEGER NOT NULL DEFAULT 0,
        timesShown INTEGER NOT NULL DEFAULT 0,
        lastResponse TEXT,
        lastNotifiedAt TEXT,
        updatedAt TEXT NOT NULL,
        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE,
        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vocabulary_reminder_schedule (
        notificationId INTEGER PRIMARY KEY,
        courseId INTEGER NOT NULL,
        cardId INTEGER NOT NULL,
        scheduledAt TEXT NOT NULL,
        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE,
        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vocab_reminder_schedule_course '
      'ON vocabulary_reminder_schedule(courseId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vocab_reminder_states_course '
      'ON vocabulary_reminder_states(courseId, learned)',
    );
  }

  Future<void> ensureSyncOutboxTable() async {
    if (_syncOutboxReady) return;
    final db = await database;
    if (_syncOutboxReady) return;
    await _createSyncV2Schema(db);
  }

  /// Adds a durable sync marker using the same SQLite transaction that writes
  /// learning progress. This is intentionally network-independent: closing
  /// the app or losing connectivity after an answer must not leave an SRS row
  /// that can be overwritten by an older cloud snapshot.
  Future<void> enqueueSyncOutbox(
    DatabaseExecutor executor, {
    required String kind,
    required Object entityId,
    DateTime? queuedAt,
  }) async {
    final now = (queuedAt ?? DateTime.now()).toIso8601String();
    final id = entityId.toString();
    await executor.insert(
      'sync_outbox',
      {
        'kind': kind,
        'entityId': id,
        'createdAt': now,
        'updatedAt': now,
        'attempts': 0,
        'lastError': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await executor.update(
      'sync_outbox',
      {
        'updatedAt': now,
        'attempts': 0,
        'lastError': null,
      },
      where: 'kind = ? AND entityId = ?',
      whereArgs: [kind, id],
    );
  }

  /// Stores one review event, not only the resulting state. The mutation ID is
  /// the durable idempotency key used by the Supabase SRS RPC on every retry.
  Future<String> enqueueReviewMutation(
    DatabaseExecutor executor, {
    required int cardId,
    required String rating,
    required DateTime reviewedAt,
    int? baseRevision,
  }) async {
    final mutationId = _newLocalUuid();
    final now = DateTime.now().toIso8601String();
    final stateRows = await executor.query(
      'review_states',
      columns: const ['id'],
      where: 'cardId = ?',
      whereArgs: [cardId],
      limit: 1,
    );
    if (stateRows.isNotEmpty) {
      // The INSERT/UPDATE trigger queued a generic state upsert earlier in
      // this transaction. Replace it with the immutable answer event so only
      // the canonical server-side SRS algorithm advances the schedule.
      await executor.delete(
        'sync_outbox',
        where: "tableName = 'review_states' AND entityId = ? "
            "AND operation = 'upsert'",
        whereArgs: ['${stateRows.first['id']}'],
      );
    }
    await executor.insert('sync_outbox', {
      'kind': 'v2:review_states:review',
      'entityId': '$cardId:$mutationId',
      'tableName': 'review_states',
      'operation': 'review',
      'mutationId': mutationId,
      'baseRevision': baseRevision ?? 0,
      'payload': jsonEncode({
        'cardId': cardId,
        'rating': rating,
        'reviewedAt': reviewedAt.toUtc().toIso8601String(),
      }),
      'createdAt': now,
      'updatedAt': now,
      'nextAttemptAt': now,
      'attempts': 0,
      'status': 'pending',
      'lastError': null,
    });
    return mutationId;
  }

  Future<void> suppressSyncOutbox(DatabaseExecutor executor) async {
    await executor.insert(
      'sync_runtime',
      {'key': 'suppress_outbox', 'value': '1'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> resumeSyncOutbox(DatabaseExecutor executor) async {
    await executor.delete(
      'sync_runtime',
      where: 'key = ?',
      whereArgs: ['suppress_outbox'],
    );
  }

  String _newLocalUuid() {
    final secureRandom = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => secureRandom.nextInt(256));
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

  Future<void> _createSyncOutboxTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        kind TEXT NOT NULL,
        entityId TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        lastError TEXT,
        PRIMARY KEY (kind, entityId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_outbox_updatedAt '
      'ON sync_outbox(updatedAt)',
    );
    _syncOutboxReady = true;
  }

  Future<void> _createSyncV2Schema(Database db) async {
    await _createSyncOutboxTable(db);
    await _ensureSyncV2SchemaOnExecutor(db);
    _syncOutboxReady = true;
  }

  Future<void> _ensureSyncV2SchemaOnExecutor(DatabaseExecutor db) async {
    Future<void> addColumn(String table, String definition) async {
      final columnName = definition.trim().split(RegExp(r'\s+')).first;
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (!columns.any((row) => row['name'] == columnName)) {
        await db.execute('ALTER TABLE $table ADD COLUMN $definition');
      }
    }

    for (final table in const [
      'topics',
      'courses',
      'cards',
      'card_examples',
      'review_states',
    ]) {
      await addColumn(table, 'remoteId TEXT');
      await addColumn(table, 'serverRevision INTEGER NOT NULL DEFAULT 0');
      await addColumn(table, 'lastDeviceId TEXT');
      await addColumn(table, 'lastMutationId TEXT');
    }
    await addColumn('card_examples', 'deletedAt TEXT');
    await addColumn('review_states', 'deletedAt TEXT');

    await addColumn('sync_outbox', 'tableName TEXT');
    await addColumn('sync_outbox', "operation TEXT NOT NULL DEFAULT 'upsert'");
    await addColumn('sync_outbox', 'remoteId TEXT');
    await addColumn('sync_outbox', 'mutationId TEXT');
    await addColumn('sync_outbox', 'baseRevision INTEGER NOT NULL DEFAULT 0');
    await addColumn('sync_outbox', 'payload TEXT');
    await addColumn('sync_outbox', "status TEXT NOT NULL DEFAULT 'pending'");
    await addColumn('sync_outbox', 'nextAttemptAt TEXT');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_runtime (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_outbox_v2_retry '
      'ON sync_outbox(status, nextAttemptAt, createdAt)',
    );

    const mutationIdSql = "lower(hex(randomblob(4))) || '-' || "
        "lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-8' || "
        "substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6)))";
    for (final table in const [
      'topics',
      'courses',
      'cards',
      'card_examples',
      'review_states',
    ]) {
      final entityExpr = "CAST(NEW.id AS TEXT)";
      final deleteEntityExpr = "CAST(OLD.id AS TEXT)";
      final deletedColumn = 'deletedAt';
      await db.execute('DROP TRIGGER IF EXISTS sync_v2_${table}_insert');
      await db.execute('DROP TRIGGER IF EXISTS sync_v2_${table}_update');
      await db.execute('DROP TRIGGER IF EXISTS sync_v2_${table}_delete');
      await db.execute('''
        CREATE TRIGGER sync_v2_${table}_insert
        AFTER INSERT ON $table
        WHEN COALESCE((SELECT value FROM sync_runtime WHERE key = 'suppress_outbox'), '0') <> '1'
        BEGIN
          INSERT OR REPLACE INTO sync_outbox(
            kind, entityId, tableName, operation, remoteId, mutationId,
            baseRevision, createdAt, updatedAt, nextAttemptAt, attempts, status, lastError
          ) VALUES(
            'v2:$table', $entityExpr, '$table',
            CASE WHEN NEW.$deletedColumn IS NULL THEN 'upsert' ELSE 'delete' END,
            NEW.remoteId, $mutationIdSql, 0,
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'), 0, 'pending', NULL
          );
        END
      ''');
      await db.execute('''
        CREATE TRIGGER sync_v2_${table}_update
        AFTER UPDATE ON $table
        WHEN COALESCE((SELECT value FROM sync_runtime WHERE key = 'suppress_outbox'), '0') <> '1'
        BEGIN
          INSERT OR REPLACE INTO sync_outbox(
            kind, entityId, tableName, operation, remoteId, mutationId,
            baseRevision, createdAt, updatedAt, nextAttemptAt, attempts, status, lastError
          ) VALUES(
            'v2:$table', $entityExpr, '$table',
            CASE WHEN NEW.$deletedColumn IS NULL THEN 'upsert' ELSE 'delete' END,
            COALESCE(NEW.remoteId, OLD.remoteId), $mutationIdSql,
            COALESCE(OLD.serverRevision, 0),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'), 0, 'pending', NULL
          );
        END
      ''');
      await db.execute('''
        CREATE TRIGGER sync_v2_${table}_delete
        BEFORE DELETE ON $table
        WHEN COALESCE((SELECT value FROM sync_runtime WHERE key = 'suppress_outbox'), '0') <> '1'
        BEGIN
          INSERT OR REPLACE INTO sync_outbox(
            kind, entityId, tableName, operation, remoteId, mutationId,
            baseRevision, payload, createdAt, updatedAt, nextAttemptAt,
            attempts, status, lastError
          ) VALUES(
            'v2:$table', $deleteEntityExpr, '$table', 'delete', OLD.remoteId,
            $mutationIdSql, COALESCE(OLD.serverRevision, 0),
            json_object('deleted_at', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            strftime('%Y-%m-%dT%H:%M:%fZ','now'), 0, 'pending', NULL
          );
        END
      ''');
    }
  }

  Future<void> ensureTopicSchema() async {
    final db = await database;
    await _ensureTopicSchema(db);
    await _ensureCourseSyncMetadata(db);
  }

  Future<void> _ensureCourseSyncMetadata(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(courses)');
    final names = columns
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
    if (!names.contains('syncOrigin')) {
      await db.execute(
        "ALTER TABLE courses ADD COLUMN syncOrigin TEXT NOT NULL DEFAULT 'local'",
      );
    }
    if (!names.contains('hasLocalNameConflict')) {
      await db.execute(
        'ALTER TABLE courses ADD COLUMN hasLocalNameConflict INTEGER NOT NULL DEFAULT 0',
      );
    }

    // Merge may intentionally keep a cloud course and a local course with the
    // same display name. Creation/edit screens still validate duplicate names.
    await db.execute('DROP INDEX IF EXISTS idx_courses_title_unique');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_courses_title '
      'ON courses(lower(trim(title))) WHERE deletedAt IS NULL',
    );
  }

  Future<void> _ensureTopicSchema(Database db) async {
    await _createTopicsTable(db);
    await _addTopicIdToCourses(db);
    await _backfillCourseTopics(db);
    await _repairLegacyTopicAssignments(db);
    await _normalizeBuiltInCourseTopics(db);
    await _createTopicIndexes(db);
  }

  Future<void> _createTopicsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS topics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        deletedAt TEXT
      )
    ''');
  }

  Future<void> _addTopicIdToCourses(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(courses)');
    final hasTopicId = columns.any((column) => column['name'] == 'topicId');
    if (hasTopicId) return;

    await db.execute('ALTER TABLE courses ADD COLUMN topicId INTEGER');
  }

  Future<int> _ensureTopic(Database db, String name, String now) async {
    return ensureActiveTopicByName(
      db,
      name: name,
      now: now,
    );
  }

  /// Returns the active topic with [name], restoring its tombstone when the
  /// same topic was deleted earlier. Older databases have a column-level
  /// UNIQUE constraint on topics.name, so inserting a replacement row would
  /// otherwise fail with SQLITE_CONSTRAINT_UNIQUE (2067).
  Future<int> ensureActiveTopicByName(
    DatabaseExecutor executor, {
    required String name,
    required String now,
  }) async {
    final normalized = name.trim().isEmpty ? 'Chủ đề mới' : name.trim();
    final rows = await executor.query(
      'topics',
      columns: ['id', 'deletedAt'],
      where: 'lower(trim(name)) = ?',
      whereArgs: [normalized.toLowerCase()],
      orderBy: 'CASE WHEN deletedAt IS NULL THEN 0 ELSE 1 END, id ASC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final row = rows.first;
      final topicId = row['id'] as int;
      if (row['deletedAt'] != null) {
        await executor.update(
          'topics',
          {
            'name': normalized,
            'updatedAt': now,
            'deletedAt': null,
          },
          where: 'id = ?',
          whereArgs: [topicId],
        );
      }
      return topicId;
    }

    return executor.insert('topics', {
      'name': normalized,
      'createdAt': now,
      'updatedAt': now,
    });
  }

  Future<void> _backfillCourseTopics(Database db) async {
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'courses',
      columns: ['id', 'title', 'description', 'topicId'],
      where: 'deletedAt IS NULL',
    );

    for (final row in rows) {
      if (row['topicId'] != null) continue;

      final description = row['description']?.toString() ?? '';
      final title = row['title']?.toString() ?? '';
      String topicName;

      if (description.contains('assets/TOEIC/')) {
        topicName = 'TOEIC';
      } else if (description.contains('assets/TOCFL/')) {
        topicName = 'Tiếng Trung B1';
      } else {
        topicName = title.trim().isEmpty ? 'Chủ đề mới' : title.trim();
      }

      final topicId = await _ensureTopic(db, topicName, now);
      await db.update(
        'courses',
        {'topicId': topicId, 'updatedAt': now},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<void> _normalizeBuiltInCourseTopics(Database db) async {
    final now = DateTime.now().toIso8601String();
    await _normalizeBuiltInTopic(
      db: db,
      topicName: 'TOEIC',
      now: now,
      where: "deletedAt IS NULL AND description LIKE ?",
      whereArgs: ['%assets/TOEIC/%'],
    );
    await _normalizeBuiltInTopic(
      db: db,
      topicName: 'Tiếng Trung B1',
      now: now,
      where: "deletedAt IS NULL AND description LIKE ?",
      whereArgs: ['%assets/TOCFL/%'],
    );
  }

  /// Older builds treated every English course whose title started with
  /// "day" as bundled TOEIC data. Restore a recently deleted user topic when
  /// its timestamps clearly match a course moved by that legacy rule.
  Future<void> _repairLegacyTopicAssignments(Database db) async {
    final courses = await db.rawQuery('''
      SELECT c.id, c.title, c.languageCode, c.createdAt,
             t.id AS currentTopicId, lower(trim(t.name)) AS currentTopicName
      FROM courses c
      INNER JOIN topics t ON t.id = c.topicId
      WHERE c.deletedAt IS NULL
        AND COALESCE(c.description, '') NOT LIKE '%assets/TOEIC/%'
        AND COALESCE(c.description, '') NOT LIKE '%assets/TOCFL/%'
        AND (
          (lower(trim(t.name)) = 'toeic'
            AND c.languageCode = 'en-US'
            AND lower(c.title) LIKE 'day%')
          OR
          (lower(trim(t.name)) = 'tiếng trung b1'
            AND (c.title LIKE '%_TOCFL%' OR c.title LIKE '% TOCFL%'))
        )
    ''');

    for (final course in courses) {
      final courseCreated = _parseDatabaseWallClock(course['createdAt']);
      if (courseCreated == null) continue;

      final deletedTopics = await db.query(
        'topics',
        columns: ['id', 'name', 'createdAt', 'deletedAt'],
        where: '''
          deletedAt IS NOT NULL
          AND id != ?
          AND lower(trim(name)) NOT IN (?, ?, ?)
        ''',
        whereArgs: [
          course['currentTopicId'],
          'chủ đề khác',
          'toeic',
          'tiếng trung b1',
        ],
      );

      Map<String, Object?>? bestMatch;
      Duration? bestDistance;
      for (final topic in deletedTopics) {
        final topicCreated = _parseDatabaseWallClock(topic['createdAt']);
        final topicDeleted = _parseDatabaseWallClock(topic['deletedAt']);
        if (topicCreated == null || topicDeleted == null) continue;
        if (topicDeleted.isBefore(courseCreated)) continue;

        final distance = topicCreated.difference(courseCreated).abs();
        if (distance > const Duration(minutes: 2)) continue;
        if (bestDistance == null || distance < bestDistance) {
          bestMatch = topic;
          bestDistance = distance;
        }
      }
      if (bestMatch == null) continue;

      final now = DateTime.now().toIso8601String();
      final restoredTopicId = await ensureActiveTopicByName(
        db,
        name: bestMatch['name']?.toString() ?? '',
        now: now,
      );
      await db.update(
        'courses',
        {'topicId': restoredTopicId, 'updatedAt': now},
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [course['id']],
      );
    }
  }

  DateTime? _parseDatabaseWallClock(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    // Old local rows have no timezone while pulled Supabase rows use UTC.
    // Their wall-clock portion came from the same original local timestamp.
    final wallClock = text.length >= 19 ? text.substring(0, 19) : text;
    return DateTime.tryParse(wallClock);
  }

  Future<void> _normalizeBuiltInTopic({
    required Database db,
    required String topicName,
    required String now,
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final rows = await db.query(
      'courses',
      columns: ['id'],
      where: where,
      whereArgs: whereArgs,
      limit: 1,
    );
    if (rows.isEmpty) return;

    final topicId = await _ensureTopic(db, topicName, now);
    await db.update(
      'courses',
      {'topicId': topicId, 'updatedAt': now},
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<void> _createTopicIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_courses_topicId ON courses(topicId)',
    );
    await _deduplicateActiveTopics(db);
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_topics_name_unique ON topics(lower(trim(name))) WHERE deletedAt IS NULL',
    );
  }

  /// Repairs legacy/cloud data containing active topic names that differ only
  /// by case or surrounding whitespace. Courses are moved to the oldest topic
  /// and the duplicate rows become syncable tombstones.
  Future<void> _deduplicateActiveTopics(Database db) async {
    final duplicateGroups = await db.rawQuery('''
      SELECT lower(trim(name)) AS normalizedName
      FROM topics
      WHERE deletedAt IS NULL
      GROUP BY lower(trim(name))
      HAVING COUNT(*) > 1
    ''');
    if (duplicateGroups.isEmpty) return;

    final now = DateTime.now().toIso8601String();
    for (final group in duplicateGroups) {
      final normalizedName = group['normalizedName']?.toString();
      if (normalizedName == null) continue;

      final rows = await db.query(
        'topics',
        columns: ['id'],
        where: 'lower(trim(name)) = ? AND deletedAt IS NULL',
        whereArgs: [normalizedName],
        orderBy: 'id ASC',
      );
      final ids = rows
          .map((row) => row['id'] as int?)
          .whereType<int>()
          .toList(growable: false);
      if (ids.length < 2) continue;

      final survivorId = ids.first;
      final duplicateIds = ids.skip(1).toList(growable: false);
      final placeholders = List.filled(duplicateIds.length, '?').join(',');
      await db.update(
        'courses',
        {'topicId': survivorId, 'updatedAt': now},
        where: 'topicId IN ($placeholders)',
        whereArgs: duplicateIds,
      );
      await db.update(
        'topics',
        {'deletedAt': now, 'updatedAt': now},
        where: 'id IN ($placeholders)',
        whereArgs: duplicateIds,
      );
    }
  }

  Future<void> _createReviewSentenceQuestionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS review_sentence_questions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        courseId INTEGER NOT NULL,
        cardId INTEGER NOT NULL,
        languageCode TEXT NOT NULL,
        direction TEXT NOT NULL,
        sourceTerm TEXT NOT NULL,
        sourceDefinition TEXT NOT NULL,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT,

        FOREIGN KEY (courseId) REFERENCES courses(id) ON DELETE CASCADE,
        FOREIGN KEY (cardId) REFERENCES cards(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_review_sentence_questions_unique '
      'ON review_sentence_questions(courseId, cardId, languageCode, direction)',
    );

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_review_sentence_questions_course '
      'ON review_sentence_questions(courseId, languageCode, direction)',
    );
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX idx_courses_languageCode ON courses(languageCode)',
    );
    await _createTopicIndexes(db);

    await db.execute(
      'CREATE INDEX idx_cards_courseId ON cards(courseId)',
    );

    await db.execute(
      'CREATE INDEX idx_cards_term ON cards(term)',
    );

    await db.execute(
      'CREATE INDEX idx_cards_pronunciation ON cards(pronunciation)',
    );

    await db.execute(
      'CREATE INDEX idx_review_nextReviewAt ON review_states(nextReviewAt)',
    );

    await db.execute(
      'CREATE INDEX idx_study_sessions_courseId ON study_sessions(courseId)',
    );

    await db.execute(
      'CREATE INDEX idx_study_results_cardId ON study_results(cardId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_courses_title '
      'ON courses(lower(trim(title))) WHERE deletedAt IS NULL',
    );
  }

  Future<void> _insertDefaultLanguages(Database db) async {
    final now = DateTime.now().toIso8601String();

    final languages = [
      {
        'name': 'Tiếng Trung Phồn thể',
        'nativeName': '繁體中文',
        'code': 'zh-TW',
        'ttsCode': 'zh-TW',
        'scriptType': 'traditional',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Trung Giản thể',
        'nativeName': '简体中文',
        'code': 'zh-CN',
        'ttsCode': 'zh-CN',
        'scriptType': 'simplified',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Anh',
        'nativeName': 'English',
        'code': 'en-US',
        'ttsCode': 'en-US',
        'scriptType': 'latin',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Đức',
        'nativeName': 'Deutsch',
        'code': 'de-DE',
        'ttsCode': 'de-DE',
        'scriptType': 'latin',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Nhật',
        'nativeName': '日本語',
        'code': 'ja-JP',
        'ttsCode': 'ja-JP',
        'scriptType': 'japanese',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Hàn',
        'nativeName': '한국어',
        'code': 'ko-KR',
        'ttsCode': 'ko-KR',
        'scriptType': 'korean',
        'createdAt': now,
      },
      {
        'name': 'Tiếng Việt',
        'nativeName': 'Tiếng Việt',
        'code': 'vi-VN',
        'ttsCode': 'vi-VN',
        'scriptType': 'latin',
        'createdAt': now,
      },
    ];

    for (final language in languages) {
      await db.insert(
        'languages',
        language,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _insertDefaultSettings(Database db) async {
    final now = DateTime.now().toIso8601String();

    final settings = {
      'defaultLanguageCode': 'zh-TW',
      'defaultInputFormat': 'auto',
      'defaultTermSeparator': 'tab',
      'defaultCardSeparator': 'newline',
      'autoShowPreview': 'false',
      'themeMode': 'light',
    };

    for (final entry in settings.entries) {
      await db.insert(
        'app_settings',
        {
          'key': entry.key,
          'value': entry.value,
          'updatedAt': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db == null) return;

    await db.close();
    _database = null;
  }

  Future<void> deleteDatabaseFile() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'list_card.db');

    print("DATABASE PATH: $path");
    await deleteDatabase(path);
    _database = null;
  }
}
