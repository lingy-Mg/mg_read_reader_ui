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
    ReaderPlatform.instance = _GoldenPlatform();
  });

  tearDown(() {
    ReaderPlatform.instance = originalPlatform;
  });

  for (final ReaderThemePreset preset in ReaderThemePreset.values) {
    testWidgets('${preset.name} Android reading surface', (
      WidgetTester tester,
    ) async {
      await _pumpReader(tester, preset, const Size(360, 640));
      await expectLater(
        find.byType(TextReaderView),
        matchesGoldenFile('goldens/${preset.name}_android.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('Windows wide reading surface with controls', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await _pumpReader(
      tester,
      ReaderThemePreset.parchment,
      const Size(1000, 700),
      controller: controller,
    );
    await controller.showControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('目录'), findsOneWidget);
    await expectLater(
      find.byType(TextReaderView),
      matchesGoldenFile('goldens/windows_wide_controls.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> _pumpReader(
  WidgetTester tester,
  ReaderThemePreset preset,
  Size size, {
  TextReaderController? controller,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TextReaderView(
        bookId: 'golden-book',
        dataSource: _GoldenDataSource(),
        stateStore: _GoldenStore(preset),
        controller: controller,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

class _GoldenPlatform extends ReaderPlatform with MockPlatformInterfaceMixin {
  @override
  Future<void> setKeepScreenOn(bool enabled) async {}
}

class _GoldenDataSource implements TextReaderDataSource {
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    return const ReaderBookInfo(
      id: 'golden-book',
      title: '山灯未眠',
      author: '示例作者',
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    return ChapterCatalogPage(
      items: const <ReaderChapterInfo>[
        ReaderChapterInfo(id: 'chapter-1', title: '第一章 雾从河面升起', index: 0),
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
      title: '第一章 雾从河面升起',
      paragraphs: const <TextParagraph>[
        TextParagraph(
          id: 'p1',
          text: '清晨的河面还没有醒，薄雾沿着石阶缓慢爬上来。对岸那盏多年未熄的山灯，仍在灰白天色里留着一点温暖。',
        ),
        TextParagraph(
          id: 'p2',
          text: '风从屋檐下掠过，带来潮湿泥土和松针的气息。他停下脚步，把沿途细小的线索重新排在心里。',
        ),
        TextParagraph(id: 'p3', text: '旧邮车在山路拐角处出现，车灯穿过雾气，像一封迟到了许多年的回信。'),
      ],
    );
  }
}

class _GoldenStore implements TextReaderStateStore {
  const _GoldenStore(this.preset);

  final ReaderThemePreset preset;

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      TextReaderPreferences(theme: preset);

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
