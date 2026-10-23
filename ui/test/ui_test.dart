import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart';
import 'package:ai_electricity_ui/ui.dart';
import 'package:fl_chart/fl_chart.dart';

class _ShutdownRepository implements ShutdownScheduleRepository {
  int calls = 0;
  bool fail = false;
  final requested = <Location>[];
  @override
  Future<ShutdownSchedule?> fetch(Location location) async {
    calls++;
    requested.add(location);
    if (fail) throw const ShutdownException('Collector unavailable.');
    return ShutdownSchedule(
        region: location.region,
        city: location.city,
        street: location.street,
        building: location.building,
        groups: const ['GPV4.1'],
        updatedAt: '22.10.2026 21:44',
        fetchedAt: DateTime.utc(2026, 10, 23),
        days: const [
          ShutdownDay('2026-10-23', [ShutdownInterval(660, 900)])
        ]);
  }
}

class _TestLocations implements LocationRepository {
  const _TestLocations(this.locations);
  final List<Location> locations;
  @override
  Stream<List<Location>> watchAll({bool includeArchived = false}) =>
      Stream.value(locations);
  @override
  Future<void> save(Location location) async {}
  @override
  Future<void> delete(int id) async {}
}

class _DelayedShutdownRepository implements ShutdownScheduleRepository {
  final pending = <int, Completer<ShutdownSchedule?>>{};
  @override
  Future<ShutdownSchedule?> fetch(Location location) =>
      (pending[location.id] = Completer<ShutdownSchedule?>()).future;
}

