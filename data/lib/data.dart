library;

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'data.g.dart';

ElectricityDatabase openElectricityDatabase() =>
    ElectricityDatabase(driftDatabase(name: 'electricity'));

/// Ids <= 0 mean "new row": let SQLite assign one instead of overwriting.
Value<int> _idValue(int id) => id > 0 ? Value(id) : const Value.absent();

class TariffZones extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()();
  IntColumn get colorArgb => integer()();
  IntColumn get sortOrder => integer()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
}

class TariffRates extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get zoneId => text()();
  IntColumn get priceMinorUnits => integer()();
  TextColumn get currencyCode => text().withLength(min: 3, max: 3)();
  DateTimeColumn get validFrom => dateTime()();
  DateTimeColumn get validTo => dateTime().nullable()();
}

@TableIndex(name: 'meter_reading_date_idx', columns: {#readingDate})
class MeterReadings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get zoneId => text()();
  DateTimeColumn get readingDate => dateTime()();
  RealColumn get valueKwh => real()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isReset => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {zoneId, readingDate}
      ];
}

@DriftDatabase(tables: [TariffZones, TariffRates, MeterReadings])
class ElectricityDatabase extends _$ElectricityDatabase {
  ElectricityDatabase(super.connection);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await batch((batch) {
            batch.insertAll(tariffZones, [
              TariffZonesCompanion.insert(
                  code: 'total',
                  name: 'Total',
                  kind: 'total',
                  colorArgb: 0xff008577,
                  sortOrder: 0),
              TariffZonesCompanion.insert(
                  code: 'day',
                  name: 'Day',
                  kind: 'day',
                  colorArgb: 0xfff4b400,
                  sortOrder: 1,
                  isArchived: const Value(true)),
              TariffZonesCompanion.insert(
                  code: 'night',
                  name: 'Night',
                  kind: 'night',
                  colorArgb: 0xff4285f4,
                  sortOrder: 2,
                  isArchived: const Value(true)),
            ]);
          });
        },
      );
}

class DriftMeterReadingRepository implements domain.MeterReadingRepository {
  DriftMeterReadingRepository(this.database);
  final ElectricityDatabase database;
  @override
  Stream<List<domain.MeterReading>> watchAll({String? zoneId}) =>
      (database.select(database.meterReadings)
            ..where((row) => zoneId == null
                ? const Constant(true)
                : row.zoneId.equals(zoneId))
            ..orderBy([(row) => OrderingTerm.asc(row.readingDate)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());
  @override
  Future<domain.MeterReading?> find(int id) async {
    final row = await (database.select(database.meterReadings)
          ..where((item) => item.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  @override
  Future<void> save(domain.MeterReading reading) => database
      .into(database.meterReadings)
      .insertOnConflictUpdate(MeterReadingsCompanion.insert(
          id: _idValue(reading.id),
          zoneId: reading.zoneId,
          readingDate: reading.readingDate,
          valueKwh: reading.valueKwh.value,
          note: Value(reading.note),
          createdAt: reading.createdAt ?? DateTime.now(),
          updatedAt: reading.updatedAt ?? DateTime.now(),
          isReset: Value(reading.isReset)));
  @override
  Future<void> delete(int id) => (database.delete(database.meterReadings)
        ..where((row) => row.id.equals(id)))
      .go();
  domain.MeterReading _toDomain(MeterReading row) => domain.MeterReading(
      row.id, row.zoneId, row.readingDate, domain.Kwh(row.valueKwh),
      note: row.note,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      isReset: row.isReset);
}

class DriftTariffZoneRepository implements domain.TariffZoneRepository {
  DriftTariffZoneRepository(this.database);
  final ElectricityDatabase database;
  @override
  Stream<List<domain.TariffZone>> watchAll({bool includeArchived = false}) =>
      (database.select(database.tariffZones)
            ..where((row) => includeArchived
                ? const Constant(true)
                : row.isArchived.equals(false))
            ..orderBy([(row) => OrderingTerm.asc(row.sortOrder)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());
  @override
  Future<void> save(domain.TariffZone zone) => database
      .into(database.tariffZones)
      .insertOnConflictUpdate(TariffZonesCompanion.insert(
          id: _idValue(zone.id),
          code: zone.code.value,
          name: zone.name,
          kind: zone.kind.name,
          colorArgb: zone.colorArgb,
          sortOrder: zone.sortOrder,
          isArchived: Value(zone.isArchived)));
  @override
  Future<void> delete(int id) =>
      (database.delete(database.tariffZones)..where((row) => row.id.equals(id)))
          .go();
  domain.TariffZone _toDomain(TariffZone row) => domain.TariffZone(
      row.id,
      domain.ZoneCode(row.code),
      row.name,
      domain.ZoneKind.values.byName(row.kind),
      colorArgb: row.colorArgb,
      sortOrder: row.sortOrder,
      isArchived: row.isArchived);
}

class DriftTariffRateRepository implements domain.TariffRateRepository {
  DriftTariffRateRepository(this.database);
  final ElectricityDatabase database;
  @override
  Stream<List<domain.TariffRate>> watchAll() =>
      (database.select(database.tariffRates)
            ..orderBy([(row) => OrderingTerm.asc(row.validFrom)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());
  @override
  Stream<List<domain.TariffRate>> watchForZone(String zoneId) =>
      (database.select(database.tariffRates)
            ..where((row) => row.zoneId.equals(zoneId))
            ..orderBy([(row) => OrderingTerm.asc(row.validFrom)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());
  @override
  Future<void> save(domain.TariffRate rate) => database
      .into(database.tariffRates)
      .insertOnConflictUpdate(TariffRatesCompanion.insert(
          id: _idValue(rate.id),
          zoneId: rate.zoneId,
          priceMinorUnits: rate.pricePerKwh.minorUnits,
          currencyCode: rate.pricePerKwh.currencyCode,
          validFrom: rate.validFrom,
          validTo: Value(rate.validTo)));
  @override
  Future<void> delete(int id) =>
      (database.delete(database.tariffRates)..where((row) => row.id.equals(id)))
          .go();
  domain.TariffRate _toDomain(TariffRate row) => domain.TariffRate(
      row.id,
      row.zoneId,
      domain.Money(row.priceMinorUnits, currencyCode: row.currencyCode),
      row.validFrom,
      validTo: row.validTo);
}
