import 'dart:convert';

import 'package:ai_electricity_data/data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('different devices can unlock and decrypt with a recovery secret',
      () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    final restored = VaultHeader.fromJson(
        jsonDecode(jsonEncode(created.header.toJson()))
            as Map<String, Object?>);
    final secondDevice =
        await SyncVault.unlock(restored, 'a long independent recovery secret');
    final first =
        await created.vault.encrypt('change-1', utf8.encode('123 kWh'));
    final second =
        await created.vault.encrypt('change-1', utf8.encode('123 kWh'));
    expect(first['nonce'], isNot(second['nonce']));
    expect(jsonEncode(first), isNot(contains('123 kWh')));
    expect(jsonEncode(created.header.toJson()),
        isNot(contains('a long independent recovery secret')));
    expect(utf8.decode(await secondDevice.decrypt(first)), '123 kWh');
    expect(utf8.decode(await secondDevice.decrypt(second)), '123 kWh');
  });

  test('wrong recovery secret and changed header fail authentication',
      () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    await expectLater(
        SyncVault.unlock(created.header, 'a different recovery secret'),
        throwsException);
    await expectLater(
        SyncVault.unlock(
            VaultHeader('another-vault', created.header.salt,
                created.header.wrappedKey),
            'a long independent recovery secret'),
        throwsException);
  });

  test('payload metadata and ciphertext are authenticated', () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    final payload = await created.vault.encrypt('change-1', [1, 2, 3]);
    await expectLater(
        created.vault.decrypt({...payload, 'changeId': 'change-2'}),
        throwsException);
    await expectLater(
        created.vault.decrypt({...payload, 'vaultId': 'another-vault'}),
        throwsFormatException);
    await expectLater(
        created.vault.decrypt({
          ...payload,
          'cipherText': base64Encode([9, 9, 9])
        }),
        throwsException);
    await expectLater(created.vault.decrypt({...payload, 'version': 2}),
        throwsFormatException);
  });

  test('rejects short secrets, malformed recovery metadata and oversized data',
      () async {
    await expectLater(SyncVault.create('short'), throwsArgumentError);
    final created =
        await SyncVault.create('a long independent recovery secret');
    final header = created.header.toJson();
    expect(() => VaultHeader.fromJson({...header, 'version': 2}),
        throwsFormatException);
    expect(
        () => VaultHeader.fromJson({
              ...header,
              'salt': base64Encode([1])
            }),
        throwsFormatException);
    await expectLater(created.vault.encrypt('', [1]), throwsArgumentError);
    await expectLater(created.vault.encrypt('big', List.filled(1048577, 0)),
        throwsArgumentError);
    await expectLater(
        created.vault.decrypt({
          'version': 1,
          'vaultId': created.header.vaultId,
          'changeId': 'small',
          'nonce': base64Encode(List.filled(12, 0)),
          'cipherText': 'A' * 1398105,
          'mac': base64Encode(List.filled(16, 0)),
        }),
        throwsFormatException);
    await expectLater(
        created.vault.decrypt({
          'version': 1,
          'vaultId': created.header.vaultId,
          'changeId': 'small',
          'nonce': base64Encode([1]),
          'cipherText': base64Encode([1]),
          'mac': base64Encode(List.filled(16, 0)),
        }),
        throwsFormatException);
  });
}
