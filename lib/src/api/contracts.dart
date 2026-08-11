import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Supplies book metadata, catalog pages, and chapter content asynchronously.
abstract interface class TextReaderDataSource {
  Future<ReaderBookInfo> loadBookInfo(String bookId);

  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  });

  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  );
}

/// Persists user-specific reader state without constraining the host database.
abstract interface class TextReaderStateStore {
  Future<ReaderProgress?> loadProgress(String bookId);

  Future<void> saveProgress(String bookId, ReaderProgress progress);

  Future<TextReaderPreferences?> loadPreferences();

  Future<void> savePreferences(TextReaderPreferences preferences);

  Future<List<ReaderBookmark>> loadBookmarks(String bookId);

  Future<void> addBookmark(ReaderBookmark bookmark);

  Future<void> removeBookmark(String bookId, String bookmarkId);
}

/// Optional host notifications for reader session and lifecycle events.
class ReaderObserver {
  const ReaderObserver();

  FutureOr<void> onSessionStarted(String bookId) {}

  FutureOr<void> onSessionEnded(String bookId, ReaderProgress? progress) {}

  FutureOr<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) {}

  FutureOr<void> onChapterChanged(ReaderChapterInfo chapter) {}

  FutureOr<void> onFailure(ReaderFailure failure) {}

  FutureOr<void> onExitRequested(ReaderProgress? progress) {}
}

@immutable
/// Optional capabilities that can be registered without changing core data APIs.
class ReaderExtensions {
  const ReaderExtensions({this.comments});

  final ReaderCommentsCapability? comments;
}

/// Reserved host entry point for a future comments experience.
abstract interface class ReaderCommentsCapability {
  Future<void> open(ReaderCommentTarget target);
}
