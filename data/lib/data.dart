library;

import 'dart:convert';
import 'dart:math';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'src/drive_store.dart' show EncryptedChangeStore;
import 'src/sync_vault.dart' show SyncVault;
import 'src/secure_credentials.dart'
    show SecureGoogleCredentialStore, SecureVaultKeyCache;
import 'src/vault_provisioner.dart' show DriveVaultProvisioner;

export 'src/sync_vault.dart';
export 'src/drive_store.dart';
export 'src/secure_credentials.dart';
export 'src/desktop_google_oauth.dart';
export 'src/native_google_oauth.dart';
export 'src/vault_provisioner.dart';

part 'data.g.dart';

ElectricityDatabase openElectricityDatabase() =>
    ElectricityDatabase(driftDatabase(name: 'electricity'));

/// Ids <= 0 mean "new row": let SQLite assign one instead of overwriting.
Value<int> _idValue(int id) => id > 0 ? Value(id) : const Value.absent();

String _newSyncId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

const _homeSeedSyncId = '00000000-0000-4000-8000-000000000001';
const _totalSeedSyncId = '00000000-0000-4000-8000-000000000002';
const _daySeedSyncId = '00000000-0000-4000-8000-000000000003';
const _nightSeedSyncId = '00000000-0000-4000-8000-000000000004';

class Locations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get colorArgb => integer()();
  IntColumn get sortOrder => integer()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
}

class TariffZones extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().nullable()();
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
  TextColumn get syncId => text().nullable()();
  TextColumn get zoneId => text()();
  IntColumn get priceMinorUnits => integer()();
  TextColumn get currencyCode => text().withLength(min: 3, max: 3)();
  DateTimeColumn get validFrom => dateTime()();
  DateTimeColumn get validTo => dateTime().nullable()();
}

