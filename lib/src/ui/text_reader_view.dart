import 'dart:async';
import 'dart:collection';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../pagination/text_paginator.dart';
import '../platform/reader_platform.dart';
import '../platform/screen_awake_coordinator.dart';
import 'reader_strings.dart';
import 'reader_theme.dart';

enum _TopBarMenuAction { refresh, catalog, bookmarks, theme, settings }

/// A complete, embeddable text reading surface.
///
/// The host supplies content and persistence interfaces. Navigation out of the
/// reader is reported through [ReaderObserver.onExitRequested].
class TextReaderView extends StatefulWidget {
  const TextReaderView({
    super.key,
    required this.bookId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.controller,
    this.extensions = const ReaderExtensions(),
  });

  final String bookId;
  final TextReaderDataSource dataSource;
  final TextReaderStateStore stateStore;
  final ReaderObserver? observer;
  final TextReaderController? controller;
  final ReaderExtensions extensions;

  @override
  State<TextReaderView> createState() => _TextReaderViewState();
}

class _TextReaderViewState extends State<TextReaderView> {
  static const Duration _saveDelay = Duration(milliseconds: 800);
  static const int _chapterCacheLimit = 2;
  static const double _pageFooterBottomInset = 10;
  // TextPainter measures fractional line heights, while RenderParagraph rounds
  // their painted extent to device pixels. Keep a small reserve so a page that
  // exactly fits during pagination cannot overflow by a rounding pixel.
  static const double _horizontalPageLayoutSafety = 2;
  static const double _mouseTapSlop = 18;
  // PointerEvent.buttons uses a bit mask; 1 denotes the primary mouse button.
  static const int _primaryMouseButton = 1;

  final TextPaginator _paginator = const TextPaginator();
  final Object _awakeHolder = Object();
  final FocusNode _focusNode = FocusNode(debugLabel: 'TextReader');
  final ScrollController _verticalController = ScrollController();
  final LinkedHashMap<String, TextChapterContent> _chapterCache =
      LinkedHashMap<String, TextChapterContent>();
  final Map<String, GlobalKey> _paragraphKeys = <String, GlobalKey>{};

  late TextReaderController _controller;
  late AppLifecycleListener _lifecycleListener;
  final PageController _pageController = PageController(initialPage: 1);
  Timer? _saveTimer;
  Timer? _noticeTimer;
  Timer? _clockTimer;
  Timer? _wheelResetTimer;

  ReaderBookInfo? _book;
  final List<ReaderChapterInfo> _catalog = <ReaderChapterInfo>[];
  String? _catalogCursor;
  int _catalogTotal = 0;
  bool _catalogHasMore = false;
  bool _catalogLoading = false;
  TextChapterContent? _content;
  ReaderChapterInfo? _currentChapterInfo;
  List<ReaderPage> _pages = const <ReaderPage>[];
  List<ReaderBookmark> _bookmarks = const <ReaderBookmark>[];
  TextReaderPreferences _preferences = TextReaderPreferences.defaults;
  ReaderProgress? _progress;
  ReaderFailure? _failure;
  Size? _layoutSize;
  int _chapterIndex = -1;
  int _pageIndex = 0;
  int _requestGeneration = 0;
  int _sessionGeneration = 0;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _foreground = true;
  ReaderLifecycleState _lifecycleState = ReaderLifecycleState.foreground;
  bool _awakeAcquired = false;
  ReaderPlatformCapabilities _platformCapabilities =
      const ReaderPlatformCapabilities();
  Future<void> _preferencesWrite = Future<void>.value();
  bool _changingChapter = false;
  bool _disposed = false;
  int? _mouseTapPointer;
  Offset? _mouseTapDownPosition;
  bool _mouseTapMoved = false;
  double? _sliderPreview;
  double _wheelDelta = 0;
  String? _noticeMessage;
  DateTime _clock = DateTime.now();