void main() {
  testWidgets('Status uses the active location and switches regions',
      (tester) async {
    final repository = _ShutdownRepository();
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            locationRepository: const _TestLocations([
              Location(1, 'Region house',
                  city: 'Village', street: 'Main', building: '66'),
              Location(2, 'City apartment',
                  region: ShutdownRegion.kyivCity,
                  city: 'Kyiv',
                  street: 'Other',
                  building: '10'),
            ]),
            shutdownRepository: repository)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(repository.requested.single.id, 1);
    expect(find.text('Kyiv region'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('City apartment').last);
    await tester.pumpAndSettle();
    expect(repository.requested.last.id, 2);
    expect(repository.requested.last.region, ShutdownRegion.kyivCity);
    expect(find.text('Kyiv city'), findsOneWidget);
    expect(find.text('Village, Main, 66'), findsNothing);
  });

  testWidgets('Status remains unused for an empty address', (tester) async {
    final repository = _ShutdownRepository();
    await tester.pumpWidget(
        MaterialApp(home: SharedHome(shutdownRepository: repository)));
    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(find.text('Address incomplete.'), findsOneWidget);
    expect(repository.calls, 0);
  });

  testWidgets('Status ignores late results from a previous location',
      (tester) async {
    final repository = _DelayedShutdownRepository();
    const first =
        Location(1, 'First', city: 'Old', street: 'Main', building: '1');
    const second = Location(2, 'Second',
        region: ShutdownRegion.kyivCity,
        city: 'Kyiv',
        street: 'Other',
        building: '2');
    ShutdownSchedule result(Location location) => ShutdownSchedule(
        region: location.region,
        city: location.city,
        street: location.street,
        building: location.building,
        groups: const ['GPV1.1'],
        updatedAt: '23.10.2026',
        fetchedAt: DateTime.utc(2026, 10, 23),
        days: const [ShutdownDay('2026-10-23', [])]);
    await tester.pumpWidget(MaterialApp(
        home: ShutdownStatusView(location: first, repository: repository)));
    await tester.pumpWidget(MaterialApp(
        home: ShutdownStatusView(location: second, repository: repository)));
    repository.pending[2]!.complete(result(second));
    await tester.pumpAndSettle();
    expect(find.text('Kyiv, Other, 2'), findsOneWidget);
    repository.pending[1]!.complete(result(first));
    await tester.pumpAndSettle();
    expect(find.text('Kyiv, Other, 2'), findsOneWidget);
    expect(find.text('Old, Main, 1'), findsNothing);
  });

  testWidgets('region editor saves Kyiv city with its locality',
      (tester) async {
    final repository = _ShutdownRepository();
    await tester.pumpWidget(
        MaterialApp(home: SharedHome(shutdownRepository: repository)));
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit location'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<ShutdownRegion>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kyiv city').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Street (optional)'), 'Main');
    await tester.enterText(
        find.widgetWithText(TextField, 'Building (optional)'), '66');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(repository.requested.single.region, ShutdownRegion.kyivCity);
    expect(
        repository.requested.single.city, '\u043c. \u041a\u0438\u0457\u0432');
  });

  testWidgets('shutdown failure can retry on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _ShutdownRepository()..fail = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocationsView(
                locations: const [
          Location(1, 'Home', city: 'Village', street: 'Main', building: '66')
        ],
                zones: const [],
                shutdownRepository: repository,
                onToggleLocation: (_) {},
                onAddLocation: () {},
                onEditLocation: (_) {},
                onDeleteLocation: (_) {}))));
    await tester.tap(find.byTooltip('Shutdown schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Collector unavailable.'), findsOneWidget);
    expect(find.textContaining('No planned outages'), findsNothing);
    repository.fail = false;
    await tester.tap(find.byTooltip('Refresh schedule'));
    await tester.pumpAndSettle();
    expect(find.text('11:00 - 15:00'), findsOneWidget);
    expect(repository.calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty location address never enables shutdown fetch',
      (tester) async {
    final repository = _ShutdownRepository();
    await tester.pumpWidget(
        MaterialApp(home: SharedHome(shutdownRepository: repository)));
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(find.byWidgetPredicate((widget) =>
        widget is IconButton && widget.tooltip == 'Shutdown schedule'));
    expect(button.onPressed, isNull);
    expect(repository.calls, 0);
  });

  testWidgets('address edit enables fetching and clearing disables it',
      (tester) async {
    final repository = _ShutdownRepository();
    await tester.pumpWidget(
        MaterialApp(home: SharedHome(shutdownRepository: repository)));
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit location'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'City (optional)'), 'Village');
    await tester.enterText(
        find.widgetWithText(TextField, 'Street (optional)'), 'Main');
    await tester.enterText(
        find.widgetWithText(TextField, 'Building (optional)'), '66');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repository.calls, 0);
    await tester.tap(find.byTooltip('Shutdown schedule'));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
    expect(find.text('Group: GPV4.1'), findsOneWidget);
    expect(find.text('11:00 - 15:00'), findsOneWidget);
    expect(find.text('2026-10-23'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit location'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Building (optional)'), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate((widget) =>
                widget is IconButton && widget.tooltip == 'Shutdown schedule'))
            .onPressed,
        isNull);
    expect(repository.calls, 1);
  });

  testWidgets('creates the shared light theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme(),
        home: const Placeholder(),
      ),
    );

    expect(find.byType(Placeholder), findsOneWidget);
  });

  testWidgets('sync settings connect and disconnect Google account',
      (tester) async {
    var connected = false;
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            isGoogleConnected: () async => connected,
            loadSyncConflicts: () async => const [
                  SyncConflictItem(
                      id: 'remote-change',
                      entityKind: 'reading',
                      entityId: 'stable-reading',
                      reason:
                          'A reading already exists for this location, zone and date',
                      candidateSummaries: [
                        'This device: 100.0 kWh on 2026-09-29',
                        'Incoming: 130.0 kWh on 2026-09-29',
                      ]),
                ],
            onGoogleConnect: () async {
              connected = true;
            },
            onGoogleDisconnect: () async {
              connected = false;
            })));
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Connect Google'));
    await tester.pumpAndSettle();
    expect(find.text('Google account connected'), findsOneWidget);
    expect(
        find.textContaining('Create a new vault or join one'), findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, 'Disconnect Google'), findsOneWidget);
    expect(find.textContaining('Conflicts to review'), findsOneWidget);
    expect(find.textContaining('This device: 100.0 kWh'), findsOneWidget);
    expect(find.textContaining('Incoming: 130.0 kWh'), findsOneWidget);
    expect(find.textContaining('no value was overwritten'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect Google'));
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('sync settings presents safe OAuth setup failures',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            isGoogleConnected: () async => false,
            onGoogleConnect: () async {
              throw const SyncUiException(
                  'Set GOOGLE_OAUTH_DESKTOP_CLIENT_ID to a public desktop client ID');
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect Google'));
    await tester.pumpAndSettle();

    expect(
        find.text(
            'Set GOOGLE_OAUTH_DESKTOP_CLIENT_ID to a public desktop client ID'),
        findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('recovery secret is cleared after vault creation',
      (tester) async {
    var vaultUnlocked = false;
    String? submittedSecret;
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            isGoogleConnected: () async => true,
            hasGoogleVault: () async => vaultUnlocked,
            onGoogleCreateVault: (secret) async {
              submittedSecret = secret;
              vaultUnlocked = true;
            },
            onGoogleSyncNow: () async => const SyncRunSummary(
                uploaded: 1,
                applied: 2,
                duplicates: 0,
                conflicts: 1,
                otherVault: 0))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Create vault'), findsOneWidget);
    final secretField = find.widgetWithText(TextField, 'Recovery secret');
    expect(tester.widget<TextField>(secretField).obscureText, isTrue);
    await tester.enterText(secretField, 'temporary recovery phrase');
    await tester.tap(find.text('Create vault'));
    await tester.pumpAndSettle();

    expect(submittedSecret, 'temporary recovery phrase');
    expect(find.text('Recovery secret'), findsNothing);
    expect(find.text('Sync now'), findsOneWidget);
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Uploaded 1, received 2, 1 conflicts'),
        findsOneWidget);
  });

  testWidgets('eligible sync conflicts expose candidate resolution actions',
      (tester) async {
    String? resolvedId;
    int? resolvedIndex;
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            isGoogleConnected: () async => true,
            loadSyncConflicts: () async => const [
                  SyncConflictItem(
                      id: 'remote-branch',
                      entityKind: 'reading',
                      entityId: 'shared-reading',
                      reason: 'Reading changed independently',
                      candidateSummaries: [
                        'This device: 100 kWh',
                        'Incoming: 110 kWh',
                      ],
                      resolutionChoices: [
                        'Use this device',
                        'Use incoming',
                      ]),
                ],
            onGoogleResolveConflict: (id, index) async {
              resolvedId = id;
              resolvedIndex = index;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Use this device'), findsOneWidget);
    expect(find.text('Use incoming'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Use incoming'), 250,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use incoming'));
    await tester.pumpAndSettle();
    expect(resolvedId, 'remote-branch');
    expect(resolvedIndex, 1);
  });

  testWidgets('cross-ID conflicts clearly label the identity being kept',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: SharedHome(
            isGoogleConnected: () async => true,
            loadSyncConflicts: () async => const [
                  SyncConflictItem(
                      id: 'duplicate-slot',
                      entityKind: 'reading',
                      entityId: 'incoming-reading-id',
                      reason: 'A reading already exists in this slot',
                      candidateSummaries: [
                        'This device: 100 kWh',
                        'Incoming: 110 kWh',
                      ],
                      resolutionChoices: [
                        'Keep this device reading identity',
                        'Merge into incoming reading identity',
                      ]),
                ],
            onGoogleResolveConflict: (_, __) async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Merge into incoming reading identity'), 250,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();

    expect(find.text('Keep this device reading identity'), findsOneWidget);
    expect(find.text('Merge into incoming reading identity'), findsOneWidget);
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

  testWidgets('stats range selector supports a one-week range', (tester) async {
    DateRange? selectedRange;
    String? selectedKey;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatsView(
                readings: [],
                rates: [],
                zones: [],
                range: DateRange.lastMonths(3),
                rangeKey: '3M',
                currencyCode: 'EUR',
                onRangeChanged: (range, key) {
                  selectedRange = range;
                  selectedKey = key;
                }))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 week').last);
    await tester.pumpAndSettle();

    expect(selectedKey, '1W');
    expect(selectedRange, isNotNull);
    expect(selectedRange!.days, 7);
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
    // snack bar rather than opening a confirmation dialog. A second location
    // also adds a location switcher to the app bar, so 'Home' now renders
    // twice (switcher + Locations list tile).
    expect(find.text('Home'), findsWidgets);
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
          locationIds: {1}),
      TariffZone(2, ZoneCode('cabin-total'), 'Cabin total', ZoneKind.total,
          locationIds: {2}),
    ];
    final readings = [
      MeterReading(1, 'home-total', DateTime(2026, 3, 1), Kwh(100),
          locationId: 1),
      MeterReading(2, 'home-total', DateTime(2026, 3, 10), Kwh(130),
          locationId: 1),
      MeterReading(3, 'cabin-total', DateTime(2026, 3, 1), Kwh(20),
          locationId: 2),
      MeterReading(4, 'cabin-total', DateTime(2026, 3, 10), Kwh(35),
          locationId: 2),
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

  testWidgets(
      'combined mode reports each location\'s own total, not the grand total, for a shared zone',
      (tester) async {
    final locations = [
      const Location(1, 'Home', colorArgb: 0xff008577),
      const Location(2, 'Cabin', colorArgb: 0xffdb4437),
    ];
    // Same zone (and tariff) reused by both locations instead of duplicated.
    final zones = [
      TariffZone(1, ZoneCode('total'), 'Total', ZoneKind.total,
          locationIds: {1, 2}),
    ];
    final readings = [
      MeterReading(1, 'total', DateTime(2026, 3, 1), Kwh(100), locationId: 1),
      MeterReading(2, 'total', DateTime(2026, 3, 10), Kwh(130), locationId: 1),
      MeterReading(3, 'total', DateTime(2026, 3, 1), Kwh(500), locationId: 2),
      MeterReading(4, 'total', DateTime(2026, 3, 10), Kwh(540), locationId: 2),
    ];
    final rates = [
      TariffRate(1, 'total', Money(20), DateTime(2025, 1, 1)),
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

    await tester.tap(find.text('Combined (all locations)'));
    await tester.pumpAndSettle();

    // Home: 100 -> 130 (30 kWh); Cabin: 500 -> 540 (40 kWh); grand total 70.
    // The grand total still legitimately appears once, in the "Total
    // consumption" summary tile — only the per-location donut/legend values
    // must not also read 70.
    expect(find.text('30.0 kWh'), findsWidgets);
    expect(find.text('40.0 kWh'), findsWidgets);
    expect(find.text('70.0 kWh'), findsOneWidget);
  });

  testWidgets('Locations tab sits above Zones & tariffs with a home icon',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    String labelOf(NavigationRailDestination destination) =>
        (destination.label as Text).data!;
    final labels = rail.destinations.map(labelOf).toList();
    expect(labels.indexOf('Locations'),
        lessThan(labels.indexOf('Zones & tariffs')));
    expect(
        (rail.destinations.firstWhere((d) => labelOf(d) == 'Locations').icon
                as Icon)
            .icon,
        Icons.home_outlined);
  });

  testWidgets(
      'a zone can be quick-toggled on/off for the current location, guarding the last link',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SharedHome()));
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New location'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Location name'), 'Cabin');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zones & tariffs'));
    await tester.pumpAndSettle();

    // 'Total' is only linked to 'Home' (the currently selected location), so
    // toggling it off here would leave it linked to no location at all.
    expect(find.byTooltip('Linked to the currently selected location'),
        findsWidgets);
    await tester
        .tap(find.byTooltip('Linked to the currently selected location').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('must stay linked to at least one location'),
        findsOneWidget);
  });

  testWidgets(
      'a zone shared by two locations keeps their readings separate in Per zone mode',
      (tester) async {
    final locations = [
      const Location(1, 'Home', colorArgb: 0xff008577),
      const Location(2, 'Cabin', colorArgb: 0xffdb4437),
    ];
    // Same zone (and tariff) reused by both locations instead of duplicated.
    final zones = [
      TariffZone(1, ZoneCode('total'), 'Total', ZoneKind.total,
          locationIds: {1, 2}),
    ];
    final readings = [
      MeterReading(1, 'total', DateTime(2026, 3, 1), Kwh(100), locationId: 1),
      MeterReading(2, 'total', DateTime(2026, 3, 10), Kwh(130), locationId: 1),
      MeterReading(3, 'total', DateTime(2026, 3, 1), Kwh(500), locationId: 2),
      MeterReading(4, 'total', DateTime(2026, 3, 10), Kwh(540), locationId: 2),
    ];
    final rates = [
      TariffRate(1, 'total', Money(20), DateTime(2025, 1, 1)),
    ];

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatsView(
                readings: readings,
                rates: rates,
                zones: zones,
                locations: locations,
                currentLocationId: 1,
                range: DateRange(DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
                rangeKey: 'custom',
                currencyCode: 'EUR',
                onRangeChanged: (_, __) {}))));
    await tester.pumpAndSettle();

    // Per zone (default) mode is scoped to currentLocationId=1: only Home's
    // 30 kWh delta should be reflected, not Cabin's 40 kWh delta.
    expect(find.text('30.0 kWh'), findsWidgets);
    expect(find.text('40.0 kWh'), findsNothing);
  });
}
