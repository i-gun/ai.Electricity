import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';

void main() {
  test('opens an in-memory database', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    expect(database.schemaVersion, 1);
    expect(await database.select(database.tariffZones).get(), hasLength(3));
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
}
