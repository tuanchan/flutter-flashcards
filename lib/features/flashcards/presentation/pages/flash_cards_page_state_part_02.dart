part of flutterflashcard_main;

extension FlashCardsPageStatePart02 on _FlashCardsPageState {
  Future<({
    Map<String, Object?>? previousReviewState,
    int studyResultId,
  })?> recordCurrentCardProgress(bool known) async {
    final card = currentCard;
    final sessionId = _studySessionId;
    if (card == null || sessionId == null || _studySessionFinished) return null;

    final now = DateTime.now();
    final operation = _flashStudyWriteTail.then((_) async {
      try {
        await AppDatabase.instance.ensureSyncOutboxTable();
        final db = await AppDatabase.instance.database;
        return await db.transaction((txn) async {
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
            isCorrect: known,
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
            rating: known ? 'Good' : 'Again',
            reviewedAt: now,
            baseRevision: (previousState?['serverRevision'] as num?)?.toInt(),
          );
          final resultId = await txn.insert('study_results', {
            'sessionId': sessionId,
            'cardId': card.id,
            'answerText': known ? 'known' : 'unknown',
            'isCorrect': known ? 1 : 0,
            'responseTimeMs': null,
            'reviewedAt': now.toIso8601String(),
          });
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
          return (
            previousReviewState: previousState,
            studyResultId: resultId,
          );
        });
      } catch (error) {
        debugPrint('RECORD FLASH PROGRESS ERROR: $error');
        return null;
      }
    });
    _flashStudyWriteTail = operation.then<void>((_) {});
    return await operation;
  }


  Future<void> playCurrentCardAudio() async {
    final card = currentCard;
    final courseId = selectedCourseId ?? widget.courseId;

    if (card == null) return;

    try {
      await TtsAudioCache.instance.playText(
        text: card.term,
        languageCode: _languageCode,
        courseId: courseId,
      );
    } catch (e) {
      this.showFlashMessage("Không phát được âm thanh");
      debugPrint("PLAY TTS ERROR: $e");
    }
  }


  void _playAutoAudioIfNeeded() {
    if (!autoPlayAudio || currentCard == null || showCompletion) return;
    Future.microtask(playCurrentCardAudio);
  }


  Future<void> openEditCardDialog() async {
    final card = currentCard;
    if (card == null) return;

    final termController = TextEditingController(text: card.term);
    final definitionController = TextEditingController(text: card.definition);
    final pronunciationController = TextEditingController(
      text: card.pronunciation,
    );

    String? errorText;
    String? geminiErrorText;
    var meaningSuggestions = <String>[];
    String? pronunciationSuggestion;
    var isGeneratingMeanings = false;
    var isDialogOpen = true;

    String cleanGeminiJson(String raw) {
      var value = raw.trim();
      if (value.startsWith('```')) {
        value = value.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
        value = value.replaceFirst(RegExp(r'\s*```$'), '');
      }
      return value.trim();
    }

    Future<void> generateMeanings(StateSetter setDialogState) async {
      final term = termController.text.trim();
      if (term.isEmpty) {
        setDialogState(() {
          geminiErrorText = 'Vui lòng nhập từ vựng trước khi tạo nghĩa.';
        });
        return;
      }

      setDialogState(() {
        isGeneratingMeanings = true;
        geminiErrorText = null;
        meaningSuggestions = <String>[];
        pronunciationSuggestion = null;
      });

      try {
        final raw = await GeminiFlashLiteClient.generateText(
          '''Chỉ dựa vào từ hoặc cụm từ ${jsonEncode(term)} thuộc ngôn ngữ $_languageCode để tạo dữ liệu học từ vựng.
Tuyệt đối không suy đoán hoặc sử dụng bất kỳ nghĩa cũ nào do người dùng đã nhập.
Tạo từ 3 đến 8 nghĩa tiếng Việt ngắn gọn, không lặp. Mỗi mục chỉ chứa nghĩa, không ghi từ loại, ngữ cảnh, giải thích hoặc chú thích trong ngoặc đơn.
Đồng thời tạo phiên âm chuẩn, ưu tiên IPA nếu ngôn ngữ này dùng IPA.
Chỉ trả về JSON đúng mẫu: {"meanings":["nghĩa 1","nghĩa 2"],"pronunciation":"phiên âm"}.''',
          maxOutputTokens: 500,
          responseMimeType: 'application/json',
        );
        final decoded = jsonDecode(cleanGeminiJson(raw));
        final source = decoded is Map<String, dynamic>
            ? decoded['meanings']
            : decoded;
        final suggestions = source is List
            ? source
                  .map(
                    (item) => item
                        .toString()
                        .replaceAll(RegExp(r'\s*\([^()]*\)'), '')
                        .replaceAll(RegExp(r'\s+'), ' ')
                        .trim(),
                  )
                  .where((item) => item.isNotEmpty)
                  .toSet()
                  .take(8)
                  .toList(growable: false)
            : <String>[];
        final pronunciation = decoded is Map<String, dynamic>
            ? decoded['pronunciation']?.toString().trim() ?? ''
            : '';

        if (!isDialogOpen || termController.text.trim() != term) return;
        setDialogState(() {
          if (suggestions.isNotEmpty) {
            definitionController.clear();
          }
          meaningSuggestions = suggestions;
          pronunciationSuggestion = pronunciation.isEmpty
              ? null
              : pronunciation;
          if (suggestions.isEmpty && pronunciation.isEmpty) {
            geminiErrorText = 'Gemini chưa trả về dữ liệu phù hợp.';
          }
        });
      } catch (e) {
        if (!isDialogOpen || termController.text.trim() != term) return;
        setDialogState(() {
          geminiErrorText = 'Không tạo được nghĩa và phiên âm: ${e.toString().replaceFirst('Exception: ', '')}';
        });
      } finally {
        if (isDialogOpen) {
          setDialogState(() => isGeneratingMeanings = false);
        }
      }
    }

    final deleteRequest = Object();
    final result = await showDialog<Object?>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.48),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget editInput({
              required TextEditingController controller,
              required String label,
              int maxLines = 1,
              ValueChanged<String>? onChanged,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      color: Color(0xffe6e6f0),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(height: 6),
                  TextField(
                    controller: controller,
                    onChanged: onChanged,
                    maxLines: maxLines,
                    minLines: maxLines,
                    style: TextStyle(
                      color: Color(0xffe6e6f0),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Color(0xff1a1a2e),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Color(0xff3c3c50)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Color(0xff5a78ff)),
                      ),
                    ),
                  ),
                ],
              );
            }

            Widget geminiActionButton({
              required String tooltip,
              required bool isLoading,
              required VoidCallback onPressed,
            }) {
              return Tooltip(
                message: tooltip,
                child: Material(
                  color: Color(0x14ffffff),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: isLoading ? null : onPressed,
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 36,
                      height: 34,
                      child: Center(
                        child: isLoading
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xff8fa2ff),
                                ),
                              )
                            : geminiColorIcon(size: 19),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Dialog(
              insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              backgroundColor: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxWidth: 560),
                padding: EdgeInsets.fromLTRB(22, 22, 22, 18),
                decoration: BoxDecoration(
                  color: Color(0xff141428),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Color(0x405a78ff)),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x8c000000),
                      blurRadius: 44,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              "Chỉnh sửa thẻ",
                              style: TextStyle(
                                color: Color(0xffe6e6f0),
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          geminiActionButton(
                            tooltip: 'Gemini tạo nghĩa và phiên âm',
                            isLoading: isGeneratingMeanings,
                            onPressed: () => generateMeanings(setDialogState),
                          ),
                          SizedBox(width: 4),
                          IconButton(
                            onPressed: () {
                              isDialogOpen = false;
                              Navigator.pop(dialogContext);
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              color: Color(0xffe6e6f0),
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      editInput(
                        controller: termController,
                        label: "Từ vựng",
                        onChanged: (_) {
                          if (meaningSuggestions.isEmpty &&
                              pronunciationSuggestion == null &&
                              geminiErrorText == null) {
                            return;
                          }
                          setDialogState(() {
                            meaningSuggestions = <String>[];
                            pronunciationSuggestion = null;
                            geminiErrorText = null;
                          });
                        },
                      ),
                      if (meaningSuggestions.isNotEmpty) ...[
                        SizedBox(height: 12),
                        Row(
                          children: [
                            Text(
                              'NGHĨA GỢI Ý TỪ GEMINI',
                              style: TextStyle(
                                color: Color(0xffe6e6f0),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Spacer(),
                            Text(
                              'Bấm + để thêm',
                              style: TextStyle(
                                color: Color(0xff969bb2),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 7),
                        ...meaningSuggestions.map((suggestion) {
                          return Padding(
                            padding: EdgeInsets.only(bottom: 7),
                            child: Container(
                              padding: EdgeInsets.only(left: 12),
                              decoration: BoxDecoration(
                                color: Color(0xff1a1a2e),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(color: Color(0xff3c3c50)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: SelectableText(
                                      suggestion,
                                      style: TextStyle(
                                        color: Color(0xffe6e6f0),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Thêm nghĩa này',
                                    onPressed: () {
                                      final current = definitionController.text
                                          .trim();
                                      final existingMeanings = current
                                          .split(RegExp(r'[,\n]'))
                                          .map((meaning) => meaning.trim())
                                          .where(
                                            (meaning) => meaning.isNotEmpty,
                                          )
                                          .toSet();
                                      if (!existingMeanings.contains(
                                        suggestion,
                                      )) {
                                        final normalizedCurrent =
                                            existingMeanings.join(', ');
                                        definitionController.text =
                                            normalizedCurrent.isEmpty
                                            ? suggestion
                                            : '$normalizedCurrent, $suggestion';
                                        definitionController.selection =
                                            TextSelection.collapsed(
                                              offset: definitionController
                                                  .text
                                                  .length,
                                            );
                                      }
                                      setDialogState(() {
                                        meaningSuggestions =
                                            meaningSuggestions
                                                .where(
                                                  (item) => item != suggestion,
                                                )
                                                .toList(growable: false);
                                      });
                                    },
                                    icon: Icon(
                                      Icons.add_rounded,
                                      color: Color(0xff8fa2ff),
                                      size: 21,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                      if (pronunciationSuggestion != null) ...[
                        SizedBox(height: 5),
                        Divider(color: Color(0xff3c3c50), height: 20),
                        Row(
                          children: [
                            Text(
                              'PHIÊN ÂM GỢI Ý TỪ GEMINI',
                              style: TextStyle(
                                color: Color(0xffe6e6f0),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Spacer(),
                            Text(
                              'Bấm + để thêm',
                              style: TextStyle(
                                color: Color(0xff969bb2),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 7),
                        Container(
                          padding: EdgeInsets.only(left: 12),
                          decoration: BoxDecoration(
                            color: Color(0xff1a1a2e),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(color: Color(0xff3c3c50)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  pronunciationSuggestion!,
                                  style: TextStyle(
                                    color: Color(0xffe6e6f0),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Thêm phiên âm này',
                                onPressed: () {
                                  pronunciationController.text =
                                      pronunciationSuggestion!;
                                  pronunciationController.selection =
                                      TextSelection.collapsed(
                                        offset:
                                            pronunciationController.text.length,
                                      );
                                  setDialogState(() {
                                    pronunciationSuggestion = null;
                                  });
                                },
                                icon: Icon(
                                  Icons.add_rounded,
                                  color: Color(0xff8fa2ff),
                                  size: 21,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      SizedBox(height: 12),
                      editInput(
                        controller: definitionController,
                        label: "Nghĩa",
                        maxLines: 4,
                      ),
                      SizedBox(height: 12),
                      editInput(
                        controller: pronunciationController,
                        label: "Phiên âm",
                      ),
                      if (geminiErrorText != null) ...[
                        SizedBox(height: 10),
                        Text(
                          geminiErrorText!,
                          style: TextStyle(
                            color: Color(0xffffb4ab),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (errorText != null) ...[
                        SizedBox(height: 10),
                        Text(
                          errorText!,
                          style: TextStyle(
                            color: Color(0xffb3261e),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                      SizedBox(height: 18),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              isDialogOpen = false;
                              Navigator.pop(dialogContext, deleteRequest);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Color(0xffff8a80),
                              padding: EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              side: BorderSide(color: Color(0x99ff5252)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: Icon(Icons.delete_outline_rounded, size: 18),
                            label: Text(
                              "Xóa",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Spacer(),
                          OutlinedButton(
                            onPressed: () {
                              isDialogOpen = false;
                              Navigator.pop(dialogContext);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Color(0xffe6e6f0),
                              backgroundColor: Color(0x14ffffff),
                              padding: EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              side: BorderSide(color: Color(0x1affffff)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              "Hủy",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                                final term = termController.text.trim();
                                final definition = definitionController.text
                                    .trim();
                                final pronunciation = pronunciationController
                                    .text
                                    .trim();

                                if (term.isEmpty) {
                                  setDialogState(() {
                                    errorText = "Vui lòng nhập thuật ngữ";
                                  });
                                  return;
                                }

                                if (definition.isEmpty) {
                                  setDialogState(() {
                                    errorText = "Vui lòng nhập định nghĩa";
                                  });
                                  return;
                                }

                                isDialogOpen = false;
                                Navigator.pop(
                                  dialogContext,
                                  card.copyWith(
                                    term: term,
                                    definition: definition,
                                    pronunciation: pronunciation,
                                  ),
                                );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Color(0xff3e5cff),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 10,
                              ),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              "Lưu",
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

    isDialogOpen = false;
    termController.dispose();
    definitionController.dispose();
    pronunciationController.dispose();

    if (identical(result, deleteRequest)) {
      await this.deleteCurrentCard();
      return;
    }
    if (result is! StudyCardItem) return;

    try {
      final db = await AppDatabase.instance.database;

      final rawText = result.pronunciation.trim().isEmpty
          ? '${result.term}\t${result.definition}'
          : '${result.term}\t${result.definition} (${result.pronunciation})';

      await db.update(
        'cards',
        {
          'term': result.term,
          'definition': result.definition,
          'pronunciation': result.pronunciation,
          'rawText': rawText,
          'updatedAt': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [result.id],
      );
      if (SupabaseConfig.isLoggedIn) {
        unawaited(SupabaseSyncService.instance.syncPendingChanges());
      }

      if (!mounted) return;

      setState(() {
        final index = allCards.indexWhere((e) => e.id == result.id);
        if (index >= 0) {
          allCards[index] = result;
        }
      });

      await TtsAudioCache.instance.ensureAudioForText(
        text: result.term,
        languageCode: _languageCode,
        courseId: result.courseId,
      );

      this.showFlashMessage("Đã sửa thẻ");
    } catch (e) {
      this.showFlashMessage("Sửa thẻ thất bại");
      debugPrint("EDIT CARD ERROR: $e");
    }
  }


  void toggleShuffle() {
    setState(() {
      shuffleEnabled = !shuffleEnabled;
      this.rebuildVisibleOrder(resetPosition: true);
      this.resetFlip();
    });
    this.saveFlashSettings();
  }


  void toggleStarredOnly() {
    setState(() {
      starredOnly = !starredOnly;
      this.rebuildVisibleOrder(resetPosition: true);
      this.resetFlip();
    });
    this.saveFlashSettings();
  }


  Future<void> toggleProgressMode() async {
    if (widget.dueOnly) {
      this.showFlashMessage("Ôn thẻ đến hạn luôn bật theo dõi SRS");
      return;
    }

    final nextValue = !progressTracking;

    await this._finishStudySession();

    setState(() {
      progressTracking = nextValue;
      currentPos = 0;
      showCompletion = false;
      progressKnownCount = 0;
      progressUnknownCount = 0;
      _progressHistory.clear();
      _sessionUnknownCardIds.clear();
      this.rebuildVisibleOrder(resetPosition: true);
      this.resetFlip();
    });

    await this.saveFlashSettings();

    if (progressTracking) {
      await this._startStudySessionIfNeeded();
    }
  }


  void toggleAutoPlayAudio() {
    setState(() {
      autoPlayAudio = !autoPlayAudio;
    });
    this.saveFlashSettings();
    this._playAutoAudioIfNeeded();
  }


  Future<void> restartStudy() async {
    await this._finishStudySession();
    setState(() {
      currentPos = 0;
      showCompletion = false;
      progressKnownCount = 0;
      progressUnknownCount = 0;
      _progressHistory.clear();
      _sessionUnknownCardIds.clear();
      this.rebuildVisibleOrder(resetPosition: true);
      this.resetFlip();
    });
    await this._startStudySessionIfNeeded();
  }


  Future<void> restartUnknownCards() async {
    if (_sessionUnknownCardIds.isEmpty) {
      this.showFlashMessage("Không có thẻ chưa thuộc để học lại");
      return;
    }

    final unknownIndices = <int>[];

    for (int i = 0; i < allCards.length; i++) {
      if (_sessionUnknownCardIds.contains(allCards[i].id)) {
        unknownIndices.add(i);
      }
    }

    if (unknownIndices.isEmpty) {
      this.showFlashMessage("Không tìm thấy thẻ chưa thuộc");
      return;
    }

    await this._finishStudySession();

    setState(() {
      visibleOrder = unknownIndices;
      currentPos = 0;
      showCompletion = false;
      progressKnownCount = 0;
      progressUnknownCount = 0;
      _progressHistory.clear();
      _sessionUnknownCardIds.clear();
      isFlipped = false;
    });
    await this._startStudySessionIfNeeded();
  }

}