@TableIndex(name: 'meter_reading_date_idx', columns: {#readingDate})
class MeterReadings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().nullable()();
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

class SyncChanges extends Table {
  TextColumn get id => text()();
  TextColumn get parentChangeId => text().nullable()();
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get payload => text()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  BoolColumn get isUploaded => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

class AppliedSyncChanges extends Table {
  TextColumn get id => text()();
  TextColumn get parentChangeId => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class SyncConflicts extends Table {
  TextColumn get id => text()();
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get reason => text()();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get isResolved => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

class SyncEntityHeads extends Table {
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get changeId => text()();
  @override
  Set<Column> get primaryKey => {entityKind, entityId};
}

class SyncResolvedBranches extends Table {
  TextColumn get branchId => text()();
  TextColumn get resolutionId => text()();
  @override
  Set<Column> get primaryKey => {branchId};
}

class SyncEntityAliases extends Table {
  TextColumn get entityKind => text()();
  TextColumn get aliasId => text()();
  TextColumn get canonicalId => text()();
  @override
  Set<Column> get primaryKey => {entityKind, aliasId};
}

@DriftDatabase(tables: [
  Locations,
  TariffZones,
  LocationZones,
  TariffRates,
  MeterReadings,
  SyncChanges,
  AppliedSyncChanges,
  SyncConflicts,
  SyncEntityHeads,
  SyncResolvedBranches,
  SyncEntityAliases
])
class ElectricityDatabase extends _$ElectricityDatabase {
  ElectricityDatabase(super.connection);

  Future<Value<String>> syncIdFor(String tableName, int id) async {
    if (id <= 0) return Value(_newSyncId());
    final row = await customSelect(
        'SELECT sync_id FROM $tableName WHERE id = ?',
        variables: [Variable(id)]).getSingleOrNull();
    return Value(row?.read<String?>('sync_id') ?? _newSyncId());
  }

  Future<String> requireSyncIdFor(String tableName, int id) async {
    final row = await customSelect(
        'SELECT sync_id FROM $tableName WHERE id = ?',
        variables: [Variable(id)]).getSingleOrNull();
    final syncId = row?.read<String?>('sync_id');
    if (syncId == null || syncId.isEmpty) {
      throw StateError('Missing stable identity for $tableName row $id');
    }
    return syncId;
  }

  Future<String> requireZoneSyncId(String zoneCode) async {
    final rows = await (select(tariffZones)
          ..where((zone) => zone.code.equals(zoneCode)))
        .get();
    if (rows.length != 1 || rows.single.syncId == null) {
      throw StateError('Zone code must resolve to exactly one stable zone');
    }
    return rows.single.syncId!;
  }

  Future<void> _createSyncIndexes() async {
    for (final tableName in [
      'locations',
      'tariff_zones',
      'tariff_rates',
      'meter_readings'
    ]) {
      await customStatement(
          'CREATE UNIQUE INDEX ${tableName}_sync_id_unique ON $tableName(sync_id)');
    }
  }

  // NOTE: several physical shapes were shipped under schemaVersion 2 and 3
  // during development (varying combinations of a single
  // TariffZones.locationId column, the LocationZones join table, and a
  // meter_readings.location_id column added without updating its UNIQUE
  // constraint) before this app ever reached a real user. Because Drift only
  // compares version numbers, onUpgrade below detects the actual on-disk
  // shape via sqlite_master/PRAGMA instead of trusting `from` alone.
  @override
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createSyncIndexes();
          final homeId = await into(locations).insert(LocationsCompanion.insert(
              name: 'Home',
              colorArgb: 0xff008577,
              sortOrder: 0,
              syncId: const Value(_homeSeedSyncId)));
          final totalId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'total',
                  name: 'Total',
                  kind: 'total',
                  colorArgb: 0xff008577,
                  sortOrder: 0,
                  syncId: const Value(_totalSeedSyncId)));
          final dayId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'day',
                  name: 'Day',
                  kind: 'day',
                  colorArgb: 0xfff4b400,
                  sortOrder: 1,
                  syncId: const Value(_daySeedSyncId),
                  isArchived: const Value(true)));
          final nightId = await into(tariffZones).insert(
              TariffZonesCompanion.insert(
                  code: 'night',
                  name: 'Night',
                  kind: 'night',
                  colorArgb: 0xff4285f4,
                  sortOrder: 2,
                  syncId: const Value(_nightSeedSyncId),
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
          if (from < 4) {
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
            final hasReadingLocationId = readingColumns.contains('location_id');
            // Recreate meter_readings so its UNIQUE constraint covers
            // location_id too. A prior migration only added the column via
            // addColumn, which left the old UNIQUE(zone_id, reading_date)
            // index in place and rejected a second location's reading on a
            // date already used by any other location.
            await m.alterTable(TableMigration(
              meterReadings,
              newColumns: [
                if (!hasReadingLocationId) meterReadings.locationId,
                meterReadings.syncId,
              ],
            ));
            if (!hasLocationZones) {
              // Reuse an already-seeded "Home" row (a short-lived earlier shape)
              // instead of inserting a second one.
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
              if (zoneColumns.contains('location_id')) {
                // Short-lived single-FK shape: read the physical column
                // directly, since the current table definition no longer
                // declares it.
                final rows = await customSelect(
                        'SELECT id, location_id FROM tariff_zones')
                    .get();
                if (rows.isNotEmpty) {
                  await batch((batch) => batch.insertAll(locationZones, [
                        for (final row in rows)
                          LocationZonesCompanion.insert(
                              locationId: row.read<int>('location_id'),
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
            }
          }
          if (from < 5) {
            final locationColumns =
                await customSelect("PRAGMA table_info('locations')")
                    .map((row) => row.read<String>('name'))
                    .get();
            if (!locationColumns.contains('sync_id')) {
              await m.addColumn(locations, locations.syncId);
            }
            final zoneColumns =
                await customSelect("PRAGMA table_info('tariff_zones')")
                    .map((row) => row.read<String>('name'))
                    .get();
            if (!zoneColumns.contains('sync_id')) {
              await m.addColumn(tariffZones, tariffZones.syncId);
            }
            final rateColumns =
                await customSelect("PRAGMA table_info('tariff_rates')")
                    .map((row) => row.read<String>('name'))
                    .get();
            if (!rateColumns.contains('sync_id')) {
              await m.addColumn(tariffRates, tariffRates.syncId);
            }
            if (from >= 4) {
              await m.addColumn(meterReadings, meterReadings.syncId);
            }
            for (final tableName in [
              'locations',
              'tariff_zones',
              'tariff_rates',
              'meter_readings'
            ]) {
              final rows = await customSelect('SELECT id FROM $tableName')
                  .map((row) => row.read<int>('id'))
                  .get();
              for (final id in rows) {
                await customUpdate(
                    'UPDATE $tableName SET sync_id = ? WHERE id = ?',
                    variables: [Variable(_newSyncId()), Variable(id)]);
              }
            }
            await _createSyncIndexes();
          }
          if (from < 6) {
            await m.createTable(syncChanges);
            await m.createTable(appliedSyncChanges);
          }
          if (from < 7) {
            await m.createTable(syncConflicts);
          }
          if (from < 8) {
            final changeColumns =
                await customSelect("PRAGMA table_info('sync_changes')")
                    .map((row) => row.read<String>('name'))
                    .get();
            if (!changeColumns.contains('parent_change_id')) {
              await m.addColumn(syncChanges, syncChanges.parentChangeId);
            }
            await m.createTable(syncEntityHeads);
          }
          if (from < 9) {
            await _normalizeSeedSyncIds();
          }
          if (from < 10) {
            await m.createTable(syncResolvedBranches);
          }
          if (from < 11) {
            await m.createTable(syncEntityAliases);
          }
          if (from < 12) {
            final appliedColumns =
                await customSelect("PRAGMA table_info('applied_sync_changes')")
                    .map((row) => row.read<String>('name'))
                    .get();
            if (!appliedColumns.contains('parent_change_id')) {
              await m.addColumn(
                  appliedSyncChanges, appliedSyncChanges.parentChangeId);
            }
          }
        },
      );

  Future<void> _normalizeSeedSyncIds() async {
    final homeRows = await (select(locations)
          ..where((row) =>
              row.name.equals('Home') &
              row.colorArgb.equals(0xff008577) &
              row.sortOrder.equals(0) &
              row.isArchived.equals(false)))
        .get();
    if (homeRows.length == 1) {
      await _normalizeSeedId('locations', homeRows.single.id,
          homeRows.single.syncId, _homeSeedSyncId);
    }

    final seeds = <(String, int, String, String, int, int, String)>[
      ('total', 0xff008577, 'total', 'Total', 0, 0, _totalSeedSyncId),
      ('day', 0xfff4b400, 'day', 'Day', 1, 1, _daySeedSyncId),
      ('night', 0xff4285f4, 'night', 'Night', 2, 1, _nightSeedSyncId),
    ];
    for (final seed in seeds) {
      final rows = await (select(tariffZones)
            ..where((row) =>
                row.code.equals(seed.$1) &
                row.colorArgb.equals(seed.$2) &
                row.kind.equals(seed.$3) &
                row.name.equals(seed.$4) &
                row.sortOrder.equals(seed.$5) &
                row.isArchived.equals(seed.$6 == 1)))
          .get();
      if (rows.length == 1) {
        await _normalizeSeedId(
            'tariff_zones', rows.single.id, rows.single.syncId, seed.$7);
      }
    }
  }

  Future<void> _normalizeSeedId(
      String table, int rowId, String? currentId, String canonicalId) async {
    if (currentId == canonicalId) return;
    final canonicalExists = await customSelect(
        'SELECT 1 FROM $table WHERE sync_id = ? LIMIT 1',
        variables: [Variable(canonicalId)]).getSingleOrNull();
    if (canonicalExists != null) return;
    await customUpdate('UPDATE $table SET sync_id = ? WHERE id = ?',
        variables: [Variable(canonicalId), Variable(rowId)]);
  }
}

/// Durable outgoing changes and incoming replay protection.
class DriftSyncJournal {
  DriftSyncJournal(this.database);

  final ElectricityDatabase database;

  Future<void> enqueue({
    required String changeId,
    required String entityKind,
    required String entityId,
    required String payload,
    bool isDeleted = false,
    String? parentChangeId,
  }) async {
    if (changeId.isEmpty || entityKind.isEmpty || entityId.isEmpty) {
      throw ArgumentError('Sync change identity must not be empty');
    }
    final previousHead = parentChangeId ?? await head(entityKind, entityId);
    await database.into(database.syncChanges).insert(
        SyncChangesCompanion.insert(
            id: changeId,
            parentChangeId: Value(previousHead),
            entityKind: entityKind,
            entityId: entityId,
            payload: payload,
            isDeleted: Value(isDeleted)));
    await setHead(entityKind, entityId, changeId);
  }

  Future<String?> head(String entityKind, String entityId) async =>
      (await (database.select(database.syncEntityHeads)
                ..where((row) =>
                    row.entityKind.equals(entityKind) &
                    row.entityId.equals(entityId)))
              .getSingleOrNull())
          ?.changeId;

  Future<void> setHead(String entityKind, String entityId, String changeId) =>
      database.into(database.syncEntityHeads).insertOnConflictUpdate(
          SyncEntityHeadsCompanion.insert(
              entityKind: entityKind, entityId: entityId, changeId: changeId));

  Future<bool> wasSuperseded(String branchId) async =>
      await (database.select(database.syncResolvedBranches)
            ..where((row) => row.branchId.equals(branchId)))
          .getSingleOrNull() !=
      null;

  Future<void> recordSuperseded(
      Iterable<String> branchIds, String resolutionId) async {
    final superseded = branchIds.where((id) => id != resolutionId).toSet();
    await database.batch((batch) =>
        batch.insertAllOnConflictUpdate(database.syncResolvedBranches, [
          for (final branchId in superseded)
            SyncResolvedBranchesCompanion.insert(
                branchId: branchId, resolutionId: resolutionId)
        ]));
    if (superseded.isNotEmpty) {
      await (database.update(database.syncChanges)
            ..where((row) => row.id.isIn(superseded)))
          .write(const SyncChangesCompanion(isUploaded: Value(true)));
    }
  }

  Future<String> canonicalEntityId(String entityKind, String entityId) async {
    final visited = <String>{};
    var canonicalId = entityId;
    while (true) {
      if (!visited.add(canonicalId)) {
        throw StateError('Sync identity aliases contain a cycle');
      }
      final alias = await (database.select(database.syncEntityAliases)
            ..where((row) =>
                row.entityKind.equals(entityKind) &
                row.aliasId.equals(canonicalId)))
          .getSingleOrNull();
      if (alias == null) return canonicalId;
      canonicalId = alias.canonicalId;
      if (visited.length > 64) {
        throw StateError('Sync identity alias chain exceeds its limit');
      }
    }
  }

  Future<void> addEntityAlias(
      String entityKind, String aliasId, String canonicalId) async {
    if (entityKind.isEmpty || aliasId.isEmpty || canonicalId.isEmpty) {
      throw ArgumentError('Sync alias identities must not be empty');
    }
    final canonical = await canonicalEntityId(entityKind, canonicalId);
    if (aliasId == canonical) return;
    final existingCanonical = await canonicalEntityId(entityKind, aliasId);
    if (existingCanonical != aliasId) {
      if (existingCanonical == canonical) return;
      throw StateError('Sync alias already points to another identity');
    }
    await database.into(database.syncEntityAliases).insertOnConflictUpdate(
        SyncEntityAliasesCompanion.insert(
            entityKind: entityKind, aliasId: aliasId, canonicalId: canonical));
  }

  Future<bool> expectsParent(
          String entityKind, String entityId, String? parentChangeId) async =>
      await head(entityKind, entityId) == parentChangeId;

  Future<List<SyncChange>> pending() => (database.select(database.syncChanges)
        ..where((row) => row.isUploaded.equals(false)))
      .get();

  Future<int> bootstrapExistingEntities() => database.transaction(() async {
        final entities = <(String, String, Map<String, Object?>)>[];
        for (final location
            in await database.select(database.locations).get()) {
          entities.add((
            'location',
            location.syncId!,
            {
              'name': location.name,
              'colorArgb': location.colorArgb,
              'sortOrder': location.sortOrder,
              'isArchived': location.isArchived,
            }
          ));
        }
        for (final zone in await database.select(database.tariffZones).get()) {
          final links = await (database.select(database.locationZones)
                ..where((row) => row.zoneId.equals(zone.id)))
              .get();
          final locationIds = <String>[
            for (final link in links)
              await database.requireSyncIdFor('locations', link.locationId),
          ]..sort();
          entities.add((
            'zone',
            zone.syncId!,
            {
              'code': zone.code,
              'name': zone.name,
              'kind': zone.kind,
              'colorArgb': zone.colorArgb,
              'sortOrder': zone.sortOrder,
              'isArchived': zone.isArchived,
              'locationIds': locationIds,
            }
          ));
        }
        for (final rate in await database.select(database.tariffRates).get()) {
          entities.add((
            'rate',
            rate.syncId!,
            {
              'zoneId': await database.requireZoneSyncId(rate.zoneId),
              'priceMinorUnits': rate.priceMinorUnits,
              'currencyCode': rate.currencyCode,
              'validFrom': rate.validFrom.toIso8601String(),
              'validTo': rate.validTo?.toIso8601String(),
            }
          ));
        }
        for (final reading
            in await database.select(database.meterReadings).get()) {
          entities.add((
            'reading',
            reading.syncId!,
            {
              'locationId': await database.requireSyncIdFor(
                  'locations', reading.locationId),
              'zoneId': await database.requireZoneSyncId(reading.zoneId),
              'readingDate': reading.readingDate.toIso8601String(),
              'valueKwh': reading.valueKwh,
              'note': reading.note,
              'createdAt': reading.createdAt.toIso8601String(),
              'updatedAt': reading.updatedAt.toIso8601String(),
              'isReset': reading.isReset,
            }
          ));
        }

        var added = 0;
        for (final entity in entities) {
          if (await head(entity.$1, entity.$2) != null) continue;
          final payload = jsonEncode(entity.$3);
          final digest = await Sha256().hash(
              utf8.encode('${entity.$1}\u0000${entity.$2}\u0000$payload'));
          final changeId =
              'bootstrap-${digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
          await enqueue(
              changeId: changeId,
              entityKind: entity.$1,
              entityId: entity.$2,
              payload: payload,
              parentChangeId: null);
          added++;
        }
        return added;
      });

  Future<List<SyncConflict>> unresolvedConflicts() =>
      (database.select(database.syncConflicts)
            ..where((row) => row.isResolved.equals(false))
            ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
          .get();

  Future<void> queueConflict({
    required String changeId,
    required String entityKind,
    required String entityId,
    required String reason,
    required String payload,
  }) async {
    if (changeId.isEmpty ||
        entityKind.isEmpty ||
        entityId.isEmpty ||
        reason.isEmpty) {
      throw ArgumentError('Conflict identity and reason must not be empty');
    }
    await database.into(database.syncConflicts).insertOnConflictUpdate(
        SyncConflictsCompanion.insert(
            id: changeId,
            entityKind: entityKind,
            entityId: entityId,
            reason: reason,
            payload: payload,
            createdAt: DateTime.now().toUtc()));
  }

  Future<void> markConflictResolved(String changeId) =>
      (database.update(database.syncConflicts)
            ..where((row) => row.id.equals(changeId)))
          .write(const SyncConflictsCompanion(isResolved: Value(true)));

  Future<void> markUploaded(String changeId) =>
      (database.update(database.syncChanges)
            ..where((row) => row.id.equals(changeId)))
          .write(const SyncChangesCompanion(isUploaded: Value(true)));

  Future<bool> wasApplied(String changeId) async =>
      await (database.select(database.appliedSyncChanges)
            ..where((row) => row.id.equals(changeId)))
          .getSingleOrNull() !=
      null;

  Future<bool> applyOnce(String changeId, Future<void> Function() apply,
      {String? parentChangeId}) async {
    if (changeId.isEmpty) throw ArgumentError('Missing change ID');
    return database.transaction(() async {
      final existing = await (database.select(database.appliedSyncChanges)
            ..where((row) => row.id.equals(changeId)))
          .getSingleOrNull();
      if (existing != null) return false;
      await apply();
      await database.into(database.appliedSyncChanges).insert(
          AppliedSyncChangesCompanion.insert(
              id: changeId, parentChangeId: Value(parentChangeId)));
      return true;
    });
  }

  Future<List<String>> causalHistory(String changeId) async {
    final history = <String>[];
    final visited = <String>{};
    String? current = changeId;
    while (current != null) {
      if (!visited.add(current)) {
        throw StateError('Sync change history contains a cycle');
      }
      history.add(current);
      if (history.length > 10000) {
        throw StateError('Sync change history exceeds its limit');
      }
      final local = await (database.select(database.syncChanges)
            ..where((row) => row.id.equals(current!)))
          .getSingleOrNull();
      if (local != null) {
        current = local.parentChangeId;
        continue;
      }
      final applied = await (database.select(database.appliedSyncChanges)
            ..where((row) => row.id.equals(current!)))
          .getSingleOrNull();
      current = applied?.parentChangeId;
    }
    return history;
  }
}

/// Human-readable, non-sensitive summaries for conflict review UI.
List<String> syncConflictCandidateSummaries(SyncConflict conflict) {
  try {
    final decoded = jsonDecode(conflict.payload);
    if (decoded is! Map<String, dynamic> || decoded['candidates'] is! List) {
      return const [];
    }
    final candidates = decoded['candidates'] as List<dynamic>;
    return [
      for (final candidate in candidates)
        if (candidate is Map<String, dynamic> &&
            candidate['payload'] is Map<String, dynamic>)
          candidate['deleted'] == true
              ? '${candidate['side'] == 'local' ? 'This device' : 'Incoming'}: delete ${conflict.entityKind}'
              : _candidateSummary(
                  conflict.entityKind,
                  candidate['side'] as String? ?? 'Candidate',
                  candidate['payload'] as Map<String, dynamic>),
    ];
  } on FormatException {
    return const [];
  }
}

List<String> syncConflictResolutionChoices(SyncConflict conflict) {
  try {
    final decoded = jsonDecode(conflict.payload);
    if (decoded is! Map<String, dynamic> || decoded['candidates'] is! List) {
      return const [];
    }
    final candidates = decoded['candidates'] as List<dynamic>;
    final entityIds = <String>{};
    if (candidates.length != 2 ||
        decoded['localHeads'] is! Map<String, dynamic>) {
      return const [];
    }
    for (final candidate in candidates) {
      if (candidate is! Map<String, dynamic> ||
          candidate['entityId'] is! String ||
          candidate['changeId'] is! String ||
          candidate['payload'] is! Map<String, dynamic> ||
          candidate['deleted'] is! bool) {
        return const [];
      }
      final entityId = candidate['entityId'] as String;
      if ((decoded['localHeads'] as Map<String, dynamic>)
              .containsKey(entityId) !=
          true) {
        return const [];
      }
      entityIds.add(entityId);
    }
    final mergesIdentity = entityIds.length > 1;
    if (mergesIdentity &&
        !const {'reading', 'rate', 'location', 'zone'}
            .contains(conflict.entityKind)) {
      return const [];
    }
    return [
      for (final candidate in candidates)
        mergesIdentity
            ? (candidate['side'] == 'local'
                ? 'Keep this device ${conflict.entityKind} identity'
                : 'Merge into incoming ${conflict.entityKind} identity')
            : candidate['deleted'] == true
                ? (candidate['side'] == 'local'
                    ? 'Keep deleted state'
                    : 'Accept incoming deletion')
                : (candidate['side'] == 'local'
                    ? 'Use this device'
                    : 'Use incoming'),
    ];
  } on FormatException {
    return const [];
  }
}

String _candidateSummary(
    String entityKind, String side, Map<String, dynamic> payload) {
  final label = side == 'local' ? 'This device' : 'Incoming';
  if (entityKind == 'reading' &&
      payload['valueKwh'] is num &&
      payload['readingDate'] is String) {
    return '$label: ${payload['valueKwh']} kWh on ${payload['readingDate']}';
  }
  if (entityKind == 'reading' &&
      side == 'remote' &&
      payload['deleted'] == true) {
    return '$label: delete reading';
  }
  if (entityKind == 'rate' && payload['priceMinorUnits'] is int) {
    return '$label: tariff ${payload['priceMinorUnits']} ${payload['currencyCode'] ?? ''}';
  }
  return '$label candidate';
}

/// Uploads pending outbox records; downloaded changes are handled separately.
class GoogleDriveOutboxUploader {
  GoogleDriveOutboxUploader({
    required this.journal,
    required this.store,
    required this.vault,
  });

  final DriftSyncJournal journal;
  final EncryptedChangeStore store;
  final SyncVault vault;

  Future<int> uploadPending() async {
    final pending = _causalOrder(await journal.pending());
    var uploaded = 0;
    for (final change in pending) {
      final envelope = _envelope(change);
      await store.publish(vault, change.id, utf8.encode(jsonEncode(envelope)));
      await journal.markUploaded(change.id);
      uploaded++;
    }
    return uploaded;
  }

  List<SyncChange> _causalOrder(List<SyncChange> pending) {
    final pendingIds = {for (final change in pending) change.id};
    final remaining = [...pending];
    final ordered = <SyncChange>[];
    final uploadedIds = <String>{};
    while (remaining.isNotEmpty) {
      final ready = remaining
          .where((change) =>
              change.parentChangeId == null ||
              !pendingIds.contains(change.parentChangeId) ||
              uploadedIds.contains(change.parentChangeId))
          .toList()
        ..sort((first, second) {
          final rank = _dependencyRank(first.entityKind)
              .compareTo(_dependencyRank(second.entityKind));
          return rank != 0 ? rank : first.id.compareTo(second.id);
        });
      if (ready.isEmpty) {
        throw StateError('Outbox contains a causal parent cycle');
      }
      final next = ready.first;
      remaining.remove(next);
      ordered.add(next);
      uploadedIds.add(next.id);
    }
    return ordered;
  }

  int _dependencyRank(String entityKind) => switch (entityKind) {
        'location' => 0,
        'zone' => 1,
        'rate' => 2,
        'reading' => 3,
        _ => 4,
      };

  Map<String, Object?> _envelope(SyncChange change) {
    final Object? payload;
    try {
      payload = jsonDecode(change.payload);
    } on FormatException {
      throw const FormatException('Outbox payload is not valid JSON');
    }
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Outbox payload must be a JSON object');
    }
    return {
      'schemaVersion': 1,
      'changeId': change.id,
      'parentChangeId': change.parentChangeId,
      'entityKind': change.entityKind,
      'entityId': change.entityId,
      'isDeleted': change.isDeleted,
      'payload': payload,
    };
  }
}

/// Summary of applying authenticated remote operations into local SQLite.
class IncomingSyncReport {
  const IncomingSyncReport({
    required this.applied,
    required this.duplicates,
    required this.conflicts,
    required this.otherVault,
  });

  final int applied;
  final int duplicates;
  final int conflicts;
  final int otherVault;
}

class _IncomingChange {
  const _IncomingChange(
      this.changeId, this.parentChangeId, this.entityKind, this.value);

  final String changeId;
  final String? parentChangeId;
  final String entityKind;
  final Map<String, dynamic> value;
}

class _IncomingConflict {
  const _IncomingConflict(this.reason, {this.candidates = const []});

  final String reason;
  final List<Map<String, Object?>> candidates;
}

/// Applies remote encrypted changes without echoing them to the local outbox.
///
/// Existing-row edits, deletes with local dependants and all uniqueness or
/// relationship collisions are retained in [SyncConflicts] for explicit user
/// resolution. The applier never chooses a winner based on timestamps.
class GoogleDriveIncomingApplier {
  GoogleDriveIncomingApplier({
    required this.database,
    required this.journal,
    required this.store,
    required this.vault,
  });

  final ElectricityDatabase database;
  final DriftSyncJournal journal;
  final EncryptedChangeStore store;
  final SyncVault vault;

  Future<IncomingSyncReport> applyAvailable() async {
    final files = await store.listChanges();
    final changes = <_IncomingChange>[];
    var otherVault = 0;
    var duplicates = 0;
    for (final file in files) {
      final encrypted = await store.readEncrypted(file.id);
      if (encrypted['vaultId'] != vault.vaultId) {
        otherVault++;
        continue;
      }
      final plaintext = await vault.decrypt(encrypted);
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Incoming change must be a JSON object');
      }
      final change = _parseChange(decoded, encrypted['changeId']);
      if (await journal.wasApplied(change.changeId)) {
        duplicates++;
      } else {
        changes.add(change);
      }
    }

    final orderedChanges = await _orderChanges(changes);
    var applied = 0;
    var conflicts = 0;
    for (final change in orderedChanges) {
      var conflicted = false;
      final didApply = await journal.applyOnce(change.changeId, () async {
        if (await journal.wasSuperseded(change.changeId)) return;
        final entityId = await journal.canonicalEntityId(
            change.entityKind, change.value['entityId'] as String);
        final localHead = await journal.head(change.entityKind, entityId);
        final causalBaseMatches = await journal.expectsParent(
            change.entityKind, entityId, change.parentChangeId);
        final conflict = await _applyChange(change);
        if (conflict == null) {
          if (causalBaseMatches || _isResolution(change.value)) {
            await journal.setHead(change.entityKind, entityId, change.changeId);
          }
          return;
        }
        conflicted = true;
        final candidatePayload = conflict.candidates.isNotEmpty
            ? conflict.candidates
            : [
                {
                  'side': 'remote',
                  'payload': change.value['payload'],
                  'entityId': entityId,
                  'changeId': change.changeId,
                  'deleted': change.value['isDeleted'],
                }
              ];
        final candidates = <Map<String, Object?>>[];
        final localHeads = <String, Object?>{};
        for (final candidate in candidatePayload) {
          final candidateEntityId =
              candidate['entityId'] as String? ?? entityId;
          final candidateHead =
              await journal.head(change.entityKind, candidateEntityId);
          localHeads[candidateEntityId] = candidateHead;
          candidates.add({
            ...candidate,
            'entityId': candidateEntityId,
            'changeId': candidate['changeId'] ??
                (candidate['side'] == 'local'
                    ? candidateHead
                    : change.changeId),
            'deleted': candidate['deleted'] ??
                (candidate['side'] == 'remote'
                    ? change.value['isDeleted']
                    : false),
          });
        }
        await journal.queueConflict(
            changeId: change.changeId,
            entityKind: change.entityKind,
            entityId: entityId,
            reason: conflict.reason,
            payload: jsonEncode({
              'remoteChange': change.value,
              'localChangeId': localHead,
              'localHeads': localHeads,
              'candidates': candidates,
            }));
      }, parentChangeId: change.parentChangeId);
      if (didApply) {
        applied++;
        if (conflicted) conflicts++;
      } else {
        duplicates++;
      }
    }
    return IncomingSyncReport(
        applied: applied,
        duplicates: duplicates,
        conflicts: conflicts,
        otherVault: otherVault);
  }

  _IncomingChange _parseChange(
      Map<String, dynamic> value, Object? encryptedChangeId) {
    if (value['schemaVersion'] != 1 ||
        value['changeId'] is! String ||
        value['changeId'] != encryptedChangeId ||
        value['entityKind'] is! String ||
        value['entityId'] is! String ||
        value['isDeleted'] is! bool ||
        value['payload'] is! Map<String, dynamic>) {
      throw const FormatException('Unsupported incoming change envelope');
    }
    final parentChangeId = value['parentChangeId'];
    if (parentChangeId != null && parentChangeId is! String) {
      throw const FormatException('Invalid causal parent ID');
    }
    final changeId = value['changeId'] as String;
    final entityId = value['entityId'] as String;
    if (changeId.isEmpty ||
        entityId.isEmpty ||
        changeId.length > 128 ||
        entityId.length > 128) {
      throw const FormatException('Invalid incoming change identity');
    }
    return _IncomingChange(changeId, parentChangeId as String?,
        value['entityKind'] as String, value);
  }

  Future<List<_IncomingChange>> _orderChanges(
      List<_IncomingChange> changes) async {
    final remaining = [...changes];
    final ordered = <_IncomingChange>[];
    final orderedIds = <String>{};
    while (remaining.isNotEmpty) {
      final ready = <_IncomingChange>[];
      for (final change in remaining) {
        final parent = change.parentChangeId;
        final entityId = await journal.canonicalEntityId(
            change.entityKind, change.value['entityId'] as String);
        if (parent == null ||
            orderedIds.contains(parent) ||
            await journal.wasApplied(parent) ||
            await journal.head(change.entityKind, entityId) == parent) {
          ready.add(change);
        }
      }
      final candidates = ready.isEmpty ? [remaining.first] : ready;
      candidates.sort((first, second) {
        final rank = _dependencyRank(first.entityKind)
            .compareTo(_dependencyRank(second.entityKind));
        return rank != 0 ? rank : first.changeId.compareTo(second.changeId);
      });
      final next = candidates.first;
      remaining.remove(next);
      ordered.add(next);
      orderedIds.add(next.changeId);
    }
    return ordered;
  }

  int _dependencyRank(String entityKind) => switch (entityKind) {
        'location' => 0,
        'zone' => 1,
        'rate' => 2,
        'reading' => 3,
        _ => 4,
      };

  Future<_IncomingConflict?> _applyChange(_IncomingChange change) async {
    final envelope = change.value;
    final payload = envelope['payload'] as Map<String, dynamic>;
    final entityId = await journal.canonicalEntityId(
        change.entityKind, envelope['entityId'] as String);
    final deleted = envelope['isDeleted'] as bool;
    if (_isResolution(envelope)) {
      return _applyResolution(change, entityId, payload, deleted);
    }
    return switch (change.entityKind) {
      'location' =>
        _applyLocation(entityId, payload, deleted, change.parentChangeId),
      'zone' => _applyZone(entityId, payload, deleted, change.parentChangeId),
      'rate' => _applyRate(entityId, payload, deleted, change.parentChangeId),
      'reading' =>
        _applyReading(entityId, payload, deleted, change.parentChangeId),
      _ => Future.value(const _IncomingConflict('Unknown entity kind')),
    };
  }

  Future<_IncomingConflict?> _applyResolution(_IncomingChange change,
      String entityId, Map<String, dynamic> payload, bool deleted) async {
    final metadata = payload['_syncResolution'];
    if (metadata is! Map<String, dynamic> ||
        metadata['version'] != 1 ||
        metadata['supersedes'] is! List<dynamic> ||
        metadata['branches'] is! List<dynamic> ||
        metadata['aliases'] is! List<dynamic>) {
      return const _IncomingConflict('Invalid conflict resolution record');
    }
    final supersedes =
        (metadata['supersedes'] as List<dynamic>).whereType<String>().toSet();
    if (supersedes.length < 2 ||
        supersedes.length != (metadata['supersedes'] as List<dynamic>).length ||
        metadata['selectedChangeId'] is! String ||
        !supersedes.contains(metadata['selectedChangeId']) ||
        change.parentChangeId == null ||
        !supersedes.contains(change.parentChangeId)) {
      return const _IncomingConflict('Invalid superseded branch list');
    }
    final branches = metadata['branches'] as List<dynamic>;
    if (branches.length != supersedes.length) {
      return const _IncomingConflict('Resolution branches do not match');
    }
    final branchIds = <String>{};
    final currentHeads = <String>[];
    for (final branch in branches) {
      if (branch is! Map<String, dynamic> ||
          branch['entityId'] is! String ||
          branch['changeId'] is! String ||
          !supersedes.contains(branch['changeId'])) {
        return const _IncomingConflict('Invalid resolution branch identity');
      }
      branchIds.add(branch['changeId'] as String);
      final branchEntityId = await journal.canonicalEntityId(
          change.entityKind, branch['entityId'] as String);
      final branchHead = await journal.head(change.entityKind, branchEntityId);
      if (branchHead != null && supersedes.contains(branchHead)) {
        currentHeads.add(branchHead);
      }
    }
    if (branchIds.length != supersedes.length) {
      return const _IncomingConflict('Resolution omits a superseded branch');
    }
    if (currentHeads.isEmpty) {
      return const _IncomingConflict(
          'Resolution does not include this device current branch');
    }
    final aliases = metadata['aliases'] as List<dynamic>;
    final aliasIds = <String>{};
    for (final alias in aliases) {
      if (alias is! Map<String, dynamic> ||
          alias['entityKind'] != change.entityKind ||
          alias['aliasId'] is! String ||
          alias['canonicalId'] != entityId ||
          alias['aliasId'] == entityId) {
        return const _IncomingConflict('Invalid resolution alias mapping');
      }
      aliasIds.add(alias['aliasId'] as String);
    }
    final branchEntityIds = {
      for (final branch in branches)
        (branch as Map<String, dynamic>)['entityId'] as String,
    };
    final expectedAliasIds = branchEntityIds.difference({entityId});
    if (aliasIds.length != expectedAliasIds.length ||
        !aliasIds.containsAll(expectedAliasIds) ||
        !branchEntityIds.contains(entityId)) {
      return const _IncomingConflict(
          'Resolution aliases do not match branches');
    }
    final mergeConflict = await _applyEntityAliases(
        change.entityKind, aliases, entityId, deleted);
    if (mergeConflict != null) return mergeConflict;
    final currentHead = await journal.head(change.entityKind, entityId);
    final selectedPayload = Map<String, dynamic>.from(payload)
      ..remove('_syncResolution');
    final conflict = await _applyEntitySnapshot(
        change.entityKind, entityId, selectedPayload, deleted, currentHead);
    if (conflict != null) return conflict;
    for (final branch in supersedes) {
      await journal.markConflictResolved(branch);
    }
    await journal.recordSuperseded(supersedes, change.changeId);
    return null;
  }

  Future<_IncomingConflict?> _applyEntityAliases(String entityKind,
      List<dynamic> aliases, String canonicalId, bool deleted) async {
    if (aliases.isNotEmpty &&
        !const {'reading', 'rate', 'location', 'zone'}.contains(entityKind)) {
      return const _IncomingConflict(
          'This entity kind does not support identity merging');
    }
    for (final alias in aliases) {
      if (alias is! Map<String, dynamic> ||
          alias['entityKind'] != entityKind ||
          alias['aliasId'] is! String ||
          alias['canonicalId'] != canonicalId ||
          alias['aliasId'] == canonicalId) {
        return const _IncomingConflict('Invalid identity alias');
      }
      final aliasId = alias['aliasId'] as String;
      if (entityKind == 'location') {
        final canonical = await _locationBySyncId(canonicalId);
        final aliasRow = await _locationBySyncId(aliasId);
        if (canonical != null && aliasRow != null) {
          final aliasLinks = await (database.select(database.locationZones)
                ..where((row) => row.locationId.equals(aliasRow.id)))
              .get();
          final aliasReadings = await (database.select(database.meterReadings)
                ..where((row) => row.locationId.equals(aliasRow.id)))
              .get();
          final canonicalLinks = await (database.select(database.locationZones)
                ..where((row) => row.locationId.equals(canonical.id)))
              .get();
          final canonicalReadings =
              await (database.select(database.meterReadings)
                    ..where((row) => row.locationId.equals(canonical.id)))
                  .get();
          if (deleted) {
            if (aliasLinks.isNotEmpty ||
                aliasReadings.isNotEmpty ||
                canonicalLinks.isNotEmpty ||
                canonicalReadings.isNotEmpty) {
              return const _IncomingConflict(
                  'Location deletion has local dependencies');
            }
            await (database.delete(database.locations)
                  ..where((row) => row.id.isIn([canonical.id, aliasRow.id])))
                .go();
          } else {
            for (final reading in aliasReadings) {
              final collision = await (database.select(database.meterReadings)
                    ..where((row) =>
                        row.locationId.equals(canonical.id) &
                        row.zoneId.equals(reading.zoneId) &
                        row.readingDate.equals(reading.readingDate)))
                  .getSingleOrNull();
              if (collision != null) {
                return const _IncomingConflict(
                    'Resolve colliding reading slots before merging locations');
              }
            }
            for (final link in aliasLinks) {
              await (database.delete(database.locationZones)
                    ..where((row) =>
                        row.locationId.equals(aliasRow.id) &
                        row.zoneId.equals(link.zoneId)))
                  .go();
              await database
                  .into(database.locationZones)
                  .insertOnConflictUpdate(LocationZonesCompanion.insert(
                      locationId: canonical.id, zoneId: link.zoneId));
            }
            await (database.update(database.meterReadings)
                  ..where((row) => row.locationId.equals(aliasRow.id)))
                .write(MeterReadingsCompanion(locationId: Value(canonical.id)));
            await (database.delete(database.locations)
                  ..where((row) => row.id.equals(aliasRow.id)))
                .go();
          }
        } else if (aliasRow != null) {
          if (deleted) {
            final links = await (database.select(database.locationZones)
                  ..where((row) => row.locationId.equals(aliasRow.id)))
                .get();
            final readings = await (database.select(database.meterReadings)
                  ..where((row) => row.locationId.equals(aliasRow.id)))
                .get();
            if (links.isNotEmpty || readings.isNotEmpty) {
              return const _IncomingConflict(
                  'Location deletion has local dependencies');
            }
            await (database.delete(database.locations)
                  ..where((row) => row.id.equals(aliasRow.id)))
                .go();
          } else {
            await (database.update(database.locations)
                  ..where((row) => row.id.equals(aliasRow.id)))
                .write(LocationsCompanion(syncId: Value(canonicalId)));
          }
        } else if (deleted && canonical != null) {
          final links = await (database.select(database.locationZones)
                ..where((row) => row.locationId.equals(canonical.id)))
              .get();
          final readings = await (database.select(database.meterReadings)
                ..where((row) => row.locationId.equals(canonical.id)))
              .get();
          if (links.isNotEmpty || readings.isNotEmpty) {
            return const _IncomingConflict(
                'Location deletion has local dependencies');
          }
          await (database.delete(database.locations)
                ..where((row) => row.id.equals(canonical.id)))
              .go();
        }
        await journal.addEntityAlias(entityKind, aliasId, canonicalId);
        continue;
      }
      if (entityKind == 'zone') {
        final canonical = await _zoneBySyncId(canonicalId);
        final aliasRow = await _zoneBySyncId(aliasId);
        if (canonical != null && aliasRow != null) {
          if (canonical.code != aliasRow.code) {
            return const _IncomingConflict(
                'Zone identities with different codes cannot be merged');
          }
          final readings = await (database.select(database.meterReadings)
                ..where((row) => row.zoneId.equals(canonical.code)))
              .get();
          final rates = await (database.select(database.tariffRates)
                ..where((row) => row.zoneId.equals(canonical.code)))
              .get();
          if (deleted && (readings.isNotEmpty || rates.isNotEmpty)) {
            return const _IncomingConflict(
                'Zone deletion has local readings or tariff rates');
          }
          final aliasLinks = await (database.select(database.locationZones)
                ..where((row) => row.zoneId.equals(aliasRow.id)))
              .get();
          for (final link in aliasLinks) {
            await (database.delete(database.locationZones)
                  ..where((row) =>
                      row.zoneId.equals(aliasRow.id) &
                      row.locationId.equals(link.locationId)))
                .go();
            if (!deleted) {
              await database
                  .into(database.locationZones)
                  .insertOnConflictUpdate(LocationZonesCompanion.insert(
                      locationId: link.locationId, zoneId: canonical.id));
            }
          }
          await (database.delete(database.tariffZones)
                ..where((row) => row.id.equals(aliasRow.id)))
              .go();
          if (deleted) {
            await (database.delete(database.tariffZones)
                  ..where((row) => row.id.equals(canonical.id)))
                .go();
          }
        } else if (aliasRow != null) {
          if (deleted) {
            final readings = await (database.select(database.meterReadings)
                  ..where((row) => row.zoneId.equals(aliasRow.code)))
                .get();
            final rates = await (database.select(database.tariffRates)
                  ..where((row) => row.zoneId.equals(aliasRow.code)))
                .get();
            if (readings.isNotEmpty || rates.isNotEmpty) {
              return const _IncomingConflict(
                  'Zone deletion has local readings or tariff rates');
            }
            await (database.delete(database.locationZones)
                  ..where((row) => row.zoneId.equals(aliasRow.id)))
                .go();
            await (database.delete(database.tariffZones)
                  ..where((row) => row.id.equals(aliasRow.id)))
                .go();
          } else {
            await (database.update(database.tariffZones)
                  ..where((row) => row.id.equals(aliasRow.id)))
                .write(TariffZonesCompanion(syncId: Value(canonicalId)));
          }
        } else if (deleted && canonical != null) {
          final readings = await (database.select(database.meterReadings)
                ..where((row) => row.zoneId.equals(canonical.code)))
              .get();
          final rates = await (database.select(database.tariffRates)
                ..where((row) => row.zoneId.equals(canonical.code)))
              .get();
          if (readings.isNotEmpty || rates.isNotEmpty) {
            return const _IncomingConflict(
                'Zone deletion has local readings or tariff rates');
          }
          await (database.delete(database.locationZones)
                ..where((row) => row.zoneId.equals(canonical.id)))
              .go();
          await (database.delete(database.tariffZones)
                ..where((row) => row.id.equals(canonical.id)))
              .go();
        }
        await journal.addEntityAlias(entityKind, aliasId, canonicalId);
        continue;
      }
      if (entityKind == 'rate') {
        final canonicalRate = await _rateBySyncId(canonicalId);
        final aliasRate = await _rateBySyncId(aliasId);
        if (canonicalRate != null && aliasRate != null) {
          if (canonicalRate.zoneId != aliasRate.zoneId ||
              !_periodsOverlap(canonicalRate.validFrom, canonicalRate.validTo,
                  aliasRate.validFrom, aliasRate.validTo)) {
            return const _IncomingConflict(
                'Tariff rates do not share an overlapping zone period');
          }
          if (deleted) {
            await (database.delete(database.tariffRates)
                  ..where(
                      (row) => row.id.isIn([canonicalRate.id, aliasRate.id])))
                .go();
          } else {
            await (database.delete(database.tariffRates)
                  ..where((row) => row.id.equals(aliasRate.id)))
                .go();
          }
        } else if (aliasRate != null) {
          if (deleted) {
            await (database.delete(database.tariffRates)
                  ..where((row) => row.id.equals(aliasRate.id)))
                .go();
          } else {
            await (database.update(database.tariffRates)
                  ..where((row) => row.id.equals(aliasRate.id)))
                .write(TariffRatesCompanion(syncId: Value(canonicalId)));
          }
        } else if (deleted && canonicalRate != null) {
          await (database.delete(database.tariffRates)
                ..where((row) => row.id.equals(canonicalRate.id)))
              .go();
        }
        await journal.addEntityAlias(entityKind, aliasId, canonicalId);
        continue;
      }
      final canonicalRow = await _readingBySyncId(canonicalId);
      final aliasRow = await _readingBySyncId(aliasId);
      if (canonicalRow != null && aliasRow != null) {
        if (canonicalRow.locationId != aliasRow.locationId ||
            canonicalRow.zoneId != aliasRow.zoneId ||
            canonicalRow.readingDate != aliasRow.readingDate) {
          return const _IncomingConflict(
              'Readings with different identities do not occupy the same slot');
        }
        if (deleted) {
          await (database.delete(database.meterReadings)
                ..where((row) => row.id.isIn([canonicalRow.id, aliasRow.id])))
              .go();
        } else {
          await (database.delete(database.meterReadings)
                ..where((row) => row.id.equals(aliasRow.id)))
              .go();
        }
      } else if (aliasRow != null) {
        if (deleted) {
          await (database.delete(database.meterReadings)
                ..where((row) => row.id.equals(aliasRow.id)))
              .go();
        } else {
          await (database.update(database.meterReadings)
                ..where((row) => row.id.equals(aliasRow.id)))
              .write(MeterReadingsCompanion(syncId: Value(canonicalId)));
        }
      } else if (deleted && canonicalRow != null) {
        await (database.delete(database.meterReadings)
              ..where((row) => row.id.equals(canonicalRow.id)))
            .go();
      }
      await journal.addEntityAlias(entityKind, aliasId, canonicalId);
    }
    return null;
  }

  Future<_IncomingConflict?> _applyEntitySnapshot(
          String entityKind,
          String entityId,
          Map<String, dynamic> payload,
          bool deleted,
          String? parent) =>
      switch (entityKind) {
        'location' => _applyLocation(entityId, payload, deleted, parent),
        'zone' => _applyZone(entityId, payload, deleted, parent),
        'rate' => _applyRate(entityId, payload, deleted, parent),
        'reading' => _applyReading(entityId, payload, deleted, parent),
        _ => Future.value(const _IncomingConflict('Unknown entity kind')),
      };

  bool _isResolution(Map<String, dynamic> envelope) =>
      (envelope['payload'] as Map<String, dynamic>)
          .containsKey('_syncResolution');

  Future<void> resolveConflict(String changeId, int candidateIndex) async {
    await database.transaction(() async {
      final conflict = await (database.select(database.syncConflicts)
            ..where((row) => row.id.equals(changeId)))
          .getSingleOrNull();
      if (conflict == null || conflict.isResolved) {
        throw StateError('Conflict is no longer available');
      }
      final content = jsonDecode(conflict.payload) as Map<String, dynamic>;
      final choices = syncConflictResolutionChoices(conflict);
      final candidates = content['candidates'] as List<dynamic>;
      if (candidateIndex < 0 || candidateIndex >= choices.length) {
        throw ArgumentError('This conflict does not support that resolution');
      }
      final localHeads = content['localHeads'] as Map<String, dynamic>;
      for (final entry in localHeads.entries) {
        if (await journal.head(conflict.entityKind, entry.key) != entry.value) {
          throw StateError('Conflict changed; sync again before resolving');
        }
      }
      final selected = candidates[candidateIndex] as Map<String, dynamic>;
      final canonicalId = selected['entityId'] as String;
      final branchEntities = <String, String>{};
      for (final candidate in candidates) {
        final branchEntityId = candidate['entityId'] as String;
        for (final branchId
            in await journal.causalHistory(candidate['changeId'] as String)) {
          branchEntities[branchId] = branchEntityId;
        }
      }
      final supersedes = branchEntities.keys.toSet();
      final branches = [
        for (final entry in branchEntities.entries)
          {'entityId': entry.value, 'changeId': entry.key},
      ];
      final aliases = <Map<String, Object?>>[
        for (final candidate in candidates)
          if (candidate['entityId'] != canonicalId)
            {
              'entityKind': conflict.entityKind,
              'aliasId': candidate['entityId'],
              'canonicalId': canonicalId,
            }
      ];
      final selectedPayload = Map<String, dynamic>.from(
          selected['payload'] as Map<String, dynamic>);
      final chosenPayload = Map<String, dynamic>.from(selectedPayload);
      selectedPayload['_syncResolution'] = {
        'version': 1,
        'supersedes': supersedes.toList()..sort(),
        'selectedChangeId': selected['changeId'],
        'branches': branches,
        'aliases': aliases,
      };
      final deleted = selected['deleted'] == true;
      final mergeConflict = await _applyEntityAliases(
          conflict.entityKind, aliases, canonicalId, deleted);
      if (mergeConflict != null) throw StateError(mergeConflict.reason);
      final currentHead = await journal.head(conflict.entityKind, canonicalId);
      final rejected = await _applyEntitySnapshot(conflict.entityKind,
          canonicalId, chosenPayload, deleted, currentHead);
      if (rejected != null) throw StateError(rejected.reason);
      final resolutionId = _newSyncId();
      await journal.enqueue(
          changeId: resolutionId,
          entityKind: conflict.entityKind,
          entityId: canonicalId,
          payload: jsonEncode(selectedPayload),
          isDeleted: deleted,
          parentChangeId: selected['changeId'] as String);
      await journal.applyOnce(resolutionId, () async {});
      await journal.recordSuperseded(supersedes, resolutionId);
      await journal.markConflictResolved(changeId);
    });
  }

  Future<_IncomingConflict?> _applyLocation(
      String syncId,
      Map<String, dynamic> payload,
      bool deleted,
      String? parentChangeId) async {
    final existing = await _locationBySyncId(syncId);
    if (existing != null) {
      if (deleted) {
        if (!await journal.expectsParent('location', syncId, parentChangeId)) {
          return _IncomingConflict(
              'Location changed after the remote deletion was based',
              candidates: [
                {
                  'side': 'local',
                  'entityId': syncId,
                  'payload': {
                    'name': existing.name,
                    'colorArgb': existing.colorArgb,
                    'sortOrder': existing.sortOrder,
                    'isArchived': existing.isArchived,
                  }
                },
                {
                  'side': 'remote',
                  'entityId': syncId,
                  'payload': payload,
                  'deleted': true,
                },
              ]);
        }
        final zones = await (database.select(database.locationZones)
              ..where((row) => row.locationId.equals(existing.id)))
            .get();
        final readings = await (database.select(database.meterReadings)
              ..where((row) => row.locationId.equals(existing.id)))
            .get();
        if (zones.isNotEmpty || readings.isNotEmpty) {
          return _IncomingConflict(
              'Deleted location still has local zone links or readings',
              candidates: [
                {
                  'side': 'local',
                  'entityId': syncId,
                  'payload': {
                    'name': existing.name,
                    'colorArgb': existing.colorArgb,
                    'sortOrder': existing.sortOrder,
                    'isArchived': existing.isArchived,
                  }
                },
                {
                  'side': 'remote',
                  'entityId': syncId,
                  'payload': payload,
                  'deleted': true,
                },
              ]);
        }
        await (database.delete(database.locations)
              ..where((row) => row.id.equals(existing.id)))
            .go();
        return null;
      }
      if (_locationMatches(existing, payload)) return null;
      if (await journal.expectsParent('location', syncId, parentChangeId)) {
        await (database.update(database.locations)
              ..where((row) => row.id.equals(existing.id)))
            .write(LocationsCompanion(
                name: Value(_string(payload, 'name')),
                colorArgb: Value(_integer(payload, 'colorArgb')),
                sortOrder: Value(_integer(payload, 'sortOrder')),
                isArchived: Value(_boolean(payload, 'isArchived'))));
        return null;
      }
      return _IncomingConflict('Location changed independently on this device',
          candidates: [
            {
              'side': 'local',
              'entityId': syncId,
              'payload': {
                'name': existing.name,
                'colorArgb': existing.colorArgb,
                'sortOrder': existing.sortOrder,
                'isArchived': existing.isArchived,
              }
            },
            {'side': 'remote', 'entityId': syncId, 'payload': payload},
          ]);
    }
    if (deleted) return null;
    if (parentChangeId != null) {
      return const _IncomingConflict('Location causal parent is missing');
    }
    final name = _string(payload, 'name');
    final duplicateName = await (database.select(database.locations)
          ..where((row) => row.name.equals(name)))
        .getSingleOrNull();
    if (duplicateName != null) {
      return _IncomingConflict(
          'A location with this name already exists; review its identity',
          candidates: [
            {
              'side': 'local',
              'entityId': duplicateName.syncId,
              'payload': {
                'name': duplicateName.name,
                'colorArgb': duplicateName.colorArgb,
                'sortOrder': duplicateName.sortOrder,
                'isArchived': duplicateName.isArchived,
              }
            },
            {'side': 'remote', 'entityId': syncId, 'payload': payload},
          ]);
    }
    await database.into(database.locations).insert(LocationsCompanion.insert(
        syncId: Value(syncId),
        name: name,
        colorArgb: _integer(payload, 'colorArgb'),
        sortOrder: _integer(payload, 'sortOrder'),
        isArchived: Value(_boolean(payload, 'isArchived'))));
    return null;
  }

  Future<_IncomingConflict?> _applyZone(
      String syncId,
      Map<String, dynamic> payload,
      bool deleted,
      String? parentChangeId) async {
    final existing = await _zoneBySyncId(syncId);
    if (existing != null) {
      final localLinks = await (database.select(database.locationZones)
            ..where((row) => row.zoneId.equals(existing.id)))
          .get();
      final localLocationSyncIds = <String>[
        for (final link in localLinks)
          await database.requireSyncIdFor('locations', link.locationId),
      ];
      if (deleted) {
        if (!await journal.expectsParent('zone', syncId, parentChangeId)) {
          return _IncomingConflict(
              'Zone changed after the remote deletion was based',
              candidates: [
                {
                  'side': 'local',
                  'entityId': syncId,
                  'payload': {
                    'code': existing.code,
                    'name': existing.name,
                    'kind': existing.kind,
                    'colorArgb': existing.colorArgb,
                    'sortOrder': existing.sortOrder,
                    'isArchived': existing.isArchived,
                    'locationIds': localLocationSyncIds,
                  }
                },
                {
                  'side': 'remote',
                  'entityId': syncId,
                  'payload': payload,
                  'deleted': true,
                },
              ]);
        }
        final readings = await (database.select(database.meterReadings)
              ..where((row) => row.zoneId.equals(existing.code)))
            .get();
        final rates = await (database.select(database.tariffRates)
              ..where((row) => row.zoneId.equals(existing.code)))
            .get();
        if (readings.isNotEmpty || rates.isNotEmpty) {
          return _IncomingConflict(
              'Deleted zone still has local readings or tariff rates',
              candidates: [
                {
                  'side': 'local',
                  'entityId': syncId,
                  'payload': {
                    'code': existing.code,
                    'name': existing.name,
                    'kind': existing.kind,
                    'colorArgb': existing.colorArgb,
                    'sortOrder': existing.sortOrder,
                    'isArchived': existing.isArchived,
                    'locationIds': localLocationSyncIds,
                  }
                },
                {
                  'side': 'remote',
                  'entityId': syncId,
                  'payload': payload,
                  'deleted': true,
                },
              ]);
        }
        await (database.delete(database.locationZones)
              ..where((row) => row.zoneId.equals(existing.id)))
            .go();
        await (database.delete(database.tariffZones)
              ..where((row) => row.id.equals(existing.id)))
            .go();
        return null;
      }
      final remoteLocations = payload['locationIds'];
      if (remoteLocations is! List<dynamic>) {
        return const _IncomingConflict('Invalid zone links');
      }
      final remoteLinkIds = <int>[];
      for (final locationSyncId in remoteLocations) {
        if (locationSyncId is! String) {
          return const _IncomingConflict('Invalid zone link identity');
        }
        final canonicalLocationId =
            await journal.canonicalEntityId('location', locationSyncId);
        final location = await _locationBySyncId(canonicalLocationId);
        if (location == null) {
          return const _IncomingConflict('Zone references a missing location');
        }
        remoteLinkIds.add(location.id);
      }
      if (_zoneMatches(existing, payload) &&
          _sameSet(localLinks.map((link) => link.locationId), remoteLinkIds)) {
        return null;
      }
      if (await journal.expectsParent('zone', syncId, parentChangeId)) {
        await (database.update(database.tariffZones)
              ..where((row) => row.id.equals(existing.id)))
            .write(TariffZonesCompanion(
                name: Value(_string(payload, 'name')),
                kind: Value(_string(payload, 'kind')),
                colorArgb: Value(_integer(payload, 'colorArgb')),
                sortOrder: Value(_integer(payload, 'sortOrder')),
                isArchived: Value(_boolean(payload, 'isArchived'))));
        await (database.delete(database.locationZones)
              ..where((row) => row.zoneId.equals(existing.id)))
            .go();
        if (remoteLinkIds.isNotEmpty) {
          await database
              .batch((batch) => batch.insertAll(database.locationZones, [
                    for (final locationId in remoteLinkIds)
                      LocationZonesCompanion.insert(
                          locationId: locationId, zoneId: existing.id)
                  ]));
        }
        return null;
      }
      return _IncomingConflict(
          'Zone fields or location links changed independently',
          candidates: [
            {
              'side': 'local',
              'entityId': syncId,
              'payload': {
                'code': existing.code,
                'name': existing.name,
                'kind': existing.kind,
                'colorArgb': existing.colorArgb,
                'sortOrder': existing.sortOrder,
                'isArchived': existing.isArchived,
                'locationIds': localLocationSyncIds,
              }
            },
            {'side': 'remote', 'entityId': syncId, 'payload': payload},
          ]);
    }
    if (deleted) return null;
    if (parentChangeId != null) {
      return const _IncomingConflict('Zone causal parent is missing');
    }
    final code = _string(payload, 'code');
    final codeCollision = await (database.select(database.tariffZones)
          ..where((row) => row.code.equals(code)))
        .getSingleOrNull();
    if (codeCollision != null) {
      final links = await (database.select(database.locationZones)
            ..where((row) => row.zoneId.equals(codeCollision.id)))
          .get();
      final locationIds = <String>[
        for (final link in links)
          await database.requireSyncIdFor('locations', link.locationId),
      ]..sort();
      return _IncomingConflict('Zone code already exists; review its identity',
          candidates: [
            {
              'side': 'local',
              'entityId': codeCollision.syncId,
              'payload': {
                'code': codeCollision.code,
                'name': codeCollision.name,
                'kind': codeCollision.kind,
                'colorArgb': codeCollision.colorArgb,
                'sortOrder': codeCollision.sortOrder,
                'isArchived': codeCollision.isArchived,
                'locationIds': locationIds,
              }
            },
            {'side': 'remote', 'entityId': syncId, 'payload': payload},
          ]);
    }
    final locationSyncIds = payload['locationIds'];
    if (locationSyncIds is! List<dynamic>) {
      return const _IncomingConflict('Invalid zone links');
    }
    final localLocationIds = <int>[];
    for (final locationSyncId in locationSyncIds) {
      if (locationSyncId is! String) {
        return const _IncomingConflict('Invalid zone link identity');
      }
      final canonicalLocationId =
          await journal.canonicalEntityId('location', locationSyncId);
      final location = await _locationBySyncId(canonicalLocationId);
      if (location == null) {
        return const _IncomingConflict('Zone references a missing location');
      }
      localLocationIds.add(location.id);
    }
    final zoneId = await database.into(database.tariffZones).insert(
        TariffZonesCompanion.insert(
            syncId: Value(syncId),
            code: code,
            name: _string(payload, 'name'),
            kind: _string(payload, 'kind'),
            colorArgb: _integer(payload, 'colorArgb'),
            sortOrder: _integer(payload, 'sortOrder'),
            isArchived: Value(_boolean(payload, 'isArchived'))));
    if (localLocationIds.isNotEmpty) {
      await database.batch((batch) => batch.insertAll(database.locationZones, [
            for (final locationId in localLocationIds)
              LocationZonesCompanion.insert(
                  locationId: locationId, zoneId: zoneId)
          ]));
    }
    return null;
  }

  Future<_IncomingConflict?> _applyRate(
      String syncId,
      Map<String, dynamic> payload,
      bool deleted,
      String? parentChangeId) async {
    final existing = await _rateBySyncId(syncId);
    if (existing != null) {
      if (deleted) {
        if (!await journal.expectsParent('rate', syncId, parentChangeId)) {
          return _IncomingConflict(
              'Tariff rate changed after the remote deletion was based',
              candidates: [
                {
                  'side': 'local',
                  'entityId': syncId,
                  'payload': {
                    'zoneId': await database.requireZoneSyncId(existing.zoneId),
                    'priceMinorUnits': existing.priceMinorUnits,
                    'currencyCode': existing.currencyCode,
                    'validFrom': existing.validFrom.toIso8601String(),
                    'validTo': existing.validTo?.toIso8601String(),
                  }
                },
                {
                  'side': 'remote',
                  'entityId': syncId,
                  'payload': payload,
                  'deleted': true,
                },
              ]);
        }
        await (database.delete(database.tariffRates)
              ..where((row) => row.id.equals(existing.id)))
            .go();
        return null;
      }
      if (_rateMatches(existing, payload)) return null;
      if (await journal.expectsParent('rate', syncId, parentChangeId)) {
        final validFrom = _date(payload, 'validFrom');
        final validTo = _nullableDate(payload, 'validTo');
        final siblings = await (database.select(database.tariffRates)
              ..where((row) => row.zoneId.equals(existing.zoneId)))
            .get();
        if (siblings.any((rate) =>
            rate.id != existing.id &&
            _periodsOverlap(
                validFrom, validTo, rate.validFrom, rate.validTo))) {
          return const _IncomingConflict(
              'Updated tariff period overlaps a different local rate');
        }
        await (database.update(database.tariffRates)
              ..where((row) => row.id.equals(existing.id)))
            .write(TariffRatesCompanion(
                priceMinorUnits: Value(_integer(payload, 'priceMinorUnits')),
                currencyCode: Value(_string(payload, 'currencyCode')),
                validFrom: Value(validFrom),
                validTo: Value(validTo)));
        return null;
      }
      return _IncomingConflict(
          'Tariff rate changed independently on this device',
          candidates: [
            {
              'side': 'local',
              'entityId': syncId,
              'payload': {
                'zoneId': await database.requireZoneSyncId(existing.zoneId),
                'priceMinorUnits': existing.priceMinorUnits,
                'currencyCode': existing.currencyCode,
                'validFrom': existing.validFrom.toIso8601String(),
                'validTo': existing.validTo?.toIso8601String(),
              }
            },
            {'side': 'remote', 'entityId': syncId, 'payload': payload},
          ]);
    }
    if (deleted) return null;
    if (parentChangeId != null) {
      return const _IncomingConflict('Tariff rate causal parent is missing');
    }
    final rawZoneSyncId = _string(payload, 'zoneId');
    final zoneSyncId = await journal.canonicalEntityId('zone', rawZoneSyncId);
    final zone = await _zoneBySyncId(zoneSyncId);
    if (zone == null) {
      return const _IncomingConflict('Tariff rate references a missing zone');
    }
    final validFrom = _date(payload, 'validFrom');
    final validTo = _nullableDate(payload, 'validTo');
    final rates = await (database.select(database.tariffRates)
          ..where((rate) => rate.zoneId.equals(zone.code)))
        .get();
    final overlappingRates = rates
        .where((rate) =>
            _periodsOverlap(validFrom, validTo, rate.validFrom, rate.validTo))
        .toList();
    if (overlappingRates.isNotEmpty) {
      if (overlappingRates.length == 1) {
        final existingRate = overlappingRates.single;
        return _IncomingConflict(
            existingRate.validFrom == validFrom
                ? 'A tariff already starts at this date'
                : 'Tariff period overlaps a local rate',
            candidates: [
              {
                'side': 'local',
                'entityId': existingRate.syncId,
                'payload': await _rateSnapshot(existingRate),
              },
              {'side': 'remote', 'entityId': syncId, 'payload': payload},
            ]);
      }
      return const _IncomingConflict(
          'Tariff period overlaps multiple local rates');
    }
    await database.into(database.tariffRates).insert(
        TariffRatesCompanion.insert(
            syncId: Value(syncId),
            zoneId: zone.code,
            priceMinorUnits: _integer(payload, 'priceMinorUnits'),
            currencyCode: _string(payload, 'currencyCode'),
            validFrom: validFrom,
            validTo: Value(validTo)));
    return null;
  }

  Future<_IncomingConflict?> _applyReading(
      String syncId,
      Map<String, dynamic> payload,
      bool deleted,
      String? parentChangeId) async {
    final existing = await _readingBySyncId(syncId);
    if (existing != null) {
      if (!deleted && _readingMatches(existing, payload)) return null;
      if (await journal.expectsParent('reading', syncId, parentChangeId)) {
        if (deleted) {
          await (database.delete(database.meterReadings)
                ..where((row) => row.id.equals(existing.id)))
              .go();
          return null;
        }
        final targetDate = _date(payload, 'readingDate');
        final duplicateSlot = await (database.select(database.meterReadings)
              ..where((row) =>
                  row.id.isNotValue(existing.id) &
                  row.locationId.equals(existing.locationId) &
                  row.zoneId.equals(existing.zoneId) &
                  row.readingDate.equals(targetDate)))
            .getSingleOrNull();
        if (duplicateSlot != null) {
          return const _IncomingConflict(
              'Updated reading collides with another date slot');
        }
        await (database.update(database.meterReadings)
              ..where((row) => row.id.equals(existing.id)))
            .write(MeterReadingsCompanion(
                readingDate: Value(targetDate),
                valueKwh: Value(_number(payload, 'valueKwh')),
                note: Value(_nullableString(payload, 'note')),
                createdAt: Value(_date(payload, 'createdAt')),
                updatedAt: Value(_date(payload, 'updatedAt')),
                isReset: Value(_boolean(payload, 'isReset'))));
        return null;
      }
      final localCandidate = await _readingCandidate(existing);
      return _IncomingConflict(
          deleted
              ? 'Remote deletion conflicts with a local reading'
              : 'Reading changed independently on this device',
          candidates: [
            {
              'side': 'local',
              'entityId': syncId,
              'payload': localCandidate,
            },
            {
              'side': 'remote',
              'entityId': syncId,
              'payload': deleted ? {'deleted': true} : payload,
              'deleted': deleted,
            }
          ]);
    }
    if (deleted) return null;
    if (parentChangeId != null) {
      return const _IncomingConflict('Reading causal parent is missing');
    }
    final rawLocationSyncId = _string(payload, 'locationId');
    final rawZoneSyncId = _string(payload, 'zoneId');
    final locationSyncId =
        await journal.canonicalEntityId('location', rawLocationSyncId);
    final zoneSyncId = await journal.canonicalEntityId('zone', rawZoneSyncId);
    final location = await _locationBySyncId(locationSyncId);
    if (location == null) {
      return const _IncomingConflict('Reading references a missing location');
    }
    final zone = await _zoneBySyncId(zoneSyncId);
    if (zone == null) {
      return const _IncomingConflict('Reading references a missing zone');
    }
    final link = await (database.select(database.locationZones)
          ..where((row) =>
              row.locationId.equals(location.id) & row.zoneId.equals(zone.id)))
        .getSingleOrNull();
    if (link == null) {
      return const _IncomingConflict(
          'Reading location is not linked to its zone');
    }
    final readingDate = _date(payload, 'readingDate');
    final sameSlot = await (database.select(database.meterReadings)
          ..where((row) =>
              row.locationId.equals(location.id) &
              row.zoneId.equals(zone.code) &
              row.readingDate.equals(readingDate)))
        .getSingleOrNull();
    if (sameSlot != null) {
      return _IncomingConflict(
          'A reading already exists for this location, zone and date',
          candidates: [
            {
              'side': 'local',
              'entityId': sameSlot.syncId,
              'payload': {
                'locationId': locationSyncId,
                'zoneId': zoneSyncId,
                'readingDate': sameSlot.readingDate.toIso8601String(),
                'valueKwh': sameSlot.valueKwh,
                'note': sameSlot.note,
                'createdAt': sameSlot.createdAt.toIso8601String(),
                'updatedAt': sameSlot.updatedAt.toIso8601String(),
                'isReset': sameSlot.isReset,
              }
            },
            {
              'side': 'remote',
              'payload': payload,
            }
          ]);
    }
    await database.into(database.meterReadings).insert(
        MeterReadingsCompanion.insert(
            syncId: Value(syncId),
            locationId: Value(location.id),
            zoneId: zone.code,
            readingDate: readingDate,
            valueKwh: _number(payload, 'valueKwh'),
            note: Value(_nullableString(payload, 'note')),
            createdAt: _date(payload, 'createdAt'),
            updatedAt: _date(payload, 'updatedAt'),
            isReset: Value(_boolean(payload, 'isReset'))));
    return null;
  }

  Future<Location?> _locationBySyncId(String id) =>
      (database.select(database.locations)
            ..where((row) => row.syncId.equals(id)))
          .getSingleOrNull();

  Future<TariffZone?> _zoneBySyncId(String id) =>
      (database.select(database.tariffZones)
            ..where((row) => row.syncId.equals(id)))
          .getSingleOrNull();

  Future<TariffRate?> _rateBySyncId(String id) =>
      (database.select(database.tariffRates)
            ..where((row) => row.syncId.equals(id)))
          .getSingleOrNull();

  Future<MeterReading?> _readingBySyncId(String id) =>
      (database.select(database.meterReadings)
            ..where((row) => row.syncId.equals(id)))
          .getSingleOrNull();

  Future<Map<String, Object?>> _readingCandidate(MeterReading row) async => {
        'locationId':
            await database.requireSyncIdFor('locations', row.locationId),
        'zoneId': await database.requireZoneSyncId(row.zoneId),
        'readingDate': row.readingDate.toIso8601String(),
        'valueKwh': row.valueKwh,
        'note': row.note,
        'createdAt': row.createdAt.toIso8601String(),
        'updatedAt': row.updatedAt.toIso8601String(),
        'isReset': row.isReset,
      };

  Future<Map<String, Object?>> _rateSnapshot(TariffRate row) async => {
        'zoneId': await database.requireZoneSyncId(row.zoneId),
        'priceMinorUnits': row.priceMinorUnits,
        'currencyCode': row.currencyCode,
        'validFrom': row.validFrom.toIso8601String(),
        'validTo': row.validTo?.toIso8601String(),
      };

  bool _locationMatches(Location row, Map<String, dynamic> payload) =>
      row.name == payload['name'] &&
      row.colorArgb == payload['colorArgb'] &&
      row.sortOrder == payload['sortOrder'] &&
      row.isArchived == payload['isArchived'];

  bool _zoneMatches(TariffZone row, Map<String, dynamic> payload) =>
      row.code == payload['code'] &&
      row.name == payload['name'] &&
      row.kind == payload['kind'] &&
      row.colorArgb == payload['colorArgb'] &&
      row.sortOrder == payload['sortOrder'] &&
      row.isArchived == payload['isArchived'];

  bool _rateMatches(TariffRate row, Map<String, dynamic> payload) =>
      row.priceMinorUnits == payload['priceMinorUnits'] &&
      row.currencyCode == payload['currencyCode'] &&
      row.validFrom == _date(payload, 'validFrom') &&
      row.validTo == _nullableDate(payload, 'validTo');

  bool _readingMatches(MeterReading row, Map<String, dynamic> payload) =>
      row.valueKwh == _number(payload, 'valueKwh') &&
      row.note == _nullableString(payload, 'note') &&
      row.readingDate == _date(payload, 'readingDate') &&
      row.createdAt == _date(payload, 'createdAt') &&
      row.updatedAt == _date(payload, 'updatedAt') &&
      row.isReset == _boolean(payload, 'isReset');

  bool _sameSet(Iterable<int> left, Iterable<int> right) =>
      left.toSet().length == right.toSet().length &&
      left.toSet().containsAll(right);

  bool _periodsOverlap(DateTime firstFrom, DateTime? firstTo,
      DateTime secondFrom, DateTime? secondTo) {
    final firstEndsAfterSecondStarts =
        firstTo == null || firstTo.isAfter(secondFrom);
    final secondEndsAfterFirstStarts =
        secondTo == null || secondTo.isAfter(firstFrom);
    return firstEndsAfterSecondStarts && secondEndsAfterFirstStarts;
  }

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid $key in sync payload');
    }
    return value;
  }

  String? _nullableString(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('Invalid $key in sync payload');
    return value;
  }

  int _integer(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! int) throw FormatException('Invalid $key in sync payload');
    return value;
  }

  double _number(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! num || !value.isFinite) {
      throw FormatException('Invalid $key in sync payload');
    }
    return value.toDouble();
  }

  bool _boolean(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! bool) throw FormatException('Invalid $key in sync payload');
    return value;
  }

  DateTime _date(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! String) throw FormatException('Invalid $key in sync payload');
    return DateTime.parse(value);
  }

  DateTime? _nullableDate(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('Invalid $key in sync payload');
    return DateTime.parse(value);
  }
}

