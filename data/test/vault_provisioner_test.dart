import 'dart:convert';

import 'package:ai_electricity_data/data.dart';
import 'package:flutter_test/flutter_test.dart';

class VaultDriveStore implements EncryptedChangeStore {
  final headers = <String, VaultHeader>{};

  @override
  Future<List<EncryptedDriveFile>> listChanges() async => const [];

  @override
  Future<Map<String, Object?>> readEncrypted(String fileId) async =>
      throw UnimplementedError();

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
  Future<VaultHeader> readVaultHeader(String fileId) async {
    final header = headers[fileId];
    if (header == null) throw const FormatException('Vault not found');
    return header;
  }

  @override
  Future<String> publishVaultHeader(VaultHeader header) async {
    final fileId = 'vault-file-${headers.length}';
    headers[fileId] = header;
    return fileId;
  }
}

class VaultMemoryBackend implements SecureCredentialBackend {
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

void main() {
  test('creates a recovery-wrapped remote vault and discovers it', () async {
    final remote = VaultDriveStore();
    final cache = SecureVaultKeyCache(VaultMemoryBackend());
    final provisioner = DriveVaultProvisioner(store: remote, keyCache: cache);
    final created = await provisioner.create(
        'a sufficiently long recovery secret', 'google-account-subject');

    expect(created.header.vaultId, isNotEmpty);
    expect(remote.headers, contains(created.fileId));
    expect(jsonEncode(created.header.toJson()),
        isNot(contains('a sufficiently long recovery secret')));
    final discovered = await provisioner.discover();
    expect(discovered, hasLength(1));
    expect(discovered.single.header.vaultId, created.header.vaultId);
    expect((await provisioner.restoreCached('google-account-subject'))!.vaultId,
        created.header.vaultId);
  });

  test('another device unlocks only with recovery secret and caches by account',
      () async {
    final remote = VaultDriveStore();
    final creator = DriveVaultProvisioner(
        store: remote, keyCache: SecureVaultKeyCache(VaultMemoryBackend()));
    final created = await creator.create(
        'a sufficiently long recovery secret', 'account-one');
    final newDevice = DriveVaultProvisioner(
        store: remote, keyCache: SecureVaultKeyCache(VaultMemoryBackend()));

    await expectLater(
        newDevice.unlock(
            fileId: created.fileId,
            recoverySecret: 'a different recovery secret',
            accountSubject: 'account-one'),
        throwsException);
    final unlocked = await newDevice.unlock(
        fileId: created.fileId,
        recoverySecret: 'a sufficiently long recovery secret',
        accountSubject: 'account-one');
    expect(unlocked.vaultId, created.header.vaultId);
    expect((await newDevice.restoreCached('account-one'))!.vaultId,
        created.header.vaultId);
  });
}
