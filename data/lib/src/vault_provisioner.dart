import 'secure_credentials.dart';
import 'sync_vault.dart';
import 'drive_store.dart';

/// A discovered Drive vault and its recovery metadata.
class RemoteVaultDescriptor {
  const RemoteVaultDescriptor({required this.fileId, required this.header});

  final String fileId;
  final VaultHeader header;
}

/// Coordinates user-driven vault creation, discovery, unlock and secure cache.
/// The recovery secret is used only in memory and is never written to storage.
class DriveVaultProvisioner {
  DriveVaultProvisioner({required this.store, required this.keyCache});

  final EncryptedChangeStore store;
  final SecureVaultKeyCache keyCache;

  Future<RemoteVaultDescriptor> create(
      String recoverySecret, String accountSubject) async {
    final created = await SyncVault.create(recoverySecret);
    final fileId = await store.publishVaultHeader(created.header);
    await keyCache.save(created.vault, accountSubject);
    return RemoteVaultDescriptor(fileId: fileId, header: created.header);
  }

  Future<List<RemoteVaultDescriptor>> discover() async {
    final files = await store.listVaultHeaders();
    final vaults = <RemoteVaultDescriptor>[];
    for (final file in files) {
      final header = await store.readVaultHeader(file.id);
      vaults.add(RemoteVaultDescriptor(fileId: file.id, header: header));
    }
    return vaults;
  }

  Future<SyncVault> unlock({
    required String fileId,
    required String recoverySecret,
    required String accountSubject,
  }) async {
    final header = await store.readVaultHeader(fileId);
    final vault = await SyncVault.unlock(header, recoverySecret);
    await keyCache.save(vault, accountSubject);
    return vault;
  }

  Future<SyncVault?> restoreCached(String accountSubject) =>
      keyCache.read(accountSubject);

  Future<void> forgetCachedKey() => keyCache.delete();
}
