library;

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'data.g.dart';

ElectricityDatabase openElectricityDatabase() =>
    ElectricityDatabase(driftDatabase(name: 'electricity'));

/// Ids <= 0 mean "new row": let SQLite assign one instead of overwriting.
Value<int> _idValue(int id) => id > 0 ? Value(id) : const Value.absent();

class Locations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get colorArgb => integer()();
  IntColumn get sortOrder => integer()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
}

class TariffZones extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()();
  IntColumn get colorArgb => integer()();
  IntColumn get sortOrder => integer()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
}

/// Many-to-many: a zone (and its tariff rates) can be linked to more than one
/// location, so it is never duplicated just to reuse the same tariff
/// elsewhere.
class LocationZones extends Table {
  IntColumn get locationId => integer().references(Locations, #id)();
  IntColumn get zoneId => integer().references(TariffZones, #id)();
  @override
  Set<Column> get primaryKey => {locationId, zoneId};
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
  // Defaults to the default "Home" location (id 1) seeded by the
  // schemaVersion-2 migration: a zone code shared across locations no
  // longer uniquely identifies which location's meter a reading belongs to.
  IntColumn get locationId => integer().withDefault(const Constant(1))();
  TextColumn get zoneId => text()();
  DateTimeColumn get readingDate => dateTime()();
  RealColumn get valueKwh => real()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isReset => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {locationId, zoneId, readingDate}
      ];
}

@DriftDatabase(
    tables: [Locations, TariffZones, LocationZones, TariffRates, MeterReadings])
class ElectricityDatabase extends _$ElectricityDatabase {
  ElectricityDatabase(super.connection);

  // NOTE: two different physical shapes were both shipped as schemaVersion 2
  // during development (one with a single TariffZones.locationId column, one
  // with the LocationZones join table) before this app ever reached a real
  // user. Because Drift only compares version numbers, an on-disk database
  // stamped "2" could be either shape, so onUpgrade below detects the actual
  // shape via sqlite_master/PRAGMA instead of trusting `from` alone.
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          final homeId = await into(locations).insert(LocationsCompanion.insert(
              name: 'Home', colorArgb: 0xff008577, sortOrder: 0));
          final totalId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'total',
                  name: 'Total',
                  kind: 'total',
                  colorArgb: 0xff008577,
                  sortOrder: 0));
          final dayId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'day',
                  name: 'Day',
                  kind: 'day',
                  colorArgb: 0xfff4b400,
                  sortOrder: 1,
                  isArchived: const Value(true)));
          final nightId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'night',
                  name: 'Night',
                  kind: 'night',
                  colorArgb: 0xff4285f4,
                  sortOrder: 2,
                  isArchived: const Value(true)));
          await batch((batch) {
            batch.insertAll(locationZones, [
              for (final zoneId in [totalId, dayId, nightId])
                LocationZonesCompanion.insert(
                    locationId: homeId, zoneId: zoneId),
            ]);
          });
        },
        onUpgrade: (m, from, to) async {
          // ADR 0006: add a Location entity, plus a many-to-many LocationZones
          // link so a zone (and its tariff rates) can be shared by more than
          // one location instead of being duplicated. Existing zones link to
          // a single default "Home" location; meter readings backfill to it,
          // so no reading/rate history is lost.
          if (from >= 3) return;
          final tableNames = await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table'")
              .map((row) => row.read<String>('name'))
              .get();
          if (!tableNames.contains('locations')) {
            await m.createTable(locations);
          }
          final hasLocationZones = tableNames.contains('location_zones');
          if (!hasLocationZones) {
            await m.createTable(locationZones);
          }
          final readingColumns =
              await customSelect("PRAGMA table_info('meter_readings')")
                  .map((row) => row.read<String>('name'))
                  .get();
          if (!readingColumns.contains('locationId')) {
            await m.addColumn(meterReadings, meterReadings.locationId);
          }
          if (hasLocationZones) return;
          // Reuse an already-seeded "Home" row (the short-lived single-FK v2
          // shape) instead of inserting a second one.
          final existingHome = await (select(locations)
                ..where((row) => row.name.equals('Home')))
              .getSingleOrNull();
          final homeId = existingHome?.id ??
              await into(locations).insert(LocationsCompanion.insert(
                  name: 'Home', colorArgb: 0xff008577, sortOrder: 0));
          final zoneColumns =
              await customSelect("PRAGMA table_info('tariff_zones')")
                  .map((row) => row.read<String>('name'))
                  .get();
          if (zoneColumns.contains('locationId')) {
            // Short-lived v2 shape: read the physical column directly, since
            // the current table definition no longer declares it.
            final rows =
                await customSelect('SELECT id, locationId FROM tariff_zones')
                    .get();
            if (rows.isNotEmpty) {
              await batch((batch) => batch.insertAll(locationZones, [
                    for (final row in rows)
                      LocationZonesCompanion.insert(
                          locationId: row.read<int>('locationId'),
                          zoneId: row.read<int>('id')),
                  ]));
            }
          } else {
            // Genuine v1 (pre-ADR-0006): link every zone to the default
            // "Home" location.
            final existingZones = await select(tariffZones).get();
            if (existingZones.isNotEmpty) {
              await batch((batch) => batch.insertAll(locationZones, [
                    for (final zone in existingZones)
                      LocationZonesCompanion.insert(
                          locationId: homeId, zoneId: zone.id),
                  ]));
            }
          }
        },
      );
}

