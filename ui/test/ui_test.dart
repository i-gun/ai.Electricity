import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart';
import 'package:ai_electricity_ui/ui.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  testWidgets('creates the shared light theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme(),
        home: const Placeholder(),
      ),
    );

    expect(find.byType(Placeholder), findsOneWidget);
  });

  testWidgets('reading form exposes zone, date, label and reset fields',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Add reading'));
    await tester.pumpAndSettle();

    expect(find.text('Zone'), findsOneWidget);
    expect(find.text('Reading date'), findsOneWidget);
    expect(find.text('Label (optional)'), findsOneWidget);
    expect(find.text('Meter was reset'), findsOneWidget);
  });

  testWidgets('saved reading keeps its label and appears in the list',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Add reading'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Cumulative value (kWh)'), '123.5');
    await tester.enterText(
        find.widgetWithText(TextField, 'Label (optional)'), 'photo checked');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('123.500 kWh'), findsOneWidget);
    expect(find.textContaining('photo checked'), findsOneWidget);
  });

  testWidgets('readings are split into newest-first zone tables',
      (tester) async {
    final zones = [
      TariffZone(1, ZoneCode('day'), 'Day', ZoneKind.day,
          colorArgb: 0xfff4b400, sortOrder: 1),
      TariffZone(2, ZoneCode('night'), 'Night', ZoneKind.night,
          colorArgb: 0xff4285f4, sortOrder: 2),
    ];
    final readings = [
      MeterReading(1, 'day', DateTime(2026, 3, 1), Kwh(100), note: 'older day'),
      MeterReading(2, 'night', DateTime(2026, 3, 2), Kwh(40),
          note: 'older night'),
      MeterReading(3, 'day', DateTime(2026, 3, 5), Kwh(125),
          note: 'latest day'),
      MeterReading(4, 'night', DateTime(2026, 3, 6), Kwh(55),
          note: 'latest night'),
    ];

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReadingsView(
                readings: readings,
                zones: zones,
                onAdd: () {},
                onEdit: (_) {},
                onDelete: (_) {}))));

    expect(find.text('Day'), findsOneWidget);
    expect(find.text('Night'), findsOneWidget);
    expect(find.byType(DataTable), findsNWidgets(2));
    expect(tester.getTopLeft(find.text('latest day')).dy,
        lessThan(tester.getTopLeft(find.text('older day')).dy));
    expect(tester.getTopLeft(find.text('latest night')).dy,
        lessThan(tester.getTopLeft(find.text('older night')).dy));
    expect(tester.getTopLeft(find.text('Day')).dx,
        lessThan(tester.getTopLeft(find.text('Night')).dx));
  });

  testWidgets('day zone can be activated from the zones tab', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Zones & tariffs'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Archived'), findsNWidgets(2));

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    expect(find.textContaining('Archived'), findsOneWidget);
  });

  testWidgets('new zone dialog creates a custom zone', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Zones & tariffs'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'New zone'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Zone name'), 'Weekend');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Weekend'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(find.text('Weekend'), findsOneWidget);
  });

  testWidgets('tariff rate can be edited from the zones tab', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Zones & tariffs'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Total'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit rate'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Price per kWh (EUR)'), '0.30');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('0.30 per kWh'), findsOneWidget);
    expect(find.textContaining('0.25 per kWh'), findsNothing);
  });

  testWidgets('stats renders side-by-side donuts split by zone',
      (tester) async {
    final zones = [
      TariffZone(1, ZoneCode('total'), 'Total', ZoneKind.total),
      TariffZone(2, ZoneCode('day'), 'Day', ZoneKind.day,
          colorArgb: 0xfff4b400, sortOrder: 1),
      TariffZone(3, ZoneCode('night'), 'Night', ZoneKind.night,
          colorArgb: 0xff4285f4, sortOrder: 2),
    ];
    final readings = [
      MeterReading(1, 'day', DateTime(2026, 3, 1), Kwh(100)),
      MeterReading(2, 'day', DateTime(2026, 3, 10), Kwh(130)),
      MeterReading(3, 'night', DateTime(2026, 3, 1), Kwh(40)),
      MeterReading(4, 'night', DateTime(2026, 3, 10), Kwh(50)),
    ];
    final rates = [
      TariffRate(1, 'day', Money(20), DateTime(2025, 1, 1)),
      TariffRate(2, 'night', Money(10), DateTime(2025, 1, 1)),
    ];

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatsView(
                readings: readings,
                rates: rates,
                zones: zones,
                range: DateRange(DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
                rangeKey: 'custom',
                currencyCode: 'EUR',
                onRangeChanged: (_, __) {}))));
    await tester.pumpAndSettle();

    expect(find.text('Consumption by zone'), findsOneWidget);
    expect(find.text('Expenses by zone'), findsOneWidget);
    expect(find.byType(PieChart), findsNWidgets(2));
    // Day and night replace the aggregate slice so nothing is double-counted.
    expect(find.text('Total'), findsNothing);
  });

  testWidgets('single-location install has no visible location scope switch',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();

    expect(find.text('Per zone'), findsNothing);
    expect(find.text('Combined (all locations)'), findsNothing);
  });

  testWidgets('locations tab creates a location and blocks delete with zones',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'New location'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Location name'), 'Cabin');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Cabin'), findsOneWidget);

    await tester
        .tap(find.widgetWithIcon(IconButton, Icons.delete_outline).first);
    await tester.pumpAndSettle();

    // 'Home' owns the seeded zones, so deletion is blocked immediately by a
    // snack bar rather than opening a confirmation dialog.
    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining('archive it instead'), findsOneWidget);
  });

  testWidgets(
      'combined scope switch appears with two locations and renders location donuts',
      (tester) async {
    final locations = [
      const Location(1, 'Home', colorArgb: 0xff008577),
      const Location(2, 'Cabin', colorArgb: 0xffdb4437),
    ];
    final zones = [
      TariffZone(1, ZoneCode('home-total'), 'Home total', ZoneKind.total,
          locationId: 1),
      TariffZone(2, ZoneCode('cabin-total'), 'Cabin total', ZoneKind.total,
          locationId: 2),
    ];
    final readings = [
      MeterReading(1, 'home-total', DateTime(2026, 3, 1), Kwh(100)),
      MeterReading(2, 'home-total', DateTime(2026, 3, 10), Kwh(130)),
      MeterReading(3, 'cabin-total', DateTime(2026, 3, 1), Kwh(20)),
      MeterReading(4, 'cabin-total', DateTime(2026, 3, 10), Kwh(35)),
    ];
    final rates = [
      TariffRate(1, 'home-total', Money(20), DateTime(2025, 1, 1)),
      TariffRate(2, 'cabin-total', Money(20), DateTime(2025, 1, 1)),
    ];

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatsView(
                readings: readings,
                rates: rates,
                zones: zones,
                locations: locations,
                range: DateRange(DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
                rangeKey: 'custom',
                currencyCode: 'EUR',
                onRangeChanged: (_, __) {}))));
    await tester.pumpAndSettle();

    expect(find.text('Per zone'), findsOneWidget);
    expect(find.text('Combined (all locations)'), findsOneWidget);

    await tester.tap(find.text('Combined (all locations)'));
    await tester.pumpAndSettle();

    expect(find.text('Consumption by location'), findsOneWidget);
    expect(find.text('Expenses by location'), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Cabin'), findsWidgets);
  });
}
