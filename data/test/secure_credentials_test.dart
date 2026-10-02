import 'package:ai_electricity_data/data.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySecureBackend implements SecureCredentialBackend {
  final values = <String, String>{};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('secure backend unavailable');
    return values[key];
  }

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
  test('credential store round-trips tokens and supports account removal',
      () async {
    final backend = MemorySecureBackend();
    final store = SecureGoogleCredentialStore(backend);
    final credentials = GoogleCredentials(
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAt: DateTime.utc(2026, 10, 1),
        accountSubject: 'google-subject');

    await store.write(credentials);
    expect(await store.read(), isNotNull);
    expect((await store.read())!.accessToken, 'access');
    expect((await store.read())!.refreshToken, 'refresh');
    expect((await store.read())!.accountSubject, 'google-subject');
    expect((await store.read())!.expiresAt, DateTime.utc(2026, 10, 1));
    expect(backend.values.keys, hasLength(1));
    await store.delete();
    expect(await store.read(), isNull);
  });

  test('malformed stored credentials fail closed', () async {
    final backend = MemorySecureBackend()
      ..values['ai.electricity.google.oauth.v1'] = '{"version":99}';
    final store = SecureGoogleCredentialStore(backend);
    await expectLater(store.read(), throwsFormatException);
    expect(
        () => GoogleCredentials(
            accessToken: '',
            refreshToken: 'refresh',
            expiresAt: DateTime.utc(2026),
            accountSubject: 'subject'),
        throwsArgumentError);
  });

  test('secure-store failures propagate without a persistence fallback',
      () async {
    final backend = MemorySecureBackend()..failReads = true;
    final store = SecureGoogleCredentialStore(backend);
    await expectLater(store.read(), throwsStateError);
    expect(backend.values, isEmpty);
  });

  test('vault cache restores the key only for its linked Google account',
      () async {
    final backend = MemorySecureBackend();
    final cache = SecureVaultKeyCache(backend);
    final created =
        await SyncVault.create('a sufficiently long recovery secret');
    await cache.save(created.vault, 'account-one');

    final restored = await cache.read('account-one');
    expect(restored!.vaultId, created.vault.vaultId);
    final encrypted = await created.vault.encrypt('cache-test-0001', [1, 2, 3]);
    expect(await restored.decrypt(encrypted), [1, 2, 3]);
    await expectLater(cache.read('account-two'), throwsStateError);
    expect(backend.values.values.single,
        isNot(contains('a sufficiently long recovery secret')));
    await cache.delete();
    expect(await cache.read('account-one'), isNull);
  });
}
