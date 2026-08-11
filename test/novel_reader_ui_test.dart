import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/pagination/text_paginator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TextPaginator', () {
    const TextPaginator paginator = TextPaginator();
    final TextChapterContent chapter = TextChapterContent(
      chapterId: 'c1',
      title: '第一章',
      paragraphs: <TextParagraph>[
        const TextParagraph(id: 'p1', text: '这是第一段正文，用于验证分页服务能够根据可用高度稳定拆分文字。'),
        const TextParagraph(id: 'p2', text: '这是第二段正文，段落拥有独立而稳定的语义标识。'),
      ],
    );

    test('creates pages with semantic anchors', () {
      final List<ReaderPage> pages = paginator.paginate(
        chapter: chapter,
        width: 220,
        height: 180,
        titleStyle: const TextStyle(fontSize: 24, height: 1.3),
        bodyStyle: const TextStyle(fontSize: 18, height: 1.7),
        paragraphSpacing: 12,
      );

      expect(pages, isNotEmpty);
      expect(pages.first.showsTitle, isTrue);
      expect(pages.expand((page) => page.blocks), isNotEmpty);
      expect(pages.first.blocks.first.paragraphId, 'p1');
    });

    test('finds the page containing a semantic position', () {
      final List<ReaderPage> pages = paginator.paginate(
        chapter: chapter,
        width: 150,
        height: 120,
        titleStyle: const TextStyle(fontSize: 22),
        bodyStyle: const TextStyle(fontSize: 18, height: 1.8),
        paragraphSpacing: 10,
      );
      final int index = paginator.pageIndexForAnchor(pages, 'p2', 2);

      expect(index, inInclusiveRange(0, pages.length - 1));
      expect(
        pages[index].blocks.any((block) => block.paragraphId == 'p2'),
        isTrue,
      );
    });
  });

  test('preferences normalize unsafe persisted values', () {
    const TextReaderPreferences unsafe = TextReaderPreferences(
      fontSize: 200,
      lineHeight: 0.2,
      brightness: -1,
    );
    final TextReaderPreferences normalized = unsafe.normalized();

    expect(normalized.fontSize, 32);
    expect(normalized.lineHeight, 1.3);
    expect(normalized.brightness, 0.25);
  });
}
