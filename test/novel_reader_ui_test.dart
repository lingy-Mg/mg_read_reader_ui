import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/pagination/text_paginator.dart';
import 'package:novel_reader_ui/src/ui/reader_theme.dart';

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
      topPadding: 1,
      bottomPadding: 200,
    );
    final TextReaderPreferences normalized = unsafe.normalized();

    expect(normalized.fontSize, 32);
    expect(normalized.lineHeight, 1.5);
    expect(normalized.brightness, 0.25);
    expect(normalized.topPadding, 8);
    expect(normalized.bottomPadding, 64);
  });

  test('MiSans is the bundled default reader font', () {
    expect(TextReaderPreferences.defaults.font, ReaderFontPreset.system);
    expect(readerFontFamily(ReaderFontPreset.system), readerDefaultFontFamily);
    expect(
      readerFontPackageFor(ReaderFontPreset.system),
      readerFontPackageName,
    );
    expect(readerPackageFontFamily, 'packages/novel_reader_ui/MiSans');
  });

  testWidgets('horizontal pages accept a primary-button mouse drag', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: TextReaderView(
            bookId: 'mouse-drag-book',
            controller: controller,
            dataSource: _MouseDragDataSource(),
            stateStore: _MouseDragStateStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final double initialFraction =
        controller.snapshot.progress!.chapterFraction;
    final ScrollableState scrollable = tester.state(find.byType(Scrollable));
    final double initialPixels = scrollable.position.pixels;
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-240, 0));
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(initialPixels));
    await gesture.moveBy(const Offset(-220, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.snapshot.progress!.chapterFraction,
      greaterThan(initialFraction),
    );
  });

  testWidgets('horizontal pages do not overflow at desktop text scale', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1264, 711));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: TextReaderView(
            bookId: 'desktop-layout-book',
            dataSource: _MouseDragDataSource(),
            stateStore: _MouseDragStateStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

class _MouseDragDataSource implements TextReaderDataSource {
  final TextChapterContent _chapter = TextChapterContent(
    chapterId: 'chapter-1',
    title: '鼠标翻页测试',
    paragraphs: List<TextParagraph>.generate(
      12,
      (int index) => TextParagraph(
        id: 'paragraph-$index',
        text: List<String>.filled(
          5,
          '这是用于验证鼠标拖动翻页的第 ${index + 1} 段正文。文字足够长，以确保测试视口会生成多个页面。',
        ).join(),
      ),
    ),
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: _chapter.title);

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: <ReaderChapterInfo>[
      ReaderChapterInfo(
        id: _chapter.chapterId,
        title: _chapter.title,
        index: 0,
      ),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => _chapter;
}

class _MouseDragStateStore implements TextReaderStateStore {
  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(keepScreenOn: false);

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
