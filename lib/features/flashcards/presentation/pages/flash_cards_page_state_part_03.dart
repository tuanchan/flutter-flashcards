part of flutterflashcard_main;

extension FlashCardsPageStatePart03 on _FlashCardsPageState {
  Future<void> resetMemorizedCards() async {
    try {
      final db = await AppDatabase.instance.database;
      final cardRows = await db.query(
        'cards',
        columns: ['id'],
        where: 'courseId = ? AND deletedAt IS NULL',
        whereArgs: [selectedCourseId],
      );
      final cardIds = cardRows
          .map((row) => row['id'] as int?)
          .whereType<int>()
          .toList(growable: false);

      await AppDatabase.instance.ensureSyncOutboxTable();
      await db.transaction((txn) async {
        await txn.delete(
          'review_states',
          where: '''
          cardId IN (
            SELECT id FROM cards
            WHERE courseId = ? AND deletedAt IS NULL
          )
        ''',
          whereArgs: [selectedCourseId],
        );
      });
      if (SupabaseConfig.isLoggedIn) {
        unawaited(
          SupabaseSyncService.instance
              .deleteRemoteReviewStatesForCards(cardIds),
        );
      }

      if (!mounted) return;

      setState(() {
        progressKnownCount = 0;
        progressUnknownCount = 0;
        _progressHistory.clear();
        _sessionUnknownCardIds.clear();
        currentPos = 0;
        showCompletion = false;
        isFlipped = false;
        this.rebuildVisibleOrder(resetPosition: true);
      });

      await this._finishStudySession();
      await this._startStudySessionIfNeeded();

      this.showFlashMessage("Đã đặt lại thẻ ghi nhớ");
    } catch (e) {
      this.showFlashMessage("Không đặt lại được thẻ ghi nhớ");
      debugPrint("RESET MEMORY ERROR: $e");
    }
  }


  void exitFlashCards() {
    this._finishStudySession();
    Navigator.pop(context, {'courseId': selectedCourseId});
  }


  Future<void> undoLastCard() async {
    if (_progressHistory.isEmpty) return;

    final undoItem = _progressHistory.removeLast();

    try {
      final db = await AppDatabase.instance.database;

      if (undoItem.previousReviewState == null) {
        await AppDatabase.instance.ensureSyncOutboxTable();
        await db.transaction((txn) async {
          await txn.delete(
            'review_states',
            where: 'cardId = ?',
            whereArgs: [undoItem.cardId],
          );
        });
        if (SupabaseConfig.isLoggedIn) {
          unawaited(
            SupabaseSyncService.instance.deleteRemoteReviewStatesForCards(
              [undoItem.cardId],
            ),
          );
        }
      } else {
        final restored = Map<String, Object?>.from(
          undoItem.previousReviewState!,
        );
        restored.remove('id');
        final now = DateTime.now();
        restored['updatedAt'] = now.toIso8601String();
        await AppDatabase.instance.ensureSyncOutboxTable();
        await db.transaction((txn) async {
          await txn.update(
            'review_states',
            restored,
            where: 'cardId = ?',
            whereArgs: [undoItem.cardId],
          );
        });
        if (SupabaseConfig.isLoggedIn) {
          unawaited(
            SupabaseSyncService.instance.syncReviewStatesAfterStudy(
              cardIds: [undoItem.cardId],
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("UNDO ERROR: $e");
    }

    setState(() {
      if (undoItem.known && progressKnownCount > 0) {
        progressKnownCount--;
      }
      if (!undoItem.known && progressUnknownCount > 0) {
        progressUnknownCount--;
        _sessionUnknownCardIds.remove(undoItem.cardId);
      }

      currentPos = undoItem.previousPos;
      showCompletion = undoItem.previousCompletion;
      isFlipped = false;
    });

    await this._deleteFlashStudyResult(undoItem.studyResultId, undoItem.known);
  }


  void openMicOverlay() {
    final card = currentCard;
    if (card == null) return;
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => PronunciationOverlay(
        targetText: card.term,
        subText: card.pronunciation.isNotEmpty
            ? card.pronunciation
            : card.definition,
        languageCode: this._getCourseLanguageCode(),
      ),
    );
  }


  String _getCourseLanguageCode() {
    return _languageCode;
  }


  void showFlashMessage(String text) {
    showAppToast(context, text);
  }


  void openSettingsSheet() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget settingsToggle({
              required bool value,
              required VoidCallback onTap,
            }) {
              return GestureDetector(
                onTap: () {
                  onTap();
                  setDialogState(() {});
                },
                child: AnimatedContainer(
                  duration: Duration(milliseconds: 200),
                  width: 44,
                  height: 24,
                  padding: EdgeInsets.all(2),
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: value ? Color(0xff3e5cff) : Color(0xff464650),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: value
                        ? [
                            BoxShadow(
                              color: Color(0x8c3e5cff),
                              blurRadius: 14,
                            ),
                          ]
                        : null,
                  ),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }

            Widget settingsRow({
              required String title,
              String? description,
              required bool value,
              required VoidCallback onTap,
              bool last = false,
            }) {
              return Container(
                width: double.infinity,
                padding: EdgeInsets.only(bottom: last ? 0 : 20),
                margin: EdgeInsets.only(bottom: last ? 0 : 20),
                decoration: BoxDecoration(
                  border: last
                      ? null
                      : Border(
                          bottom: BorderSide(color: Color(0x14ffffff)),
                        ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: Color(0xffe6e6f0),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (description != null) ...[
                      SizedBox(height: 6),
                      Text(
                        description,
                        style: TextStyle(
                          color: Color(0xffa0a0b0),
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                    ],
                    SizedBox(height: 10),
                    settingsToggle(value: value, onTap: onTap),
                  ],
                ),
              );
            }

            final screenHeight = MediaQuery.sizeOf(context).height;
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 520),
                child: Container(
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Color(0xff141428),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Color(0x405a78ff)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Tùy chọn',
                              style: TextStyle(
                                color: Color(0xffe6e6f0),
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Đóng',
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: Icon(
                              Icons.close_rounded,
                              color: Color(0xffe6e6f0),
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 18),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: screenHeight * 0.6),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              settingsRow(
                                title: 'Theo dõi tiến độ',
                                description:
                                    'Sắp xếp thẻ để theo dõi những gì bạn đã biết và đang học.',
                                value: progressTracking,
                                onTap: this.toggleProgressMode,
                              ),
                              settingsRow(
                                title: 'Chỉ học thuật ngữ có gắn sao',
                                value: starredOnly,
                                onTap: this.toggleStarredOnly,
                              ),
                              settingsRow(
                                title: 'Trộn thẻ',
                                value: shuffleEnabled,
                                onTap: this.toggleShuffle,
                              ),
                              settingsRow(
                                title: 'Tự động phát âm',
                                description:
                                    'Tự động đọc thuật ngữ khi đổi hoặc lật thẻ.',
                                value: autoPlayAudio,
                                onTap: this.toggleAutoPlayAudio,
                                last: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 18),
                      Divider(color: Color(0x14ffffff), height: 1),
                      SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Color(0xffe6e6f0),
                              backgroundColor: Color(0x14ffffff),
                              side: BorderSide(color: Color(0x1affffff)),
                              padding: EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Hủy',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Color(0xff3e5cff),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Lưu',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
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
      },
    );
  }
}
