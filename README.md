# novel_reader_ui

一个可嵌入 Flutter App 的文本小说阅读器插件，提供异步章节加载、横向分页、纵向滚动、目录、书签、主题与排版设置，并在 Android 和 Windows 上管理阅读期间的屏幕常亮。

## 平台

| 平台 | 状态 | 原生能力 |
| --- | --- | --- |
| Android | 优先支持 | `FLAG_KEEP_SCREEN_ON` |
| Windows | 支持 | `SetThreadExecutionState` |

iOS、macOS、Linux 和 Web 暂不属于承诺支持范围。

## 接入

宿主提供异步内容接口和状态存储接口，然后嵌入 `TextReaderView`：

```dart
TextReaderView(
  bookId: book.id,
  dataSource: appReaderDataSource,
  stateStore: appReaderStateStore,
  observer: AppReaderObserver(
    onExit: () => Navigator.of(context).pop(),
  ),
)
```

### 内容接口

```dart
class AppReaderDataSource implements TextReaderDataSource {
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    return api.fetchBook(bookId);
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    return api.fetchCatalog(bookId, cursor: cursor, limit: pageSize);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    return api.fetchChapter(bookId, chapterId);
  }
}
```

每个 `TextParagraph` 必须有稳定且非空的 ID。阅读位置和书签使用 `chapterId + paragraphId + characterOffset` 保存，因此改变字体或窗口尺寸后仍能恢复到相同语义位置。

### 状态接口

宿主实现 `TextReaderStateStore`，负责保存：

- `ReaderProgress`
- `TextReaderPreferences`
- `ReaderBookmark`

插件不依赖数据库、用户系统或网络库。示例使用内存实现，生产 App 可接入 SQLite、Isar、服务端同步或自己的数据层。

### 外部控制

需要从宿主主动控制阅读器时传入 `TextReaderController`：

```dart
final controller = TextReaderController();

await controller.openChapter('chapter-120');
await controller.nextPage();
await controller.showControls();
```

通过 `controller.snapshot` 或监听 Controller 可以读取当前书籍、章节、进度、loading 和错误状态。

## 组件内功能

- 默认左右滑页和左/中/右点击区域。
- 可切换上下连续滚动。
- 目录分页、当前章高亮和进度跳转。
- 语义书签的添加、跳转和删除。
- 日间、护眼、羊皮纸、夜间主题。
- 字体、字号、行距、页边距和阅读区域亮度。
- Android 返回键及 Windows 键盘、鼠标交互。
- 前后台生命周期通知、进度 flush 和引用计数常亮。

评论功能首版只保留稳定目标和 capability 扩展点，不显示评论 UI，也不请求评论数据。

## 运行示例

```bash
cd example
flutter run -d <android-device>
```

Windows 主机：

```powershell
cd example
flutter run -d windows
```

示例小说《山灯未眠》是项目内原创演示文本。

## 验证

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
cd example && flutter test
cd example && flutter build apk --debug
```

Windows 构建必须在 Windows 主机或 Windows CI 上执行。

完整工程约定见 [AGENTS.md](AGENTS.md)。
