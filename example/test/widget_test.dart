import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui_example/main.dart';

void main() {
  testWidgets('example opens the reader', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderExampleApp());
    expect(find.text('山灯未眠'), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.text('0 FPS · 小窗'), findsOneWidget);

    await tester.tap(find.text('0 FPS · 小窗'));
    await tester.pump();

    expect(find.text('0 FPS · 全局'), findsOneWidget);
  });
}
