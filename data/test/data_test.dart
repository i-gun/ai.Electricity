import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';

void main() {
  test('opens an in-memory database', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    expect(database.schemaVersion, 4);
    expect(await database.select(database.tariffZones).get(), hasLength(3));
    final seededLocations = await database.select(database.locations).get();
    expect(seededLocations, hasLength(1));
    expect(seededLocations.single.name, 'Home');
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

    // The pre-existing reading must survive the migration.
    expect(await repository.watchAll(locationId: 1).first, hasLength(1));

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
