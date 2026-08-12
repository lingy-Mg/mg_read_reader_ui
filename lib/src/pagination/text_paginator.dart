import 'package:flutter/widgets.dart';

import '../api/models.dart';

@immutable
class ReaderPageBlock {
  const ReaderPageBlock({
    required this.paragraphId,
    required this.text,
    required this.startOffset,
    required this.isParagraphStart,
    required this.isParagraphEnd,
  });

  final String paragraphId;
  final String text;
  final int startOffset;
  final bool isParagraphStart;
  final bool isParagraphEnd;
}

@immutable
class ReaderPage {
  ReaderPage({required List<ReaderPageBlock> blocks, this.showsTitle = false})
    : blocks = List.unmodifiable(blocks);

  final List<ReaderPageBlock> blocks;
  final bool showsTitle;

  String get paragraphId => blocks.isEmpty ? '' : blocks.first.paragraphId;
  int get characterOffset => blocks.isEmpty ? 0 : blocks.first.startOffset;
}

class TextPaginator {
  const TextPaginator();

  List<ReaderPage> paginate({
    required TextChapterContent chapter,
    required double width,
    required double height,
    required TextStyle titleStyle,
    required TextStyle bodyStyle,
    required double paragraphSpacing,
    int firstLineIndent = 2,
    TextDirection textDirection = TextDirection.ltr,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (width <= 0 || height <= 0) return const <ReaderPage>[];

    final List<ReaderPage> pages = <ReaderPage>[];
    List<ReaderPageBlock> blocks = <ReaderPageBlock>[];
    var usedHeight = _measure(
      chapter.title,
      width,
      titleStyle,
      textDirection,
      textScaler,
    ).height;
    usedHeight += 28;
    var showsTitle = true;

    void commitPage() {
      if (blocks.isEmpty && pages.isNotEmpty) return;
      pages.add(ReaderPage(blocks: blocks, showsTitle: showsTitle));
      blocks = <ReaderPageBlock>[];
      usedHeight = 0;
      showsTitle = false;
    }

    for (final TextParagraph paragraph in chapter.paragraphs) {
      final String source = paragraph.text.trim();
      if (source.isEmpty) continue;
      var offset = 0;
      while (offset < source.length) {
        var available = height - usedHeight;
        if (available < _minimumLineHeight(bodyStyle) && blocks.isNotEmpty) {
          commitPage();
          available = height;
        }

        final bool paragraphStart = offset == 0;
        final int end = _largestFittingEnd(
          source: source,
          start: offset,
          availableWidth: width,
          availableHeight: available,
          style: bodyStyle,
          textDirection: textDirection,
          addIndent: paragraphStart,
          firstLineIndent: firstLineIndent,
          textScaler: textScaler,
        );

        if (end <= offset) {
          if (blocks.isNotEmpty || showsTitle) {
            commitPage();
            continue;
          }
          final int forcedEnd = _safeBoundary(source, offset + 1);
          blocks.add(
            ReaderPageBlock(
              paragraphId: paragraph.id,
              text: source.substring(offset, forcedEnd),
              startOffset: offset,
              isParagraphStart: paragraphStart,
              isParagraphEnd: forcedEnd == source.length,
            ),
          );
          offset = forcedEnd;
          commitPage();
          continue;
        }

        final String chunk = source.substring(offset, end);
        final bool paragraphEnd = end == source.length;
        final String display = paragraphStart
            ? '${'\u3000' * firstLineIndent}$chunk'
            : chunk;
        final double chunkHeight = _measure(
          display,
          width,
          bodyStyle,
          textDirection,
          textScaler,
        ).height;
        blocks.add(
          ReaderPageBlock(
            paragraphId: paragraph.id,
            text: chunk,
            startOffset: offset,
            isParagraphStart: paragraphStart,
            isParagraphEnd: paragraphEnd,
          ),
        );
        usedHeight += chunkHeight;
        offset = end;

        if (paragraphEnd) {
          usedHeight += paragraphSpacing;
        } else {
          commitPage();
        }
      }
    }

    if (blocks.isNotEmpty || pages.isEmpty) commitPage();
    return List.unmodifiable(pages);
  }

  int pageIndexForAnchor(
    List<ReaderPage> pages,
    String paragraphId,
    int characterOffset,
  ) {
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final ReaderPage page = pages[pageIndex];
      for (final ReaderPageBlock block in page.blocks) {
        final int end = block.startOffset + block.text.length;
        if (block.paragraphId == paragraphId &&
            characterOffset >= block.startOffset &&
            characterOffset <= end) {
          return pageIndex;
        }
      }
    }
    return 0;
  }

  int _largestFittingEnd({
    required String source,
    required int start,
    required double availableWidth,
    required double availableHeight,
    required TextStyle style,
    required TextDirection textDirection,
    required bool addIndent,
    required int firstLineIndent,
    required TextScaler textScaler,
  }) {
    int low = start;
    int high = source.length;
    while (low < high) {
      int mid = (low + high + 1) ~/ 2;
      mid = _safeBoundary(source, mid);
      if (mid <= low) mid = low + 1;
      final String chunk = source.substring(start, mid);
      final String display = addIndent
          ? '${'\u3000' * firstLineIndent}$chunk'
          : chunk;
      final Size size = _measure(
        display,
        availableWidth,
        style,
        textDirection,
        textScaler,
      );
      if (size.height <= availableHeight + 0.1) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return _safeBoundary(source, low);
  }

  int _safeBoundary(String value, int offset) {
    int result = offset.clamp(0, value.length);
    if (result > 0 &&
        result < value.length &&
        _isLowSurrogate(value.codeUnitAt(result))) {
      result--;
    }
    return result;
  }

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  Size _measure(
    String text,
    double width,
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    return painter.size;
  }

  double _minimumLineHeight(TextStyle style) {
    return (style.fontSize ?? 16) * (style.height ?? 1.2);
  }
}
