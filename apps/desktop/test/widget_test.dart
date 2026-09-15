import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_desktop/main.dart';

void main() {
  testWidgets('desktop shell shows meter readings', (tester) async {
    await tester.pumpWidget(const DesktopApp());

    expect(find.text('Meter readings'), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget);
  });
}
