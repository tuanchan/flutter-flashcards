part of flutterflashcard_main;

extension HomePageStatePart03 on _HomePageState {
  Future<void> openCreateTopicDialog() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.72),
      builder: (dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460),
            child: Container(
              padding: EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Color(0xff0b0d12),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Color(0xff2a334a)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Tạo chủ đề',
                          style: TextStyle(
                            color: Color(0xfff8fafc),
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Đóng',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: Icon(
                          Icons.close_rounded,
                          color: Color(0xff94a3b8),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'TÊN CHỦ ĐỀ',
                    style: TextStyle(
                      color: Color(0xffcbd5e1),
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 7),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 80,
                    style: TextStyle(
                      color: Color(0xfff8fafc),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Ví dụ: Tiếng Trung phồn thể, Lập trình...',
                      hintStyle: TextStyle(color: Color(0xff64748b)),
                      counterStyle: TextStyle(color: Color(0xff94a3b8)),
                      filled: true,
                      fillColor: Color(0xff080a0f),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Color(0xff2a334a)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Color(0xff3b82f6),
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: TextButton.styleFrom(
                          foregroundColor: Color(0xff94a3b8),
                        ),
                        child: Text(
                          'Hủy',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: () async {
                          final name = controller.text.trim();
                          final error = this.validateTopicName(name);
                          if (error != null) {
                            this.showHomeMessage(error);
                            return;
                          }

                          await AppDatabase.instance.ensureTopicSchema();
                          final duplicated = await this.isDuplicateTopicName(
                            name: name,
                          );
                          if (duplicated) {
                            this.showHomeMessage("Tên chủ đề đã tồn tại");
                            return;
                          }

                          final db = await AppDatabase.instance.database;
                          final now = DateTime.now().toIso8601String();
                          final topicId = await AppDatabase.instance
                              .ensureActiveTopicByName(
                                db,
                                name: name,
                                now: now,
                              );

                          if (!mounted) return;
                          expandedTopicIds.add(topicId);
                          Navigator.pop(dialogContext);
                          await this.loadCourses(showLoading: false);
                          if (SupabaseConfig.isLoggedIn) {
                            unawaited(
                              SupabaseSyncService.instance
                                  .pushTopicMutation(topicId)
                                  .then((result) {
                                if (result.hasError) {
                                  debugPrint(
                                    'CREATE TOPIC SYNC ERROR: ${result.error}',
                                  );
                                }
                              }),
                            );
                          }
                          this.showHomeMessage("Đã tạo chủ đề");
                        },
                        style: ElevatedButton.styleFrom(
                          elevation: 0,
                          backgroundColor: Color(0xff2563eb),
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Tạo',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    controller.dispose();
  }


  Future<void> openEditTopicDialog(CourseTopicItem topic) async {
    final controller = TextEditingController(text: topic.name);

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460),
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color(0xff1e293b),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Color(0xff334155)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x4d000000),
                    blurRadius: 15,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Sửa chủ đề",
                          style: TextStyle(
                            color: Color(0xfff8fafc),
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Đóng',
                        onPressed: () => Navigator.pop(dialogContext),
                        style: IconButton.styleFrom(
                          side: BorderSide(color: Color(0xff334155)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: Icon(
                          Icons.close_rounded,
                          color: Color(0xfff8fafc),
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    'TÊN CHỦ ĐỀ',
                    style: TextStyle(
                      color: Color(0xfff8fafc),
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 7),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 80,
                    style: TextStyle(
                      color: Color(0xfff8fafc),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Ví dụ: Tiếng Trung phồn thể, Lập trình...',
                      hintStyle: TextStyle(color: Color(0xff64748b)),
                      counterStyle: TextStyle(color: Color(0xff94a3b8)),
                      filled: true,
                      fillColor: Color(0xff0f172a),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Color(0xff334155)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Color(0xff84ceeb)),
                      ),
                    ),
                  ),
                  SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: TextButton.styleFrom(
                          foregroundColor: Color(0xff94a3b8),
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        child: Text(
                          'Hủy',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      SizedBox(width: 10),
                      TextButton(
                        onPressed: () async {
                          final name = controller.text.trim();
                          final error = this.validateTopicName(name);
                          if (error != null) {
                            this.showHomeMessage(error);
                            return;
                          }

                          await AppDatabase.instance.ensureTopicSchema();
                          final duplicated = await this.isDuplicateTopicName(
                            name: name,
                            ignoreTopicId: topic.id,
                          );
                          if (duplicated) {
                            this.showHomeMessage("Tên chủ đề đã tồn tại");
                            return;
                          }

                          final db = await AppDatabase.instance.database;
                          await db.update(
                            'topics',
                            {
                              'name': name,
                              'updatedAt': DateTime.now().toIso8601String(),
                            },
                            where: 'id = ? AND deletedAt IS NULL',
                            whereArgs: [topic.id],
                          );

                          if (!mounted) return;
                          Navigator.pop(dialogContext);
                          await this.loadCourses(showLoading: false);
                          if (SupabaseConfig.isLoggedIn) {
                            unawaited(
                              SupabaseSyncService.instance.syncPendingChanges(),
                            );
                          }
                          this.showHomeMessage("Đã sửa chủ đề");
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: Color(0xfff8fafc),
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        child: Text(
                          'Lưu',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    controller.dispose();
  }


  Future<void> confirmDeleteTopic(CourseTopicItem topic) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.72),
      builder: (dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440),
            child: Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Color(0xff0b0d12),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Color(0xff2a334a)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Color(0x24ef4444),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.delete_outline_rounded,
                          color: Color(0xffff6b6b),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Xóa chủ đề',
                          style: TextStyle(
                            color: Color(0xfff8fafc),
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Đóng',
                        onPressed: () => Navigator.pop(dialogContext, false),
                        icon: Icon(
                          Icons.close_rounded,
                          color: Color(0xff94a3b8),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 18),
                  Text(
                    topic.courseCount > 0
                        ? 'Xóa "${topic.name}"? Tất cả học phần, thẻ và tiến độ ôn tập bên trong cũng sẽ bị xóa. Thao tác này không thể hoàn tác.'
                        : 'Xóa "${topic.name}"? Thao tác này không thể hoàn tác.',
                    style: TextStyle(
                      color: Color(0xffcbd5e1),
                      fontSize: 14,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        style: TextButton.styleFrom(
                          foregroundColor: Color(0xff94a3b8),
                        ),
                        child: Text(
                          'Hủy',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        icon: Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text(
                          'Xóa',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        style: ElevatedButton.styleFrom(
                          elevation: 0,
                          backgroundColor: Color(0xffef4444),
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (result != true) return;

    try {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toIso8601String();
      final syncDeletion = SupabaseConfig.isLoggedIn;
      final tableRows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final existingTables = tableRows
          .map((row) => row['name']?.toString())
          .whereType<String>()
          .toSet();
      final courseRows = await db.query(
        'courses',
        columns: ['id'],
        where: 'topicId = ? AND deletedAt IS NULL',
        whereArgs: [topic.id],
      );
      final courseIds = courseRows
          .map((row) => row['id'] as int?)
          .whereType<int>()
          .toList(growable: false);

      // Cache files live outside SQLite. Cache cleanup is best-effort and
      // must never leave the database transaction only partially applied.
      for (final courseId in courseIds) {
        try {
          await TtsAudioCache.instance.deleteCourseAudioCache(
            courseId: courseId,
          );
        } catch (error) {
          debugPrint('DELETE TOPIC AUDIO CACHE ERROR ($courseId): $error');
        }
      }

      await db.transaction((txn) async {
        if (courseIds.isNotEmpty) {
          final placeholders = List.filled(courseIds.length, '?').join(',');
          final courseWhere = 'courseId IN ($placeholders)';
          final cardWhere =
              'cardId IN (SELECT id FROM cards WHERE $courseWhere)';

          await txn.delete(
            'study_results',
            where:
                'sessionId IN (SELECT id FROM study_sessions WHERE $courseWhere) OR $cardWhere',
            whereArgs: [...courseIds, ...courseIds],
          );
          if (existingTables.contains('review_sentence_questions')) {
            await txn.delete(
              'review_sentence_questions',
              where: courseWhere,
              whereArgs: courseIds,
            );
          }
          await txn.delete(
            'study_sessions',
            where: courseWhere,
            whereArgs: courseIds,
          );
          await txn.delete(
            'review_states',
            where: cardWhere,
            whereArgs: courseIds,
          );
          await txn.delete(
            'card_examples',
            where: cardWhere,
            whereArgs: courseIds,
          );
          await txn.delete(
            'course_tags',
            where: 'courseId IN ($placeholders)',
            whereArgs: courseIds,
          );
          await txn.delete(
            'import_exports',
            where: 'courseId IN ($placeholders)',
            whereArgs: courseIds,
          );

          if (syncDeletion) {
            // Logged-in deletes must reach the other devices.
            await txn.update(
              'cards',
              {'deletedAt': now, 'updatedAt': now},
              where: courseWhere,
              whereArgs: courseIds,
            );
            await txn.update(
              'courses',
              {'deletedAt': now, 'updatedAt': now, 'cardCount': 0},
              where: 'id IN ($placeholders)',
              whereArgs: courseIds,
            );
          } else {
            // Guest changes are local-only. A later login can download the
            // account copy instead of uploading guest tombstones.
            await txn.delete(
              'cards',
              where: courseWhere,
              whereArgs: courseIds,
            );
            await txn.delete(
              'courses',
              where: 'id IN ($placeholders)',
              whereArgs: courseIds,
            );
          }
        }

        final deletedTopicCount = syncDeletion
            ? await txn.update(
                'topics',
                {'deletedAt': now, 'updatedAt': now},
                where: 'id = ?',
                whereArgs: [topic.id],
              )
            : await txn.delete(
                'topics',
                where: 'id = ?',
                whereArgs: [topic.id],
              );
        if (deletedTopicCount != 1) {
          throw StateError('Không tìm thấy chủ đề id=${topic.id} để xóa');
        }
      });

      expandedTopicIds.remove(topic.id);
      if (!mounted) return;
      await this.loadCourses(showLoading: false);
      this.showHomeMessage("Đã xóa chủ đề");
      if (syncDeletion) {
        unawaited(
          SupabaseSyncService.instance
              .markRemoteCoursesDeleted(courseIds, deletedAt: now)
              .then((_) => SupabaseSyncService.instance.syncPendingChanges())
              .then((syncResult) {
                if (syncResult.hasError) {
                  debugPrint('DELETE TOPIC SYNC ERROR: ${syncResult.error}');
                }
              })
              .catchError((error, stackTrace) {
                debugPrint('DELETE TOPIC REMOTE ERROR: $error\n$stackTrace');
              }),
        );
      }
    } catch (e, stackTrace) {
      this.showHomeMessage("Xóa chủ đề thất bại: $e");
      debugPrint("DELETE TOPIC ERROR: $e\n$stackTrace");
    }
  }


  Future<int> ensureTopicByName({
    required Database db,
    required String name,
    required String now,
    int? ignoreTopicId,
  }) async {
    final normalized = name.trim();
    if (ignoreTopicId == null) {
      return AppDatabase.instance.ensureActiveTopicByName(
        db,
        name: normalized,
        now: now,
      );
    }

    final rows = await db.query(
      'topics',
      columns: ['id'],
      where:
          'lower(trim(name)) = ? AND id != ? AND deletedAt IS NULL',
      whereArgs: [normalized.toLowerCase(), ignoreTopicId],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return ignoreTopicId;
  }


  String? validateTopicName(String value) {
    final name = value.trim();
    if (name.isEmpty) return "Vui lòng nhập tên chủ đề";
    if (name.length < 2) return "Tên chủ đề phải có ít nhất 2 ký tự";
    if (name.length > 80) return "Tên chủ đề không được quá 80 ký tự";
    return null;
  }


  Future<bool> isDuplicateTopicName({
    required String name,
    int? ignoreTopicId,
  }) async {
    await AppDatabase.instance.ensureTopicSchema();
    final db = await AppDatabase.instance.database;
    final normalized = name.trim().toLowerCase();
    final rows = await db.query(
      'topics',
      columns: ['id'],
      where: ignoreTopicId == null
          ? 'lower(trim(name)) = ? AND deletedAt IS NULL'
          : 'lower(trim(name)) = ? AND id != ? AND deletedAt IS NULL',
      whereArgs: ignoreTopicId == null
          ? [normalized]
          : [normalized, ignoreTopicId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }


  Future<void> openEditCourseDialog(CourseListItem course) async {
    final controller = TextEditingController(text: course.title);
    String selectedLanguage = this.languageNameFromCode(course.languageCode);

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, dialogSetState) {
            return AlertDialog(
              backgroundColor: Color(0xff1e293b),
              insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              titlePadding: EdgeInsets.fromLTRB(16, 12, 8, 0),
              contentPadding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: Color(0xff334155)),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Sửa học phần",
                      style: TextStyle(
                        color: Color(0xfff8fafc),
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Đóng',
                    onPressed: () => Navigator.pop(dialogContext),
                    style: IconButton.styleFrom(
                      side: BorderSide(color: Color(0xff334155)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: Icon(
                      Icons.close_rounded,
                      color: Color(0xfff8fafc),
                      size: 18,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 428,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TÊN HỌC PHẦN',
                      style: TextStyle(
                        color: Color(0xfff8fafc),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 7),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLength: 80,
                      style: TextStyle(
                        color: Color(0xfff8fafc),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        counterStyle: TextStyle(color: Color(0xff94a3b8)),
                        filled: true,
                        fillColor: Color(0xff0f172a),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Color(0xff334155)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Color(0xff84ceeb)),
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      "Ngôn ngữ học phần",
                      style: TextStyle(
                        color: Color(0xfff8fafc),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 8),
                    Container(
                      height: 42,
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Color(0xff0f172a),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Color(0xff334155)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedLanguage,
                          isExpanded: true,
                          dropdownColor: Color(0xff1e293b),
                          iconEnabledColor: Color(0xff94a3b8),
                          style: TextStyle(
                            color: Color(0xfff8fafc),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                          items: this.buildLanguageItems(),
                          onChanged: (value) {
                            if (value == null) return;
                            dialogSetState(() {
                              selectedLanguage = value;
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Color(0xff94a3b8),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  child: Text(
                    "Hủy",
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final newTitle = controller.text.trim();

                    final error = this.validateCourseTitle(newTitle);
                    if (error != null) {
                      this.showHomeMessage(error);
                      return;
                    }

                    final duplicated = await this.isDuplicateCourseTitle(
                      title: newTitle,
                      ignoreCourseId: course.id,
                    );

                    if (duplicated) {
                      this.showHomeMessage("Tên học phần đã tồn tại");
                      return;
                    }

                    final db = await AppDatabase.instance.database;
                    final now = DateTime.now().toIso8601String();
                    final oldLanguageCode = course.languageCode;
                    final newLanguageCode = this.languageCodeFromName(
                      selectedLanguage,
                    );
                    final languageChanged = oldLanguageCode != newLanguageCode;

                    await db.update(
                      'courses',
                      {
                        'title': newTitle,
                        'languageName': selectedLanguage,
                        'languageCode': newLanguageCode,
                        'updatedAt': now,
                        'syncOrigin': 'local',
                        'hasLocalNameConflict': 0,
                      },
                      where: 'id = ? AND deletedAt IS NULL',
                      whereArgs: [course.id],
                    );

                    if (languageChanged) {
                      this.showHomeMessage(
                        "Đang tạo lại âm thanh cho ngôn ngữ mới...",
                      );

                      final cardRows = await db.query(
                        'cards',
                        where:
                            'courseId = ? AND deletedAt IS NULL AND isHidden = 0',
                        whereArgs: [course.id],
                        orderBy: 'position ASC, id ASC',
                      );

                      final items = cardRows.map((row) {
                        return FlashCardItem(
                          term: row['term']?.toString() ?? '',
                          definition: row['definition']?.toString() ?? '',
                          pronunciation: row['pronunciation']?.toString() ?? '',
                        );
                      }).toList();

                      await TtsAudioCache.instance.deleteCourseAudioCache(
                        courseId: course.id,
                      );

                      await TtsAudioCache.instance.prepareCourseAudio(
                        items: items,
                        languageCode: newLanguageCode,
                        courseId: course.id,
                      );
                    }

                    if (!mounted) return;

                    Navigator.pop(dialogContext);
                    await this.loadCourses(showLoading: false);
                    if (SupabaseConfig.isLoggedIn) {
                      unawaited(
                        SupabaseSyncService.instance.syncPendingChanges(),
                      );
                    }
                    this.showHomeMessage(
                      languageChanged
                          ? "Đã đổi ngôn ngữ và tạo lại âm thanh"
                          : "Đã sửa học phần",
                    );
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Color(0xfff8fafc),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  child: Text(
                    "Lưu",
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }


  Future<void> confirmDeleteCourse(CourseListItem course) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text("Xóa học phần"),
          content: Text("Bạn có chắc muốn xóa \"${course.title}\" không?"),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: Text("Hủy"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text("Xóa"),
            ),
          ],
        );
      },
    );

    if (result != true) return;

    try {
      final db = await AppDatabase.instance.database;
      final syncDeletion = SupabaseConfig.isLoggedIn;
      final now = DateTime.now().toIso8601String();

      await TtsAudioCache.instance.deleteCourseAudioCache(courseId: course.id);

      await db.transaction((txn) async {
        await txn.delete(
          'study_results',
          where:
              'sessionId IN (SELECT id FROM study_sessions WHERE courseId = ?) OR cardId IN (SELECT id FROM cards WHERE courseId = ?)',
          whereArgs: [course.id, course.id],
        );
        await txn.delete(
          'study_sessions',
          where: 'courseId = ?',
          whereArgs: [course.id],
        );
        await txn.delete(
          'review_states',
          where: 'cardId IN (SELECT id FROM cards WHERE courseId = ?)',
          whereArgs: [course.id],
        );
        await txn.delete(
          'card_examples',
          where: 'cardId IN (SELECT id FROM cards WHERE courseId = ?)',
          whereArgs: [course.id],
        );
        await txn.delete(
          'course_tags',
          where: 'courseId = ?',
          whereArgs: [course.id],
        );
        await txn.delete(
          'import_exports',
          where: 'courseId = ?',
          whereArgs: [course.id],
        );
        if (syncDeletion) {
          await txn.update(
            'cards',
            {'deletedAt': now, 'updatedAt': now},
            where: 'courseId = ?',
            whereArgs: [course.id],
          );
          await txn.update(
            'courses',
            {'deletedAt': now, 'updatedAt': now, 'cardCount': 0},
            where: 'id = ?',
            whereArgs: [course.id],
          );
        } else {
          await txn.delete(
            'cards',
            where: 'courseId = ?',
            whereArgs: [course.id],
          );
          await txn.delete(
            'courses',
            where: 'id = ?',
            whereArgs: [course.id],
          );
        }
      });

      await this.loadCourses(showLoading: false);
      this.showHomeMessage("Đã xóa học phần khỏi app và DB");
      if (syncDeletion && !course.hasLocalNameConflict) {
        unawaited(
          SupabaseSyncService.instance
              .deleteRemoteCourseChildren(course.id)
              .then((_) => SupabaseSyncService.instance.syncPendingChanges())
              .then((syncResult) {
            if (syncResult.hasError) {
              debugPrint('DELETE COURSE SYNC ERROR: ${syncResult.error}');
            }
          }),
        );
      }
    } catch (e) {
      this.showHomeMessage("Xóa thất bại");
      debugPrint("DELETE COURSE ERROR: $e");
    }
  }

}