class DriveVaultOption {
  const DriveVaultOption({required this.fileId, required this.vaultId});

  final String fileId;
  final String vaultId;
}

class DriveSyncRunResult {
  const DriveSyncRunResult({
    required this.uploaded,
    required this.applied,
    required this.duplicates,
    required this.conflicts,
    required this.otherVault,
  });

  final int uploaded;
  final int applied;
  final int duplicates;
  final int conflicts;
  final int otherVault;
}

/// Coordinates one account's vault selection, local key cache and sync run.
class GoogleDriveSyncSession {
  GoogleDriveSyncSession({
    required this.database,
    required this.credentials,
    required this.keyCache,
    required this.store,
  });

  final ElectricityDatabase database;
  final SecureGoogleCredentialStore credentials;
  final SecureVaultKeyCache keyCache;
  final EncryptedChangeStore store;

  Future<bool> get isConnected async => await credentials.read() != null;

  Future<String> _accountSubject() async {
    final credential = await credentials.read();
    if (credential == null) throw StateError('Connect a Google account first');
    return credential.accountSubject;
  }

  Future<bool> get hasUnlockedVault async =>
      await keyCache.read(await _accountSubject()) != null;

  Future<List<DriveVaultOption>> discoverVaults() async => [
        for (final vault
            in await DriveVaultProvisioner(store: store, keyCache: keyCache)
                .discover())
          DriveVaultOption(fileId: vault.fileId, vaultId: vault.header.vaultId),
      ];

