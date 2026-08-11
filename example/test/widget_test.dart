import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui_example/main.dart';

void main() {
  testWidgets('example opens the reader', (WidgetTester tester) async {
    await tester.pumpWidget(const ReaderExampleApp());
    expect(find.text('山灯未眠'), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);
  });
}
