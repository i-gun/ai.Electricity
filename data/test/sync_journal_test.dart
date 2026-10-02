import 'dart:convert';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeEncryptedChangeStore implements EncryptedChangeStore {
  final payloads = <String, List<int>>{};
  final headers = <String, VaultHeader>{};
  bool failPublish = false;

  @override
  Future<List<EncryptedDriveFile>> listChanges() async => const [];

  @override
  Future<Map<String, Object?>> readEncrypted(String fileId) async =>
      throw UnimplementedError();

  @override
  Future<String> publish(
      SyncVault vault, String changeId, List<int> plaintext) async {
    if (failPublish) throw StateError('upload failed');
    payloads[changeId] = plaintext;
    return 'file-$changeId';
  }

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

void main() {
  test('identity alias chains resolve and conflicting targets are rejected',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);

    await journal.addEntityAlias('reading', 'legacy-reading', 'reading-a');
    await journal.addEntityAlias('reading', 'reading-a', 'reading-root');
    expect(await journal.canonicalEntityId('reading', 'legacy-reading'),
        'reading-root');
    await expectLater(
        journal.addEntityAlias('reading', 'legacy-reading', 'reading-b'),
        throwsStateError);
  });

  test('legacy bootstrap baselines are deterministic across installations',
      () async {
    final first = ElectricityDatabase(NativeDatabase.memory());
    final second = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);

    expect(await DriftSyncJournal(first).bootstrapExistingEntities(), 4);
    expect(await DriftSyncJournal(second).bootstrapExistingEntities(), 4);
    final firstChanges = await DriftSyncJournal(first).pending();
    final secondChanges = await DriftSyncJournal(second).pending();
    final byId = {for (final change in secondChanges) change.id: change};
    expect(firstChanges.map((change) => change.id).toSet(), byId.keys.toSet());
    for (final change in firstChanges) {
      expect(byId[change.id]!.payload, change.payload);
      expect(
          await DriftSyncJournal(first)
              .head(change.entityKind, change.entityId),
          change.id);
    }
    expect(await DriftSyncJournal(first).bootstrapExistingEntities(), 0);
  });

  test('uploader encrypts a versioned envelope and acknowledges after publish',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final store = FakeEncryptedChangeStore();
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final uploader =
        GoogleDriveOutboxUploader(journal: journal, store: store, vault: vault);
    await journal.enqueue(
        changeId: 'change-upload-001',
        entityKind: 'reading',
        entityId: 'stable-reading-id',
        payload: '{"valueKwh":10}');

    expect(await uploader.uploadPending(), 1);
    expect(await journal.pending(), isEmpty);
    final remote = jsonDecode(utf8.decode(store.payloads.values.single))
        as Map<String, dynamic>;
    expect(remote['schemaVersion'], 1);
    expect(remote['changeId'], 'change-upload-001');
    expect(remote['entityKind'], 'reading');
    expect(remote['entityId'], 'stable-reading-id');
    expect(remote['payload']['valueKwh'], 10);
  });

  test('outbox uploads causal parents before dependent operations', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final store = FakeEncryptedChangeStore();
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final uploader =
        GoogleDriveOutboxUploader(journal: journal, store: store, vault: vault);

    await journal.enqueue(
        changeId: 'dependent-change',
        entityKind: 'reading',
        entityId: 'stable-reading-id',
        payload: '{}',
        parentChangeId: 'parent-change');
    await journal.enqueue(
        changeId: 'parent-change',
        entityKind: 'reading',
        entityId: 'stable-parent-reading-id',
        payload: '{}');

    expect(await uploader.uploadPending(), 2);
    expect(store.payloads.keys, ['parent-change', 'dependent-change']);
  });

  test('upload failure leaves change pending and malformed JSON is rejected',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final store = FakeEncryptedChangeStore()..failPublish = true;
    final vault =
        (await SyncVault.create('a sufficiently long recovery secret')).vault;
    final uploader =
        GoogleDriveOutboxUploader(journal: journal, store: store, vault: vault);
    await journal.enqueue(
        changeId: 'change-upload-002',
        entityKind: 'location',
        entityId: 'stable-location-id',
        payload: '{}');
    await expectLater(uploader.uploadPending(), throwsStateError);
    expect((await journal.pending()).single.id, 'change-upload-002');

    store.failPublish = false;
    await journal.enqueue(
        changeId: 'change-upload-003',
        entityKind: 'location',
        entityId: 'stable-location-id',
        payload: 'not-json');
    await expectLater(uploader.uploadPending(), throwsFormatException);
    expect((await journal.pending()).map((change) => change.id),
        ['change-upload-003']);
  });

  test('location zone and rate changes use stable references and tombstones',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    final locations = DriftLocationRepository(database);
    final zones = DriftTariffZoneRepository(database);
    final rates = DriftTariffRateRepository(database);

    await locations.save(const domain.Location(0, 'Cabin'));
    final cabin = await (database.select(database.locations)
          ..where((row) => row.name.equals('Cabin')))
        .getSingle();
    final home = (await database.select(database.locations).get())
        .singleWhere((row) => row.name == 'Home');
    await zones.save(domain.TariffZone(
        0, domain.ZoneCode('shared'), 'Shared', domain.ZoneKind.custom,
        locationIds: {home.id, cabin.id}));
    final zone = await (database.select(database.tariffZones)
          ..where((row) => row.code.equals('shared')))
        .getSingle();
    await rates.save(
        domain.TariffRate(0, 'shared', domain.Money(17), DateTime(2026, 1, 1)));
    final rate = await (database.select(database.tariffRates)
          ..where((row) => row.zoneId.equals('shared')))
        .getSingle();

    var changes = await journal.pending();
    final locationChange =
        changes.firstWhere((item) => item.entityKind == 'location');
    final zoneChange = changes.firstWhere((item) => item.entityKind == 'zone');
    final rateChange = changes.firstWhere((item) => item.entityKind == 'rate');
    expect(locationChange.entityId, cabin.syncId);
    final zonePayload = jsonDecode(zoneChange.payload) as Map<String, dynamic>;
    expect(zoneChange.entityId, zone.syncId);
    expect(
        zonePayload['locationIds'], containsAll([home.syncId, cabin.syncId]));
    final ratePayload = jsonDecode(rateChange.payload) as Map<String, dynamic>;
    expect(rateChange.entityId, rate.syncId);
    expect(ratePayload['zoneId'], zone.syncId);

    await rates.delete(rate.id);
    await zones.delete(zone.id);
    await locations.delete(cabin.id);
    changes = await journal.pending();
    expect(changes.where((item) => item.isDeleted).map((item) => item.entityId),
        [rate.syncId, zone.syncId, cabin.syncId]);
  });

  test('reading create, edit, and delete journal the same stable entity',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    final journal = DriftSyncJournal(database);
    final date = DateTime(2026, 9, 29);

    await repository
        .save(domain.MeterReading(0, 'total', date, domain.Kwh(100)));
    final saved = (await database.select(database.meterReadings).get()).single;
    await repository.save(domain.MeterReading(
        saved.id, 'total', date, domain.Kwh(105),
        note: 'corrected', isReset: true));
    await repository.delete(saved.id);
    await repository.delete(saved.id);

    final changes = await journal.pending();
    expect(changes, hasLength(3));
    expect(changes.map((change) => change.id).toSet(), hasLength(3));
    expect(changes.map((change) => change.entityId).toSet(), {saved.syncId});
    expect(changes.map((change) => change.entityKind).toSet(), {'reading'});
    expect(changes.map((change) => change.isDeleted), [false, false, true]);
    final originalChange = changes.singleWhere((change) =>
        (jsonDecode(change.payload) as Map<String, dynamic>)['valueKwh'] ==
        100);
    final revisedChange = changes.singleWhere((change) =>
        (jsonDecode(change.payload) as Map<String, dynamic>)['valueKwh'] ==
        105);
    final deletion = changes.singleWhere((change) => change.isDeleted);
    expect(originalChange.parentChangeId, isNull);
    expect(revisedChange.parentChangeId, originalChange.id);
    expect(deletion.parentChangeId, revisedChange.id);
    expect(await journal.head('reading', saved.syncId!), deletion.id);
    final original = jsonDecode(originalChange.payload) as Map<String, dynamic>;
    final revised = jsonDecode(revisedChange.payload) as Map<String, dynamic>;
    expect(original['valueKwh'], 100);
    expect(revised['valueKwh'], 105);
    expect(revised['isReset'], isTrue);
    expect(revised['note'], 'corrected');
    expect((await database.select(database.meterReadings).get()), isEmpty);
  });

  test('failed journal insert rolls back the reading save', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftMeterReadingRepository(database);
    await database.select(database.syncChanges).get();
    await database.customStatement('''
      CREATE TRIGGER reject_reading_journal BEFORE INSERT ON sync_changes
      WHEN NEW.entity_kind = 'reading'
      BEGIN SELECT RAISE(ABORT, 'journal unavailable'); END;
    ''');

    await expectLater(
        repository.save(domain.MeterReading(
            0, 'total', DateTime(2026, 9, 29), domain.Kwh(100))),
        throwsException);
    expect(await database.select(database.meterReadings).get(), isEmpty);
    expect(await DriftSyncJournal(database).pending(), isEmpty);
  });

  test('outbox changes remain pending until acknowledged', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);

    await journal.enqueue(
        changeId: 'change-one',
        entityKind: 'reading',
        entityId: 'reading-one',
        payload: '{"value":100}');
    await journal.enqueue(
        changeId: 'change-two',
        entityKind: 'reading',
        entityId: 'reading-two',
        payload: '{}',
        isDeleted: true);
    expect((await journal.pending()).map((item) => item.id),
        ['change-one', 'change-two']);
    expect((await journal.pending()).last.isDeleted, isTrue);
    await journal.markUploaded('change-one');
    expect((await journal.pending()).map((item) => item.id), ['change-two']);
    expect(
        () => journal.enqueue(
            changeId: 'change-two',
            entityKind: 'reading',
            entityId: 'reading-two',
            payload: '{}'),
        throwsException);
  });

  test('incoming change is applied once and failure rolls back the marker',
      () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final journal = DriftSyncJournal(database);
    var applications = 0;

    expect(
        await journal.applyOnce('remote-one', () async {
          applications++;
        }),
        isTrue);
    expect(
        await journal.applyOnce('remote-one', () async {
          applications++;
        }),
        isFalse);
    expect(applications, 1);

    await expectLater(
        journal.applyOnce('remote-two', () async {
          await journal.enqueue(
              changeId: 'nested',
              entityKind: 'reading',
              entityId: 'reading-one',
              payload: '{}');
          throw StateError('apply failed');
        }),
        throwsStateError);
    expect(await journal.pending(), isEmpty);
    expect(
        await journal.applyOnce('remote-two', () async {
          applications++;
        }),
        isTrue);
    expect(applications, 2);
    await expectLater(journal.applyOnce('', () async {}), throwsArgumentError);
  });
}
