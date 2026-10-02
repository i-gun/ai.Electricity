import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_vault.dart';

/// A Google Drive app-data file containing one encrypted sync change.
class EncryptedDriveFile {
  const EncryptedDriveFile(this.id, this.name);

  final String id;
  final String name;
}

/// An HTTP failure with no provider response body or bearer token attached.
class DriveSyncException implements Exception {
  const DriveSyncException(this.statusCode);

  final int statusCode;
}

/// Encrypted transport contract consumed by the sync coordinator.
abstract interface class EncryptedChangeStore {
  Future<List<EncryptedDriveFile>> listChanges();
  Future<Map<String, Object?>> readEncrypted(String fileId);
  Future<String> publish(SyncVault vault, String changeId, List<int> plaintext);
  Future<List<EncryptedDriveFile>> listVaultHeaders();
  Future<VaultHeader> readVaultHeader(String fileId);
  Future<String> publishVaultHeader(VaultHeader header);
}

/// Reads and writes opaque encrypted changes in Google Drive appDataFolder.
class GoogleDriveEncryptedStore implements EncryptedChangeStore {
  GoogleDriveEncryptedStore(this.client, this.accessToken);

  factory GoogleDriveEncryptedStore.withAccessToken(
          Future<String> Function() accessToken) =>
      GoogleDriveEncryptedStore(http.Client(), accessToken);

  final http.Client client;
  final Future<String> Function() accessToken;

  static const _maxResponseSize = 2 * 1024 * 1024;
  static final _changeIdPattern = RegExp(r'^[a-zA-Z0-9_-]{8,128}$');

  Future<List<EncryptedDriveFile>> _listNamedFiles(String prefix) async {
    final results = <EncryptedDriveFile>[];
    final seenTokens = <String>{};
    String? pageToken;
    do {
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'fields': 'nextPageToken,files(id,name)',
        'pageSize': '1000',
        if (pageToken != null) 'pageToken': pageToken,
      });
      final page = jsonDecode(utf8.decode(await _send('GET', uri)))
          as Map<String, dynamic>;
      for (final file in page['files'] as List<dynamic>) {
        final item = file as Map<String, dynamic>;
        final name = item['name'] as String;
        if (name.startsWith(prefix)) {
          results.add(EncryptedDriveFile(item['id'] as String, name));
        }
      }
      pageToken = page['nextPageToken'] as String?;
      if (pageToken != null && !seenTokens.add(pageToken)) {
        throw const FormatException('Repeated Drive page token');
      }
    } while (pageToken != null);
    return results;
  }

  Future<List<int>> _send(String method, Uri uri,
      {List<int>? body, String? contentType}) async {
    if (uri.scheme != 'https' || uri.host != 'www.googleapis.com') {
      throw ArgumentError('Unsupported Drive endpoint');
    }
    final token = await accessToken();
    if (token.isEmpty || token.contains(RegExp(r'[\r\n]'))) {
      throw StateError('No valid Google access token');
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $token';
    if (contentType != null) request.headers['Content-Type'] = contentType;
    if (body != null) request.bodyBytes = body;
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw DriveSyncException(response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxResponseSize) {
        throw const FormatException('Drive response exceeds size limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// Lists all encrypted change objects, following Drive's pagination tokens.
  @override
  Future<List<EncryptedDriveFile>> listChanges() =>
      _listNamedFiles('electricity-v1-');

  @override
  Future<List<EncryptedDriveFile>> listVaultHeaders() =>
      _listNamedFiles('electricity-vault-v1-');

  @override
  Future<VaultHeader> readVaultHeader(String fileId) async {
    if (!_changeIdPattern.hasMatch(fileId)) {
      throw ArgumentError('Invalid Drive file ID');
    }
    final uri = Uri.https(
        'www.googleapis.com', '/drive/v3/files/$fileId', {'alt': 'media'});
    final decoded = jsonDecode(utf8.decode(await _send('GET', uri)));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid vault header');
    }
    return VaultHeader.fromJson(decoded);
  }

  @override
  Future<String> publishVaultHeader(VaultHeader header) async {
    final random = Random.secure();
    String opaqueId() => List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final boundary = 'electricity-${opaqueId()}';
    final prefix = utf8.encode('--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode({
          'name': 'electricity-vault-v1-${opaqueId()}',
          'parents': ['appDataFolder']
        })}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n');
    final data = utf8.encode(jsonEncode(header.toJson()));
    final suffix = utf8.encode('\r\n--$boundary--\r\n');
    final uri = Uri.https('www.googleapis.com', '/upload/drive/v3/files',
        {'uploadType': 'multipart', 'fields': 'id'});
    final result = jsonDecode(utf8.decode(await _send('POST', uri,
            body: [...prefix, ...data, ...suffix],
            contentType: 'multipart/related; boundary=$boundary')))
        as Map<String, dynamic>;
    return result['id'] as String;
  }

  /// Downloads an encrypted payload, without decrypting or logging it.
  @override
  Future<Map<String, Object?>> readEncrypted(String fileId) async {
    if (!_changeIdPattern.hasMatch(fileId)) {
      throw ArgumentError('Invalid Drive file ID');
    }
    final uri = Uri.https(
        'www.googleapis.com', '/drive/v3/files/$fileId', {'alt': 'media'});
    return jsonDecode(utf8.decode(await _send('GET', uri)))
        as Map<String, Object?>;
  }

  /// Encrypts a change before publishing it as one immutable Drive file.
  @override
  Future<String> publish(
      SyncVault vault, String changeId, List<int> plaintext) async {
    if (!_changeIdPattern.hasMatch(changeId)) {
      throw ArgumentError('Invalid change ID');
    }
    final encrypted = await vault.encrypt(changeId, plaintext);
    final random = Random.secure();
    String opaqueId() => List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final boundary = 'electricity-${opaqueId()}';
    final filename = 'electricity-v1-${opaqueId()}';
    final prefix = utf8.encode('--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode({
          'name': filename,
          'parents': ['appDataFolder']
        })}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final data = utf8.encode(jsonEncode(encrypted));
    final suffix = utf8.encode('\r\n--$boundary--\r\n');
    final uri = Uri.https('www.googleapis.com', '/upload/drive/v3/files',
        {'uploadType': 'multipart', 'fields': 'id'});
    final result = jsonDecode(utf8.decode(await _send('POST', uri,
            body: [...prefix, ...data, ...suffix],
            contentType: 'multipart/related; boundary=$boundary')))
        as Map<String, dynamic>;
    return result['id'] as String;
  }
}
