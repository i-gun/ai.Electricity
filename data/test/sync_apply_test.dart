import 'dart:convert';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class IncomingStore implements EncryptedChangeStore {
  final files = <EncryptedDriveFile>[];
  final payloads = <String, Map<String, Object?>>{};
  final headers = <String, VaultHeader>{};

  Future<void> add(SyncVault vault, Map<String, Object?> envelope) async {
    final changeId = envelope['changeId'] as String;
    final fileId = 'file-${files.length}';
    files.add(EncryptedDriveFile(fileId, 'electricity-v1-$fileId'));
    payloads[fileId] =
        await vault.encrypt(changeId, utf8.encode(jsonEncode(envelope)));
  }

  @override
  Future<List<EncryptedDriveFile>> listChanges() async => files;

  @override
  Future<Map<String, Object?>> readEncrypted(String fileId) async =>
      payloads[fileId]!;

  @override
  Future<String> publish(
          SyncVault vault, String changeId, List<int> plaintext) async =>
      throw UnimplementedError();

  @override
  Future<List<EncryptedDriveFile>> listVaultHeaders() async => [
        for (final entry in headers.entries)
          EncryptedDriveFile(entry.key, 'electricity-vault-v1-${entry.key}'),
      ];

  @override
  Future<VaultHeader> readVaultHeader(String fileId) async => headers[fileId]!;

  @override
  Future<String> publishVaultHeader(VaultHeader header) async {
    final fileId = 'vault-${headers.length}';
    headers[fileId] = header;
    return fileId;
  }
}

Map<String, Object?> envelope(
        String id, String kind, String entityId, Map<String, Object?> payload,
        {bool deleted = false, String? parentChangeId}) =>
    {
      'schemaVersion': 1,
      'changeId': id,
      'parentChangeId': parentChangeId,
      'entityKind': kind,
      'entityId': entityId,
      'isDeleted': deleted,
      'payload': payload,
    };

