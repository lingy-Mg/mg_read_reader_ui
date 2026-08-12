import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() => runApp(const ReaderExampleApp());

class ReaderExampleApp extends StatefulWidget {
  const ReaderExampleApp({super.key});

  @override
  State<ReaderExampleApp> createState() => _ReaderExampleAppState();
}

class _ReaderExampleAppState extends State<ReaderExampleApp> {
  bool _showGlobalPerformanceOverlay = false;

  void _togglePerformanceOverlay() {
    setState(() {
      _showGlobalPerformanceOverlay = !_showGlobalPerformanceOverlay;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novel Reader UI Example',
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _showGlobalPerformanceOverlay,
      builder: (BuildContext context, Widget? child) {
        return Stack(
          children: <Widget>[
            child ?? const SizedBox.shrink(),
            _FrameRateOverlay(
              showGlobalPerformanceOverlay: _showGlobalPerformanceOverlay,
              onToggle: _togglePerformanceOverlay,
            ),
          ],
        );
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE7683F)),
        fontFamily: 'packages/novel_reader_ui/MiSans',
        useMaterial3: true,
      ),
      home: const ReaderExampleHome(),
    );
  }
}

class _FrameRateOverlay extends StatefulWidget {
  const _FrameRateOverlay({
    required this.showGlobalPerformanceOverlay,
    required this.onToggle,
  });

  final bool showGlobalPerformanceOverlay;
  final VoidCallback onToggle;

  @override
  State<_FrameRateOverlay> createState() => _FrameRateOverlayState();
}

class _FrameRateOverlayState extends State<_FrameRateOverlay> {
  static const Duration _refreshInterval = Duration(seconds: 1);

