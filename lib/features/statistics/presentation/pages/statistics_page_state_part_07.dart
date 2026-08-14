part of flutterflashcard_main;

extension StatisticsPageStatePart07 on _StatisticsPageState {
  Widget _buildInlineSrsManager(StatisticsData data) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: _dashPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _dashBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final title = Text(
                'QUẢN LÝ SRS & THẺ ĐẾN HẠN',
                style: TextStyle(
                  color: _dashText,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              );
              final actions = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  this._srsActionButton(
                    text: 'Ôn thẻ đến hạn',
                    onTap: this._openAllDueFlashcards,
                  ),
                  this._srsActionButton(
                    text: 'Kiểm tra thẻ đến hạn',
                    onTap: this._openAllDueTest,
                  ),
                ],
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, SizedBox(height: 12), actions],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  actions,
                ],
              );
            },
          ),
          SizedBox(height: 10),
          Divider(color: _dashBorder.withOpacity(0.35), height: 1),
          SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final search = TextField(
                controller: _srsSearchController,
                onChanged: (_) => setState(() {}),
                style: TextStyle(color: _dashText, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: 'Tìm học phần, từ vựng, nghĩa...',
                  hintStyle: TextStyle(color: _dashMuted),
                  prefixIcon: Icon(Icons.search_rounded, color: _dashMuted),
                  suffixIcon: _srsSearchController.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _srsSearchController.clear();
                            setState(() {});
                          },
                          icon: Icon(Icons.close_rounded, color: _dashMuted),
                        ),
                  filled: true,
                  fillColor: _dashPanel2,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(color: _dashBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(color: _dashBlue),
                  ),
                ),
              );
              final dueToggle = ValueListenableBuilder<bool>(
                valueListenable: _srsOnlyDueTodayNotifier,
                builder: (context, onlyDueToday, _) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: onlyDueToday,
                        onChanged: (value) {
                          _srsOnlyDueTodayNotifier.value = value ?? false;
                        },
                        activeColor: _dashBlue,
                        checkColor: Colors.white,
                        side: BorderSide(color: _dashBorder),
                        visualDensity: VisualDensity.compact,
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          _srsOnlyDueTodayNotifier.value = !onlyDueToday;
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 8,
                          ),
                          child: Text(
                            'Chỉ thẻ đến hạn hôm nay',
                            style: TextStyle(
                              color: _dashText,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
              if (constraints.maxWidth < 680) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [search, SizedBox(height: 6), dueToggle],
                );
              }
              return Row(
                children: [
                  Expanded(child: search),
                  SizedBox(width: 10),
                  dueToggle,
                ],
              );
            },
          ),
          SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable: _srsOnlyDueTodayNotifier,
            builder: (context, onlyDueToday, _) {
              return FutureBuilder<List<_SrsEditorItem>>(
                future: _srsManagerFuture,
                builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return SizedBox(
                  height: 160,
                  child: Center(
                    child: CircularProgressIndicator(color: _dashBlue),
                  ),
                );
              }
              if (snapshot.hasError) {
                return this._dashEmpty('Không tải được dữ liệu quản lý SRS');
              }

              final allItems = snapshot.data ?? [];
              final filtered = this._filterSrsManagerItems(
                allItems,
                onlyDueToday: onlyDueToday,
              );
              if (filtered.isEmpty) {
                return SizedBox(
                  height: 110,
                  child: Center(
                    child: this._dashEmpty(
                      onlyDueToday
                          ? 'Không có thẻ đến hạn phù hợp'
                          : 'Không có từ vựng phù hợp',
                    ),
                  ),
                );
              }

              final allItemsByCourse = <int, List<_SrsEditorItem>>{};
              for (final item in allItems) {
                (allItemsByCourse[item.courseId] ??= []).add(item);
              }
              final visibleItemsByCourse = <int, List<_SrsEditorItem>>{};
              for (final item in filtered) {
                (visibleItemsByCourse[item.courseId] ??= []).add(item);
              }
              final courses = this
                  ._buildSrsEditorCourses(allItems)
                  .where(
                    (course) => visibleItemsByCourse.containsKey(course.id),
                  )
                  .toList();
              return ListView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: courses.length,
                itemBuilder: (context, index) {
                  final course = courses[index];
                  final allCourseItems =
                      allItemsByCourse[course.id] ?? <_SrsEditorItem>[];
                  final visibleItems =
                      visibleItemsByCourse[course.id] ?? <_SrsEditorItem>[];
                  return this._buildInlineSrsCourse(
                    course,
                    allCourseItems,
                    visibleItems,
                  );
                },
              );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  List<_SrsEditorItem> _filterSrsManagerItems(
    List<_SrsEditorItem> items, {
    required bool onlyDueToday,
  }) {
    final query = normalizeText(_srsSearchController.text.trim());
    final now = DateTime.now();
    final tomorrow = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(getDuration(days: 1));
    return items.where((item) {
      if (onlyDueToday) {
        final due = DateTime.tryParse(item.nextReviewAt);
        if (item.repetitionCount <= 0 ||
            due == null ||
            !due.isBefore(tomorrow)) {
          return false;
        }
      } else {
        if (item.repetitionCount <= 0) {
          return false;
        }
      }
      if (query.isEmpty) return true;
      final haystack = normalizeText(
        '${item.courseTitle} ${item.term} ${item.definition}',
      );
      return haystack.contains(query);
    }).toList();
  }

  Widget _buildInlineSrsCourse(
    _SrsEditorCourse course,
    List<_SrsEditorItem> allItems,
    List<_SrsEditorItem> visibleItems,
  ) {
    final expanded = _expandedCourseIds.contains(course.id);
    final first = allItems.first;
    final defaultDate = DateTime.tryParse(first.nextReviewAt) ?? DateTime.now();
    final level = _courseSrsLevelDraft.putIfAbsent(
      course.id,
      () => first.level,
    );
    final date = _courseSrsDateDraft.putIfAbsent(
      course.id,
      () => DateTime(defaultDate.year, defaultDate.month, defaultDate.day),
    );

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _dashPanel2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _dashBorder.withOpacity(0.82)),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final identity = InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() {
                      expanded
                          ? _expandedCourseIds.remove(course.id)
                          : _expandedCourseIds.add(course.id);
                    });
                  },
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: Duration(milliseconds: 160),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 15,
                            color: _dashBlue,
                          ),
                        ),
                        SizedBox(width: 10),
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
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                '${course.cardCount} thẻ • đã ôn ${course.reviewedCount} • đến hạn ${course.dueCount}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _dashMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                return Row(
                  children: [
                    Expanded(child: identity),
                    SizedBox(width: 8),
                    this._buildCourseSrsEditMenu(
                      course: course,
                      allItems: allItems,
                      visibleItems: visibleItems,
                      level: level,
                      date: date,
                    ),
                  ],
                );
              },
            ),
          ),
          AnimatedCrossFade(
            firstChild: SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: _dashBorder.withOpacity(0.5)),
                ),
              ),
              child: Column(
                children: visibleItems
                    .map((item) => _InlineSrsCardWidget(
                          key: ValueKey(item.cardId),
                          course: course,
                          item: item,
                          onRefresh: () => this._refreshSrsManager(),
                          onOpenSrsFlashcards: this._openSrsFlashcards,
                          onOpenSrsTest: this._openSrsTest,
                          onOpenSrsDeepLearn: this._openSrsDeepLearn,
                          onDeleteCard: this._deleteCard,
                          onClearCardSrs: this._clearCardSrs,
                          onSaveCardSrs: this._saveCardSrs,
                        ))
                    .toList(),
              ),
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }

  Widget _buildCourseSrsEditMenu({
    required _SrsEditorCourse course,
    required List<_SrsEditorItem> allItems,
    required List<_SrsEditorItem> visibleItems,
    required int level,
    required DateTime date,
  }) {
    PopupMenuItem<String> menuItem({
      required String value,
      required IconData icon,
      required String label,
      bool danger = false,
    }) {
      final color = danger ? _dashRed : _dashText;
      return PopupMenuItem<String>(
        value: value,
        height: 40,
        child: Row(
          children: [
            Icon(icon, size: 17, color: color),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Chỉnh sửa SRS học phần',
      color: _dashPanel2,
      elevation: 12,
      offset: Offset(0, 34),
      constraints: BoxConstraints(minWidth: 220, maxWidth: 270),
      onSelected: (action) async {
        switch (action) {
          case 'level':
            await this._pickCourseSrsLevel(course.id, level);
            break;
          case 'date':
            await this._pickCourseSrsDate(course.id, date);
            break;
          case 'review':
            await this._openSrsFlashcards(course, visibleItems);
            break;
          case 'test':
            await this._openSrsTest(course, visibleItems);
            break;
          case 'deep':
            await this._openSrsDeepLearn(course, visibleItems);
            break;
          case 'apply':
            await this._applySrsToCourse(
              course,
              allItems,
              _courseSrsLevelDraft[course.id] ?? level,
              _courseSrsDateDraft[course.id] ?? date,
            );
            break;
          case 'delete':
            await this._deleteCourseSrs(course, allItems);
            break;
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        menuItem(
          value: 'level',
          icon: Icons.stairs_rounded,
          label: 'Cấp độ SRS: $level',
        ),
        menuItem(
          value: 'date',
          icon: Icons.calendar_month_rounded,
          label: 'Đến hạn: ${this._formatCompactDate(date)}',
        ),
        PopupMenuDivider(height: 8),
        menuItem(
          value: 'review',
          icon: Icons.style_rounded,
          label: 'Ôn riêng',
        ),
        menuItem(
          value: 'test',
          icon: Icons.quiz_rounded,
          label: 'Kiểm tra',
        ),
        menuItem(
          value: 'deep',
          icon: Icons.psychology_rounded,
          label: 'Chuyên sâu',
        ),
        menuItem(
          value: 'apply',
          icon: Icons.save_rounded,
          label: 'SRS cả học phần',
        ),
        menuItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: 'Xóa SRS học phần',
          danger: true,
        ),
      ],
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: _dashPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _dashBorder),
        ),
        child: Icon(
          Icons.edit_rounded,
          size: 17,
          color: _dashBlue,
        ),
      ),
    );
  }

  Widget _srsActionButton({required String text, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: Container(
        height: 24,
        padding: EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Color(0xff202735),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: _dashBorder.withOpacity(0.28)),
        ),
        child: Align(
          widthFactor: 1,
          alignment: Alignment.center,
          child: Text(
            text,
            style: TextStyle(
              color: _dashText,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _srsIconButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _dashPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _dashBorder),
        ),
        child: Icon(icon, color: _dashText, size: 18),
      ),
    );
  }

  String _formatCompactDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.month)}/${two(date.day)}/${date.year}';
  }

  Future<void> _pickCourseSrsLevel(int courseId, int current) async {
    final value = await this._showSrsLevelDialog(current);
    if (!mounted || value == null) return;
    setState(() => _courseSrsLevelDraft[courseId] = value);
  }

  Future<int?> _showSrsLevelDialog(int current) {
    var value = current.clamp(0, 8).toInt();
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _dashPanel,
          title: Text('Chọn cấp độ SRS', style: TextStyle(color: _dashText)),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              this._srsIconButton(
                Icons.remove_rounded,
                () => setDialogState(() => value = math.max(0, value - 1)),
              ),
              SizedBox(width: 18),
              Text(
                '$value',
                style: TextStyle(
                  color: _dashText,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(width: 18),
              this._srsIconButton(
                Icons.add_rounded,
                () => setDialogState(() => value = math.min(8, value + 1)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Hủy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: Text('Chọn'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCourseSrsDate(int courseId, DateTime current) async {
    final picked = await this._showSrsDatePicker(current);
    if (!mounted || picked == null) return;
    setState(() => _courseSrsDateDraft[courseId] = picked);
  }

  Future<DateTime?> _showSrsDatePicker(DateTime initial) {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.dark(
            primary: _dashBlue,
            surface: _dashPanel,
            onSurface: _dashText,
          ),
        ),
        child: child!,
      ),
    );
  }

  Future<void> _changeCardSrs(_SrsEditorItem item, int delta) async {
    await this._changeSrsLevel(item, delta);
    this._refreshSrsManager();
  }

  Future<void> _pickCardSrsDate(_SrsEditorItem item) async {
    final initial = DateTime.tryParse(item.nextReviewAt) ?? DateTime.now();
    final picked = await this._showSrsDatePicker(initial);
    if (picked == null) return;
    await this._setSrsDueDate(item, picked);
    this._refreshSrsManager();
  }

  Future<void> _applySrsToCourse(
    _SrsEditorCourse course,
    List<_SrsEditorItem> items,
    int level,
    DateTime date,
  ) async {
    final confirmed = await this._confirmSrsAction(
      'Áp dụng SRS cấp $level và hạn ${this._formatCompactDate(date)} cho ${items.length} thẻ trong “${course.title}”?',
      confirmText: 'Áp dụng',
    );
    if (confirmed != true) return;
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final interval = math.max(0, target.difference(today).inDays);
    await db.transaction((txn) async {
      for (final item in items) {
        await this._upsertSrsStateOn(
          txn,
          cardId: item.cardId,
          level: level,
          easeFactor: null,
          intervalDays: interval,
          repetitionCount: level > 0 ? math.max(1, item.repetitionCount) : 0,
          correctCount: null,
          wrongCount: null,
          lastReviewedAt: null,
          nextReviewAt: target,
        );
      }
    });
    SyncResult? syncResult;
    if (SupabaseConfig.isLoggedIn) {
      syncResult = await SupabaseSyncService.instance.syncReviewStatesAfterStudy(
        cardIds: items.map((item) => item.cardId),
      );
    }
    if (!mounted) return;
    if (syncResult?.hasError == true) {
      showAppToast(context, 'Đã lưu local nhưng lỗi đẩy SRS: ${syncResult!.error}');
    } else {
      showAppToast(context, 'Đã cập nhật SRS cho ${items.length} thẻ');
    }
    this._refreshSrsManager();
  }

  Future<void> _deleteCourseSrs(
    _SrsEditorCourse course,
    List<_SrsEditorItem> items,
  ) async {
    final confirmed = await this._confirmSrsAction(
      'Xóa toàn bộ tiến độ SRS của ${items.length} thẻ trong “${course.title}”?',
      confirmText: 'Xóa SRS',
    );
    if (confirmed != true) return;
    final db = await AppDatabase.instance.database;
    final ids = items.map((item) => item.cardId).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      'review_states',
      where: 'cardId IN ($placeholders)',
      whereArgs: ids,
    );

    if (SupabaseConfig.isLoggedIn) {
      try {
        await SupabaseSyncService.instance
            .deleteRemoteReviewStatesForCards(ids);
      } catch (e) {
        debugPrint('DELETE REMOTE COURSE SRS ERROR: $e');
      }
    }

    if (!mounted) return;
    showAppToast(context, 'Đã xóa SRS học phần ${course.title}');
    this._refreshSrsManager();
  }

  Future<bool?> _confirmSrsAction(
    String message, {
    required String confirmText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _dashPanel,
        title: Text('Xác nhận', style: TextStyle(color: _dashText)),
        content: Text(
          message,
          style: TextStyle(color: _dashMuted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  void _refreshSrsManager() {
    if (!mounted) return;
    setState(() {
      _courseSrsLevelDraft.clear();
      _courseSrsDateDraft.clear();
      _future = this.loadStatistics();
      _srsManagerFuture = this._loadSrsEditorItems();
    });
  }

  Future<void> _openAllDueFlashcards() async {
    final info = await _loadDueReviewLaunchInfo();
    if (!mounted) return;
    if (info == null) {
      showAppToast(context, 'Hôm nay chưa có thẻ đến hạn');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FlashCardsPage(
          courseId: info.courseId,
          courseTitle: 'Thẻ đến hạn hôm nay',
          dueOnly: true,
        ),
      ),
    );
    this._refreshSrsManager();
  }

  Future<void> _openAllDueTest() async {
    final info = await _loadDueReviewLaunchInfo();
    if (!mounted) return;
    if (info == null) {
      showAppToast(context, 'Hôm nay chưa có thẻ đến hạn');
      return;
    }
    final preset = await _showDueReviewSetupDialog(context, info);
    if (!mounted || preset == null) return;
    if (preset == 'deepLearn') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeepLearnPage(
            courseId: info.courseId,
            courseTitle: 'Học chuyên sâu thẻ đến hạn hôm nay',
            courseLanguageCode: info.languageCode,
            dueOnly: true,
          ),
        ),
      );
      this._refreshSrsManager();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewPracticePage(
          courseId: info.courseId,
          courseTitle: 'Kiểm tra thẻ đến hạn hôm nay',
          courseLanguageCode: info.languageCode,
          dueOnly: true,
          presetMode: preset,
        ),
      ),
    );
    this._refreshSrsManager();
  }

  Future<void> _openSrsFlashcards(
    _SrsEditorCourse course,
    List<_SrsEditorItem> items,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FlashCardsPage(
          courseId: course.id,
          courseTitle: course.title,
          dueOnly: true,
          cardIds: items.map((item) => item.cardId).toList(),
        ),
      ),
    );
    this._refreshSrsManager();
  }

  Future<void> _openSrsTest(
    _SrsEditorCourse course,
    List<_SrsEditorItem> items,
  ) async {
    final info = _DueReviewLaunchInfo(
      count: items.length,
      courseId: course.id,
      courseTitle: course.title,
      languageCode: course.languageCode,
    );
    final preset = await _showDueReviewSetupDialog(
      context,
      info,
      title: 'Thiết lập bài kiểm tra',
      subtitle: items.length == 1
          ? 'Kiểm tra riêng từ “${items.first.term}”'
          : '${items.length} thẻ trong ${course.title}',
    );
    if (!mounted || preset == null) return;
    if (preset == 'deepLearn') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeepLearnPage(
            courseId: course.id,
            courseTitle: course.title,
            courseLanguageCode: course.languageCode,
            cardIds: items.map((item) => item.cardId).toList(),
          ),
        ),
      );
      this._refreshSrsManager();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewPracticePage(
          courseId: course.id,
          courseTitle: course.title,
          courseLanguageCode: course.languageCode,
          dueOnly: true,
          presetMode: preset,
          cardIds: items.map((item) => item.cardId).toList(),
        ),
      ),
    );
    this._refreshSrsManager();
  }

  Future<void> _openSrsDeepLearn(
    _SrsEditorCourse course,
    List<_SrsEditorItem> items,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeepLearnPage(
          courseId: course.id,
          courseTitle: course.title,
          courseLanguageCode: course.languageCode,
          cardIds: items.map((item) => item.cardId).toList(),
        ),
      ),
    );
    this._refreshSrsManager();
  }

  Future<void> _saveCardSrs({
    required int cardId,
    required int level,
    required DateTime? dueDate,
    required int reviews,
    required int lapses,
  }) async {
    await AppDatabase.instance.ensureSyncOutboxTable();
    final db = await AppDatabase.instance.database;
    final nowIso = DateTime.now().toIso8601String();
    final rows = await db.query(
      'review_states',
      where: 'cardId = ?',
      whereArgs: [cardId],
      limit: 1,
    );
    final nextLevel = level.clamp(0, 8).toInt();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final normalizedDueDate = dueDate == null
        ? null
        : DateTime(dueDate.year, dueDate.month, dueDate.day);
    final effectiveDueDate = normalizedDueDate ??
        (nextLevel > 0
            ? today.add(
                Duration(
                  days: ReviewScheduler.intervalDaysForLevel(nextLevel),
                ),
              )
            : null);
    final interval = effectiveDueDate == null
        ? 0
        : math.max(0, effectiveDueDate.difference(today).inDays);
    final effectiveReviews = nextLevel > 0
        ? math.max(1, reviews)
        : math.max(0, reviews);
        
    final values = <String, Object?>{
      'cardId': cardId,
      'level': nextLevel,
      'easeFactor': rows.isEmpty ? 2.5 : _dbDouble(rows.first['easeFactor'], 2.5),
      'intervalDays': interval,
      'repetitionCount': effectiveReviews,
      'correctCount': rows.isEmpty ? 0 : _dbInt(rows.first['correctCount']),
      'wrongCount': math.max(0, lapses),
      'lastReviewedAt': effectiveReviews > 0
          ? (rows.isEmpty || rows.first['lastReviewedAt'] == null ? nowIso : rows.first['lastReviewedAt']?.toString())
          : null,
      'nextReviewAt': effectiveDueDate?.toIso8601String(),
      'updatedAt': nowIso,
    };
    
    await db.transaction((txn) async {
      if (rows.isEmpty) {
        values['createdAt'] = nowIso;
        await txn.insert('review_states', values);
      } else {
        await txn.update(
          'review_states',
          values,
          where: 'cardId = ?',
          whereArgs: [cardId],
        );
      }
    });
    
    if (SupabaseConfig.isLoggedIn) {
      unawaited(
        SupabaseSyncService.instance
            .syncReviewStatesAfterStudy(cardIds: [cardId])
            .then((syncResult) {
          if (syncResult.hasError) {
            debugPrint('SAVE CARD SRS SYNC ERROR: ${syncResult.error}');
          }
        }),
      );
    }
  }

  Future<void> _clearCardSrs(int cardId) async {
    final db = await AppDatabase.instance.database;
    await db.delete(
      'review_states',
      where: 'cardId = ?',
      whereArgs: [cardId],
    );
    
    if (SupabaseConfig.isLoggedIn) {
      try {
        await SupabaseSyncService.instance
            .deleteRemoteReviewStatesForCards([cardId]);
      } catch (e) {
        debugPrint('DELETE REMOTE SRS ERROR: $e');
      }
    }
  }

  Future<void> _deleteCard(int cardId) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toIso8601String();
    
    if (SupabaseConfig.isLoggedIn) {
      await db.update(
        'cards',
        {'deletedAt': now, 'updatedAt': now},
        where: 'id = ?',
        whereArgs: [cardId],
      );
    } else {
      await db.delete(
        'cards',
        where: 'id = ?',
        whereArgs: [cardId],
      );
    }
    
    // Also delete review state for the card
    await db.delete(
      'review_states',
      where: 'cardId = ?',
      whereArgs: [cardId],
    );
    
    if (SupabaseConfig.isLoggedIn) {
      unawaited(
        SupabaseSyncService.instance.syncPendingChanges().then((syncResult) {
          if (syncResult.hasError) {
            debugPrint('DELETE CARD SYNC ERROR: ${syncResult.error}');
          }
        }),
      );
    }
  }
}

