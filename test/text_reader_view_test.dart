import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderPlatform originalPlatform;
  late UrlLauncherPlatform originalUrlLauncher;
  late _FakeUrlLauncherPlatform urlLauncher;

  setUp(() {
    originalPlatform = ReaderPlatform.instance;
    ReaderPlatform.instance = _FakeReaderPlatform();
    originalUrlLauncher = UrlLauncherPlatform.instance;
    urlLauncher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = urlLauncher;
  });

  tearDown(() {
    ReaderPlatform.instance = originalPlatform;
    UrlLauncherPlatform.instance = originalUrlLauncher;
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
    expect(find.text('书源: 测试书源'), findsOneWidget);
    expect(find.text('https://example.com/book/test-chapter'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('keeps bookmark and refresh visible and groups extra actions', (
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

    await controller.showControls();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byTooltip('添加书签'), findsOneWidget);
    expect(find.byTooltip('刷新本章'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('刷新本章'), findsOneWidget);
    expect(find.text('目录'), findsNWidgets(2));
    expect(find.text('书签'), findsNWidgets(2));
    expect(find.text('主题'), findsNWidgets(2));
    expect(find.text('设置'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('opens the supplied chapter URL in the external browser', (
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

    await controller.showControls();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('https://example.com/book/test-chapter'));
    await tester.pump();

    expect(urlLauncher.launchedUrl, 'https://example.com/book/test-chapter');
    expect(urlLauncher.launchMode, PreferredLaunchMode.externalApplication);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('theme sheet is separate from settings groups', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await _pumpReader(tester, controller, _MemoryStore());
    await controller.showControls();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('主题').last);
    await tester.pumpAndSettle();

    expect(find.text('日间'), findsOneWidget);
    expect(find.text('护眼'), findsOneWidget);
    expect(find.text('羊皮纸'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);
    expect(find.text('字体'), findsNothing);
    expect(find.text('排版'), findsNothing);
    expect(find.text('显示与翻页'), findsNothing);
    expect(find.text('设备能力'), findsNothing);

    await _disposeReader(tester);
  });

  testWidgets('layout submenu updates first-line indent in place', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    final _MemoryStore store = _MemoryStore();
    await _pumpReader(tester, controller, store);
    await _openSettings(tester, controller);

    await tester.tap(find.text('排版').last);
    await tester.pumpAndSettle();
    expect(_choiceChip('两字符').selected, isTrue);

    await tester.ensureVisible(find.text('无').last);
    await tester.pump();
    await tester.tap(find.text('无').last);
    await tester.pump();

    expect(_choiceChip('两字符').selected, isFalse);
    expect(_choiceChip('无').selected, isTrue);
    await tester.pumpAndSettle();
    expect(store.lastSavedPreferences?.firstLineIndent, 0);

    await _disposeReader(tester);
  });

  testWidgets('layout submenu persists independent top and bottom margins', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    final _MemoryStore store = _MemoryStore();
    await _pumpReader(tester, controller, store);
    await _openSettings(tester, controller);

    await tester.tap(find.text('排版').last);
    await tester.pumpAndSettle();
    expect(find.text('顶部边距'), findsOneWidget);
    expect(find.text('底部边距'), findsOneWidget);

    await tester.ensureVisible(find.text('底部边距'));
    await tester.tap(find.byType(ChoiceChip).last);
    await tester.pumpAndSettle();

    expect(store.lastSavedPreferences?.bottomPadding, 64);
    await _disposeReader(tester);
  });

  testWidgets('horizontal page footer overlays content at the bottom edge', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await _pumpReader(tester, controller, _MemoryStore());

    final Rect readerBounds = tester.getRect(find.byType(TextReaderView));
    final Rect footerBounds = tester.getRect(
      find.byKey(const ValueKey<String>('reader-page-footer')),
    );

    expect(readerBounds.bottom - footerBounds.bottom, closeTo(10, 0.1));
    await _disposeReader(tester);
  });

  testWidgets(
    'layout update repaginates rendered text without losing progress',
    (WidgetTester tester) async {
      const String paragraph = '这是一段用于组件测试的正文内容。';
      final TextReaderController controller = TextReaderController();
      await _pumpReader(tester, controller, _MemoryStore());
      final ReaderProgress? progressBefore = controller.snapshot.progress;
      expect(find.text('　　$paragraph'), findsOneWidget);

      await _openSettings(tester, controller);
      await tester.tap(find.text('排版').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('无').last);
      await tester.tap(find.text('无').last);
      await tester.pumpAndSettle();

      expect(find.text('　　$paragraph'), findsNothing);
      expect(find.text(paragraph), findsOneWidget);
      expect(controller.snapshot.progress, progressBefore);

      await _disposeReader(tester);
    },
  );

  testWidgets('display submenu reacts to vertical mode', (
    WidgetTester tester,
  ) async {
    final TextReaderController controller = TextReaderController();
    await _pumpReader(tester, controller, _MemoryStore());
    await _openSettings(tester, controller);

    await tester.tap(find.text('显示与翻页').last);
    await tester.pumpAndSettle();
    expect(find.text('滑动'), findsOneWidget);
    expect(find.text('关闭动画'), findsOneWidget);

    await tester.tap(find.text('上下滚动').last);
    await tester.pump();

    expect(find.text('上下滚动时不使用翻页动画'), findsOneWidget);
    expect(find.text('滑动'), findsNothing);
    expect(find.text('关闭动画'), findsNothing);

    await _disposeReader(tester);
  });

  testWidgets(
    'device capabilities hide unsupported controls and allow immersive without awake',
    (WidgetTester tester) async {
      final _FakeReaderPlatform unsupported = _FakeReaderPlatform();
      ReaderPlatform.instance = unsupported;
      final TextReaderController unsupportedController = TextReaderController();
      await _pumpReader(tester, unsupportedController, _MemoryStore());
      await _openSettings(tester, unsupportedController);
      expect(find.text('设备能力'), findsNothing);
      await _disposeReader(tester);

      final _FakeReaderPlatform supported = _FakeReaderPlatform(
        platformCapabilities: const ReaderPlatformCapabilities(
          keepScreenOn: true,
          immersiveMode: true,
        ),
      );
      ReaderPlatform.instance = supported;
      final TextReaderController controller = TextReaderController();
      await _pumpReader(tester, controller, _MemoryStore());
      await _openSettings(tester, controller);

      await tester.tap(find.text('设备能力').last);
      await tester.pumpAndSettle();
      final Finder switches = find.byType(Switch);
      expect(switches, findsNWidgets(2));

      await tester.tap(switches.first);
      await tester.pump();
      await tester.tap(switches.last);
      await tester.pumpAndSettle();

      expect(
        supported.systemUiCalls,
        containsAllInOrder(const <_SystemUiCall>[
          _SystemUiCall(false, false),
          _SystemUiCall(false, true),
        ]),
      );
      await _disposeReader(tester);
    },
  );
}

class _FakeReaderPlatform extends ReaderPlatform
    with MockPlatformInterfaceMixin {
  _FakeReaderPlatform({
    this.platformCapabilities = const ReaderPlatformCapabilities(),
  });

  final ReaderPlatformCapabilities platformCapabilities;
  final List<_SystemUiCall> systemUiCalls = <_SystemUiCall>[];

  @override
  Future<ReaderPlatformCapabilities> capabilities() async =>
      platformCapabilities;

  @override
  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
  }) async {
    systemUiCalls.add(_SystemUiCall(keepScreenOn, immersiveMode));
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}
}

class _SystemUiCall {
  const _SystemUiCall(this.keepScreenOn, this.immersiveMode);

  final bool keepScreenOn;
  final bool immersiveMode;

  @override
  bool operator ==(Object other) =>
      other is _SystemUiCall &&
      other.keepScreenOn == keepScreenOn &&
      other.immersiveMode == immersiveMode;

  @override
  int get hashCode => Object.hash(keepScreenOn, immersiveMode);
}

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  String? launchedUrl;
  PreferredLaunchMode? launchMode;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    launchMode = options.mode;
    return true;
  }
}

class _FakeDataSource implements TextReaderDataSource {
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    return const ReaderBookInfo(id: 'book', title: '测试书籍', sourceName: '测试书源');
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
      chapterUrl: 'https://example.com/book/test-chapter',
      paragraphs: const <TextParagraph>[
        TextParagraph(id: 'paragraph', text: '这是一段用于组件测试的正文内容。'),
      ],
    );
  }
}

class _MemoryStore implements TextReaderStateStore {
  TextReaderPreferences? lastSavedPreferences;

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
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    lastSavedPreferences = preferences;
  }

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}

Future<void> _pumpReader(
  WidgetTester tester,
  TextReaderController controller,
  _MemoryStore store,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextReaderView(
          bookId: 'book',
          dataSource: _FakeDataSource(),
          stateStore: store,
          controller: controller,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _openSettings(
  WidgetTester tester,
  TextReaderController controller,
) async {
  await controller.showControls();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text('设置').last);
  await tester.pumpAndSettle();
}

ChoiceChip _choiceChip(String label) =>
    find
            .ancestor(
              of: find.text(label).last,
              matching: find.byType(ChoiceChip),
            )
            .evaluate()
            .single
            .widget
        as ChoiceChip;

Future<void> _disposeReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
