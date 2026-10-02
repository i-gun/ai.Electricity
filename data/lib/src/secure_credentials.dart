import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sync_vault.dart';

/// OAuth credentials stored together so updates can replace them atomically.
class GoogleCredentials {
  GoogleCredentials({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    required this.accountSubject,
  }) {
    if (accessToken.isEmpty || accountSubject.isEmpty) {
      throw ArgumentError('Google credential fields must not be empty');
    }
  }

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final String accountSubject;

  Map<String, Object?> toJson() => {
        'version': 1,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
        'accountSubject': accountSubject,
      };

  factory GoogleCredentials.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1 ||
        json['accessToken'] is! String ||
        (json['refreshToken'] != null && json['refreshToken'] is! String) ||
        json['expiresAt'] is! int ||
        json['accountSubject'] is! String) {
      throw const FormatException('Invalid stored Google credential format');
    }
    return GoogleCredentials(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int,
          isUtc: true),
      accountSubject: json['accountSubject'] as String,
    );
  }
}

/// Platform secure storage contract for testing and adapter injection.
abstract interface class SecureCredentialBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Uses Keychain, Android Keystore-backed encryption, Windows protection and
/// Linux Secret Service through flutter_secure_storage. Errors propagate; no
/// plaintext fallback is provided.
class FlutterSecureCredentialBackend implements SecureCredentialBackend {
  FlutterSecureCredentialBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            FlutterSecureStorage(
                aOptions: AndroidOptions(migrateWithBackup: true),
                mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Stores OAuth tokens only through an OS-backed encrypted credential store.
class SecureGoogleCredentialStore {
  SecureGoogleCredentialStore(this.backend);

  static const _key = 'ai.electricity.google.oauth.v1';
  final SecureCredentialBackend backend;

  Future<GoogleCredentials?> read() async {
    final serialized = await backend.read(_key);
    if (serialized == null) return null;
    final decoded = jsonDecode(serialized);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid stored Google credentials');
    }
    return GoogleCredentials.fromJson(decoded);
  }

  Future<void> write(GoogleCredentials credentials) =>
      backend.write(_key, jsonEncode(credentials.toJson()));

  Future<void> delete() => backend.delete(_key);
}

/// Caches only the unlocked random vault key in OS-backed encrypted storage.
/// Recovery secrets are never stored. Cache records are bound to the Google
/// account subject so switching accounts cannot silently reuse another vault.
class SecureVaultKeyCache {
  SecureVaultKeyCache(this.backend);

  static const _key = 'ai.electricity.sync.vault-key.v1';
  final SecureCredentialBackend backend;

  Future<void> save(SyncVault vault, String accountSubject) async {
    if (accountSubject.isEmpty) throw ArgumentError('Missing Google account');
    final key = await vault.exportKeyForSecureStorage();
    await backend.write(
        _key,
        jsonEncode({
          'version': 1,
          'vaultId': vault.vaultId,
          'accountSubject': accountSubject,
          'key': base64Encode(key),
        }));
  }

  Future<SyncVault?> read(String accountSubject) async {
    final encoded = await backend.read(_key);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['vaultId'] is! String ||
        decoded['accountSubject'] is! String ||
        decoded['key'] is! String) {
      throw const FormatException('Invalid cached vault key');
    }
    if (decoded['accountSubject'] != accountSubject) {
      throw StateError('Cached vault belongs to a different Google account');
    }
    if ((decoded['key'] as String).length > 64) {
      throw const FormatException('Invalid cached vault key');
    }
    final key = base64Decode(decoded['key'] as String);
    return SyncVault.fromDeviceKey(decoded['vaultId'] as String, key);
  }

  Future<void> delete() => backend.delete(_key);
}
