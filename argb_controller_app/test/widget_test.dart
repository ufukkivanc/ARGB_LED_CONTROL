import 'package:flutter_test/flutter_test.dart';
import 'package:argb_controller/main.dart';

void main() {
  testWidgets('ARGB Controller Dashboard loads smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ArgbControllerApp());
    expect(find.text('ESP32 ARGB CONTROLLER'), findsOneWidget);
  });
}