class _InlineSrsCardWidget extends StatefulWidget {
  final _SrsEditorCourse course;
  final _SrsEditorItem item;
  final VoidCallback onRefresh;
  final Future<void> Function(_SrsEditorCourse, List<_SrsEditorItem>) onOpenSrsFlashcards;
  final Future<void> Function(_SrsEditorCourse, List<_SrsEditorItem>) onOpenSrsTest;
  final Future<void> Function(_SrsEditorCourse, List<_SrsEditorItem>) onOpenSrsDeepLearn;
  final Future<void> Function(int) onDeleteCard;
  final Future<void> Function(int) onClearCardSrs;
  final Future<void> Function({
    required int cardId,
    required int level,
    required DateTime? dueDate,
    required int reviews,
    required int lapses,
  }) onSaveCardSrs;

  const _InlineSrsCardWidget({
    Key? key,
    required this.course,
    required this.item,
    required this.onRefresh,
    required this.onOpenSrsFlashcards,
    required this.onOpenSrsTest,
    required this.onOpenSrsDeepLearn,
    required this.onDeleteCard,
    required this.onClearCardSrs,
    required this.onSaveCardSrs,
  }) : super(key: key);

  @override
  State<_InlineSrsCardWidget> createState() => _InlineSrsCardWidgetState();
}

