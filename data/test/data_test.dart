import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';

void main() {
  test('opens an in-memory database', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    expect(database.schemaVersion, 12);
    expect(await database.select(database.tariffZones).get(), hasLength(3));
    final seededLocations = await database.select(database.locations).get();
    expect(seededLocations, hasLength(1));
    expect(seededLocations.single.name, 'Home');
    expect(
        seededLocations.single.syncId, '00000000-0000-4000-8000-000000000001');
    expect(
        (await database.select(database.tariffZones).get())
            .every((row) => row.syncId != null),
        isTrue);
  });

  test('independent installations use the same built-in seed identities',
      () async {
    final first = ElectricityDatabase(NativeDatabase.memory());
    final second = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);

    final firstLocation = (await first.select(first.locations).get()).single;
    final secondLocation = (await second.select(second.locations).get()).single;
    expect(firstLocation.syncId, secondLocation.syncId);

    final firstZones = await first.select(first.tariffZones).get();
    final secondZones = await second.select(second.tariffZones).get();
    expect({for (final zone in firstZones) zone.code: zone.syncId},
        {for (final zone in secondZones) zone.code: zone.syncId});
  });

  test('schema-v8 upgrades normalize exact seeds and adds sync history fields',
      () async {
    final executor = NativeDatabase.memory(setup: (db) {
      db
        ..execute('''
          CREATE TABLE locations (
            id INTEGER NOT NULL PRIMARY KEY,
            sync_id TEXT NULL,
            name TEXT NOT NULL,
            color_argb INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0
          );
        ''')
        ..execute('''
          CREATE TABLE tariff_zones (
            id INTEGER NOT NULL PRIMARY KEY,
            sync_id TEXT NULL,
            code TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            color_argb INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0
          );
        ''')
        ..execute('''
          CREATE TABLE applied_sync_changes (
            id TEXT NOT NULL PRIMARY KEY
          );
        ''')
        ..execute("INSERT INTO locations VALUES (1, 'legacy-home', 'Home', "
            '4278224247, 0, 0)')
        ..execute("INSERT INTO locations VALUES (2, 'custom-home', 'Home', "
            '123, 0, 0)')
        ..execute("INSERT INTO tariff_zones VALUES "
            "(1, 'legacy-total', 'total', 'Total', 'total', 4278224247, 0, 0)")
        ..execute("INSERT INTO tariff_zones VALUES "
            "(2, 'legacy-day', 'day', 'Day', 'day', 4294226944, 1, 1)")
        ..execute("INSERT INTO tariff_zones VALUES "
            "(3, 'legacy-night', 'night', 'Night', 'night', 4282549748, 2, 1)")
        ..execute('PRAGMA user_version = 8');
    });
    final database = ElectricityDatabase(executor);
    addTearDown(database.close);

    final locations = await database.select(database.locations).get();
    expect(locations.first.syncId, '00000000-0000-4000-8000-000000000001');
    expect(locations.last.syncId, 'custom-home');
    final zones = await database.select(database.tariffZones).get();
    final night = zones.singleWhere((zone) => zone.code == 'night');
    expect(night.name, 'Night');
    expect(night.kind, 'night');
    expect(night.colorArgb, 0xff4285f4);
    expect(night.sortOrder, 2);
    expect(night.isArchived, isTrue);
    expect({
      for (final zone in zones) zone.code: zone.syncId
    }, {
      'total': '00000000-0000-4000-8000-000000000002',
      'day': '00000000-0000-4000-8000-000000000003',
      'night': '00000000-0000-4000-8000-000000000004',
    });
    expect(await database.select(database.syncResolvedBranches).get(), isEmpty);
    expect(await database.select(database.syncEntityAliases).get(), isEmpty);
    final appliedColumns = await database
        .customSelect("PRAGMA table_info('applied_sync_changes')")
        .map((row) => row.read<String>('name'))
        .get();
    expect(appliedColumns, contains('parent_change_id'));
  });

  test('stable IDs survive edits across all four entity tables', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final locations = DriftLocationRepository(database);
    final zones = DriftTariffZoneRepository(database);
    final rates = DriftTariffRateRepository(database);
    final readings = DriftMeterReadingRepository(database);

    await locations.save(const domain.Location(0, 'Cabin'));
    expect(await database.select(database.locations).get(), hasLength(2));
    expect(
        await (database.select(database.locations)
              ..where((row) => row.name.equals('Cabin')))
            .get(),
        hasLength(1));
    final location = await (database.select(database.locations)
          ..where((row) => row.name.equals('Cabin')))
        .getSingle();
    await locations.save(domain.Location(location.id, 'New cabin'));
    expect(
        (await (database.select(database.locations)
                  ..where((row) => row.id.equals(location.id)))
                .getSingle())
            .syncId,
        location.syncId);

    await zones.save(domain.TariffZone(
        0, domain.ZoneCode('custom'), 'Custom', domain.ZoneKind.custom));
    expect(await database.select(database.tariffZones).get(), hasLength(4));
    final zone = await (database.select(database.tariffZones)
          ..where((row) => row.code.equals('custom')))
        .getSingle();
    await zones.save(domain.TariffZone(
        zone.id, domain.ZoneCode('custom'), 'Renamed', domain.ZoneKind.custom));
    expect(
        (await (database.select(database.tariffZones)
                  ..where((row) => row.id.equals(zone.id)))
                .getSingle())
            .syncId,
        zone.syncId);

    await rates
        .save(domain.TariffRate(0, 'custom', domain.Money(20), DateTime(2026)));
    expect(await database.select(database.tariffRates).get(), hasLength(1));
    final rate = await (database.select(database.tariffRates)
          ..where((row) => row.zoneId.equals('custom')))
        .getSingle();
    await rates.save(
        domain.TariffRate(rate.id, 'custom', domain.Money(30), DateTime(2026)));
    expect(
        (await (database.select(database.tariffRates)
                  ..where((row) => row.id.equals(rate.id)))
                .getSingle())
            .syncId,
        rate.syncId);

    await readings.save(
        domain.MeterReading(0, 'custom', DateTime(2026), domain.Kwh(100)));
    expect(await database.select(database.meterReadings).get(), hasLength(1));
    final reading = await (database.select(database.meterReadings)
          ..where((row) => row.zoneId.equals('custom')))
        .getSingle();
    await readings.save(domain.MeterReading(
        reading.id, 'custom', DateTime(2026), domain.Kwh(105)));
    expect(
        (await (database.select(database.meterReadings)
                  ..where((row) => row.id.equals(reading.id)))
                .getSingle())
            .syncId,
        reading.syncId);
    expect({location.syncId, zone.syncId, rate.syncId, reading.syncId},
        hasLength(4));
  });

  test('every seeded zone links to the default Home location', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final home = (await database.select(database.locations).get()).single;
    final links = await database.select(database.locationZones).get();
    expect(links, hasLength(3));
    expect(links.map((link) => link.locationId), everyElement(home.id));
  });

  test('reading repository round-trips through Drift', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    final reading =
        domain.MeterReading(1, 'total', DateTime(2026, 1, 1), domain.Kwh(100));

    await repository.save(reading);

    expect((await repository.find(1))?.valueKwh, domain.Kwh(100));
    await repository.delete(1);
    expect(await repository.find(1), isNull);
  });

  test('database rejects duplicate zone and date readings', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    final date = DateTime(2026, 1, 1);
    await repository
        .save(domain.MeterReading(1, 'total', date, domain.Kwh(100)));

    expect(
      () => repository
          .save(domain.MeterReading(2, 'total', date, domain.Kwh(101))),
      throwsA(isA<Exception>()),
    );
  });

  test('new rows with id 0 get distinct database ids', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);

    await repository.save(
        domain.MeterReading(0, 'total', DateTime(2026, 1, 1), domain.Kwh(100)));
    await repository.save(
        domain.MeterReading(0, 'total', DateTime(2026, 1, 2), domain.Kwh(110)));

    final rows = await database.select(database.meterReadings).get();
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.id).toSet(), hasLength(2));
  });

  test('zone repository toggles archive state and deletes zones', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftTariffZoneRepository(database);

    final archived = await repository.watchAll(includeArchived: true).first;
    expect(await repository.watchAll().first, hasLength(1));

    final day = archived.firstWhere((zone) => zone.code.value == 'day');
    await repository.save(day.copyWith(isArchived: false));
    expect(await repository.watchAll().first, hasLength(2));

    await repository.save(domain.TariffZone(
        0, domain.ZoneCode('weekend'), 'Weekend', domain.ZoneKind.custom,
        sortOrder: 3));
    final zones = await repository.watchAll().first;
    expect(zones.map((zone) => zone.name), contains('Weekend'));

    final weekend = zones.firstWhere((zone) => zone.code.value == 'weekend');
    await repository.delete(weekend.id);
    expect((await repository.watchAll().first).map((zone) => zone.code.value),
        isNot(contains('weekend')));
  });

  test('rate repository watches all zones and deletes rates', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftTariffRateRepository(database);

    await repository.save(
        domain.TariffRate(0, 'day', domain.Money(20), DateTime(2026, 1, 1)));
    await repository.save(
        domain.TariffRate(0, 'night', domain.Money(10), DateTime(2026, 1, 1)));

    final all = await repository.watchAll().first;
    expect(all, hasLength(2));
    expect(await repository.watchForZone('day').first, hasLength(1));

    await repository.delete(all.first.id);
    expect(await repository.watchAll().first, hasLength(1));
  });

  test('location repository creates, archives, and deletes locations',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftLocationRepository(database);

    expect(await repository.watchAll().first, hasLength(1));

    await repository.save(const domain.Location(0, 'Cabin', sortOrder: 1));
    final active = await repository.watchAll().first;
    expect(active.map((location) => location.name), contains('Cabin'));

    final cabin = active.firstWhere((location) => location.name == 'Cabin');
    await repository.save(cabin.copyWith(isArchived: true));
    expect(await repository.watchAll().first, hasLength(1));
    expect(
        await repository.watchAll(includeArchived: true).first, hasLength(2));

    await repository.delete(cabin.id);
    expect(
        await repository.watchAll(includeArchived: true).first, hasLength(1));
  });

  test('zone repository links a zone to more than one location', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final locationRepository = DriftLocationRepository(database);
    final zoneRepository = DriftTariffZoneRepository(database);
    await locationRepository
        .save(const domain.Location(0, 'Cabin', sortOrder: 1));
    final cabin = (await locationRepository.watchAll().first)
        .firstWhere((location) => location.name == 'Cabin');

    await zoneRepository.save(domain.TariffZone(
        0, domain.ZoneCode('shared'), 'Shared zone', domain.ZoneKind.custom,
        locationIds: {1, cabin.id}));
    final saved = (await zoneRepository.watchAll().first)
        .firstWhere((zone) => zone.code.value == 'shared');
    expect(saved.locationIds, {1, cabin.id});

    // Unlinking a location (without deleting the zone) removes it from the set.
    await zoneRepository.save(saved.copyWith(locationIds: {1}));
    final updated = (await zoneRepository.watchAll().first)
        .firstWhere((zone) => zone.code.value == 'shared');
    expect(updated.locationIds, {1});
  });

  test('deleting a zone removes its location links', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final zoneRepository = DriftTariffZoneRepository(database);
    final day = (await zoneRepository.watchAll(includeArchived: true).first)
        .firstWhere((zone) => zone.code.value == 'day');

    await zoneRepository.delete(day.id);

    final links = await database.select(database.locationZones).get();
    expect(links.map((link) => link.zoneId), isNot(contains(day.id)));
  });

  test('meter reading repository filters by location', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    await DriftLocationRepository(database)
        .save(const domain.Location(2, 'Second location'));

    await repository.save(domain.MeterReading(
        0, 'total', DateTime(2026, 1, 1), domain.Kwh(100),
        locationId: 1));
    await repository.save(domain.MeterReading(
        0, 'total', DateTime(2026, 1, 1), domain.Kwh(50),
        locationId: 2));

    expect(await repository.watchAll(locationId: 1).first, hasLength(1));
    expect(await repository.watchAll(locationId: 2).first, hasLength(1));
    expect(await repository.watchAll().first, hasLength(2));
  });

  test(
      'migrates a database whose meter_readings UNIQUE constraint predates '
      'location scoping, allowing a same-date reading for another location',
      () async {
    final placeholderDate = DateTime(2020, 1, 1).toIso8601String();
    final executor = NativeDatabase.memory(setup: (db) {
      db
        ..execute('''
          CREATE TABLE locations (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            color_argb INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0
          );
        ''')
        ..execute('''
          CREATE TABLE tariff_zones (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            code TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            color_argb INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0
          );
        ''')
        ..execute('''
          CREATE TABLE location_zones (
            location_id INTEGER NOT NULL,
            zone_id INTEGER NOT NULL,
            PRIMARY KEY (location_id, zone_id)
          );
        ''')
        ..execute('''
          CREATE TABLE tariff_rates (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            zone_id TEXT NOT NULL,
            price_minor_units INTEGER NOT NULL,
            currency_code TEXT NOT NULL,
            valid_from TEXT NOT NULL,
            valid_to TEXT NULL
          );
        ''')
        // This is the exact broken shape: location_id already exists, but
        // the leftover UNIQUE(zone_id, reading_date) doesn't scope by it.
        ..execute('''
          CREATE TABLE meter_readings (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            location_id INTEGER NOT NULL DEFAULT 1,
            zone_id TEXT NOT NULL,
            reading_date TEXT NOT NULL,
            value_kwh REAL NOT NULL,
            note TEXT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            is_reset INTEGER NOT NULL DEFAULT 0,
            UNIQUE (zone_id, reading_date)
          );
        ''')
        ..execute('INSERT INTO locations (id, name, color_argb, sort_order) '
            "VALUES (1, 'Home', 100, 0)")
        ..execute(
            'INSERT INTO tariff_zones (id, code, name, kind, color_argb, sort_order) '
            "VALUES (1, 'total', 'Total', 'total', 100, 0)")
        ..execute(
            'INSERT INTO location_zones (location_id, zone_id) VALUES (1, 1)')
        ..execute('INSERT INTO meter_readings '
            '(id, location_id, zone_id, reading_date, value_kwh, created_at, updated_at) '
            "VALUES (1, 1, 'total', '$placeholderDate', 100, '$placeholderDate', '$placeholderDate')")
        ..execute('PRAGMA user_version = 3');
    });

    final database = ElectricityDatabase(executor);
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    await DriftLocationRepository(database)
        .save(const domain.Location(2, 'Second location'));

    // The pre-existing reading must survive the migration.
    expect(await repository.watchAll(locationId: 1).first, hasLength(1));
    final migratedReading =
        (await database.select(database.meterReadings).get()).single;
    expect(migratedReading.syncId, isNotNull);
    expect(migratedReading.valueKwh, 100);
    expect(
        (await (database.select(database.locations)
                  ..where((row) => row.id.equals(1)))
                .getSingle())
            .syncId,
        isNotNull);
    expect((await database.select(database.tariffZones).get()).single.syncId,
        isNotNull);

    // Two locations recording the same zone on the same new date must not
    // collide with the old UNIQUE(zone_id, reading_date) index.
    await repository.save(domain.MeterReading(
        0, 'total', DateTime(2026, 3, 1), domain.Kwh(120),
        locationId: 1));
    await repository.save(domain.MeterReading(
        0, 'total', DateTime(2026, 3, 1), domain.Kwh(45),
        locationId: 2));

    expect(await repository.watchAll(locationId: 1).first, hasLength(2));
    expect(await repository.watchAll(locationId: 2).first, hasLength(1));
  });
}