  ReaderObserver get _observer => widget.observer ?? const ReaderObserver();
  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);
  ReaderChapterInfo? get _currentChapter => _currentChapterInfo;
  bool get _isBookPreview =>
      !_loading && _failure == null && _progress?.isBookPreview == true;
  TextScaler get _textScaler => MediaQuery.textScalerOf(
    context,
  ).clamp(minScaleFactor: .85, maxScaleFactor: 1.3);
  String _indented(String text) => '${'　' * _preferences.firstLineIndent}$text';

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextReaderController();
    _bindController();
    _verticalController.addListener(_handleVerticalScroll);
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _clock = DateTime.now());
    });
    unawaited(_loadPlatformCapabilities());
    unawaited(_initialize());
  }

  Future<void> _loadPlatformCapabilities() async {
    try {
      final ReaderPlatformCapabilities capabilities = await ReaderPlatform
          .instance
          .capabilities();
      if (_disposed) return;
      setState(() => _platformCapabilities = capabilities);
      await _syncAwake();
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  @override
  void didUpdateWidget(covariant TextReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.unbind();
      _controller = widget.controller ?? TextReaderController();
      _bindController();
      _publishSnapshot();
    }
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.stateStore != widget.stateStore) {
      unawaited(_restart());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _requestGeneration++;
    _sessionGeneration++;
    _saveTimer?.cancel();
    _noticeTimer?.cancel();
    _clockTimer?.cancel();
    _wheelResetTimer?.cancel();
    unawaited(_flushProgress());
    unawaited(_releaseAwake());
    unawaited(
      _notify(() => _observer.onSessionEnded(widget.bookId, _progress)),
    );
    _lifecycleListener.dispose();
    _verticalController
      ..removeListener(_handleVerticalScroll)
      ..dispose();
    _pageController.dispose();
    _focusNode.dispose();
    _controller.unbind();
    super.dispose();
  }

  void _bindController() {
    _controller.bind(
      openChapter: (String id) => _openChapter(id),
      nextPage: _nextPage,
      previousPage: _previousPage,
      nextChapter: _nextChapter,
      previousChapter: _previousChapter,
      showBookPreview: _showBookPreview,
      toggleControls: () async => _setControlsVisible(!_controlsVisible),
      showControls: () async => _setControlsVisible(true),
      hideControls: () async => _setControlsVisible(false),
      refresh: () =>
          _openChapter(_content?.chapterId ?? '', forceRefresh: true),
    );
  }

  Future<void> _restart() async {
    await _releaseAwake();
    _saveTimer?.cancel();
    _requestGeneration++;
    _sessionGeneration++;
    _chapterCache.clear();
    _catalog.clear();
    _book = null;
    _bookmarks = const <ReaderBookmark>[];
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _content = null;
    _currentChapterInfo = null;
    _pages = const <ReaderPage>[];
    _progress = null;
    _failure = null;
    _layoutSize = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _changingChapter = false;
    _controlsVisible = false;
    _sliderPreview = null;
    _noticeMessage = null;
    _wheelDelta = 0;
    _wheelResetTimer?.cancel();
    _loading = true;
    if (mounted) setState(() {});
    await _initialize();
  }

  Future<void> _initialize() async {
    final int generation = ++_sessionGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }

    try {
      final Future<ReaderBookInfo> bookFuture = widget.dataSource.loadBookInfo(
        widget.bookId,
      );
      final Future<ChapterCatalogPage> catalogFuture = widget.dataSource
          .loadChapterCatalog(widget.bookId);
      final Future<ReaderProgress?> progressFuture = _safeLoadProgress();
      final Future<TextReaderPreferences> preferencesFuture =
          _safeLoadPreferences();
      final Future<List<ReaderBookmark>> bookmarksFuture = _safeLoadBookmarks();

      final List<dynamic> results = await Future.wait<dynamic>(
        <Future<dynamic>>[
          bookFuture,
          catalogFuture,
          progressFuture,
          preferencesFuture,
          bookmarksFuture,
        ],
      );
      if (!_isSessionCurrent(generation)) return;

      _book = results[0] as ReaderBookInfo;
      _mergeCatalog(results[1] as ChapterCatalogPage);
      _progress =
          results[2] as ReaderProgress? ?? const ReaderProgress.bookPreview();
      _preferences = results[3] as TextReaderPreferences;
      _bookmarks = results[4] as List<ReaderBookmark>;

      if (_progress!.isBookPreview) {
        _content = null;
        _currentChapterInfo = null;
        _chapterIndex = -1;
      } else {
        if (_catalogTotal <= 0) {
          throw const ReaderFailure(
            ReaderFailureKind.data,
            '已保存正文进度，但书籍没有可用章节',
          );
        }
        ReaderChapterInfo? target = _catalog
            .where((item) => item.id == _progress!.chapterId)
            .firstOrNull;
        target ??= await _chapterInfoAtIndex(_progress!.chapterIndex);
        if (!_isSessionCurrent(generation)) return;
        await _openChapter(target.id, initial: true);
        if (!_isSessionCurrent(generation)) return;
      }
      _loading = false;
      _failure = null;
      if (mounted) setState(() {});
      await _syncAwake();
      await _notify(() => _observer.onSessionStarted(widget.bookId));
      _publishSnapshot();
    } catch (error) {
      if (!_isSessionCurrent(generation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = failure;
        });
      }
      _publishSnapshot();
      await _reportFailure(failure);
    }
  }

  Future<ReaderProgress?> _safeLoadProgress() async {
    try {
      return await widget.stateStore.loadProgress(widget.bookId);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      return null;
    }
  }

  Future<TextReaderPreferences> _safeLoadPreferences() async {
    try {
      return (await widget.stateStore.loadPreferences() ??
              TextReaderPreferences.defaults)
          .normalized();
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      return TextReaderPreferences.defaults;
    }
  }

  Future<List<ReaderBookmark>> _safeLoadBookmarks() async {
    try {
      return List.unmodifiable(
        await widget.stateStore.loadBookmarks(widget.bookId),
      );
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      return const <ReaderBookmark>[];
    }
  }

  void _mergeCatalog(ChapterCatalogPage page) {
    final Set<String> existing = _catalog.map((item) => item.id).toSet();
    _catalog.addAll(page.items.where((item) => existing.add(item.id)));
    _catalog.sort((a, b) => a.index.compareTo(b.index));
    _catalogCursor = page.nextCursor;
    _catalogTotal = page.total;
    _catalogHasMore = page.hasMore;
  }

  Future<ReaderChapterInfo> _chapterInfoAtIndex(int index) async {
    if (index < 0 || (_catalogTotal > 0 && index >= _catalogTotal)) {
      throw ReaderFailure(ReaderFailureKind.data, '章节索引超出范围: $index');
    }
    final ReaderChapterInfo? cached = _catalog
        .where((item) => item.index == index)
        .firstOrNull;
    if (cached != null) return cached;
    final ReaderChapterInfo chapter = await widget.dataSource
        .loadChapterAtIndex(widget.bookId, index);
    if (chapter.index != index || chapter.id.isEmpty) {
      throw const ReaderFailure(ReaderFailureKind.data, '章节定位接口返回了无效数据');
    }
    if (_catalog.every((item) => item.id != chapter.id)) {
      _catalog.add(chapter);
      _catalog.sort((a, b) => a.index.compareTo(b.index));
    }
    return chapter;
  }

  Future<void> _loadMoreCatalog({bool notify = true}) async {
    if (_catalogLoading || !_catalogHasMore) return;
    final int generation = _sessionGeneration;
    _catalogLoading = true;
    if (notify && mounted) setState(() {});
    try {
      final ChapterCatalogPage page = await widget.dataSource
          .loadChapterCatalog(widget.bookId, cursor: _catalogCursor);
      if (!_isSessionCurrent(generation)) return;
      _mergeCatalog(page);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    } finally {
      _catalogLoading = false;
      if (notify && mounted) setState(() {});
    }
  }

  Future<void> _openChapter(
    String chapterId, {
    bool initial = false,
    bool forceRefresh = false,
    bool openAtEnd = false,
    double? targetChapterFraction,
  }) async {
    if (chapterId.isEmpty || _changingChapter) return;
    final ReaderChapterInfo? targetInfo = _catalog
        .where((item) => item.id == chapterId)
        .firstOrNull;
    if (targetInfo == null) return;
    final TextChapterContent? previousContent = _content;
    final int previousIndex = _chapterIndex;
    final int generation = ++_requestGeneration;
    _changingChapter = true;
    if (!initial && mounted) setState(() {});
    try {
      TextChapterContent? chapter;
      if (!forceRefresh) chapter = _takeCached(chapterId);
      chapter ??= await widget.dataSource.loadChapterContent(
        widget.bookId,
        chapterId,
      );
      if (!_isCurrent(generation)) return;
      _validateChapter(chapter);
      if (openAtEnd &&
          previousContent != null &&
          previousIndex == targetInfo.index + 1) {
        _chapterCache
          ..clear()
          ..[chapter.chapterId] = chapter
          ..[previousContent.chapterId] = previousContent;
      } else {
        _cacheChapter(chapter);
      }
      _chapterIndex = targetInfo.index;
      _currentChapterInfo = targetInfo;
      _content = chapter;
      _pages = const <ReaderPage>[];
      _layoutSize = null;
      _pageIndex = 0;
      _paragraphKeys.clear();

      final ReaderProgress? saved = _progress;
      final TextParagraph first = chapter.paragraphs.isEmpty
          ? const TextParagraph(id: '', text: '')
          : chapter.paragraphs.first;
      if (initial && saved?.chapterId == chapterId && !saved!.isBookPreview) {
        final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
        _progress = saved.copyWith(
          chapterIndex: targetInfo.index,
          bookFraction: total <= 0
              ? 0
              : ((targetInfo.index + saved.chapterFraction) / total).clamp(
                  0,
                  1,
                ),
        );
      } else {
        final double fraction =
            targetChapterFraction?.clamp(0, 1) ?? (openAtEnd ? 1 : 0);
        final int paragraphIndex = chapter.paragraphs.isEmpty
            ? 0
            : (fraction * chapter.paragraphs.length).floor().clamp(
                0,
                chapter.paragraphs.length - 1,
              );
        final TextParagraph anchor = chapter.paragraphs.isEmpty
            ? first
            : chapter.paragraphs[paragraphIndex];
        final int offset = openAtEnd
            ? anchor.text.length
            : (fraction * anchor.text.length).floor().clamp(
                0,
                anchor.text.length,
              );
        _progress = _progressForAnchor(
          anchor.id,
          offset,
          chapterFraction: fraction,
        );
      }
      _failure = null;
      if (mounted) setState(() {});
      _publishSnapshot();
      await _notify(() => _observer.onChapterChanged(targetInfo));
      await _syncAwake();
      _scheduleProgressSave(immediate: true);
      if (!openAtEnd) unawaited(_prefetchNext(targetInfo.index));
      if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
        _scheduleVerticalRestore();
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      _failure = failure;
      if (mounted) setState(() {});
      await _reportFailure(failure);
    } finally {
      if (_isCurrent(generation)) {
        _changingChapter = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _validateChapter(TextChapterContent chapter) {
    final Set<String> ids = <String>{};
    for (final TextParagraph paragraph in chapter.paragraphs) {
      if (paragraph.id.isEmpty || !ids.add(paragraph.id)) {
        throw const ReaderFailure(ReaderFailureKind.data, '章节包含无效或重复的段落标识');
      }
    }
  }

  TextChapterContent? _takeCached(String id) {
    final TextChapterContent? value = _chapterCache.remove(id);
    if (value != null) _chapterCache[id] = value;
    return value;
  }

  void _cacheChapter(TextChapterContent chapter) {
    _chapterCache.remove(chapter.chapterId);
    _chapterCache[chapter.chapterId] = chapter;
    while (_chapterCache.length > _chapterCacheLimit) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  Future<void> _prefetchNext(int currentIndex) async {
    final int nextIndex = currentIndex + 1;
    if (_catalogTotal > 0 && nextIndex >= _catalogTotal) return;
    try {
      final ReaderChapterInfo next = await _chapterInfoAtIndex(nextIndex);
      if (_chapterCache.containsKey(next.id)) return;
      final TextChapterContent content = await widget.dataSource
          .loadChapterContent(widget.bookId, next.id);
      if (_disposed || _chapterIndex != currentIndex) return;
      _validateChapter(content);
      _cacheChapter(content);
    } catch (_) {
      // Prefetch is best effort. Foreground loading reports actionable errors.
    }
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _requestGeneration;

  bool _isSessionCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  void _ensurePagination(Size size) {
    if (_content == null ||
        _preferences.navigationMode != ReaderNavigationMode.horizontalPages ||
        size.isEmpty ||
        _layoutSize == size) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layoutSize == size) return;
      _paginate(size);
    });
  }

  void _paginate(Size size) {
    final TextChapterContent? content = _content;
    if (content == null) return;
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final double width =
        size.width - (_preferences.horizontalPadding * 2).clamp(24, size.width);
    final double height =
        (size.height -
                safe.top -
                safe.bottom -
                _preferences.topPadding -
                _preferences.bottomPadding -
                _horizontalPageLayoutSafety)
            .clamp(80, size.height);
    final TextStyle bodyStyle = _bodyTextStyle;
    try {
      final List<ReaderPage> pages = _paginator.paginate(
        chapter: content,
        width: width,
        height: height,
        titleStyle: _titleTextStyle,
        bodyStyle: bodyStyle,
        paragraphSpacing: _preferences.paragraphSpacing,
        firstLineIndent: _preferences.firstLineIndent,
        textDirection: Directionality.of(context),
        textScaler: _textScaler,
      );
      final ReaderProgress? anchor = _progress;
      final int pageIndex = anchor == null
          ? 0
          : _paginator.pageIndexForAnchor(
              pages,
              anchor.paragraphId,
              anchor.characterOffset,
            );
      setState(() {
        _layoutSize = size;
        _pages = pages;
        _pageIndex = pageIndex.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(_pageIndex + 1);
      });
      _updateProgressFromPage();
    } catch (error) {
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.layout);
      setState(() => _failure = failure);
      unawaited(_reportFailure(failure));
    }
  }

  TextStyle get _bodyTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: readerFontPackageFor(_preferences.font),
    fontSize: _preferences.fontSize,
    fontWeight: FontWeight(_preferences.fontWeight),
    height: _preferences.lineHeight,
    letterSpacing: _preferences.letterSpacing,
  );

  TextStyle get _titleTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: readerFontPackageFor(_preferences.font),
    fontSize: _preferences.fontSize + 7,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );

  Future<void> _nextPage() async {
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset +
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex + 1 < _pages.length) {
      await _animateToPage(_pageIndex + 1);
    } else {
      await _nextChapter();
    }
  }

  Future<void> _previousPage() async {
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset -
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex > 0) {
      await _animateToPage(_pageIndex - 1);
    } else {
      await _previousChapter();
    }
  }

  void _handleHorizontalTap(Offset localPosition) {
    final Size? size = context.size;
    if (size == null || size.width <= 0) return;
    final double fraction = localPosition.dx / size.width;
    if (fraction < 0.3) {
      unawaited(_previousPage());
    } else if (fraction > 0.7) {
      unawaited(_nextPage());
    } else {
      _setControlsVisible(!_controlsVisible);
    }
  }

  void _trackMousePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != _primaryMouseButton) {
      return;
    }
    _mouseTapPointer = event.pointer;
    _mouseTapDownPosition = event.localPosition;
    _mouseTapMoved = false;
  }

  void _trackMousePointerMove(PointerMoveEvent event) {
    if (event.pointer != _mouseTapPointer || _mouseTapMoved) return;
    final Offset? downPosition = _mouseTapDownPosition;
    if (downPosition != null &&
        (event.localPosition - downPosition).distance > _mouseTapSlop) {
      _mouseTapMoved = true;
    }
  }

  void _finishMousePointer(PointerEvent event) {
    if (event.pointer != _mouseTapPointer) return;
    final bool isTap = !_mouseTapMoved;
    _mouseTapPointer = null;
    _mouseTapDownPosition = null;
    _mouseTapMoved = false;
    if (isTap && event is PointerUpEvent) {
      _handleHorizontalTap(event.localPosition);
    }
  }

  Future<void> _animateToPage(int page) async {
    if (!_pageController.hasClients) return;
    if (_preferences.pageAnimation == ReaderPageAnimation.none ||
        MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(page + 1);
    } else {
      await _pageController.animateToPage(
        page + 1,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _nextChapter() async {
    final int nextIndex = _chapterIndex + 1;
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (nextIndex >= total) {
      _restoreCurrentHorizontalPage();
      _showNotice(ReaderStrings.noNextChapter);
      return;
    }
    try {
      final ReaderChapterInfo next = await _chapterInfoAtIndex(nextIndex);
      await _openChapter(next.id);
    } catch (error) {
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  Future<void> _previousChapter() async {
    if (_chapterIndex < 0) {
      _showNotice(ReaderStrings.noPreviousChapter);
      return;
    }
    if (_chapterIndex == 0) {
      await _showBookPreview();
      return;
    }
    try {
      final ReaderChapterInfo previous = await _chapterInfoAtIndex(
        _chapterIndex - 1,
      );
      await _openChapter(previous.id, openAtEnd: true);
    } catch (error) {
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  Future<void> _showBookPreview() async {
    _requestGeneration++;
    _saveTimer?.cancel();
    await _flushProgress();
    _content = null;
    _chapterCache.clear();
    _currentChapterInfo = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _pages = const <ReaderPage>[];
    _layoutSize = null;
    _paragraphKeys.clear();
    _progress = const ReaderProgress.bookPreview();
    _changingChapter = false;
    _failure = null;
    if (mounted) setState(() {});
    await _releaseAwake();
    _scheduleProgressSave(immediate: true);
    _publishSnapshot();
  }

  void _restoreCurrentHorizontalPage() {
    if (_preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(_pageIndex + 1);
    });
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    if (mounted) setState(() => _noticeMessage = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _noticeMessage = null);
    });
  }

  void _onHorizontalPageChanged(int rawIndex) {
    if (_changingChapter || _pages.isEmpty) return;
    if (rawIndex == 0) {
      unawaited(_previousChapter());
      return;
    }
    if (rawIndex == _pages.length + 1) {
      unawaited(_nextChapter());
      return;
    }
    _pageIndex = rawIndex - 1;
    _updateProgressFromPage();
    if (mounted) setState(() {});
  }

  void _updateProgressFromPage() {
    if (_pages.isEmpty || _pageIndex >= _pages.length) return;
    final ReaderPage page = _pages[_pageIndex];
    if (page.blocks.isEmpty) return;
    _progress = _progressForAnchor(
      page.paragraphId,
      page.characterOffset,
      chapterFraction: (_pageIndex + 1) / _pages.length,
    );
    _scheduleProgressSave();
    _publishSnapshot();
  }

  ReaderProgress _progressForAnchor(
    String paragraphId,
    int offset, {
    required double chapterFraction,
  }) {
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    final double bookFraction = total == 0
        ? 0
        : ((_chapterIndex + chapterFraction) / total).clamp(0, 1);
    return ReaderProgress(
      chapterId: _content?.chapterId ?? _currentChapter?.id ?? '',
      paragraphId: paragraphId,
      characterOffset: offset,
      chapterIndex: _chapterIndex,
      chapterFraction: chapterFraction.clamp(0, 1),
      bookFraction: bookFraction,
    );
  }

  void _handleVerticalScroll() {
    if (!_verticalController.hasClients || _content == null) return;
    final double fraction = _verticalController.position.maxScrollExtent == 0
        ? 0
        : (_verticalController.offset /
                  _verticalController.position.maxScrollExtent)
              .clamp(0, 1);
    String paragraphId = _content!.paragraphs.firstOrNull?.id ?? '';
    for (final TextParagraph paragraph in _content!.paragraphs) {
      final BuildContext? itemContext =
          _paragraphKeys[paragraph.id]?.currentContext;
      if (itemContext == null) continue;
      final RenderBox? box = itemContext.findRenderObject() as RenderBox?;
      if (box != null &&
          box.localToGlobal(Offset.zero).dy + box.size.height > 0) {
        paragraphId = paragraph.id;
        break;
      }
    }
    _progress = _progressForAnchor(paragraphId, 0, chapterFraction: fraction);
    _scheduleProgressSave();
    _publishSnapshot();
  }

  void _scheduleVerticalRestore() {
    final String? id = _progress?.paragraphId;
    if (id == null || id.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? target = _paragraphKeys[id]?.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target, alignment: 0.05);
    });
  }

  void _scheduleProgressSave({bool immediate = false}) {
    _saveTimer?.cancel();
    if (immediate) {
      unawaited(_flushProgress());
    } else {
      _saveTimer = Timer(_saveDelay, () => unawaited(_flushProgress()));
    }
  }

  Future<void> _flushProgress() async {
    _saveTimer?.cancel();
    final ReaderProgress? progress = _progress;
    if (progress == null) return;
    try {
      await widget.stateStore.saveProgress(widget.bookId, progress);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
    }
  }

  Future<void> _updatePreferences(TextReaderPreferences value) async {
    final TextReaderPreferences normalized = value.normalized();
    final bool layoutChanged =
        normalized.font != _preferences.font ||
        normalized.fontSize != _preferences.fontSize ||
        normalized.fontWeight != _preferences.fontWeight ||
        normalized.letterSpacing != _preferences.letterSpacing ||
        normalized.lineHeight != _preferences.lineHeight ||
        normalized.paragraphSpacing != _preferences.paragraphSpacing ||
        normalized.firstLineIndent != _preferences.firstLineIndent ||
        normalized.horizontalPadding != _preferences.horizontalPadding ||
        normalized.topPadding != _preferences.topPadding ||
        normalized.bottomPadding != _preferences.bottomPadding ||
        normalized.navigationMode != _preferences.navigationMode;
    setState(() {
      _preferences = normalized;
      if (layoutChanged) _layoutSize = null;
    });
    // Capture this normalized value now: later taps must not turn this queued
    // write into a duplicate write of a newer preference snapshot.
    _preferencesWrite = _preferencesWrite.then(
      (_) => widget.stateStore.savePreferences(normalized),
      onError: (_) => widget.stateStore.savePreferences(normalized),
    );
    try {
      await _preferencesWrite;
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
    }
    await _syncAwake();
    if (normalized.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore();
    }
  }

  void _handleLifecycle(AppLifecycleState state) {
    final ReaderLifecycleState normalized = switch (state) {
      AppLifecycleState.resumed => ReaderLifecycleState.foreground,
      AppLifecycleState.inactive => ReaderLifecycleState.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => ReaderLifecycleState.background,
      AppLifecycleState.detached => ReaderLifecycleState.detached,
    };
    if (_lifecycleState == normalized) return;
    _lifecycleState = normalized;
    final bool foreground = normalized == ReaderLifecycleState.foreground;
    _foreground = foreground;
    if (!foreground) {
      unawaited(_releaseAwake());
      unawaited(_flushProgress());
    } else {
      unawaited(_syncAwake());
    }
    unawaited(
      _notify(() => _observer.onLifecycleChanged(normalized, _progress)),
    );
  }

  Future<void> _syncAwake() async {
    final bool shouldAcquire =
        !_disposed &&
        _foreground &&
        _content != null &&
        ((_preferences.keepScreenOn && _platformCapabilities.keepScreenOn) ||
            (_preferences.immersiveMode &&
                _platformCapabilities.immersiveMode));
    if (shouldAcquire && !_awakeAcquired) {
      try {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn:
              _preferences.keepScreenOn && _platformCapabilities.keepScreenOn,
          immersiveMode:
              _preferences.immersiveMode && _platformCapabilities.immersiveMode,
        );
        _awakeAcquired = true;
      } catch (error) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
      }
    } else if (shouldAcquire) {
      try {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn:
              _preferences.keepScreenOn && _platformCapabilities.keepScreenOn,
          immersiveMode:
              _preferences.immersiveMode && _platformCapabilities.immersiveMode,
        );
      } catch (error) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
      }
    } else if (!shouldAcquire) {
      await _releaseAwake();
    }
  }

  Future<void> _releaseAwake() async {
    if (!_awakeAcquired) return;
    _awakeAcquired = false;
    try {
      await ScreenAwakeCoordinator.instance.release(_awakeHolder);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  void _setControlsVisible(bool value) {
    if (_controlsVisible == value || !mounted) return;
    setState(() => _controlsVisible = value);
    _publishSnapshot();
  }

  void _publishSnapshot() {
    _controller.updateSnapshot(
      TextReaderSnapshot(
        isReady: (_content != null || _isBookPreview) && _failure == null,
        isLoading: _loading || _changingChapter,
        controlsVisible: _controlsVisible,
        book: _book,
        chapter: _currentChapter,
        progress: _progress,
        failure: _failure,
      ),
    );
  }

  ReaderFailure _asFailure(Object error, ReaderFailureKind fallbackKind) {
    if (error is ReaderFailure) return error;
    return ReaderFailure(fallbackKind, '阅读器暂时遇到问题', cause: error);
  }

  Future<void> _reportFailure(ReaderFailure failure) {
    return _notify(() => _observer.onFailure(failure));
  }

  Future<void> _notify(FutureOr<void> Function() callback) async {
    try {
      await callback();
    } catch (error, stackTrace) {
      debugPrint('novel_reader_ui observer error: $error\n$stackTrace');
    }
  }

  Future<void> _requestExit() async {
    await _flushProgress();
    await _notify(() => _observer.onExitRequested(_progress));
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = _palette;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: palette.systemBrightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Theme(
        data: _readerMaterialTheme(palette),
        child: PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (!didPop) unawaited(_requestExit());
          },
          child: Material(
            color: palette.background,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                    unawaited(_previousPage()),
                const SingleActivator(
                  LogicalKeyboardKey.space,
                  shift: true,
                ): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    unawaited(_requestExit()),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    _ensurePagination(constraints.biggest);
                    return ScrollConfiguration(
                      behavior: const _ReaderScrollBehavior(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          _buildContent(),
                          if (_content != null) _buildChrome(),
                          if (_noticeMessage != null)
                            _ReaderNotice(message: _noticeMessage!),
                          IgnorePointer(
                            child: ColoredBox(
                              color: Colors.black.withValues(
                                alpha: (1 - _preferences.brightness) * 0.65,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ThemeData _readerMaterialTheme(ReaderPalette palette) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: palette.systemBrightness,
        ).copyWith(
          primary: palette.accent,
          surface: palette.panel,
          onSurface: palette.text,
          outline: palette.divider,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: palette.systemBrightness,
      colorScheme: scheme,
      fontFamily: readerFontFamily(_preferences.font),
      fontFamilyFallback: readerFontFallback(_preferences.font),
      scaffoldBackgroundColor: palette.background,
      dividerColor: palette.divider,
    );
  }

  Widget _buildContent() {
    if (_loading && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 18),
            Text(ReaderStrings.loading),
          ],
        ),
      );
    }
    if (_failure != null && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.menu_book_outlined, size: 46),
            const SizedBox(height: 14),
            const Text(ReaderStrings.loadFailed),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _initialize,
              child: const Text(ReaderStrings.retry),
            ),
          ],
        ),
      );
    }
    if (_isBookPreview) return _buildBookPreview();
    if (_content == null) return const SizedBox.shrink();
    return _preferences.navigationMode == ReaderNavigationMode.horizontalPages
        ? _buildHorizontalReader()
        : _buildVerticalReader();
  }

  Widget _buildBookPreview() {
    final ReaderBookInfo? book = _book;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: ReaderStrings.back,
                    onPressed: _requestExit,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Container(
                    width: 132,
                    height: 176,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          _palette.accent.withValues(alpha: 0.92),
                          _palette.text.withValues(alpha: 0.78),
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 22,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.auto_stories_rounded,
                      size: 54,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                Text(
                  book?.title ?? ReaderStrings.bookPreview,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _palette.text,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (book?.author?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    book!.author!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _palette.secondaryText),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.format_list_numbered_rounded,
                      size: 18,
                      color: _palette.secondaryText,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '$_catalogTotal 章',
                      style: TextStyle(color: _palette.secondaryText),
                    ),
                  ],
                ),
                if (book?.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 30),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _palette.panel.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _palette.divider),
                    ),
                    child: Text(
                      book!.description!,
                      style: TextStyle(
                        color: _palette.text,
                        fontSize: 16,
                        height: 1.75,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 30),
                FilledButton.icon(
                  onPressed: _catalogTotal > 0 ? _nextChapter : null,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text(ReaderStrings.startReading),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalReader() {
    if (_pages.isEmpty) {
      return Center(
        child: Text(
          _content!.paragraphs.isEmpty
              ? ReaderStrings.emptyChapter
              : ReaderStrings.loading,
          style: TextStyle(color: _palette.secondaryText),
        ),
      );
    }
    final ScrollBehavior horizontalPageScrollBehavior =
        ScrollConfiguration.of(context).copyWith(
          // Flutter excludes mouse drags from scrollables by default. This
          // restores PageView's native, position-following drag behavior.
          dragDevices: <PointerDeviceKind>{
            ...ScrollConfiguration.of(context).dragDevices,
            PointerDeviceKind.mouse,
          },
        );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onTapUp: (TapUpDetails details) =>
          _handleHorizontalTap(details.localPosition),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _handlePointerSignal,
        onPointerDown: _trackMousePointerDown,
        onPointerMove: _trackMousePointerMove,
        onPointerUp: _finishMousePointer,
        onPointerCancel: _finishMousePointer,
        child: ScrollConfiguration(
          behavior: horizontalPageScrollBehavior,
          child: PageView.builder(
            controller: _pageController,
            physics: _preferences.pageAnimation == ReaderPageAnimation.none
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: _pages.length + 2,
            onPageChanged: _onHorizontalPageChanged,
            itemBuilder: (BuildContext context, int index) {
              if (index == 0) {
                return _chapterBoundary(ReaderStrings.previousChapter);
              }
              if (index == _pages.length + 1) {
                return _chapterBoundary(ReaderStrings.nextChapter);
              }
              return _buildPage(_pages[index - 1], index - 1);
            },
          ),
        ),
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _changingChapter) return;
    final double delta =
        event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    _wheelDelta += delta;
    _wheelResetTimer?.cancel();
    _wheelResetTimer = Timer(const Duration(milliseconds: 140), () {
      _wheelDelta = 0;
    });
    if (_wheelDelta.abs() < 36) return;
    final bool forward = _wheelDelta > 0;
    _wheelDelta = 0;
    if (forward) {
      unawaited(_nextPage());
    } else {
      unawaited(_previousPage());
    }
  }

  Widget _chapterBoundary(String label) {
    return Center(
      child: _changingChapter
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Text(label, style: TextStyle(color: _palette.secondaryText)),
    );
  }

  Widget _buildPage(ReaderPage page, int index) {
    return SafeArea(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                _preferences.horizontalPadding,
                _preferences.topPadding,
                _preferences.horizontalPadding,
                _preferences.bottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (page.showsTitle) ...<Widget>[
                    Text(
                      _content!.title,
                      style: _titleTextStyle,
                      textScaler: _textScaler,
                    ),
                    const SizedBox(height: 28),
                  ],
                  for (final ReaderPageBlock block in page.blocks) ...<Widget>[
                    Text(
                      block.isParagraphStart
                          ? _indented(block.text)
                          : block.text,
                      style: _bodyTextStyle,
                      textScaler: _textScaler,
                    ),
                    if (block.isParagraphEnd)
                      SizedBox(height: _preferences.paragraphSpacing),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            key: const ValueKey<String>('reader-page-footer'),
            left: _preferences.horizontalPadding,
            right: _preferences.horizontalPadding,
            bottom: _pageFooterBottomInset,
            child: IgnorePointer(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _content!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    '${((_progress?.bookFraction ?? 0) * 100).toStringAsFixed(1)}% · ${index + 1}/${_pages.length}',
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _clockLabel,
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalReader() {
    final List<TextParagraph> paragraphs = _content!.paragraphs;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (_) => _setControlsVisible(!_controlsVisible),
      child: SafeArea(
        child: ListView.builder(
          controller: _verticalController,
          padding: EdgeInsets.fromLTRB(
            _preferences.horizontalPadding,
            _preferences.topPadding,
            _preferences.horizontalPadding,
            _preferences.bottomPadding,
          ),
          itemCount: paragraphs.length + 2,
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Text(
                  _content!.title,
                  style: _titleTextStyle,
                  textScaler: _textScaler,
                ),
              );
            }
            if (index == paragraphs.length + 1) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: OutlinedButton(
                  onPressed: _nextChapter,
                  child: const Text(ReaderStrings.nextChapter),
                ),
              );
            }
            final TextParagraph paragraph = paragraphs[index - 1];
            final GlobalKey key = _paragraphKeys.putIfAbsent(
              paragraph.id,
              GlobalKey.new,
            );
            return Padding(
              key: key,
              padding: EdgeInsets.only(bottom: _preferences.paragraphSpacing),
              child: Text(
                _indented(paragraph.text),
                style: _bodyTextStyle,
                textScaler: _textScaler,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildChrome() {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[_buildTopBar(), _buildSourceInfoBar()],
              ),
            ),
            Align(alignment: Alignment.bottomCenter, child: _buildBottomBar()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Material(
      color: _palette.panel,
      elevation: 6,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: ReaderStrings.back,
                onPressed: _requestExit,
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _book?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _content?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _isCurrentBookmarked
                    ? ReaderStrings.removeBookmark
                    : ReaderStrings.addBookmark,
                onPressed: _toggleBookmark,
                icon: Icon(
                  _isCurrentBookmarked
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: _isCurrentBookmarked ? _palette.accent : null,
                ),
              ),
              IconButton(
                tooltip: ReaderStrings.refreshChapter,
                onPressed: _content == null
                    ? null
                    : () => unawaited(_refreshCurrentChapter()),
                icon: const Icon(Icons.refresh_rounded),
              ),
              PopupMenuButton<_TopBarMenuAction>(
                tooltip: ReaderStrings.more,
                icon: const Icon(Icons.more_vert_rounded),
                color: _palette.panel,
                elevation: 12,
                constraints: const BoxConstraints(minWidth: 208),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: _handleTopBarMenuAction,
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<_TopBarMenuAction>>[
                      _topBarMenuItem(
                        _TopBarMenuAction.refresh,
                        Icons.refresh_rounded,
                        ReaderStrings.refreshChapter,
                      ),
                      const PopupMenuDivider(),
                      _topBarMenuItem(
                        _TopBarMenuAction.catalog,
                        Icons.list_alt_rounded,
                        ReaderStrings.catalog,
                      ),
                      _topBarMenuItem(
                        _TopBarMenuAction.bookmarks,
                        Icons.bookmarks_outlined,
                        ReaderStrings.bookmarks,
                      ),
                      _topBarMenuItem(
                        _TopBarMenuAction.theme,
                        Icons.tonality_rounded,
                        ReaderStrings.theme,
                      ),
                      _topBarMenuItem(
                        _TopBarMenuAction.settings,
                        Icons.text_fields_rounded,
                        ReaderStrings.settings,
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceInfoBar() {
    final String sourceName = _sourceDisplayName;
    final String? chapterUrl = _currentChapterUrl;
    final Uri? chapterUri = _currentChapterUri;
    final Widget chapterUrlLabel = Row(
      children: <Widget>[
        Icon(
          Icons.open_in_new_rounded,
          size: 16,
          color: chapterUri == null ? _palette.secondaryText : _palette.accent,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            chapterUrl ?? ReaderStrings.chapterUrlUnavailable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: chapterUri == null
                  ? _palette.secondaryText
                  : _palette.text,
              fontSize: 12,
              decoration: chapterUri == null ? null : TextDecoration.underline,
              decorationColor: _palette.accent,
            ),
          ),
        ),
      ],
    );

    final Widget chapterUrlAction = chapterUri == null
        ? chapterUrlLabel
        : Tooltip(
            message: chapterUrl!,
            child: Semantics(
              button: true,
              link: true,
              label: '${ReaderStrings.openChapterUrl}: $chapterUrl',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => unawaited(_openCurrentChapterUrl()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: chapterUrlLabel,
                ),
              ),
            ),
          );

    return Material(
      color: _palette.panel.withValues(alpha: 0.78),
      child: Container(
        height: 40,
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _palette.divider)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_outlined, size: 16, color: _palette.secondaryText),
            const SizedBox(width: 5),
            Expanded(
              flex: 2,
              child: Text(
                '${ReaderStrings.source}: $sourceName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _palette.secondaryText, fontSize: 12),
              ),
            ),
            Container(width: 1, height: 16, color: _palette.divider),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Semantics(
                label: ReaderStrings.chapterUrl,
                child: chapterUrlAction,
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_TopBarMenuAction> _topBarMenuItem(
    _TopBarMenuAction action,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_TopBarMenuAction>(
      value: action,
      height: 44,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: _palette.secondaryText),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: _palette.text)),
        ],
      ),
    );
  }

  void _handleTopBarMenuAction(_TopBarMenuAction action) {
    switch (action) {
      case _TopBarMenuAction.refresh:
        unawaited(_refreshCurrentChapter());
        break;
      case _TopBarMenuAction.catalog:
        _showLibrarySheet();
        break;
      case _TopBarMenuAction.bookmarks:
        _showLibrarySheet(initialIndex: 1);
        break;
      case _TopBarMenuAction.theme:
      case _TopBarMenuAction.settings:
        _showSettingsSheet();
        break;
    }
  }

  Future<void> _refreshCurrentChapter() async {
    final String? chapterId = _content?.chapterId;
    if (chapterId == null) return;
    await _openChapter(chapterId, forceRefresh: true);
  }

  String get _sourceDisplayName {
    final String? sourceName = _book?.sourceName?.trim();
    return sourceName == null || sourceName.isEmpty
        ? ReaderStrings.sourceUnavailable
        : sourceName;
  }

  String? get _currentChapterUrl {
    final String? chapterUrl = _content?.chapterUrl?.trim();
    return chapterUrl == null || chapterUrl.isEmpty ? null : chapterUrl;
  }

  Uri? get _currentChapterUri {
    final String? chapterUrl = _currentChapterUrl;
    final Uri? uri = chapterUrl == null ? null : Uri.tryParse(chapterUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return switch (uri.scheme) {
      'http' || 'https' => uri,
      _ => null,
    };
  }

  Future<void> _openCurrentChapterUrl() async {
    final Uri? uri = _currentChapterUri;
    if (uri == null) {
      await _reportFailure(
        const ReaderFailure(
          ReaderFailureKind.platform,
          ReaderStrings.chapterUrlInvalid,
        ),
      );
      return;
    }
    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError(ReaderStrings.chapterUrlOpenFailed);
      }
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  Widget _buildBottomBar() {
    final double progress = _sliderPreview ?? _progress?.bookFraction ?? 0;
    return Material(
      color: _palette.panel,
      elevation: 10,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _previousChapter,
                    child: const Text(ReaderStrings.previousChapter),
                  ),
                  Expanded(
                    child: Slider(
                      value: progress.clamp(0, 1),
                      onChanged: (double value) =>
                          setState(() => _sliderPreview = value),
                      onChangeEnd: _jumpToBookFraction,
                    ),
                  ),
                  TextButton(
                    onPressed: _nextChapter,
                    child: const Text(ReaderStrings.nextChapter),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  _barAction(
                    Icons.list_alt_rounded,
                    ReaderStrings.catalog,
                    () => _showLibrarySheet(),
                  ),
                  _barAction(
                    Icons.bookmarks_outlined,
                    ReaderStrings.bookmarks,
                    () => _showLibrarySheet(initialIndex: 1),
                  ),
                  _barAction(
                    Icons.tonality_rounded,
                    ReaderStrings.theme,
                    _showThemeSheet,
                  ),
                  _barAction(
                    Icons.text_fields_rounded,
                    ReaderStrings.settings,
                    _showSettingsSheet,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barAction(IconData icon, String label, VoidCallback action) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: action,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 22),
                const SizedBox(height: 3),
                Text(label, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _clockLabel {
    final String hour = _clock.hour.toString().padLeft(2, '0');
    final String minute = _clock.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _jumpToBookFraction(double value) async {
    setState(() => _sliderPreview = null);
    if (value <= 0) {
      await _showBookPreview();
      return;
    }
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (total <= 0) return;
    final double exact = (value.clamp(0, 1) * total)
        .clamp(0, total - 0.000001)
        .toDouble();
    final int index = exact.floor().clamp(0, total - 1);
    final double chapterFraction = exact - index;
    try {
      final ReaderChapterInfo chapter = await _chapterInfoAtIndex(index);
      await _openChapter(chapter.id, targetChapterFraction: chapterFraction);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  bool get _isCurrentBookmarked {
    final ReaderProgress? progress = _progress;
    if (progress == null) return false;
    return _bookmarks.any(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
  }

  Future<void> _toggleBookmark() async {
    final ReaderProgress? progress = _progress;
    final TextChapterContent? content = _content;
    if (progress == null || content == null || content.paragraphs.isEmpty) {
      return;
    }
    final int existing = _bookmarks.indexWhere(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
    try {
      if (existing >= 0) {
        final ReaderBookmark bookmark = _bookmarks[existing];
        await widget.stateStore.removeBookmark(widget.bookId, bookmark.id);
        setState(() {
          _bookmarks = List.unmodifiable(
            _bookmarks.where((item) => item.id != bookmark.id),
          );
        });
      } else {
        final TextParagraph paragraph = content.paragraphs.firstWhere(
          (item) => item.id == progress.paragraphId,
          orElse: () => content.paragraphs.first,
        );
        final ReaderBookmark bookmark = ReaderBookmark(
          id: '${widget.bookId}-${DateTime.now().microsecondsSinceEpoch}',
          bookId: widget.bookId,
          chapterId: progress.chapterId,
          paragraphId: progress.paragraphId,
          characterOffset: progress.characterOffset,
          chapterTitle: content.title,
          excerpt: paragraph.text.length > 48
              ? '${paragraph.text.substring(0, 48)}…'
              : paragraph.text,
          createdAt: DateTime.now(),
        );
        await widget.stateStore.addBookmark(bookmark);
        setState(
          () => _bookmarks = List.unmodifiable(<ReaderBookmark>[
            ..._bookmarks,
            bookmark,
          ]),
        );
      }
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
    }
  }

  void _showLibrarySheet({int initialIndex = 0}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _palette.panel,
      builder: (BuildContext sheetContext) {
        return DefaultTabController(
          length: 2,
          initialIndex: initialIndex,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              children: <Widget>[
                const TabBar(
                  tabs: <Widget>[
                    Tab(text: ReaderStrings.catalog),
                    Tab(text: ReaderStrings.bookmarks),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _buildCatalogList(sheetContext),
                      _buildBookmarkList(sheetContext),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCatalogList(BuildContext sheetContext) {
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setSheetState) {
        return ListView.builder(
          itemCount: _catalog.length + (_catalogHasMore ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _catalog.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: _catalogLoading
                      ? null
                      : () async {
                          await _loadMoreCatalog();
                          setSheetState(() {});
                        },
                  child: Text(
                    _catalogLoading
                        ? ReaderStrings.loading
                        : ReaderStrings.loadMoreChapters,
                  ),
                ),
              );
            }
            final ReaderChapterInfo chapter = _catalog[index];
            return ListTile(
              selected: chapter.id == _content?.chapterId,
              selectedColor: _palette.accent,
              leading: SizedBox(width: 42, child: Text('${chapter.index + 1}')),
              title: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openChapter(chapter.id));
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBookmarkList(BuildContext sheetContext) {
    if (_bookmarks.isEmpty) {
      return const Center(child: Text(ReaderStrings.noBookmarks));
    }
    return ListView.builder(
      itemCount: _bookmarks.length,
      itemBuilder: (BuildContext context, int index) {
        final ReaderBookmark bookmark = _bookmarks[index];
        return ListTile(
          title: Text(bookmark.chapterTitle),
          subtitle: Text(
            bookmark.excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: ReaderStrings.removeBookmark,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              await widget.stateStore.removeBookmark(
                widget.bookId,
                bookmark.id,
              );
              if (!mounted || !sheetContext.mounted) return;
              setState(() {
                _bookmarks = List.unmodifiable(
                  _bookmarks.where((item) => item.id != bookmark.id),
                );
              });
              Navigator.of(sheetContext).pop();
            },
          ),
          onTap: () {
            _progress = ReaderProgress(
              chapterId: bookmark.chapterId,
              paragraphId: bookmark.paragraphId,
              characterOffset: bookmark.characterOffset,
            );
            Navigator.of(sheetContext).pop();
            unawaited(_openChapter(bookmark.chapterId, initial: true));
          },
        );
      },
    );
  }

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _palette.panel,
      builder: (BuildContext context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(
                title: Text(
                  ReaderStrings.readerSettings,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.text_fields_rounded),
                title: const Text(ReaderStrings.typography),
                subtitle: const Text(ReaderStrings.fontOptions),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showTypographySheet,
              ),
              ListTile(
                leading: const Icon(Icons.format_line_spacing_rounded),
                title: const Text(ReaderStrings.layout),
                subtitle: const Text(ReaderStrings.layoutOptions),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showLayoutSheet,
              ),
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text(ReaderStrings.displayAndPaging),
                subtitle: const Text(ReaderStrings.displayOptions),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showDisplaySheet,
              ),
              if (_platformCapabilities.keepScreenOn ||
                  _platformCapabilities.immersiveMode)
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: const Text(ReaderStrings.deviceCapabilities),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showDeviceSheet,
                ),
            ],
          ),
        );
      },
    );
  }

  void _showThemeSheet() => _showChoiceSheet(
    ReaderStrings.themeTitle,
    ReaderThemePreset.values,
    _preferences.theme,
    (ReaderThemePreset v) =>
        _updatePreferences(_preferences.copyWith(theme: v)),
    (ReaderThemePreset v) => switch (v) {
      ReaderThemePreset.day => ReaderStrings.day,
      ReaderThemePreset.eyeCare => ReaderStrings.eyeCare,
      ReaderThemePreset.parchment => ReaderStrings.parchment,
      ReaderThemePreset.night => ReaderStrings.night,
    },
  );
  void _showTypographySheet() {
    TextReaderPreferences sheetPreferences = _preferences;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _palette.panel,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(TextReaderPreferences next) {
            final TextReaderPreferences normalized = next.normalized();
            setSheetState(() => sheetPreferences = normalized);
            unawaited(_updatePreferences(normalized));
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const ListTile(title: Text(ReaderStrings.typography)),
                  ...ReaderFontPreset.values.map(
                    (ReaderFontPreset v) => ListTile(
                      selected: v == sheetPreferences.font,
                      title: Text(
                        v == ReaderFontPreset.system
                            ? ReaderStrings.miSans
                            : v == ReaderFontPreset.serif
                            ? ReaderStrings.serif
                            : ReaderStrings.sansSerif,
                      ),
                      trailing: v == sheetPreferences.font
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => update(sheetPreferences.copyWith(font: v)),
                    ),
                  ),
                  _choiceChips(
                    ReaderStrings.fontSize,
                    <num>[16, 19, 22, 26, 32],
                    sheetPreferences.fontSize,
                    (num v) =>
                        sheetPreferences.copyWith(fontSize: v.toDouble()),
                    update,
                  ),
                  _choiceChips(
                    ReaderStrings.fontWeight,
                    <num>[400, 500, 600],
                    sheetPreferences.fontWeight,
                    (num v) => sheetPreferences.copyWith(fontWeight: v.toInt()),
                    update,
                  ),
                  _choiceChips(
                    ReaderStrings.letterSpacing,
                    <num>[0, .2, .8],
                    sheetPreferences.letterSpacing,
                    (num v) =>
                        sheetPreferences.copyWith(letterSpacing: v.toDouble()),
                    update,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showLayoutSheet() =>
      _showNumberSheet(ReaderStrings.layout, <String, List<num>>{
        ReaderStrings.lineHeight: <num>[1.5, 1.8, 2.1],
        ReaderStrings.paragraphSpacing: <num>[8, 14, 22],
        ReaderStrings.firstLineIndent: <num>[0, 1, 2],
        ReaderStrings.pageMargin: <num>[16, 24, 40],
        ReaderStrings.topMargin: <num>[8, 24, 40, 64],
        ReaderStrings.bottomMargin: <num>[8, 24, 40, 64],
      });
  void _showDisplaySheet() {
    TextReaderPreferences sheetPreferences = _preferences;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _palette.panel,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(TextReaderPreferences next) {
            final TextReaderPreferences normalized = next.normalized();
            setSheetState(() => sheetPreferences = normalized);
            unawaited(_updatePreferences(normalized));
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const ListTile(title: Text(ReaderStrings.displayAndPaging)),
                  _choiceChips(
                    ReaderStrings.brightness,
                    <num>[.25, .5, .75, 1],
                    sheetPreferences.brightness,
                    (num v) =>
                        sheetPreferences.copyWith(brightness: v.toDouble()),
                    update,
                  ),
                  const ListTile(title: Text(ReaderStrings.readingMode)),
                  ...ReaderNavigationMode.values.map(
                    (ReaderNavigationMode v) => ListTile(
                      selected: v == sheetPreferences.navigationMode,
                      title: Text(
                        v == ReaderNavigationMode.horizontalPages
                            ? ReaderStrings.horizontal
                            : ReaderStrings.vertical,
                      ),
                      trailing: v == sheetPreferences.navigationMode
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        final next = sheetPreferences.copyWith(
                          navigationMode: v,
                        );
                        update(next);
                      },
                    ),
                  ),
                  ListTile(
                    title: const Text(ReaderStrings.pageAnimation),
                    subtitle:
                        sheetPreferences.navigationMode ==
                            ReaderNavigationMode.verticalScroll
                        ? const Text(ReaderStrings.animationVerticalHint)
                        : null,
                  ),
                  if (sheetPreferences.navigationMode ==
                      ReaderNavigationMode.horizontalPages)
                    ...ReaderPageAnimation.values.map(
                      (ReaderPageAnimation v) => ListTile(
                        selected: v == sheetPreferences.pageAnimation,
                        title: Text(
                          v == ReaderPageAnimation.slide
                              ? ReaderStrings.slide
                              : ReaderStrings.noAnimation,
                        ),
                        trailing: v == sheetPreferences.pageAnimation
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          final next = sheetPreferences.copyWith(
                            pageAnimation: v,
                          );
                          update(next);
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDeviceSheet() {
    TextReaderPreferences sheetPreferences = _preferences;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _palette.panel,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(TextReaderPreferences next) {
            final TextReaderPreferences normalized = next.normalized();
            setSheetState(() => sheetPreferences = normalized);
            unawaited(_updatePreferences(normalized));
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const ListTile(title: Text(ReaderStrings.deviceCapabilities)),
                if (_platformCapabilities.keepScreenOn)
                  SwitchListTile(
                    title: const Text(ReaderStrings.keepScreenOn),
                    value: sheetPreferences.keepScreenOn,
                    onChanged: (bool value) =>
                        update(sheetPreferences.copyWith(keepScreenOn: value)),
                  ),
                if (_platformCapabilities.immersiveMode)
                  SwitchListTile(
                    title: const Text(ReaderStrings.immersiveReading),
                    value: sheetPreferences.immersiveMode,
                    onChanged: (bool value) =>
                        update(sheetPreferences.copyWith(immersiveMode: value)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showChoiceSheet<T>(
    String title,
    List<T> values,
    T selected,
    Future<void> Function(T) change,
    String Function(T) label,
  ) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: _palette.panel,
    builder: (BuildContext c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(title: Text(title)),
          ...values.map(
            (T v) => ListTile(
              selected: v == selected,
              title: Text(label(v)),
              trailing: v == selected ? const Icon(Icons.check) : null,
              onTap: () {
                unawaited(change(v));
                Navigator.pop(c);
              },
            ),
          ),
        ],
      ),
    ),
  );
  void _showNumberSheet(String title, Map<String, List<num>> groups) {
    TextReaderPreferences sheetPreferences = _preferences;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _palette.panel,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(TextReaderPreferences next) {
            final TextReaderPreferences normalized = next.normalized();
            setSheetState(() => sheetPreferences = normalized);
            unawaited(_updatePreferences(normalized));
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(title: Text(title)),
                  for (final MapEntry<String, List<num>> entry
                      in groups.entries) ...<Widget>[
                    ListTile(title: Text(entry.key)),
                    Wrap(
                      children: entry.value
                          .map(
                            (num value) => ChoiceChip(
                              label: Text(_optionLabel(entry.key, value)),
                              selected: _optionSelected(
                                sheetPreferences,
                                entry.key,
                                value,
                              ),
                              onSelected: (_) {
                                final TextReaderPreferences next =
                                    switch (entry.key) {
                                      ReaderStrings.lineHeight =>
                                        sheetPreferences.copyWith(
                                          lineHeight: value.toDouble(),
                                        ),
                                      ReaderStrings.paragraphSpacing =>
                                        sheetPreferences.copyWith(
                                          paragraphSpacing: value.toDouble(),
                                        ),
                                      ReaderStrings.firstLineIndent =>
                                        sheetPreferences.copyWith(
                                          firstLineIndent: value.toInt(),
                                        ),
                                      ReaderStrings.pageMargin =>
                                        sheetPreferences.copyWith(
                                          horizontalPadding: value.toDouble(),
                                        ),
                                      ReaderStrings.topMargin =>
                                        sheetPreferences.copyWith(
                                          topPadding: value.toDouble(),
                                        ),
                                      ReaderStrings.bottomMargin =>
                                        sheetPreferences.copyWith(
                                          bottomPadding: value.toDouble(),
                                        ),
                                      _ => sheetPreferences,
                                    };
                                update(next);
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _choiceChips(
    String title,
    List<num> values,
    num selected,
    TextReaderPreferences Function(num) apply,
    void Function(TextReaderPreferences) update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      ListTile(title: Text(title)),
      Wrap(
        children: values
            .map(
              (num v) => ChoiceChip(
                label: Text(_optionLabel(title, v)),
                selected: v == selected,
                onSelected: (_) => update(apply(v)),
              ),
            )
            .toList(),
      ),
    ],
  );

  bool _optionSelected(
    TextReaderPreferences preferences,
    String field,
    num value,
  ) => switch (field) {
    ReaderStrings.lineHeight => preferences.lineHeight == value,
    ReaderStrings.paragraphSpacing => preferences.paragraphSpacing == value,
    ReaderStrings.firstLineIndent => preferences.firstLineIndent == value,
    ReaderStrings.pageMargin => preferences.horizontalPadding == value,
    ReaderStrings.topMargin => preferences.topPadding == value,
    ReaderStrings.bottomMargin => preferences.bottomPadding == value,
    ReaderStrings.fontSize => preferences.fontSize == value,
    ReaderStrings.fontWeight => preferences.fontWeight == value,
    ReaderStrings.letterSpacing => preferences.letterSpacing == value,
    ReaderStrings.brightness => preferences.brightness == value,
    _ => false,
  };

  String _optionLabel(String field, num value) {
    if (field == ReaderStrings.firstLineIndent) {
      return switch (value.toInt()) {
        0 => ReaderStrings.none,
        1 => ReaderStrings.oneCharacter,
        _ => ReaderStrings.twoCharacters,
      };
    }
    if (field == ReaderStrings.pageMargin) {
      return value == 16
          ? ReaderStrings.narrow
          : value == 24
          ? ReaderStrings.standard
          : ReaderStrings.wide;
    }
    if (field == ReaderStrings.lineHeight ||
        field == ReaderStrings.paragraphSpacing) {
      final num compact = field == ReaderStrings.lineHeight ? 1.5 : 8;
      final num standard = field == ReaderStrings.lineHeight ? 1.8 : 14;
      return value == compact
          ? ReaderStrings.compact
          : value == standard
          ? ReaderStrings.standard
          : ReaderStrings.relaxed;
    }
    if (field == ReaderStrings.fontSize) {
      return value == 16
          ? ReaderStrings.small
          : value == 19
          ? ReaderStrings.standard
          : value == 22
          ? ReaderStrings.large
          : value == 26
          ? ReaderStrings.extraLarge
          : ReaderStrings.huge;
    }
    if (field == ReaderStrings.fontWeight) {
      return value == 400
          ? ReaderStrings.regular
          : value == 500
          ? ReaderStrings.medium
          : ReaderStrings.bold;
    }
    if (field == ReaderStrings.letterSpacing) {
      return value == 0
          ? ReaderStrings.compact
          : value == .2
          ? ReaderStrings.standard
          : ReaderStrings.relaxed;
    }
    if (field == ReaderStrings.brightness) {
      return value == .25
          ? ReaderStrings.percent25
          : value == .5
          ? ReaderStrings.percent50
          : value == .75
          ? ReaderStrings.percent75
          : ReaderStrings.percent100;
    }
    return '$value';
  }
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: TextStyle(color: color, fontSize: 15),
      child: Center(child: child),
    );
  }
}

class _ReaderNotice extends StatelessWidget {
  const _ReaderNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: const Alignment(0, 0.72),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xD92A2926),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderScrollBehavior extends MaterialScrollBehavior {
  const _ReaderScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