class DriftMeterReadingRepository implements domain.MeterReadingRepository {
  DriftMeterReadingRepository(this.database);
  final ElectricityDatabase database;
  @override
  Stream<List<domain.MeterReading>> watchAll(
          {String? zoneId, int? locationId}) =>
      (database.select(database.meterReadings)
            ..where((row) {
              final zoneMatch = zoneId == null
                  ? const Constant(true)
                  : row.zoneId.equals(zoneId);
              final locationMatch = locationId == null
                  ? const Constant(true)
                  : row.locationId.equals(locationId);
              return zoneMatch & locationMatch;
            })
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
          locationId: Value(reading.locationId),
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
      isReset: row.isReset,
      locationId: row.locationId);
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
          .asyncMap((rows) async {
        final links = await database.select(database.locationZones).get();
        final locationsByZone = <int, Set<int>>{};
        for (final link in links) {
          locationsByZone
              .putIfAbsent(link.zoneId, () => <int>{})
              .add(link.locationId);
        }
        return [
          for (final row in rows)
            _toDomain(row, locationsByZone[row.id] ?? const <int>{})
        ];
      });
  @override
  Future<void> save(domain.TariffZone zone) => database.transaction(() async {
        final zoneId = await database
            .into(database.tariffZones)
            .insertOnConflictUpdate(TariffZonesCompanion.insert(
                id: _idValue(zone.id),
                code: zone.code.value,
                name: zone.name,
                kind: zone.kind.name,
                colorArgb: zone.colorArgb,
                sortOrder: zone.sortOrder,
                isArchived: Value(zone.isArchived)));
        final id = zone.id > 0 ? zone.id : zoneId;
        await (database.delete(database.locationZones)
              ..where((row) => row.zoneId.equals(id)))
            .go();
        if (zone.locationIds.isNotEmpty) {
          await database
              .batch((batch) => batch.insertAll(database.locationZones, [
                    for (final locationId in zone.locationIds)
                      LocationZonesCompanion.insert(
                          locationId: locationId, zoneId: id)
                  ]));
        }
      });
  @override
  Future<void> delete(int id) => database.transaction(() async {
        await (database.delete(database.locationZones)
              ..where((row) => row.zoneId.equals(id)))
            .go();
        await (database.delete(database.tariffZones)
              ..where((row) => row.id.equals(id)))
            .go();
      });
  domain.TariffZone _toDomain(TariffZone row, Set<int> locationIds) =>
      domain.TariffZone(row.id, domain.ZoneCode(row.code), row.name,
          domain.ZoneKind.values.byName(row.kind),
          colorArgb: row.colorArgb,
          sortOrder: row.sortOrder,
          isArchived: row.isArchived,
          locationIds: locationIds);
}

class DriftLocationRepository implements domain.LocationRepository {
  DriftLocationRepository(this.database);
  final ElectricityDatabase database;
  @override
  Stream<List<domain.Location>> watchAll({bool includeArchived = false}) =>
      (database.select(database.locations)
            ..where((row) => includeArchived
                ? const Constant(true)
                : row.isArchived.equals(false))
            ..orderBy([(row) => OrderingTerm.asc(row.sortOrder)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());
  @override
  Future<void> save(domain.Location location) => database
      .into(database.locations)
      .insertOnConflictUpdate(LocationsCompanion.insert(
          id: _idValue(location.id),
          name: location.name,
          colorArgb: location.colorArgb,
          sortOrder: location.sortOrder,
          isArchived: Value(location.isArchived)));
  @override
  Future<void> delete(int id) =>
      (database.delete(database.locations)..where((row) => row.id.equals(id)))
          .go();
  domain.Location _toDomain(Location row) => domain.Location(row.id, row.name,
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
