# novel_reader_ui

一个可嵌入 Flutter App 的文本小说阅读器插件，提供异步章节加载、横向分页、纵向滚动、目录、书签、主题与排版设置，并在 Android 和 Windows 上管理阅读期间的屏幕常亮。

## 平台

| 平台 | 状态 | 原生能力 |
| --- | --- | --- |
| Android | 优先支持 | 常亮与可选沉浸阅读（默认关闭；系统边缘滑动可临时唤出栏） |
| Windows | 支持 | `SetThreadExecutionState` 常亮；不接管宿主全屏 |

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
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async {
    return api.fetchChapterInfoAtIndex(bookId, index);
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

阅读器默认进入索引 `-1` 的书籍信息预览，不加载任何章节正文。`loadChapterAtIndex` 用于全书进度条随机定位章节，不会为了跳转顺序遍历所有目录页。

阅读器默认进入索引 `-1` 的书籍信息预览，不加载任何章节正文。`loadChapterAtIndex` 用于全书进度条随机定位章节，不会为了跳转顺序遍历所有目录页。

如需在阅读顶部展示来源并让用户在外部浏览器查看当前章节，可在
`ReaderBookInfo.sourceName` 和 `TextChapterContent.chapterUrl` 中提供可选值。插件只接受
HTTP/HTTPS 链接，并且仅在用户点击链接时打开外部浏览器。

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
- 左右翻页同时支持触摸和鼠标按住拖动。
- 可切换上下连续滚动。
- 目录分页、当前章高亮和进度跳转。
- 语义书签的添加、跳转和删除。
- 日间、护眼、羊皮纸、夜间主题。
- 独立主题面板（四套配色）及多级设置：字体、排版、显示与翻页、设备能力。
- 字体、字号、字重、字距、行距、段距、首行缩进、页边距和阅读区域亮度；旧持久化值会归一到最近预设。
- Android 返回键及 Windows 键盘、鼠标交互。
- 前后台生命周期通知、进度 flush 和引用计数常亮。
- 最后一章继续前进时显示“没有下一章了”，不会停在空白边界页。

正文和排版严格按需处理：内存只保留当前章和下一章正文，只有当前章会执行分页；返回上一章时重新加载、临时排版并定位到末页。不支持原生常亮的平台会忽略并隐藏常亮设置。

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

## VS Code 任务按钮

安装推荐的 `spencerwmiles.vscode-task-buttons` 扩展后，状态栏会提供：

- `开发运行`：在 `example/` 中启动 Flutter 开发版本，并自动选择设备。
- `发布 APK`：执行 Android Release 构建。
- `发布 Windows EXE`：执行 Windows Release 构建。

也可以直接按 `F5`，在 Flutter/Dart 调试配置中选择 `Example（选择设备）` 或
`Example（Windows）`。发布任务不会使用 debug 构建，Android APK 固定为单一
`arm64-v8a`（ARMv8）架构，Windows 固定为 `x64` 架构：APK 位于
`build/novel_reader_ui_example-release.apk`；Windows 完整应用位于
`build/novel_reader_ui_example-windows-release/`，任务会自动从 Flutter 的深层构建目录复制过去。需要将该目录整体作为 Windows 应用分发，不能只复制 EXE 文件。

## 验证

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
cd example
flutter analyze
```

项目不保留或运行自动化测试与 Golden 截图，也不把构建作为 Agent 验证步骤。Android 与 Windows 运行时行为由宿主通过 `example/` 人工检查。

完整工程约定见 [AGENTS.md](AGENTS.md)。
