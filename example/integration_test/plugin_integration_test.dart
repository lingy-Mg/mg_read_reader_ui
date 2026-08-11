import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader_ui_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('demo book reaches the reading surface', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ReaderExampleApp());
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('第一章 雾从河面升起'), findsWidgets);
  });
}