  Future<DriveVaultOption> createVault(String recoverySecret) async {
    final created =
        await DriveVaultProvisioner(store: store, keyCache: keyCache)
            .create(recoverySecret, await _accountSubject());
    return DriveVaultOption(
        fileId: created.fileId, vaultId: created.header.vaultId);
  }

  Future<void> unlockVault(String fileId, String recoverySecret) async {
    await DriveVaultProvisioner(store: store, keyCache: keyCache).unlock(
        fileId: fileId,
        recoverySecret: recoverySecret,
        accountSubject: await _accountSubject());
  }

  Future<DriveSyncRunResult> syncNow() async {
    final vault = await keyCache.read(await _accountSubject());
    if (vault == null) throw StateError('Create or unlock a vault first');
    final journal = DriftSyncJournal(database);
    await journal.bootstrapExistingEntities();
    final incoming = await GoogleDriveIncomingApplier(
            database: database, journal: journal, store: store, vault: vault)
        .applyAvailable();
    final uploaded = await GoogleDriveOutboxUploader(
            journal: journal, store: store, vault: vault)
        .uploadPending();
    return DriveSyncRunResult(
        uploaded: uploaded,
        applied: incoming.applied,
        duplicates: incoming.duplicates,
        conflicts: incoming.conflicts,
        otherVault: incoming.otherVault);
  }

