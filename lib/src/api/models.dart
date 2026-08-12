import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Built-in reader color themes. Hosts persist the value but do not style it.
enum ReaderThemePreset { day, eyeCare, parchment, night }

/// Built-in reader font choices.
///
/// The default [system] choice uses the bundled MiSans font so the reader
/// keeps a consistent appearance across Android and Windows.
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
    this.sourceName,
  });

  /// Stable identifier supplied by the host.
  final String id;

  /// Display title of the book.
  final String title;

  /// Optional book author.
  final String? author;

  /// Optional book description.
  final String? description;

  /// Display name of the host-managed book source.
  ///
  /// When supplied, it is shown below the reader title bar. The reader never
  /// uses this value to fetch content or select a source.
  final String? sourceName;
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
    this.chapterUrl,
  }) : paragraphs = UnmodifiableListView(paragraphs);

  /// Stable chapter identifier supplied by the host.
  final String chapterId;

  /// Display title of the chapter.
  final String title;

  /// Ordered, stable paragraph content for this chapter.
  final List<TextParagraph> paragraphs;

  /// Optional host content version used for in-memory pagination caching.
  final String? contentVersion;

  /// HTTP or HTTPS URL for this exact chapter at its source.
  ///
  /// If it is valid, the reading surface displays it below the title bar and
  /// opens it in the external browser only after an explicit user tap.
  final String? chapterUrl;
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

  /// Creates the book information preview position before chapter zero.
  const ReaderProgress.bookPreview()
    : chapterId = '',
      paragraphId = '',
      characterOffset = 0,
      chapterIndex = -1,
      chapterFraction = 0,
      bookFraction = 0;

  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final int chapterIndex;
  final double chapterFraction;
  final double bookFraction;

  /// Whether this position represents the metadata page before chapter zero.
  bool get isBookPreview => chapterIndex < 0;

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
    this.fontWeight = 400,
    this.letterSpacing = .2,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 14,
    this.firstLineIndent = 2,
    this.horizontalPadding = 24,
    this.topPadding = 24,
    this.bottomPadding = 32,
    this.brightness = 1,
    this.navigationMode = ReaderNavigationMode.horizontalPages,
    this.keepScreenOn = true,
    this.pageAnimation = ReaderPageAnimation.slide,
    this.immersiveMode = false,
  });

  static const defaults = TextReaderPreferences();

  /// Built-in reading color scheme.
  final ReaderThemePreset theme;

  /// Bundled or platform font family selection.
  final ReaderFontPreset font;

  /// Body font size in logical pixels; normalized to supported presets.
  final double fontSize;

  /// Body text weight. Values are normalized to 400, 500, or 600.
  final int fontWeight;

  /// Body text letter spacing in logical pixels.
  final double letterSpacing;

  /// Body line-height multiplier, normalized to supported presets.
  final double lineHeight;

  /// Space after a paragraph in logical pixels.
  final double paragraphSpacing;

  /// Number of full-width ideographic spaces used for a paragraph's first line.
  final int firstLineIndent;

  /// Horizontal page padding in logical pixels.
  final double horizontalPadding;

  /// Space between the top safe area and the first line of page content.
  ///
  /// This is also used as the top inset for vertical scrolling.
  final double topPadding;

  /// Space between the last line of page content and the bottom safe area.
  ///
  /// The horizontal page footer is an overlay rather than part of the text
  /// layout. A smaller value may therefore intentionally allow text to pass
  /// beneath the footer.
  final double bottomPadding;

  /// Reader overlay brightness from 0.25 to 1.0.
  final double brightness;

  /// Horizontal pagination or vertical scrolling.
  final ReaderNavigationMode navigationMode;

  /// Requests display-awake while an active reader is in the foreground.
  final bool keepScreenOn;

  /// Horizontal page transition preference.
  final ReaderPageAnimation pageAnimation;

  /// Whether supported platforms should hide system bars while reading.
  ///
  /// Defaults to false and is ignored on platforms without immersive support.
  final bool immersiveMode;

  TextReaderPreferences normalized() {
    return copyWith(
      fontSize: _nearest(fontSize, const <double>[16, 19, 22, 26, 32]),
      fontWeight: _nearest(fontWeight.toDouble(), const <double>[
        400,
        500,
        600,
      ]).round(),
      letterSpacing: _nearest(letterSpacing, const <double>[0, .2, .8]),
      lineHeight: _nearest(lineHeight, const <double>[1.5, 1.8, 2.1]),
      paragraphSpacing: _nearest(paragraphSpacing, const <double>[8, 14, 22]),
      firstLineIndent: _nearest(firstLineIndent.toDouble(), const <double>[
        0,
        1,
        2,
      ]).round(),
      horizontalPadding: _nearest(horizontalPadding, const <double>[
        16,
        24,
        40,
      ]),
      topPadding: _nearest(topPadding, const <double>[8, 24, 40, 64]),
      bottomPadding: _nearest(bottomPadding, const <double>[8, 24, 40, 64]),
      brightness: brightness.clamp(0.25, 1).toDouble(),
    );
  }

  static double _nearest(double value, List<double> choices) => choices.reduce(
    (double best, double candidate) =>
        (candidate - value).abs() < (best - value).abs() ? candidate : best,
  );

  TextReaderPreferences copyWith({
    ReaderThemePreset? theme,
    ReaderFontPreset? font,
    double? fontSize,
    int? fontWeight,
    double? letterSpacing,
    double? lineHeight,
    double? paragraphSpacing,
    int? firstLineIndent,
    double? horizontalPadding,
    double? topPadding,
    double? bottomPadding,
    double? brightness,
    ReaderNavigationMode? navigationMode,
    bool? keepScreenOn,
    ReaderPageAnimation? pageAnimation,
    bool? immersiveMode,
  }) {
    return TextReaderPreferences(
      theme: theme ?? this.theme,
      font: font ?? this.font,
      fontSize: fontSize ?? this.fontSize,
      fontWeight: fontWeight ?? this.fontWeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      firstLineIndent: firstLineIndent ?? this.firstLineIndent,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      topPadding: topPadding ?? this.topPadding,
      bottomPadding: bottomPadding ?? this.bottomPadding,
      brightness: brightness ?? this.brightness,
      navigationMode: navigationMode ?? this.navigationMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      pageAnimation: pageAnimation ?? this.pageAnimation,
      immersiveMode: immersiveMode ?? this.immersiveMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextReaderPreferences &&
      theme == other.theme &&
      font == other.font &&
      fontSize == other.fontSize &&
      fontWeight == other.fontWeight &&
      letterSpacing == other.letterSpacing &&
      lineHeight == other.lineHeight &&
      paragraphSpacing == other.paragraphSpacing &&
      firstLineIndent == other.firstLineIndent &&
      horizontalPadding == other.horizontalPadding &&
      topPadding == other.topPadding &&
      bottomPadding == other.bottomPadding &&
      brightness == other.brightness &&
      navigationMode == other.navigationMode &&
      keepScreenOn == other.keepScreenOn &&
      pageAnimation == other.pageAnimation &&
      immersiveMode == other.immersiveMode;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    theme,
    font,
    fontSize,
    fontWeight,
    letterSpacing,
    lineHeight,
    paragraphSpacing,
    firstLineIndent,
    horizontalPadding,
    topPadding,
    bottomPadding,
    brightness,
    navigationMode,
    keepScreenOn,
    pageAnimation,
    immersiveMode,
  ]);
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
