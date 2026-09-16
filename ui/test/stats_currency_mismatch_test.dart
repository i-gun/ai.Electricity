import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart';
import 'package:ai_electricity_ui/ui.dart';

void main() {
  // Regression test: rates recorded in one currency (e.g. UAH) must not crash
  // the Stats tab when the app's display currency defaults elsewhere (EUR).
  testWidgets('stats renders when display currency differs from stored rates',
      (tester) async {
    final zones = [
      TariffZone(1, ZoneCode('total'), 'Total', ZoneKind.total,
          colorArgb: 0xff008577, isArchived: true),
      TariffZone(2, ZoneCode('day'), 'Day', ZoneKind.day,
          colorArgb: 0xfff4b400, sortOrder: 1),
      TariffZone(3, ZoneCode('night'), 'Night', ZoneKind.night,
          colorArgb: 0xff4285f4, sortOrder: 2),
    ];
    final rates = [
      TariffRate(
          3, 'day', Money(486, currencyCode: 'UAH'), DateTime(2025, 9, 1)),
      TariffRate(
          4, 'night', Money(243, currencyCode: 'UAH'), DateTime(2025, 9, 1)),
    ];
    final raw = <List<Object>>[
      ['day', DateTime(2025, 9, 1), 0.0],
      ['night', DateTime(2025, 9, 1), 0.0],
      ['day', DateTime(2025, 9, 15), 7.8],
      ['night', DateTime(2025, 9, 15), 5.4],
      ['day', DateTime(2026, 9, 14), 138.6],
      ['night', DateTime(2026, 9, 14), 90.3],
      ['day', DateTime(2026, 8, 31), 132.2],
      ['night', DateTime(2026, 8, 31), 85.8],
      ['day', DateTime(2025, 9, 21), 10.8],
      ['night', DateTime(2025, 9, 21), 7.4],
      ['day', DateTime(2025, 9, 24), 11.6],
      ['night', DateTime(2025, 9, 24), 7.8],
      ['day', DateTime(2025, 10, 1), 15.4],
      ['night', DateTime(2025, 10, 1), 9.9],
      ['day', DateTime(2025, 10, 14), 20.7],
      ['night', DateTime(2025, 10, 14), 13.2],
      ['day', DateTime(2026, 7, 28), 106.6],
      ['night', DateTime(2026, 7, 28), 66.6],
      ['day', DateTime(2025, 11, 1), 29.6],
      ['night', DateTime(2025, 11, 1), 19.0],
      ['day', DateTime(2025, 12, 1), 44.1],
      ['night', DateTime(2025, 12, 1), 27.2],
      ['day', DateTime(2026, 5, 6), 70.0],
      ['night', DateTime(2026, 5, 6), 39.1],
      ['day', DateTime(2026, 6, 26), 84.5],
      ['night', DateTime(2026, 6, 26), 50.3],
      ['day', DateTime(2026, 7, 6), 90.5],
      ['night', DateTime(2026, 7, 6), 55.0],
      ['day', DateTime(2026, 9, 16), 139.2],
      ['night', DateTime(2026, 9, 16), 90.7],
    ];
    final readings = [
      for (var i = 0; i < raw.length; i++)
        MeterReading(i + 1, raw[i][0] as String, raw[i][1] as DateTime,
            Kwh(raw[i][2] as double)),
    ];

    final range = DateRange.lastMonths(3);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatsView(
                readings: readings,
                rates: rates,
                zones: zones,
                range: range,
                rangeKey: '3M',
                currencyCode: 'EUR',
                onRangeChanged: (_, __) {}))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