class _InlineSrsCardWidgetState extends State<_InlineSrsCardWidget> {
  late TextEditingController _levelController;
  late TextEditingController _reviewsController;
  late TextEditingController _lapsesController;
  DateTime? _dueDate;

  @override
  void initState() {
    super.initState();
    _initFields();
  }

  @override
  void didUpdateWidget(covariant _InlineSrsCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.cardId != widget.item.cardId ||
        oldWidget.item.level != widget.item.level ||
        oldWidget.item.repetitionCount != widget.item.repetitionCount ||
        oldWidget.item.wrongCount != widget.item.wrongCount ||
        oldWidget.item.nextReviewAt != widget.item.nextReviewAt) {
      _levelController.dispose();
      _reviewsController.dispose();
      _lapsesController.dispose();
      _initFields();
    }
  }

  void _initFields() {
    _levelController = TextEditingController(text: '${widget.item.level}');
    _reviewsController = TextEditingController(text: '${widget.item.repetitionCount}');
    _lapsesController = TextEditingController(text: '${widget.item.wrongCount}');
    _dueDate = DateTime.tryParse(widget.item.nextReviewAt);
  }

  @override
  void dispose() {
    _levelController.dispose();
    _reviewsController.dispose();
    _lapsesController.dispose();
    super.dispose();
  }

  Widget _buildInputControl(String label, Widget child, {double? width}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xff8e92a2),
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 30,
          child: child,
        ),
      ],
    );
    if (width != null) {
      return SizedBox(width: width, child: content);
    }
    return content;
  }

  Widget _buildTextField(TextEditingController controller, TextInputType keyboardType) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(
        color: Color(0xfff8fbff),
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
      cursorColor: _dashBlue,
      decoration: InputDecoration(
        filled: true,
        fillColor: const Color(0xdd0c1222),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: Color(0x784d5b81)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: _dashBlue),
        ),
      ),
    );
  }

  Widget _buildDatePickerControl(BuildContext context) {
    final text = _dueDate == null 
        ? '' 
        : '${_dueDate!.year}-${_dueDate!.month.toString().padLeft(2, '0')}-${_dueDate!.day.toString().padLeft(2, '0')}';
        
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: _dueDate ?? now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 10),
          builder: (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.dark(
                primary: _dashBlue,
                surface: _dashPanel,
                onSurface: _dashText,
              ),
            ),
            child: child!,
          ),
        );
        if (picked != null) {
          setState(() {
            _dueDate = picked;
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0xdd0c1222),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0x784d5b81)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xfff8fbff),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Icon(Icons.calendar_month_rounded, color: Color(0xff8e92a2), size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required String text,
    required VoidCallback onTap,
    required bool isDanger,
  }) {
    final bgColor = isDanger ? const Color(0x29ef4444) : const Color(0x2e3e5cff);
    final borderColor = isDanger ? const Color(0x61ef4444) : const Color(0x615e81d7);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Align(
          widthFactor: 1,
          alignment: Alignment.center,
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xffeaf0ff),
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final due = DateTime.tryParse(widget.item.nextReviewAt);
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final isDue = widget.item.repetitionCount > 0 && due != null && due.isBefore(tomorrow);

    final rowBg = isDue
        ? const Color(0x0eefaf0b) // Amber hue for due card
        : const Color(0x05ffffff); // Muted dark for non-due card

    return Container(
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: rowBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _dashBorder.withOpacity(0.2)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final infoColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.term,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (widget.item.pronunciation != null && widget.item.pronunciation!.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  widget.item.pronunciation!,
                  style: const TextStyle(
                    color: Color(0xff8e92a2),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                widget.item.definition,
                style: const TextStyle(
                  color: Color(0xffa8b6d6),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );

          final controlsRow = Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _buildInputControl('Lv', _buildTextField(_levelController, TextInputType.number), width: 64),
              _buildInputControl('Đến hạn', _buildDatePickerControl(context), width: 140),
              _buildInputControl('Lượt ôn', _buildTextField(_reviewsController, TextInputType.number), width: 82),
              _buildInputControl('Sai', _buildTextField(_lapsesController, TextInputType.number), width: 70),
            ],
          );

          final actionsRow = Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _buildButton(
                text: 'Ôn từ',
                isDanger: false,
                onTap: () => widget.onOpenSrsFlashcards(widget.course, [widget.item]),
              ),
              _buildButton(
                text: 'Kiểm tra',
                isDanger: false,
                onTap: () => widget.onOpenSrsTest(widget.course, [widget.item]),
              ),
              _buildButton(
                text: 'Chuyên sâu',
                isDanger: false,
                onTap: () => widget.onOpenSrsDeepLearn(widget.course, [widget.item]),
              ),
              _buildButton(
                text: 'Lưu SRS',
                isDanger: false,
                onTap: () async {
                  final lv = int.tryParse(_levelController.text) ?? 0;
                  final rev = int.tryParse(_reviewsController.text) ?? 0;
                  final lap = int.tryParse(_lapsesController.text) ?? 0;
                  await widget.onSaveCardSrs(
                    cardId: widget.item.cardId,
                    level: lv,
                    dueDate: _dueDate,
                    reviews: rev,
                    lapses: lap,
                  );
                  if (context.mounted) {
                    showAppToast(context, 'Đã lưu SRS cho thẻ');
                  }
                  widget.onRefresh();
                },
              ),
              _buildButton(
                text: 'Xóa SRS',
                isDanger: false,
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      backgroundColor: _dashPanel,
                      title: const Text('Xác nhận', style: TextStyle(color: _dashText)),
                      content: Text(
                        'Xóa tiến độ SRS của từ “${widget.item.term}”?',
                        style: const TextStyle(color: _dashMuted, height: 1.4),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Hủy'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Xóa SRS'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.onClearCardSrs(widget.item.cardId);
                    if (context.mounted) {
                      showAppToast(context, 'Đã xóa tiến độ SRS');
                    }
                    widget.onRefresh();
                  }
                },
              ),
              _buildButton(
                text: 'Xóa từ',
                isDanger: true,
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      backgroundColor: _dashPanel,
                      title: const Text('Xác nhận', style: TextStyle(color: _dashText)),
                      content: Text(
                        'Xóa hoàn toàn từ “${widget.item.term}” khỏi học phần?',
                        style: const TextStyle(color: _dashMuted, height: 1.4),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Hủy'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Xóa từ', style: TextStyle(color: _dashRed)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.onDeleteCard(widget.item.cardId);
                    if (context.mounted) {
                      showAppToast(context, 'Đã xóa từ vựng');
                    }
                    widget.onRefresh();
                  }
                },
              ),
            ],
          );

          if (constraints.maxWidth < 800) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                infoColumn,
                const SizedBox(height: 10),
                controlsRow,
                const SizedBox(height: 10),
                actionsRow,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: infoColumn),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: controlsRow),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: Align(alignment: Alignment.topRight, child: actionsRow)),
            ],
          );
        },
      ),
    );
  }
}