  Future<void> resolveConflict(String changeId, int candidateIndex) async {
    final vault = await keyCache.read(await _accountSubject());
    if (vault == null) throw StateError('Create or unlock a vault first');
    await GoogleDriveIncomingApplier(
            database: database,
            journal: DriftSyncJournal(database),
            store: store,
            vault: vault)
        .resolveConflict(changeId, candidateIndex);
  }

  Future<void> forgetVaultKey() => keyCache.delete();
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
  Future<void> save(domain.MeterReading reading) =>
      database.transaction(() async {
        final syncId = await database.syncIdFor('meter_readings', reading.id);
        final rowId = await database
            .into(database.meterReadings)
            .insertOnConflictUpdate(MeterReadingsCompanion.insert(
                id: _idValue(reading.id),
                syncId: syncId,
                locationId: Value(reading.locationId),
                zoneId: reading.zoneId,
                readingDate: reading.readingDate,
                valueKwh: reading.valueKwh.value,
                note: Value(reading.note),
                createdAt: reading.createdAt ?? DateTime.now(),
                updatedAt: reading.updatedAt ?? DateTime.now(),
                isReset: Value(reading.isReset)));
        final id = reading.id > 0 ? reading.id : rowId;
        final saved = await (database.select(database.meterReadings)
              ..where((row) => row.id.equals(id)))
            .getSingle();
        final locationSyncId =
            await database.requireSyncIdFor('locations', saved.locationId);
        final zoneSyncId = await database.requireZoneSyncId(saved.zoneId);
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'reading',
            entityId: saved.syncId!,
            payload: jsonEncode({
              'locationId': locationSyncId,
              'zoneId': zoneSyncId,
              'readingDate': saved.readingDate.toIso8601String(),
              'valueKwh': saved.valueKwh,
              'note': saved.note,
              'createdAt': saved.createdAt.toIso8601String(),
              'updatedAt': saved.updatedAt.toIso8601String(),
              'isReset': saved.isReset,
            }));
      });
  @override
  Future<void> delete(int id) => database.transaction(() async {
        final existing = await (database.select(database.meterReadings)
              ..where((row) => row.id.equals(id)))
            .getSingleOrNull();
        if (existing == null) return;
        final locationSyncId =
            await database.requireSyncIdFor('locations', existing.locationId);
        final zoneSyncId = await database.requireZoneSyncId(existing.zoneId);
        await (database.delete(database.meterReadings)
              ..where((row) => row.id.equals(id)))
            .go();
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'reading',
            entityId: existing.syncId!,
            payload: jsonEncode({
              'locationId': locationSyncId,
              'zoneId': zoneSyncId,
              'readingDate': existing.readingDate.toIso8601String(),
            }),
            isDeleted: true);
      });
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
        final syncId = await database.syncIdFor('tariff_zones', zone.id);
        final zoneId = await database
            .into(database.tariffZones)
            .insertOnConflictUpdate(TariffZonesCompanion.insert(
                id: _idValue(zone.id),
                syncId: syncId,
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
        final saved = await (database.select(database.tariffZones)
              ..where((row) => row.id.equals(id)))
            .getSingle();
        final locationSyncIds = <String>[
          for (final locationId in zone.locationIds)
            await database.requireSyncIdFor('locations', locationId),
        ];
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'zone',
            entityId: saved.syncId!,
            payload: jsonEncode({
              'code': saved.code,
              'name': saved.name,
              'kind': saved.kind,
              'colorArgb': saved.colorArgb,
              'sortOrder': saved.sortOrder,
              'isArchived': saved.isArchived,
              'locationIds': locationSyncIds,
            }));
      });
  @override
  Future<void> delete(int id) => database.transaction(() async {
        final existing = await (database.select(database.tariffZones)
              ..where((row) => row.id.equals(id)))
            .getSingleOrNull();
        if (existing == null) return;
        final links = await (database.select(database.locationZones)
              ..where((row) => row.zoneId.equals(id)))
            .get();
        final locationSyncIds = <String>[
          for (final link in links)
            await database.requireSyncIdFor('locations', link.locationId),
        ];
        await (database.delete(database.locationZones)
              ..where((row) => row.zoneId.equals(id)))
            .go();
        await (database.delete(database.tariffZones)
              ..where((row) => row.id.equals(id)))
            .go();
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'zone',
            entityId: existing.syncId!,
            payload: jsonEncode({
              'code': existing.code,
              'locationIds': locationSyncIds,
            }),
            isDeleted: true);
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
  Future<void> save(domain.Location location) => database.transaction(() async {
        final syncId = await database.syncIdFor('locations', location.id);
        final insertedId = await database
            .into(database.locations)
            .insertOnConflictUpdate(LocationsCompanion.insert(
                id: _idValue(location.id),
                syncId: syncId,
                name: location.name,
                colorArgb: location.colorArgb,
                sortOrder: location.sortOrder,
                isArchived: Value(location.isArchived)));
        final id = location.id > 0 ? location.id : insertedId;
        final saved = await (database.select(database.locations)
              ..where((row) => row.id.equals(id)))
            .getSingle();
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'location',
            entityId: saved.syncId!,
            payload: jsonEncode({
              'name': saved.name,
              'colorArgb': saved.colorArgb,
              'sortOrder': saved.sortOrder,
              'isArchived': saved.isArchived,
            }));
      });
  @override
  Future<void> delete(int id) => database.transaction(() async {
        final existing = await (database.select(database.locations)
              ..where((row) => row.id.equals(id)))
            .getSingleOrNull();
        if (existing == null) return;
        final links = await (database.select(database.locationZones)
              ..where((row) => row.locationId.equals(id)))
            .get();
        if (links.isNotEmpty) {
          throw StateError('Unlink zones before deleting a location');
        }
        await (database.delete(database.locations)
              ..where((row) => row.id.equals(id)))
            .go();
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'location',
            entityId: existing.syncId!,
            payload: jsonEncode({'name': existing.name}),
            isDeleted: true);
      });
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
  Future<void> save(domain.TariffRate rate) => database.transaction(() async {
        final syncId = await database.syncIdFor('tariff_rates', rate.id);
        final insertedId = await database
            .into(database.tariffRates)
            .insertOnConflictUpdate(TariffRatesCompanion.insert(
                id: _idValue(rate.id),
                syncId: syncId,
                zoneId: rate.zoneId,
                priceMinorUnits: rate.pricePerKwh.minorUnits,
                currencyCode: rate.pricePerKwh.currencyCode,
                validFrom: rate.validFrom,
                validTo: Value(rate.validTo)));
        final id = rate.id > 0 ? rate.id : insertedId;
        final saved = await (database.select(database.tariffRates)
              ..where((row) => row.id.equals(id)))
            .getSingle();
        final zoneSyncId = await database.requireZoneSyncId(saved.zoneId);
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'rate',
            entityId: saved.syncId!,
            payload: jsonEncode({
              'zoneId': zoneSyncId,
              'priceMinorUnits': saved.priceMinorUnits,
              'currencyCode': saved.currencyCode,
              'validFrom': saved.validFrom.toIso8601String(),
              'validTo': saved.validTo?.toIso8601String(),
            }));
      });
  @override
  Future<void> delete(int id) => database.transaction(() async {
        final existing = await (database.select(database.tariffRates)
              ..where((row) => row.id.equals(id)))
            .getSingleOrNull();
        if (existing == null) return;
        final zoneSyncId = await database.requireZoneSyncId(existing.zoneId);
        await (database.delete(database.tariffRates)
              ..where((row) => row.id.equals(id)))
            .go();
        await DriftSyncJournal(database).enqueue(
            changeId: _newSyncId(),
            entityKind: 'rate',
            entityId: existing.syncId!,
            payload: jsonEncode({'zoneId': zoneSyncId}),
            isDeleted: true);
      });
  domain.TariffRate _toDomain(TariffRate row) => domain.TariffRate(
      row.id,
      row.zoneId,
      domain.Money(row.priceMinorUnits, currencyCode: row.currencyCode),
      row.validFrom,
      validTo: row.validTo);
}