  int _framesSinceLastRefresh = 0;
  int _framesPerSecond = 0;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_recordFrameTimings);
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (!mounted) return;
      setState(() {
        _framesPerSecond = _framesSinceLastRefresh;
        _framesSinceLastRefresh = 0;
      });
    });
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    _framesSinceLastRefresh += timings.length;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeTimingsCallback(_recordFrameTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isGlobal = widget.showGlobalPerformanceOverlay;
    return Positioned(
      top: 12,
      left: 12,
      child: Semantics(
        button: true,
        label: isGlobal ? '全局性能监视，点击切换为小窗' : '小窗性能监视，点击切换为全局',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: Color(0xB3000000),
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                '$_framesPerSecond FPS · ${isGlobal ? '全局' : '小窗'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderExampleHome extends StatefulWidget {
  const ReaderExampleHome({super.key});

  @override
  State<ReaderExampleHome> createState() => _ReaderExampleHomeState();
}

class _ReaderExampleHomeState extends State<ReaderExampleHome> {
  final DemoReaderDataSource _dataSource = DemoReaderDataSource();
  final MemoryReaderStateStore _stateStore = MemoryReaderStateStore();
  bool _reading = false;

  @override
  Widget build(BuildContext context) {
    if (_reading) {
      return Scaffold(
        body: TextReaderView(
          bookId: 'mountain-lamp',
          dataSource: _dataSource,
          stateStore: _stateStore,
          observer: DemoReaderObserver(
            onExit: () {
              if (mounted) setState(() => _reading = false);
            },
            onFailureMessage: (String message) {
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(message)));
            },
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F1EB),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 210,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xFF304B42), Color(0xFF9A6B43)],
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.auto_stories_rounded,
                      color: Colors.white,
                      size: 72,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  '山灯未眠',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  '一份原创演示文本，用于展示异步目录、分页、书签和阅读设置。',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    color: Color(0xFF706D67),
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => setState(() => _reading = true),
                  icon: const Icon(Icons.menu_book_rounded),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 13),
                    child: Text('开始阅读'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DemoReaderObserver extends ReaderObserver {
  const DemoReaderObserver({
    required this.onExit,
    required this.onFailureMessage,
  });

  final VoidCallback onExit;
  final ValueChanged<String> onFailureMessage;

  @override
  void onExitRequested(ReaderProgress? progress) => onExit();

  @override
  void onFailure(ReaderFailure failure) => onFailureMessage(failure.message);
}

class DemoReaderDataSource implements TextReaderDataSource {
  DemoReaderDataSource() : _chapters = _buildChapters();

  final List<TextChapterContent> _chapters;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    return const ReaderBookInfo(
      id: 'mountain-lamp',
      title: '山灯未眠',
      author: '示例作者',
      description: '关于一座山城、一盏旧灯和一段归途的原创短篇。',
      sourceName: '示例书源',
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 220));
    final int start = int.tryParse(cursor ?? '0') ?? 0;
    final int end = (start + pageSize).clamp(0, _chapters.length);
    return ChapterCatalogPage(
      items: <ReaderChapterInfo>[
        for (var index = start; index < end; index++)
          ReaderChapterInfo(
            id: _chapters[index].chapterId,
            title: _chapters[index].title,
            index: index,
          ),
      ],
      total: _chapters.length,
      hasMore: end < _chapters.length,
      nextCursor: end < _chapters.length ? '$end' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final TextChapterContent chapter = _chapters[index];
    return ReaderChapterInfo(
      id: chapter.chapterId,
      title: chapter.title,
      index: index,
    );
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return _chapters.firstWhere((chapter) => chapter.chapterId == chapterId);
  }

  static List<TextChapterContent> _buildChapters() {
    const List<String> titles = <String>[
      '第一章 雾从河面升起',
      '第二章 山路上的邮车',
      '第三章 修灯的人',
      '第四章 夜市尽头',
      '第五章 风越过旧站台',
      '第六章 灯火归处',
    ];
    const List<String> seeds = <String>[
      '清晨的河面还没有醒，薄雾沿着石阶缓慢爬上来。林砚推开窗，看见对岸那盏多年未熄的山灯，仍在灰白的天色里留着一点温暖。',
      '邮车的发动机在坡道上发出低沉的声响，车窗外的竹林一段段向后退去。司机说，山顶的旧站已经停用了很多年，却总有人往那里寄没有收件人的信。',
      '修灯铺很窄，木架上摆满铜制灯罩和旧玻璃。老人把灯芯放在掌心，说每一盏灯记住的不是黑夜，而是曾经等待它的人。',
      '夜市收摊后只剩雨水反射招牌的微光。林砚顺着青石路走到尽头，第一次听见那封信里反复提到的钟声。',
      '风穿过废弃站台，把墙上的旧时刻表吹得轻轻作响。那些被岁月遮住的名字，在手电光下逐渐显露出来。',
      '天亮之前，山城所有的灯像约好一样依次熄灭，只有河对岸的新灯亮了起来。林砚终于明白，归途并不是回到旧地，而是有人为你留下方向。',
    ];
    return List<TextChapterContent>.generate(titles.length, (int chapterIndex) {
      return TextChapterContent(
        chapterId: 'chapter-${chapterIndex + 1}',
        title: titles[chapterIndex],
        contentVersion: '1',
        chapterUrl:
            'https://example.com/mountain-lamp/chapter-${chapterIndex + 1}',
        paragraphs: List<TextParagraph>.generate(14, (int paragraphIndex) {
          final String variation = paragraphIndex.isEven
              ? '风从屋檐下掠过，带来潮湿泥土和松针的气息。'
              : '他停下脚步，把沿途细小的线索重新排在心里。';
          return TextParagraph(
            id: 'c${chapterIndex + 1}-p${paragraphIndex + 1}',
            text: '${seeds[chapterIndex]}$variation这一次，他决定继续向前。',
          );
        }),
      );
    });
  }
}

class MemoryReaderStateStore implements TextReaderStateStore {
  ReaderProgress? _progress;
  TextReaderPreferences? _preferences;
  final List<ReaderBookmark> _bookmarks = <ReaderBookmark>[];

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {
    _bookmarks.add(bookmark);
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    return List<ReaderBookmark>.unmodifiable(
      _bookmarks.where((bookmark) => bookmark.bookId == bookId),
    );
  }

  @override
  Future<TextReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => _progress;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _bookmarks.removeWhere(
      (bookmark) => bookmark.bookId == bookId && bookmark.id == bookmarkId,
    );
  }

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {
    _progress = progress;
  }
}
