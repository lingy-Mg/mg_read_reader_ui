import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Built-in reader color themes. Hosts persist the value but do not style it.
enum ReaderThemePreset { day, eyeCare, parchment, night }

/// Built-in cross-platform font families.
enum ReaderFontPreset { system, sansSerif, serif }

/// Available text navigation modes.
enum ReaderNavigationMode { horizontalPages, verticalScroll }

/// Animation used for horizontal page navigation.
enum ReaderPageAnimation { slide, none }

/// Platform lifecycle states normalized for reader hosts.
enum ReaderLifecycleState { foreground, inactive, background, detached }

/// Stable failure categories exposed to reader hosts.
enum ReaderFailureKind { data, persistence, layout, platform, unknown }

@immutable
/// Lightweight metadata displayed by the reading surface.
class ReaderBookInfo {
  const ReaderBookInfo({
    required this.id,
    required this.title,
    this.author,
    this.description,
  });

  final String id;
  final String title;
  final String? author;
  final String? description;
}

@immutable
/// One stable entry in a book's ordered chapter catalog.
class ReaderChapterInfo {
  const ReaderChapterInfo({
    required this.id,
    required this.title,
    required this.index,
  });

  final String id;
  final String title;
  final int index;
}

@immutable
/// A cursor-based page of chapter metadata.
class ChapterCatalogPage {
  ChapterCatalogPage({
    required List<ReaderChapterInfo> items,
    required this.total,
    required this.hasMore,
    this.nextCursor,
  }) : items = UnmodifiableListView(items);

  final List<ReaderChapterInfo> items;
  final String? nextCursor;
  final int total;
  final bool hasMore;
}

@immutable
/// A stable plain-text paragraph used as a semantic position anchor.
class TextParagraph {
  const TextParagraph({required this.id, required this.text});

  final String id;
  final String text;
}

@immutable
/// One fully loaded plain-text chapter.
class TextChapterContent {
  TextChapterContent({
    required this.chapterId,
    required this.title,
    required List<TextParagraph> paragraphs,
    this.contentVersion,
  }) : paragraphs = UnmodifiableListView(paragraphs);

  final String chapterId;
  final String title;
  final List<TextParagraph> paragraphs;
  final String? contentVersion;
}

@immutable
/// A layout-independent reading position persisted by the host.
class ReaderProgress {
  const ReaderProgress({
    required this.chapterId,
    required this.paragraphId,
    this.characterOffset = 0,
    this.chapterIndex = 0,
    this.chapterFraction = 0,
    this.bookFraction = 0,
  });

  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final int chapterIndex;
  final double chapterFraction;
  final double bookFraction;

  ReaderProgress copyWith({
    String? chapterId,
    String? paragraphId,
    int? characterOffset,
    int? chapterIndex,
    double? chapterFraction,
    double? bookFraction,
  }) {
    return ReaderProgress(
      chapterId: chapterId ?? this.chapterId,
      paragraphId: paragraphId ?? this.paragraphId,
      characterOffset: characterOffset ?? this.characterOffset,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterFraction: chapterFraction ?? this.chapterFraction,
      bookFraction: bookFraction ?? this.bookFraction,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderProgress &&
      chapterId == other.chapterId &&
      paragraphId == other.paragraphId &&
      characterOffset == other.characterOffset &&
      chapterIndex == other.chapterIndex &&
      chapterFraction == other.chapterFraction &&
      bookFraction == other.bookFraction;

  @override
  int get hashCode => Object.hash(
    chapterId,
    paragraphId,
    characterOffset,
    chapterIndex,
    chapterFraction,
    bookFraction,
  );
}

@immutable
/// A host-persisted bookmark anchored to chapter and paragraph identities.
class ReaderBookmark {
  const ReaderBookmark({
    required this.id,
    required this.bookId,
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterTitle,
    required this.excerpt,
    required this.createdAt,
  });

  final String id;
  final String bookId;
  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final String chapterTitle;
  final String excerpt;
  final DateTime createdAt;
}

@immutable
/// Reader-owned presentation settings persisted unchanged by the host.
class TextReaderPreferences {
  const TextReaderPreferences({
    this.theme = ReaderThemePreset.day,
    this.font = ReaderFontPreset.system,
    this.fontSize = 19,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 14,
    this.horizontalPadding = 24,
    this.brightness = 1,
    this.navigationMode = ReaderNavigationMode.horizontalPages,
    this.keepScreenOn = true,
    this.pageAnimation = ReaderPageAnimation.slide,
  });

  static const defaults = TextReaderPreferences();

  final ReaderThemePreset theme;
  final ReaderFontPreset font;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final double brightness;
  final ReaderNavigationMode navigationMode;
  final bool keepScreenOn;
  final ReaderPageAnimation pageAnimation;

  TextReaderPreferences normalized() {
    return copyWith(
      fontSize: fontSize.clamp(14, 32).toDouble(),
      lineHeight: lineHeight.clamp(1.3, 2.4).toDouble(),
      paragraphSpacing: paragraphSpacing.clamp(0, 32).toDouble(),
      horizontalPadding: horizontalPadding.clamp(12, 64).toDouble(),
      brightness: brightness.clamp(0.25, 1).toDouble(),
    );
  }

  TextReaderPreferences copyWith({
    ReaderThemePreset? theme,
    ReaderFontPreset? font,
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    double? brightness,
    ReaderNavigationMode? navigationMode,
    bool? keepScreenOn,
    ReaderPageAnimation? pageAnimation,
  }) {
    return TextReaderPreferences(
      theme: theme ?? this.theme,
      font: font ?? this.font,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      brightness: brightness ?? this.brightness,
      navigationMode: navigationMode ?? this.navigationMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      pageAnimation: pageAnimation ?? this.pageAnimation,
    );
  }
}

@immutable
/// A recoverable reader error suitable for host diagnostics.
class ReaderFailure implements Exception {
  const ReaderFailure(this.kind, this.message, {this.cause});

  final ReaderFailureKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ReaderFailure($kind, $message)';
}

@immutable
/// Stable target reserved for future book, chapter, or paragraph comments.
class ReaderCommentTarget {
  const ReaderCommentTarget.book(this.bookId)
    : chapterId = null,
      paragraphId = null;

  const ReaderCommentTarget.chapter(this.bookId, this.chapterId)
    : paragraphId = null;

  const ReaderCommentTarget.paragraph(
    this.bookId,
    this.chapterId,
    this.paragraphId,
  );

  final String bookId;
  final String? chapterId;
  final String? paragraphId;
}

@immutable
/// Read-only state published by [TextReaderController].
class TextReaderSnapshot {
  const TextReaderSnapshot({
    required this.isReady,
    required this.isLoading,
    required this.controlsVisible,
    this.book,
    this.chapter,
    this.progress,
    this.failure,
  });

  const TextReaderSnapshot.initial()
    : isReady = false,
      isLoading = true,
      controlsVisible = false,
      book = null,
      chapter = null,
      progress = null,
      failure = null;

  final bool isReady;
  final bool isLoading;
  final bool controlsVisible;
  final ReaderBookInfo? book;
  final ReaderChapterInfo? chapter;
  final ReaderProgress? progress;
  final ReaderFailure? failure;
}
