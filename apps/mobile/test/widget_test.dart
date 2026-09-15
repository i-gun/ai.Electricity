import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_mobile/main.dart';

void main() {
  testWidgets('mobile shell shows meter readings', (tester) async {
    await tester.pumpWidget(const MobileApp());

    expect(find.text('Meter readings'), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget);
  });
}