void main() {
  test('applies safe records in dependency order without outgoing echoes',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final created =
        await SyncVault.create('a sufficiently long recovery secret');
    final store = IncomingStore();
    final home = (await database.select(database.locations).get()).single;
    final homeSyncId = home.syncId!;
    final cabinSyncId = 'remote-cabin-0001';
    final zoneSyncId = 'remote-zone-0001';
    final rateSyncId = 'remote-rate-0001';
    final readingSyncId = 'remote-reading-0001';

    await store.add(
        created.vault,
        envelope('reading-change-0001', 'reading', readingSyncId, {
          'locationId': cabinSyncId,
          'zoneId': zoneSyncId,
          'readingDate': DateTime(2026, 9, 29).toIso8601String(),
          'valueKwh': 125.5,
          'note': 'remote',
          'createdAt': DateTime(2026, 9, 29).toIso8601String(),
          'updatedAt': DateTime(2026, 9, 29).toIso8601String(),
          'isReset': false,
        }));
    await store.add(
        created.vault,
        envelope('rate-change-0001', 'rate', rateSyncId, {
          'zoneId': zoneSyncId,
          'priceMinorUnits': 23,
          'currencyCode': 'EUR',
          'validFrom': DateTime(2026, 1, 1).toIso8601String(),
          'validTo': null,
        }));
    await store.add(
        created.vault,
        envelope('zone-change-0001', 'zone', zoneSyncId, {
          'code': 'remote_custom',
          'name': 'Remote custom',
          'kind': 'custom',
          'colorArgb': 0xff008577,
          'sortOrder': 4,
          'isArchived': false,
          'locationIds': [homeSyncId, cabinSyncId],
        }));
    await store.add(
        created.vault,
        envelope('location-change-0001', 'location', cabinSyncId, {
          'name': 'Cabin',
          'colorArgb': 0xff008577,
          'sortOrder': 1,
          'isArchived': false,
        }));

    final applier = GoogleDriveIncomingApplier(
        database: database,
        journal: journal,
        store: store,
        vault: created.vault);
    final result = await applier.applyAvailable();
    expect(result.applied, 4);
    expect(result.conflicts, 0);
    expect(result.otherVault, 0);
    expect(await journal.pending(), isEmpty);

    final cabin = (await database.select(database.locations).get())
        .singleWhere((location) => location.syncId == cabinSyncId);
    final zone = (await database.select(database.tariffZones).get())
        .singleWhere((item) => item.syncId == zoneSyncId);
    final rate = (await database.select(database.tariffRates).get())
        .singleWhere((item) => item.syncId == rateSyncId);
    final reading = (await database.select(database.meterReadings).get())
        .singleWhere((item) => item.syncId == readingSyncId);
    expect(cabin.name, 'Cabin');
    expect(zone.code, 'remote_custom');
    expect(rate.zoneId, zone.code);
    expect(reading.locationId, cabin.id);
    expect(reading.zoneId, zone.code);
    expect(reading.valueKwh, 125.5);
    final links = await (database.select(database.locationZones)
          ..where((link) => link.zoneId.equals(zone.id)))
        .get();
    expect(links.map((link) => link.locationId).toSet(), {home.id, cabin.id});

    final replay = await applier.applyAvailable();
    expect(replay.applied, 0);
    expect(replay.duplicates, 4);
  });

  test('same-date reading is retained in conflict inbox, never overwritten',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final readings = DriftMeterReadingRepository(database);
    final home = (await database.select(database.locations).get()).single;
    final zone = (await database.select(database.tariffZones).get())
        .firstWhere((item) => item.code == 'total');
    final local =
        domain.MeterReading(0, 'total', DateTime(2026, 9, 29), domain.Kwh(100));
    await readings.save(local);
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final store = IncomingStore();
    await store.add(
        vault,
        envelope(
            'remote-reading-change-001', 'reading', 'remote-reading-identity', {
          'locationId': home.syncId,
          'zoneId': zone.syncId,
          'readingDate': DateTime(2026, 9, 29).toIso8601String(),
          'valueKwh': 130,
          'note': null,
          'createdAt': DateTime(2026, 9, 29).toIso8601String(),
          'updatedAt': DateTime(2026, 9, 29).toIso8601String(),
          'isReset': false,
        }));

    final result = await GoogleDriveIncomingApplier(
            database: database, journal: journal, store: store, vault: vault)
        .applyAvailable();
    expect(result.conflicts, 1);
    expect(
        (await database.select(database.meterReadings).get()).single.valueKwh,
        100);
    final conflicts = await journal.unresolvedConflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.entityId, 'remote-reading-identity');
    expect(conflicts.single.reason, contains('already exists'));
    expect(syncConflictResolutionChoices(conflicts.single), [
      'Keep this device reading identity',
      'Merge into incoming reading identity',
    ]);
    final conflictPayload =
        jsonDecode(conflicts.single.payload) as Map<String, dynamic>;
    expect(conflictPayload['candidates'], hasLength(2));
    expect(syncConflictCandidateSummaries(conflicts.single), [
      'This device: 100.0 kWh on 2026-09-29T00:00:00.000',
      'Incoming: 130 kWh on 2026-09-29T00:00:00.000',
    ]);
    expect((await database.select(database.appliedSyncChanges).get()),
        hasLength(1));
    expect(await journal.pending(), hasLength(1));
  });

  test('same-identity edit conflict stores local and incoming candidates',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final readings = DriftMeterReadingRepository(database);
    final home = (await database.select(database.locations).get()).single;
    final zone = (await database.select(database.tariffZones).get())
        .firstWhere((item) => item.code == 'total');
    await readings.save(domain.MeterReading(
        0, 'total', DateTime(2026, 9, 29), domain.Kwh(100)));
    final local = (await database.select(database.meterReadings).get()).single;
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final store = IncomingStore();
    await store.add(
        vault,
        envelope('remote-edit-change-001', 'reading', local.syncId!, {
          'locationId': home.syncId,
          'zoneId': zone.syncId,
          'readingDate': DateTime(2026, 9, 29).toIso8601String(),
          'valueKwh': 115,
          'note': 'edited elsewhere',
          'createdAt': local.createdAt.toIso8601String(),
          'updatedAt': DateTime(2026, 9, 30).toIso8601String(),
          'isReset': false,
        }));

    final result = await GoogleDriveIncomingApplier(
            database: database, journal: journal, store: store, vault: vault)
        .applyAvailable();
    expect(result.conflicts, 1);
    expect((await readings.find(local.id))!.valueKwh, domain.Kwh(100));
    final conflict = (await journal.unresolvedConflicts()).single;
    expect(syncConflictCandidateSummaries(conflict), [
      'This device: 100.0 kWh on 2026-09-29T00:00:00.000',
      'Incoming: 115 kWh on 2026-09-29T00:00:00.000',
    ]);
    expect(syncConflictResolutionChoices(conflict), [
      'Use this device',
      'Use incoming',
    ]);
  });

  test('resolution supersedes both reading branches and converges a peer',
      () async {
    final firstDb = ElectricityDatabase(NativeDatabase.memory());
    final secondDb = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(firstDb.close);
    addTearDown(secondDb.close);
    const entityId = 'shared-reading-identity';
    const rootChangeId = 'shared-reading-root';
    final date = DateTime(2026, 9, 29);
    final firstHome = (await firstDb.select(firstDb.locations).get()).single;
    final secondHome = (await secondDb.select(secondDb.locations).get()).single;
    Future<void> seed(ElectricityDatabase database, int locationId) async {
      await database.into(database.meterReadings).insert(
          MeterReadingsCompanion.insert(
              syncId: const Value(entityId),
              locationId: Value(locationId),
              zoneId: 'total',
              readingDate: date,
              valueKwh: 100,
              createdAt: date,
              updatedAt: date));
      await DriftSyncJournal(database)
          .setHead('reading', entityId, rootChangeId);
    }

    await seed(firstDb, firstHome.id);
    await seed(secondDb, secondHome.id);
    await DriftMeterReadingRepository(firstDb).save(domain.MeterReading(
        1, 'total', date, domain.Kwh(110),
        locationId: firstHome.id));
    await DriftMeterReadingRepository(secondDb).save(domain.MeterReading(
        1, 'total', date, domain.Kwh(120),
        locationId: secondHome.id));
    final firstEdit = (await DriftSyncJournal(firstDb).pending()).single;
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final remoteEditStore = IncomingStore();
    await remoteEditStore.add(
        vault,
        envelope(firstEdit.id, 'reading', entityId,
            jsonDecode(firstEdit.payload) as Map<String, Object?>,
            parentChangeId: rootChangeId));
    final secondJournal = DriftSyncJournal(secondDb);
    final secondApplier = GoogleDriveIncomingApplier(
        database: secondDb,
        journal: secondJournal,
        store: remoteEditStore,
        vault: vault);
    expect((await secondApplier.applyAvailable()).conflicts, 1);
    final conflict = (await secondJournal.unresolvedConflicts()).single;
    final supersededLocalBranch = (await secondJournal.pending()).single;
    await secondApplier.resolveConflict(conflict.id, 1);
    expect(
        (await secondDb.select(secondDb.meterReadings).get()).single.valueKwh,
        110);
    expect(await secondJournal.unresolvedConflicts(), isEmpty);

    final pendingAfterResolution = await secondJournal.pending();
    expect(pendingAfterResolution, hasLength(1));
    final resolution = pendingAfterResolution.single;
    expect(resolution.payload, contains('_syncResolution'));
    final resolutionStore = IncomingStore();
    await resolutionStore.add(
        vault,
        envelope(resolution.id, 'reading', entityId,
            jsonDecode(resolution.payload) as Map<String, Object?>,
            parentChangeId: resolution.parentChangeId));
    final firstApplier = GoogleDriveIncomingApplier(
        database: firstDb,
        journal: DriftSyncJournal(firstDb),
        store: resolutionStore,
        vault: vault);
    expect((await firstApplier.applyAvailable()).conflicts, 0);
    expect((await firstDb.select(firstDb.meterReadings).get()).single.valueKwh,
        110);
    expect(await DriftSyncJournal(firstDb).unresolvedConflicts(), isEmpty);

    final delayedDelivery = IncomingStore();
    await delayedDelivery.add(
        vault,
        envelope(resolution.id, 'reading', entityId,
            jsonDecode(resolution.payload) as Map<String, Object?>,
            parentChangeId: resolution.parentChangeId));
    await delayedDelivery.add(
        vault,
        envelope(supersededLocalBranch.id, 'reading', entityId,
            jsonDecode(supersededLocalBranch.payload) as Map<String, Object?>,
            parentChangeId: supersededLocalBranch.parentChangeId));
    await delayedDelivery.add(
        vault,
        envelope(rootChangeId, 'reading', entityId, {
          'locationId': firstHome.syncId,
          'zoneId': (await firstDb.select(firstDb.tariffZones).get())
              .firstWhere((zone) => zone.code == 'total')
              .syncId,
          'readingDate': date.toIso8601String(),
          'valueKwh': 100,
          'note': null,
          'createdAt': date.toIso8601String(),
          'updatedAt': date.toIso8601String(),
          'isReset': false,
        }));
    final delayedResult = await GoogleDriveIncomingApplier(
            database: firstDb,
            journal: DriftSyncJournal(firstDb),
            store: delayedDelivery,
            vault: vault)
        .applyAvailable();
    expect(delayedResult.conflicts, 0);
    expect((await firstDb.select(firstDb.meterReadings).get()).single.valueKwh,
        110);
    expect(await DriftSyncJournal(firstDb).unresolvedConflicts(), isEmpty);
  });

  test('different reading IDs merge through an alias on both peers', () async {
    final resolverDb = ElectricityDatabase(NativeDatabase.memory());
    final peerDb = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(resolverDb.close);
    addTearDown(peerDb.close);
    const localId = 'independent-reading-local';
    const remoteId = 'independent-reading-remote';
    const localBranch = 'independent-reading-local-branch';
    const remoteBranch = 'independent-reading-remote-branch';
    final readingDate = DateTime(2026, 9, 29);
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;

    Future<void> insertReading(
        ElectricityDatabase database, String syncId, double value) async {
      final home = (await database.select(database.locations).get()).single;
      await database.into(database.meterReadings).insert(
          MeterReadingsCompanion.insert(
              syncId: Value(syncId),
              locationId: Value(home.id),
              zoneId: 'total',
              readingDate: readingDate,
              valueKwh: value,
              createdAt: readingDate,
              updatedAt: readingDate));
    }

    await insertReading(resolverDb, localId, 100);
    await insertReading(peerDb, remoteId, 130);
    final resolverJournal = DriftSyncJournal(resolverDb);
    final localPayload = {
      'locationId':
          (await resolverDb.select(resolverDb.locations).get()).single.syncId,
      'zoneId': (await resolverDb.select(resolverDb.tariffZones).get())
          .firstWhere((zone) => zone.code == 'total')
          .syncId,
      'readingDate': readingDate.toIso8601String(),
      'valueKwh': 100,
      'note': null,
      'createdAt': readingDate.toIso8601String(),
      'updatedAt': readingDate.toIso8601String(),
      'isReset': false,
    };
    await resolverJournal.enqueue(
        changeId: localBranch,
        entityKind: 'reading',
        entityId: localId,
        payload: jsonEncode(localPayload),
        parentChangeId: null);
    await DriftSyncJournal(peerDb).setHead('reading', remoteId, remoteBranch);

    final remotePayload = {
      ...localPayload,
      'valueKwh': 130,
    };
    final incomingStore = IncomingStore();
    await incomingStore.add(
        vault, envelope(remoteBranch, 'reading', remoteId, remotePayload));
    final resolver = GoogleDriveIncomingApplier(
        database: resolverDb,
        journal: resolverJournal,
        store: incomingStore,
        vault: vault);
    expect((await resolver.applyAvailable()).conflicts, 1);
    final conflict = (await resolverJournal.unresolvedConflicts()).single;
    expect(syncConflictResolutionChoices(conflict), [
      'Keep this device reading identity',
      'Merge into incoming reading identity',
    ]);
    await resolver.resolveConflict(conflict.id, 1);
    expect(
        await resolverJournal.canonicalEntityId('reading', localId), remoteId);
    expect(
        (await resolverDb.select(resolverDb.meterReadings).get()).single.syncId,
        remoteId);
    final resolution = (await resolverJournal.pending()).single;

    final peerStore = IncomingStore();
    await peerStore.add(
        vault,
        envelope(resolution.id, 'reading', remoteId,
            jsonDecode(resolution.payload) as Map<String, Object?>,
            parentChangeId: resolution.parentChangeId));
    final peerJournal = DriftSyncJournal(peerDb);
    expect(
        (await GoogleDriveIncomingApplier(
                    database: peerDb,
                    journal: peerJournal,
                    store: peerStore,
                    vault: vault)
                .applyAvailable())
            .conflicts,
        0);
    expect(await peerJournal.canonicalEntityId('reading', localId), remoteId);
    expect(
        (await peerDb.select(peerDb.meterReadings).get()).single.valueKwh, 130);

    final delayedStore = IncomingStore();
    await delayedStore.add(
        vault, envelope(localBranch, 'reading', localId, localPayload));
    final delayed = await GoogleDriveIncomingApplier(
            database: peerDb,
            journal: peerJournal,
            store: delayedStore,
            vault: vault)
        .applyAvailable();
    expect(delayed.conflicts, 0);
    expect(await peerJournal.unresolvedConflicts(), isEmpty);
    expect(
        (await peerDb.select(peerDb.meterReadings).get()).single.valueKwh, 130);
  });

  test('same-identity delete conflict resolves and propagates tombstone',
      () async {
    final resolverDb = ElectricityDatabase(NativeDatabase.memory());
    final peerDb = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(resolverDb.close);
    addTearDown(peerDb.close);
    const readingId = 'delete-conflict-reading';
    const localBranch = 'delete-conflict-local-branch';
    const deleteBranch = 'delete-conflict-remote-branch';
    const baseBranch = 'delete-conflict-base-branch';
    final date = DateTime(2026, 9, 29);
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;

    Future<void> insertReading(ElectricityDatabase database) async {
      final home = (await database.select(database.locations).get()).single;
      await database.into(database.meterReadings).insert(
          MeterReadingsCompanion.insert(
              syncId: const Value(readingId),
              locationId: Value(home.id),
              zoneId: 'total',
              readingDate: date,
              valueKwh: 100,
              createdAt: date,
              updatedAt: date));
    }

    await insertReading(resolverDb);
    await insertReading(peerDb);
    final resolverJournal = DriftSyncJournal(resolverDb);
    await resolverJournal.enqueue(
        changeId: localBranch,
        entityKind: 'reading',
        entityId: readingId,
        payload: jsonEncode({'valueKwh': 100}),
        parentChangeId: null);
    final peerJournal = DriftSyncJournal(peerDb);
    await peerJournal.setHead('reading', readingId, deleteBranch);

    final store = IncomingStore();
    await store.add(
        vault,
        envelope(deleteBranch, 'reading', readingId,
            {'readingDate': date.toIso8601String()},
            deleted: true, parentChangeId: baseBranch));
    final applier = GoogleDriveIncomingApplier(
        database: resolverDb,
        journal: resolverJournal,
        store: store,
        vault: vault);
    expect((await applier.applyAvailable()).conflicts, 1);
    final conflict = (await resolverJournal.unresolvedConflicts()).single;
    expect(syncConflictResolutionChoices(conflict), [
      'Use this device',
      'Accept incoming deletion',
    ]);
    await applier.resolveConflict(conflict.id, 1);
    expect(await resolverDb.select(resolverDb.meterReadings).get(), isEmpty);
    final resolution = (await resolverJournal.pending()).single;
    expect(resolution.isDeleted, isTrue);

    final resolutionStore = IncomingStore();
    await resolutionStore.add(
        vault,
        envelope(resolution.id, 'reading', readingId,
            jsonDecode(resolution.payload) as Map<String, Object?>,
            deleted: true, parentChangeId: resolution.parentChangeId));
    expect(
        (await GoogleDriveIncomingApplier(
                    database: peerDb,
                    journal: peerJournal,
                    store: resolutionStore,
                    vault: vault)
                .applyAvailable())
            .conflicts,
        0);
    expect(await peerDb.select(peerDb.meterReadings).get(), isEmpty);
    expect(await peerJournal.unresolvedConflicts(), isEmpty);
  });

  test('same-identity location zone and rate conflicts resolve snapshots',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final locations = DriftLocationRepository(database);
    final zones = DriftTariffZoneRepository(database);
    final rates = DriftTariffRateRepository(database);
    await locations.save(const domain.Location(0, 'Cabin'));
    final cabin = (await database.select(database.locations).get())
        .singleWhere((location) => location.name == 'Cabin');
    final home = (await database.select(database.locations).get())
        .singleWhere((location) => location.name == 'Home');
    await zones.save(domain.TariffZone(
        0, domain.ZoneCode('shared'), 'Shared', domain.ZoneKind.custom,
        locationIds: {home.id}));
    await rates
        .save(domain.TariffRate(0, 'shared', domain.Money(17), DateTime(2026)));
    final zone = (await database.select(database.tariffZones).get())
        .singleWhere((item) => item.code == 'shared');
    final rate = (await database.select(database.tariffRates).get()).single;
    final store = IncomingStore();
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    const remoteParent = 'different-branch-parent';

    await store.add(
        vault,
        envelope(
            'remote-location-edit',
            'location',
            cabin.syncId!,
            {
              'name': 'Remote cabin',
              'colorArgb': 0xff123456,
              'sortOrder': 2,
              'isArchived': false,
            },
            parentChangeId: remoteParent));
    await store.add(
        vault,
        envelope(
            'remote-zone-edit',
            'zone',
            zone.syncId!,
            {
              'code': zone.code,
              'name': 'Remote shared',
              'kind': zone.kind,
              'colorArgb': zone.colorArgb,
              'sortOrder': zone.sortOrder,
              'isArchived': zone.isArchived,
              'locationIds': [home.syncId],
            },
            parentChangeId: remoteParent));
    await store.add(
        vault,
        envelope(
            'remote-rate-edit',
            'rate',
            rate.syncId!,
            {
              'zoneId': zone.syncId,
              'priceMinorUnits': 29,
              'currencyCode': 'EUR',
              'validFrom': DateTime(2026).toIso8601String(),
              'validTo': null,
            },
            parentChangeId: remoteParent));

    final applier = GoogleDriveIncomingApplier(
        database: database, journal: journal, store: store, vault: vault);
    expect((await applier.applyAvailable()).conflicts, 3);
    final conflicts = await journal.unresolvedConflicts();
    expect(conflicts.map((conflict) => conflict.entityKind).toSet(),
        {'location', 'zone', 'rate'});
    for (final conflict in conflicts) {
      expect(syncConflictResolutionChoices(conflict), [
        'Use this device',
        'Use incoming',
      ]);
      await applier.resolveConflict(conflict.id, 1);
    }

    expect(
        (await database.select(database.locations).get())
            .singleWhere((item) => item.id == cabin.id)
            .name,
        'Remote cabin');
    expect(
        (await database.select(database.tariffZones).get())
            .singleWhere((item) => item.id == zone.id)
            .name,
        'Remote shared');
    expect(
        (await database.select(database.tariffRates).get())
            .single
            .priceMinorUnits,
        29);
    expect(await journal.unresolvedConflicts(), isEmpty);
  });

  test('overlapping rates with different IDs merge into selected identity',
      () async {
    final resolverDb = ElectricityDatabase(NativeDatabase.memory());
    final peerDb = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(resolverDb.close);
    addTearDown(peerDb.close);
    const localRateId = 'independent-local-rate';
    const remoteRateId = 'independent-remote-rate';
    const localBranch = 'independent-local-rate-branch';
    const remoteBranch = 'independent-remote-rate-branch';
    final validFrom = DateTime(2026, 1, 1);
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    Future<void> insertRate(
        ElectricityDatabase database, String id, int price) async {
      await database.into(database.tariffRates).insert(
          TariffRatesCompanion.insert(
              syncId: Value(id),
              zoneId: 'total',
              priceMinorUnits: price,
              currencyCode: 'EUR',
              validFrom: validFrom));
    }

    await insertRate(resolverDb, localRateId, 17);
    await insertRate(peerDb, remoteRateId, 29);
    final resolverJournal = DriftSyncJournal(resolverDb);
    await resolverJournal.setHead('rate', localRateId, localBranch);
    final peerJournal = DriftSyncJournal(peerDb);
    await peerJournal.setHead('rate', remoteRateId, remoteBranch);
    final remotePayload = {
      'zoneId': (await resolverDb.select(resolverDb.tariffZones).get())
          .firstWhere((zone) => zone.code == 'total')
          .syncId,
      'priceMinorUnits': 29,
      'currencyCode': 'EUR',
      'validFrom': validFrom.toIso8601String(),
      'validTo': null,
    };
    final store = IncomingStore();
    await store.add(
        vault, envelope(remoteBranch, 'rate', remoteRateId, remotePayload));
    final resolver = GoogleDriveIncomingApplier(
        database: resolverDb,
        journal: resolverJournal,
        store: store,
        vault: vault);
    expect((await resolver.applyAvailable()).conflicts, 1);
    final conflict = (await resolverJournal.unresolvedConflicts()).single;
    expect(syncConflictResolutionChoices(conflict), [
      'Keep this device rate identity',
      'Merge into incoming rate identity',
    ]);
    await resolver.resolveConflict(conflict.id, 1);
    expect(await resolverJournal.canonicalEntityId('rate', localRateId),
        remoteRateId);
    expect(
        (await resolverDb.select(resolverDb.tariffRates).get()).single.syncId,
        remoteRateId);
    final resolution = (await resolverJournal.pending()).single;

    final resolutionStore = IncomingStore();
    await resolutionStore.add(
        vault,
        envelope(resolution.id, 'rate', remoteRateId,
            jsonDecode(resolution.payload) as Map<String, Object?>,
            parentChangeId: resolution.parentChangeId));
    expect(
        (await GoogleDriveIncomingApplier(
                    database: peerDb,
                    journal: peerJournal,
                    store: resolutionStore,
                    vault: vault)
                .applyAvailable())
            .conflicts,
        0);
    expect(
        await peerJournal.canonicalEntityId('rate', localRateId), remoteRateId);
    expect(
        (await peerDb.select(peerDb.tariffRates).get()).single.priceMinorUnits,
        29);
  });

  test('legacy Home and default zone IDs can merge into canonical seed IDs',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    await journal.bootstrapExistingEntities();
    final home = (await database.select(database.locations).get()).single;
    final total = (await database.select(database.tariffZones).get())
        .singleWhere((zone) => zone.code == 'total');
    final linksBefore = await database.select(database.locationZones).get();
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;

    final locationStore = IncomingStore();
    await locationStore.add(
        vault,
        envelope('legacy-home-branch', 'location', 'legacy-home-id', {
          'name': 'Home',
          'colorArgb': home.colorArgb,
          'sortOrder': home.sortOrder,
          'isArchived': home.isArchived,
        }));
    final locationApplier = GoogleDriveIncomingApplier(
        database: database,
        journal: journal,
        store: locationStore,
        vault: vault);
    expect((await locationApplier.applyAvailable()).conflicts, 1);
    final locationConflict = (await journal.unresolvedConflicts()).single;
    expect(syncConflictResolutionChoices(locationConflict), [
      'Keep this device location identity',
      'Merge into incoming location identity',
    ]);
    await locationApplier.resolveConflict(locationConflict.id, 1);
    expect(await journal.canonicalEntityId('location', home.syncId!),
        'legacy-home-id');
    expect((await database.select(database.locationZones).get()).length,
        linksBefore.length);

    final zoneStore = IncomingStore();
    await zoneStore.add(
        vault,
        envelope('legacy-total-branch', 'zone', 'legacy-total-id', {
          'code': total.code,
          'name': total.name,
          'kind': total.kind,
          'colorArgb': total.colorArgb,
          'sortOrder': total.sortOrder,
          'isArchived': total.isArchived,
          'locationIds': ['legacy-home-id'],
        }));
    final zoneApplier = GoogleDriveIncomingApplier(
        database: database, journal: journal, store: zoneStore, vault: vault);
    expect((await zoneApplier.applyAvailable()).conflicts, 1);
    final zoneConflict = (await journal.unresolvedConflicts()).single;
    expect(syncConflictResolutionChoices(zoneConflict), [
      'Keep this device zone identity',
      'Merge into incoming zone identity',
    ]);
    await zoneApplier.resolveConflict(zoneConflict.id, 1);
    expect(await journal.canonicalEntityId('zone', total.syncId!),
        'legacy-total-id');
    expect((await database.select(database.locationZones).get()).length,
        linksBefore.length);
    expect(await journal.unresolvedConflicts(), isEmpty);

    final laterDate = DateTime(2026, 10, 1);
    final laterStore = IncomingStore();
    await laterStore.add(
        vault,
        envelope('reading-after-alias-merge', 'reading', 'legacy-reading-id', {
          'locationId': 'legacy-home-id',
          'zoneId': 'legacy-total-id',
          'readingDate': laterDate.toIso8601String(),
          'valueKwh': 150,
          'note': null,
          'createdAt': laterDate.toIso8601String(),
          'updatedAt': laterDate.toIso8601String(),
          'isReset': false,
        }));
    final laterResult = await GoogleDriveIncomingApplier(
            database: database,
            journal: journal,
            store: laterStore,
            vault: vault)
        .applyAvailable();
    expect(laterResult.conflicts, 0);
    final laterReading =
        (await database.select(database.meterReadings).get()).single;
    expect(laterReading.locationId, home.id);
    expect(laterReading.zoneId, total.code);
  });

  test('remote edit applies only when its causal parent is the current head',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final readings = DriftMeterReadingRepository(database);
    final home = (await database.select(database.locations).get()).single;
    final zone = (await database.select(database.tariffZones).get())
        .firstWhere((item) => item.code == 'total');
    await readings.save(domain.MeterReading(
        0, 'total', DateTime(2026, 9, 29), domain.Kwh(100)));
    final local = (await database.select(database.meterReadings).get()).single;
    final parent = (await journal.pending()).single.id;
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final store = IncomingStore();
    await store.add(
        vault,
        envelope(
            'remote-descendant-0001',
            'reading',
            local.syncId!,
            {
              'locationId': home.syncId,
              'zoneId': zone.syncId,
              'readingDate': local.readingDate.toIso8601String(),
              'valueKwh': 110,
              'note': null,
              'createdAt': local.createdAt.toIso8601String(),
              'updatedAt': DateTime(2026, 9, 30).toIso8601String(),
              'isReset': false,
            },
            parentChangeId: parent));

    final applier = GoogleDriveIncomingApplier(
        database: database, journal: journal, store: store, vault: vault);
    final result = await applier.applyAvailable();
    expect(result.applied, 1);
    expect(result.conflicts, 0);
    expect((await readings.find(local.id))!.valueKwh, domain.Kwh(110));
    expect(
        await journal.head('reading', local.syncId!), 'remote-descendant-0001');
    expect((await journal.pending()).single.id, parent);

    final staleStore = IncomingStore();
    await staleStore.add(
        vault,
        envelope(
            'remote-stale-0001',
            'reading',
            local.syncId!,
            {
              'locationId': home.syncId,
              'zoneId': zone.syncId,
              'readingDate': local.readingDate.toIso8601String(),
              'valueKwh': 120,
              'note': null,
              'createdAt': local.createdAt.toIso8601String(),
              'updatedAt': DateTime(2026, 10, 1).toIso8601String(),
              'isReset': false,
            },
            parentChangeId: parent));
    final staleResult = await GoogleDriveIncomingApplier(
            database: database,
            journal: journal,
            store: staleStore,
            vault: vault)
        .applyAvailable();
    expect(staleResult.conflicts, 1);
    expect((await readings.find(local.id))!.valueKwh, domain.Kwh(110));

    final staleReplayStore = IncomingStore();
    await staleReplayStore.add(
        vault,
        envelope(
            'remote-stale-identical-0001',
            'reading',
            local.syncId!,
            {
              'locationId': home.syncId,
              'zoneId': zone.syncId,
              'readingDate': local.readingDate.toIso8601String(),
              'valueKwh': 110,
              'note': null,
              'createdAt': local.createdAt.toIso8601String(),
              'updatedAt': DateTime(2026, 9, 30).toIso8601String(),
              'isReset': false,
            },
            parentChangeId: parent));
    final identicalStale = await GoogleDriveIncomingApplier(
            database: database,
            journal: journal,
            store: staleReplayStore,
            vault: vault)
        .applyAvailable();
    expect(identicalStale.conflicts, 0);
    expect(
        await journal.head('reading', local.syncId!), 'remote-descendant-0001');
  });

  test('wrong vault and invalid authenticated envelope do not apply records',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final firstVault =
        (await SyncVault.create('first long recovery secret')).vault;
    final secondVault =
        (await SyncVault.create('second long recovery secret')).vault;
    final store = IncomingStore();
    await store.add(
        secondVault,
        envelope(
            'other-vault-change-001', 'location', 'remote-location-identity', {
          'name': 'Other',
          'colorArgb': 1,
          'sortOrder': 0,
          'isArchived': false,
        }));
    final result = await GoogleDriveIncomingApplier(
            database: database,
            journal: journal,
            store: store,
            vault: firstVault)
        .applyAvailable();
    expect(result.otherVault, 1);
    expect(await journal.unresolvedConflicts(), isEmpty);
    expect(await database.select(database.locations).get(), hasLength(1));

    final tampered = Map<String, Object?>.from(store.payloads.values.single)
      ..['changeId'] = 'mismatched-change-id';
    store.payloads[store.files.single.id] = tampered;
    await expectLater(
        GoogleDriveIncomingApplier(
                database: database,
                journal: journal,
                store: store,
                vault: secondVault)
            .applyAvailable(),
        throwsException);
    expect(await database.select(database.locations).get(), hasLength(1));
  });
}
