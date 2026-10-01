import 'dart:convert';

import 'package:ai_electricity_core/core.dart' as domain;
import 'package:ai_electricity_data/data.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class SessionCredentialBackend implements SecureCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class SessionDriveStore implements EncryptedChangeStore {
  final headers = <String, VaultHeader>{};
  final encryptedChanges = <String, Map<String, Object?>>{};
  var nextFile = 0;

  @override
  Future<List<EncryptedDriveFile>> listChanges() async => [
        for (final id in encryptedChanges.keys)
          EncryptedDriveFile(id, 'electricity-v1-$id'),
      ];

  @override
  Future<Map<String, Object?>> readEncrypted(String fileId) async =>
      encryptedChanges[fileId]!;

  @override
  Future<String> publish(
      SyncVault vault, String changeId, List<int> plaintext) async {
    final id = 'change-file-${nextFile++}';
    encryptedChanges[id] = await vault.encrypt(changeId, plaintext);
    return id;
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
    final id = 'vault-file-${headers.length}';
    headers[id] = header;
    return id;
  }
}

void main() {
  test('session creates a vault and syncs outbox idempotently', () async {
    final database = ElectricityDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final credentialBackend = SessionCredentialBackend();
    final credentials = SecureGoogleCredentialStore(credentialBackend);
    await credentials.write(GoogleCredentials(
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        accountSubject: 'google-account'));
    final store = SessionDriveStore();
    final keyCache = SecureVaultKeyCache(credentialBackend);
    final session = GoogleDriveSyncSession(
        database: database,
        credentials: credentials,
        keyCache: keyCache,
        store: store);

    final vault =
        await session.createVault('a sufficiently long recovery secret');
    expect(vault.vaultId, isNotEmpty);
    expect(await session.hasUnlockedVault, isTrue);

    final location = (await database.select(database.locations).get()).single;
    await DriftMeterReadingRepository(database).save(domain.MeterReading(
        0, 'total', DateTime(2026, 9, 29), domain.Kwh(100),
        locationId: location.id));

    final upload = await session.syncNow();
    expect(upload.uploaded, 5);
    expect(upload.applied, 0);
    expect(await DriftSyncJournal(database).pending(), isEmpty);

    final applyOwnChange = await session.syncNow();
    expect(applyOwnChange.uploaded, 0);
    expect(applyOwnChange.applied, 5);
    expect(await DriftSyncJournal(database).pending(), isEmpty);

    final replay = await session.syncNow();
    expect(replay.applied, 0);
    expect(replay.duplicates, 5);
    expect((await database.select(database.meterReadings).get()), hasLength(1));
    final restoredVault = (await keyCache.read('google-account'))!;
    Map<String, Object?>? encryptedReading;
    for (final encrypted in store.encryptedChanges.values) {
      final envelope =
          jsonDecode(utf8.decode(await restoredVault.decrypt(encrypted)))
              as Map<String, dynamic>;
      if (envelope['entityKind'] == 'reading') encryptedReading = encrypted;
    }
    expect(encryptedReading, isNotNull);
    expect(encryptedReading!['cipherText'], isNot(contains('100')));
  });
}
