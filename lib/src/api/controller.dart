import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

typedef ReaderCommand = Future<void> Function();
typedef OpenChapterCommand = Future<void> Function(String chapterId);

/// Optional imperative controller and listenable snapshot for [TextReaderView].
class TextReaderController extends ChangeNotifier {
  TextReaderSnapshot _snapshot = const TextReaderSnapshot.initial();
  OpenChapterCommand? _openChapter;
  ReaderCommand? _nextPage;
  ReaderCommand? _previousPage;
  ReaderCommand? _nextChapter;
  ReaderCommand? _previousChapter;
  ReaderCommand? _showBookPreview;
  ReaderCommand? _toggleControls;
  ReaderCommand? _showControls;
  ReaderCommand? _hideControls;
  ReaderCommand? _refresh;

  TextReaderSnapshot get snapshot => _snapshot;

  bool get isAttached => _openChapter != null;

  Future<void> openChapter(String chapterId) =>
      _openChapter?.call(chapterId) ?? Future<void>.value();

  Future<void> nextPage() => _nextPage?.call() ?? Future<void>.value();

  Future<void> previousPage() => _previousPage?.call() ?? Future<void>.value();

  Future<void> nextChapter() => _nextChapter?.call() ?? Future<void>.value();

  Future<void> previousChapter() =>
      _previousChapter?.call() ?? Future<void>.value();

  /// Opens the metadata preview represented by chapter index `-1`.
  Future<void> showBookPreview() =>
      _showBookPreview?.call() ?? Future<void>.value();

  Future<void> toggleControls() =>
      _toggleControls?.call() ?? Future<void>.value();

  Future<void> showControls() => _showControls?.call() ?? Future<void>.value();

  Future<void> hideControls() => _hideControls?.call() ?? Future<void>.value();

  Future<void> refreshCurrentChapter() =>
      _refresh?.call() ?? Future<void>.value();

  @internal
  void bind({
    required OpenChapterCommand openChapter,
    required ReaderCommand nextPage,
    required ReaderCommand previousPage,
    required ReaderCommand nextChapter,
    required ReaderCommand previousChapter,
    required ReaderCommand showBookPreview,
    required ReaderCommand toggleControls,
    required ReaderCommand showControls,
    required ReaderCommand hideControls,
    required ReaderCommand refresh,
  }) {
    _openChapter = openChapter;
    _nextPage = nextPage;
    _previousPage = previousPage;
    _nextChapter = nextChapter;
    _previousChapter = previousChapter;
    _showBookPreview = showBookPreview;
    _toggleControls = toggleControls;
    _showControls = showControls;
    _hideControls = hideControls;
    _refresh = refresh;
  }

  @internal
  void updateSnapshot(TextReaderSnapshot value) {
    _snapshot = value;
    notifyListeners();
  }

  @internal
  void unbind() {
    _openChapter = null;
    _nextPage = null;
    _previousPage = null;
    _nextChapter = null;
    _previousChapter = null;
    _showBookPreview = null;
    _toggleControls = null;
    _showControls = null;
    _hideControls = null;
    _refresh = null;
  }
}
