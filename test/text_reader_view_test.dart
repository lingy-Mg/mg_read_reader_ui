import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderPlatform originalPlatform;

  setUp(() {
    originalPlatform = ReaderPlatform.instance;
    ReaderPlatform.instance = _FakeReaderPlatform();
  });

  tearDown(() {
    ReaderPlatform.instance = originalPlatform;
  });

  testWidgets('loads content and exposes built-in controls', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'book',
            dataSource: _FakeDataSource(),
            stateStore: _MemoryStore(),
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('测试章节'), findsWidgets);
    expect(controller.snapshot.isReady, isTrue);

    await controller.showControls();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _FakeReaderPlatform extends ReaderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<void> setKeepScreenOn(bool enabled) async {}
}

class _FakeDataSource implements TextReaderDataSource {
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    return const ReaderBookInfo(id: 'book', title: '测试书籍');
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    return ChapterCatalogPage(
      items: const <ReaderChapterInfo>[
        ReaderChapterInfo(id: 'chapter', title: '测试章节', index: 0),
      ],
      total: 1,
      hasMore: false,
    );
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    return TextChapterContent(
      chapterId: chapterId,
      title: '测试章节',
      paragraphs: const <TextParagraph>[
        TextParagraph(id: 'paragraph', text: '这是一段用于组件测试的正文内容。'),
      ],
    );
  }
}

class _MemoryStore implements TextReaderStateStore {
  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
