import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../pagination/text_paginator.dart';
import '../platform/screen_awake_coordinator.dart';
import 'reader_strings.dart';
import 'reader_theme.dart';

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
  static const int _chapterCacheLimit = 3;

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

  ReaderBookInfo? _book;
  final List<ReaderChapterInfo> _catalog = <ReaderChapterInfo>[];
  String? _catalogCursor;
  int _catalogTotal = 0;
  bool _catalogHasMore = false;
  bool _catalogLoading = false;
  TextChapterContent? _content;
  List<ReaderPage> _pages = const <ReaderPage>[];
  List<ReaderBookmark> _bookmarks = const <ReaderBookmark>[];
  TextReaderPreferences _preferences = TextReaderPreferences.defaults;
  ReaderProgress? _progress;
  ReaderFailure? _failure;
  Size? _layoutSize;
  int _chapterIndex = 0;
  int _pageIndex = 0;
  int _requestGeneration = 0;
  int _sessionGeneration = 0;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _foreground = true;
  bool _awakeAcquired = false;
  bool _changingChapter = false;
  bool _disposed = false;
  double? _sliderPreview;

  ReaderObserver get _observer => widget.observer ?? const ReaderObserver();
  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);
  ReaderChapterInfo? get _currentChapter =>
      _catalog.isEmpty || _chapterIndex >= _catalog.length
      ? null
      : _catalog[_chapterIndex];

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextReaderController();
    _bindController();
    _verticalController.addListener(_handleVerticalScroll);
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    unawaited(_initialize());
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
    _content = null;
    _pages = const <ReaderPage>[];
    _progress = null;
    _failure = null;
    _layoutSize = null;
    if (mounted) setState(() => _loading = true);
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
      _progress = results[2] as ReaderProgress?;
      _preferences = results[3] as TextReaderPreferences;
      _bookmarks = results[4] as List<ReaderBookmark>;

      if (_catalog.isEmpty) {
        throw const ReaderFailure(ReaderFailureKind.data, '这本书还没有可阅读的章节');
      }

      final String targetChapter = _progress?.chapterId ?? _catalog.first.id;
      while (_catalog.indexWhere((item) => item.id == targetChapter) < 0 &&
          _catalogHasMore) {
        await _loadMoreCatalog(notify: false);
        if (!_isSessionCurrent(generation)) return;
      }

      await _openChapter(targetChapter, initial: true);
      if (!_isSessionCurrent(generation)) return;
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

  Future<void> _loadMoreCatalog({bool notify = true}) async {
    if (_catalogLoading || !_catalogHasMore) return;
    _catalogLoading = true;
    if (notify && mounted) setState(() {});
    try {
      final ChapterCatalogPage page = await widget.dataSource
          .loadChapterCatalog(widget.bookId, cursor: _catalogCursor);
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
  }) async {
    if (chapterId.isEmpty || _changingChapter) return;
    final int targetIndex = _catalog.indexWhere((item) => item.id == chapterId);
    if (targetIndex < 0) return;
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
      _cacheChapter(chapter);
      _chapterIndex = targetIndex;
      _content = chapter;
      _pages = const <ReaderPage>[];
      _layoutSize = null;
      _pageIndex = 0;
      _paragraphKeys.clear();

      final ReaderProgress? saved = _progress;
      final TextParagraph first = chapter.paragraphs.isEmpty
          ? const TextParagraph(id: '', text: '')
          : chapter.paragraphs.first;
      if (initial && saved?.chapterId == chapterId) {
        _progress = saved;
      } else {
        final TextParagraph anchor = openAtEnd && chapter.paragraphs.isNotEmpty
            ? chapter.paragraphs.last
            : first;
        _progress = _progressForAnchor(
          anchor.id,
          openAtEnd ? anchor.text.length : 0,
          chapterFraction: openAtEnd ? 1 : 0,
        );
      }
      _failure = null;
      if (mounted) setState(() {});
      _publishSnapshot();
      await _notify(() => _observer.onChapterChanged(_catalog[targetIndex]));
      _scheduleProgressSave(immediate: true);
      unawaited(_prefetchAround(targetIndex));
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

  Future<void> _prefetchAround(int index) async {
    for (final int candidate in <int>[index - 1, index + 1]) {
      if (candidate < 0 || candidate >= _catalog.length) continue;
      final String id = _catalog[candidate].id;
      if (_chapterCache.containsKey(id)) continue;
      try {
        final TextChapterContent content = await widget.dataSource
            .loadChapterContent(widget.bookId, id);
        if (_disposed) return;
        _validateChapter(content);
        _cacheChapter(content);
      } catch (_) {
        // Prefetch is intentionally best effort. Foreground loading reports errors.
      }
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
    final double height = (size.height - safe.top - safe.bottom - 72).clamp(
      80,
      size.height,
    );
    final TextStyle bodyStyle = _bodyTextStyle;
    try {
      final List<ReaderPage> pages = _paginator.paginate(
        chapter: content,
        width: width,
        height: height,
        titleStyle: _titleTextStyle,
        bodyStyle: bodyStyle,
        paragraphSpacing: _preferences.paragraphSpacing,
        textDirection: Directionality.of(context),
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
    fontSize: _preferences.fontSize,
    height: _preferences.lineHeight,
    letterSpacing: 0.2,
  );

  TextStyle get _titleTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
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
    if (_chapterIndex + 1 >= _catalog.length && _catalogHasMore) {
      await _loadMoreCatalog();
    }
    if (_chapterIndex + 1 < _catalog.length) {
      await _openChapter(_catalog[_chapterIndex + 1].id);
    }
  }

  Future<void> _previousChapter() async {
    if (_chapterIndex > 0) {
      await _openChapter(_catalog[_chapterIndex - 1].id, openAtEnd: true);
    }
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
        normalized.lineHeight != _preferences.lineHeight ||
        normalized.paragraphSpacing != _preferences.paragraphSpacing ||
        normalized.horizontalPadding != _preferences.horizontalPadding ||
        normalized.navigationMode != _preferences.navigationMode;
    setState(() {
      _preferences = normalized;
      if (layoutChanged) _layoutSize = null;
    });
    try {
      await widget.stateStore.savePreferences(normalized);
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
    final bool foreground = normalized == ReaderLifecycleState.foreground;
    if (_foreground == foreground &&
        normalized == ReaderLifecycleState.foreground) {
      return;
    }
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
        _preferences.keepScreenOn;
    if (shouldAcquire && !_awakeAcquired) {
      try {
        await ScreenAwakeCoordinator.instance.acquire(_awakeHolder);
        _awakeAcquired = true;
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
        isReady: _content != null && _failure == null,
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
                  return Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      _buildContent(),
                      if (_content != null) _buildChrome(),
                      IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: (1 - _preferences.brightness) * 0.65,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
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
    if (_content == null) return const SizedBox.shrink();
    return _preferences.navigationMode == ReaderNavigationMode.horizontalPages
        ? _buildHorizontalReader()
        : _buildVerticalReader();
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
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (TapUpDetails details) {
        final double fraction = details.localPosition.dx / context.size!.width;
        if (fraction < 0.3) {
          unawaited(_previousPage());
        } else if (fraction > 0.7) {
          unawaited(_nextPage());
        } else {
          _setControlsVisible(!_controlsVisible);
        }
      },
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
    );
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
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _preferences.horizontalPadding,
          22,
          _preferences.horizontalPadding,
          34,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (page.showsTitle) ...<Widget>[
                    Text(_content!.title, style: _titleTextStyle),
                    const SizedBox(height: 28),
                  ],
                  for (final ReaderPageBlock block in page.blocks) ...<Widget>[
                    Text(
                      block.isParagraphStart
                          ? '\u3000\u3000${block.text}'
                          : block.text,
                      style: _bodyTextStyle,
                    ),
                    if (block.isParagraphEnd)
                      SizedBox(height: _preferences.paragraphSpacing),
                  ],
                ],
              ),
            ),
            Row(
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
                  '${index + 1} / ${_pages.length}',
                  style: TextStyle(color: _palette.secondaryText, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
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
            28,
            _preferences.horizontalPadding,
            40,
          ),
          itemCount: paragraphs.length + 2,
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Text(_content!.title, style: _titleTextStyle),
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
                '\u3000\u3000${paragraph.text}',
                style: _bodyTextStyle,
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
            Align(alignment: Alignment.topCenter, child: _buildTopBar()),
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
            ],
          ),
        ),
      ),
    );
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
                    _showSettingsSheet,
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
    return InkWell(
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
    );
  }

  Future<void> _jumpToBookFraction(double value) async {
    setState(() => _sliderPreview = null);
    if (_catalog.isEmpty) return;
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    int index = (value * (total - 1).clamp(0, total)).round();
    while (index >= _catalog.length && _catalogHasMore) {
      await _loadMoreCatalog();
    }
    index = index.clamp(0, _catalog.length - 1);
    await _openChapter(_catalog[index].id);
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
                    _catalogLoading ? ReaderStrings.loading : '加载更多章节',
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
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            void update(TextReaderPreferences value) {
              unawaited(_updatePreferences(value));
              setSheetState(() {});
            }

            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      ReaderStrings.theme,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: ReaderThemePreset.values.map((preset) {
                        final ReaderPalette itemPalette =
                            ReaderPalette.fromPreset(preset);
                        final String label = switch (preset) {
                          ReaderThemePreset.day => ReaderStrings.day,
                          ReaderThemePreset.eyeCare => ReaderStrings.eyeCare,
                          ReaderThemePreset.parchment =>
                            ReaderStrings.parchment,
                          ReaderThemePreset.night => ReaderStrings.night,
                        };
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: InkWell(
                              onTap: () =>
                                  update(_preferences.copyWith(theme: preset)),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                height: 52,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: itemPalette.background,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _preferences.theme == preset
                                        ? _palette.accent
                                        : itemPalette.divider,
                                    width: _preferences.theme == preset ? 2 : 1,
                                  ),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    color: itemPalette.text,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 22),
                    _settingSlider(
                      ReaderStrings.fontSize,
                      _preferences.fontSize,
                      14,
                      32,
                      (value) => update(_preferences.copyWith(fontSize: value)),
                    ),
                    _settingSlider(
                      ReaderStrings.lineHeight,
                      _preferences.lineHeight,
                      1.3,
                      2.4,
                      (value) =>
                          update(_preferences.copyWith(lineHeight: value)),
                    ),
                    _settingSlider(
                      ReaderStrings.pageMargin,
                      _preferences.horizontalPadding,
                      12,
                      64,
                      (value) => update(
                        _preferences.copyWith(horizontalPadding: value),
                      ),
                    ),
                    _settingSlider(
                      ReaderStrings.brightness,
                      _preferences.brightness,
                      0.25,
                      1,
                      (value) =>
                          update(_preferences.copyWith(brightness: value)),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<ReaderFontPreset>(
                      segments: const <ButtonSegment<ReaderFontPreset>>[
                        ButtonSegment(
                          value: ReaderFontPreset.system,
                          label: Text('默认'),
                        ),
                        ButtonSegment(
                          value: ReaderFontPreset.sansSerif,
                          label: Text('黑体'),
                        ),
                        ButtonSegment(
                          value: ReaderFontPreset.serif,
                          label: Text('宋体'),
                        ),
                      ],
                      selected: <ReaderFontPreset>{_preferences.font},
                      onSelectionChanged: (value) =>
                          update(_preferences.copyWith(font: value.first)),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<ReaderNavigationMode>(
                      segments: const <ButtonSegment<ReaderNavigationMode>>[
                        ButtonSegment(
                          value: ReaderNavigationMode.horizontalPages,
                          label: Text(ReaderStrings.horizontal),
                          icon: Icon(Icons.view_carousel_outlined),
                        ),
                        ButtonSegment(
                          value: ReaderNavigationMode.verticalScroll,
                          label: Text(ReaderStrings.vertical),
                          icon: Icon(Icons.swap_vert_rounded),
                        ),
                      ],
                      selected: <ReaderNavigationMode>{
                        _preferences.navigationMode,
                      },
                      onSelectionChanged: (value) => update(
                        _preferences.copyWith(navigationMode: value.first),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(ReaderStrings.keepScreenOn),
                      value: _preferences.keepScreenOn,
                      onChanged: (value) =>
                          update(_preferences.copyWith(keepScreenOn: value)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _settingSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: <Widget>[
        SizedBox(width: 54, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(value.toStringAsFixed(1), textAlign: TextAlign.end),
        ),
      ],
    );
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

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
