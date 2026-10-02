import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const _version = 1;
const _memory = 65536;
const _iterations = 2;
const _parallelism = 1;

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List.generate(length, (_) => random.nextInt(256));
}

List<int> _aad(String vaultId, String changeId) =>
    utf8.encode('ai.electricity:$_version:$vaultId:$changeId');

SecretBox _box(Map<String, Object?> payload) {
  final encodedNonce = payload['nonce'] as String;
  final encodedCipherText = payload['cipherText'] as String;
  final encodedMac = payload['mac'] as String;
  if (encodedNonce.length > 32 ||
      encodedCipherText.length > 1398104 ||
      encodedMac.length > 32) {
    throw const FormatException('Invalid encrypted record');
  }
  final nonce = base64Decode(encodedNonce);
  final cipherText = base64Decode(encodedCipherText);
  final mac = base64Decode(encodedMac);
  if (nonce.length != 12 || mac.length != 16 || cipherText.length > 1048576) {
    throw const FormatException('Invalid encrypted record');
  }
  return SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
}

/// Serialized recovery metadata; never contains a plaintext data key or secret.
class VaultHeader {
  const VaultHeader(this.vaultId, this.salt, this.wrappedKey);

  final String vaultId;
  final String salt;
  final Map<String, Object?> wrappedKey;

  Map<String, Object?> toJson() => {
        'version': _version,
        'vaultId': vaultId,
        'kdf': 'argon2id',
        'memory': _memory,
        'iterations': _iterations,
        'parallelism': _parallelism,
        'salt': salt,
        'wrappedKey': wrappedKey,
      };

  factory VaultHeader.fromJson(Map<String, Object?> json) {
    if (json['version'] != _version ||
        json['kdf'] != 'argon2id' ||
        json['memory'] != _memory ||
        json['iterations'] != _iterations ||
        json['parallelism'] != _parallelism ||
        json['vaultId'] is! String ||
        json['wrappedKey'] is! Map<String, Object?>) {
      throw const FormatException('Unsupported vault format');
    }
    final encodedSalt = json['salt'] as String;
    if (encodedSalt.length > 32) {
      throw const FormatException('Invalid vault salt');
    }
    final salt = base64Decode(encodedSalt);
    if (salt.length != 16) throw const FormatException('Invalid vault salt');
    return VaultHeader(json['vaultId'] as String, json['salt'] as String,
        json['wrappedKey'] as Map<String, Object?>);
  }
}

/// A new recovery header and its in-memory unlocked vault.
class CreatedVault {
  const CreatedVault(this.header, this.vault);

  final VaultHeader header;
  final SyncVault vault;
}

/// Encrypts records using a per-vault key, recoverable with a user secret.
class SyncVault {
  SyncVault._(this.vaultId, this._dataKey);

  final String vaultId;
  final SecretKey _dataKey;
  static final _cipher = AesGcm.with256bits();

  static Future<SecretKey> _derive(String recoverySecret, List<int> salt) =>
      Argon2id(
              memory: _memory,
              iterations: _iterations,
              parallelism: _parallelism,
              hashLength: 32)
          .deriveKeyFromPassword(password: recoverySecret, nonce: salt);

  static Future<CreatedVault> create(String recoverySecret) async {
    if (recoverySecret.length < 16) {
      throw ArgumentError('Recovery secret must have at least 16 characters');
    }
    final vaultId = base64UrlEncode(_randomBytes(24)).replaceAll('=', '');
    final salt = _randomBytes(16);
    final wrappingKey = await _derive(recoverySecret, salt);
    final dataKey = await _cipher.newSecretKey();
    final wrapped = await _cipher.encrypt(await dataKey.extractBytes(),
        secretKey: wrappingKey, aad: _aad(vaultId, 'key'));
    final header = VaultHeader(vaultId, base64Encode(salt), {
      'nonce': base64Encode(wrapped.nonce),
      'cipherText': base64Encode(wrapped.cipherText),
      'mac': base64Encode(wrapped.mac.bytes),
    });
    return CreatedVault(header, SyncVault._(vaultId, dataKey));
  }

  static Future<SyncVault> unlock(
      VaultHeader header, String recoverySecret) async {
    if (header.salt.length > 32) {
      throw const FormatException('Invalid vault salt');
    }
    final salt = base64Decode(header.salt);
    if (salt.length != 16) throw const FormatException('Invalid vault salt');
    final wrappingKey = await _derive(recoverySecret, salt);
    final data = await _cipher.decrypt(_box(header.wrappedKey),
        secretKey: wrappingKey, aad: _aad(header.vaultId, 'key'));
    if (data.length != 32) throw const FormatException('Invalid data key');
    return SyncVault._(header.vaultId, SecretKey(data));
  }

  static Future<SyncVault> fromDeviceKey(
      String vaultId, List<int> keyMaterial) async {
    if (vaultId.isEmpty || keyMaterial.length != 32) {
      throw const FormatException('Invalid cached vault key');
    }
    return SyncVault._(
        vaultId, await _cipher.newSecretKeyFromBytes(keyMaterial));
  }

  Future<List<int>> exportKeyForSecureStorage() => _dataKey.extractBytes();

  Future<Map<String, Object?>> encrypt(
      String changeId, List<int> plaintext) async {
    if (changeId.isEmpty || plaintext.length > 1048576) {
      throw ArgumentError('Invalid change');
    }
    final box = await _cipher.encrypt(plaintext,
        secretKey: _dataKey, aad: _aad(vaultId, changeId));
    return {
      'version': _version,
      'vaultId': vaultId,
      'changeId': changeId,
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<List<int>> decrypt(Map<String, Object?> payload) async {
    if (payload['version'] != _version ||
        payload['vaultId'] != vaultId ||
        payload['changeId'] is! String ||
        (payload['changeId'] as String).isEmpty) {
      throw const FormatException('Wrong vault or unsupported change');
    }
    return _cipher.decrypt(_box(payload),
        secretKey: _dataKey, aad: _aad(vaultId, payload['changeId'] as String));
  }
}
