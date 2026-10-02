import 'dart:convert';

import 'package:ai_electricity_data/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('publishes only encrypted payload with authorization in headers',
      () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    final client = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'www.googleapis.com');
      expect(request.url.toString(), isNot(contains('test-token')));
      expect(request.headers['Authorization'], 'Bearer test-token');
      expect(request.followRedirects, isFalse);
      expect(request.url.queryParameters['uploadType'], 'multipart');
      expect(request.headers['Content-Type'], startsWith('multipart/related'));
      expect(utf8.decode(request.bodyBytes), contains('appDataFolder'));
      expect(utf8.decode(request.bodyBytes), isNot(contains('sensitive note')));
      expect(utf8.decode(request.bodyBytes),
          isNot(contains('electricity-v1-change-001')));
      return http.Response('{"id":"encrypted-file-1"}', 200);
    });
    final store = GoogleDriveEncryptedStore(client, () async => 'test-token');
    expect(
        await store.publish(
            created.vault, 'change-001', utf8.encode('sensitive note')),
        'encrypted-file-1');
  });

  test('lists app data with pagination and reads opaque encrypted content',
      () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    final encrypted = await created.vault.encrypt('change-001', [1, 2, 3]);
    final client = MockClient((request) async {
      if (request.url.path == '/drive/v3/files/encrypted-file-1') {
        expect(request.url.queryParameters['alt'], 'media');
        return http.Response(jsonEncode(encrypted), 200);
      }
      expect(request.url.queryParameters['spaces'], 'appDataFolder');
      if (request.url.queryParameters['pageToken'] == null) {
        return http.Response(
            jsonEncode({
              'nextPageToken': 'next',
              'files': [
                {'id': 'encrypted-file-1', 'name': 'electricity-v1-change-001'},
                {'id': 'unrelated-1', 'name': 'unrelated'}
              ]
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'files': [
              {'id': 'encrypted-file-2', 'name': 'electricity-v1-change-002'}
            ]
          }),
          200);
    });
    final store = GoogleDriveEncryptedStore(client, () async => 'test-token');
    final files = await store.listChanges();
    expect(
        files.map((file) => file.id), ['encrypted-file-1', 'encrypted-file-2']);
    expect(
        utf8.decode(await created.vault
            .decrypt(await store.readEncrypted(files.first.id))),
        isNotEmpty);
  });

  test('stores and discovers a wrapped vault header without recovery secret',
      () async {
    final created =
        await SyncVault.create('a long independent recovery secret');
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        final body = utf8.decode(request.bodyBytes);
        expect(body, contains('electricity-vault-v1-'));
        expect(body, isNot(contains('a long independent recovery secret')));
        expect(body, contains(jsonEncode(created.header.toJson())));
        return http.Response('{"id":"vault-file-1"}', 200);
      }
      if (request.url.path == '/drive/v3/files') {
        expect(request.url.queryParameters['spaces'], 'appDataFolder');
        return http.Response(
            jsonEncode({
              'files': [
                {'id': 'vault-file-1', 'name': 'electricity-vault-v1-random'},
                {'id': 'change-file-1', 'name': 'electricity-v1-random'},
              ]
            }),
            200);
      }
      expect(request.url.path, '/drive/v3/files/vault-file-1');
      return http.Response(jsonEncode(created.header.toJson()), 200);
    });
    final store = GoogleDriveEncryptedStore(client, () async => 'test-token');

    expect(await store.publishVaultHeader(created.header), 'vault-file-1');
    final headers = await store.listVaultHeaders();
    expect(headers, hasLength(1));
    final header = await store.readVaultHeader(headers.single.id);
    expect(header.vaultId, created.header.vaultId);
    final restored =
        await SyncVault.unlock(header, 'a long independent recovery secret');
    final payload = await created.vault.encrypt('header-check-0001', [4, 5]);
    expect(await restored.decrypt(payload), [4, 5]);
  });

  test('fails closed on redirects and never includes response bodies in errors',
      () async {
    final store = GoogleDriveEncryptedStore(
        MockClient((request) async => http.Response('private detail', 302)),
        () async => 'test-token');
    await expectLater(
        store.listChanges(),
        throwsA(isA<DriveSyncException>()
            .having((error) => error.statusCode, 'statusCode', 302)));
    expect(const DriveSyncException(302).toString(),
        isNot(contains('private detail')));
  });

  test('rejects invalid object IDs, looped pages and empty tokens', () async {
    final badToken = GoogleDriveEncryptedStore(
        MockClient((request) async => http.Response('{}', 200)),
        () async => '');
    await expectLater(badToken.listChanges(), throwsStateError);
    await expectLater(badToken.readEncrypted('../other'), throwsArgumentError);

    final looping = GoogleDriveEncryptedStore(
        MockClient((request) async =>
            http.Response('{"files":[],"nextPageToken":"repeat"}', 200)),
        () async => 'test-token');
    await expectLater(looping.listChanges(), throwsFormatException);
  });
}
