import 'dart:convert';
import 'dart:io';

import 'package:ai_electricity_data/data.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class OAuthMemoryBackend implements SecureCredentialBackend {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }

  @override
  Future<void> delete(String key) async {
    value = null;
  }
}

Future<void> _completeLoopback(Uri authorizationUri,
    {String? code, String? error, String? stateOverride}) async {
  final redirect = Uri.parse(authorizationUri.queryParameters['redirect_uri']!);
  final callback = redirect.replace(queryParameters: {
    'state': stateOverride ?? authorizationUri.queryParameters['state']!,
    if (code != null) 'code': code,
    if (error != null) 'error': error,
  });
  final client = HttpClient();
  try {
    final request = await client.getUrl(callback);
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('PKCE challenge is S256 over a high-entropy verifier', () async {
    final pair = await DesktopGoogleOAuth.createPkcePair();
    expect(pair.verifier.length, inInclusiveRange(43, 128));
    final digest = await Sha256().hash(ascii.encode(pair.verifier));
    expect(pair.challenge, base64Url.encode(digest.bytes).replaceAll('=', ''));
    expect(pair.challenge, isNot(pair.verifier));
  });

  test('desktop sign-in uses scoped PKCE loopback and stores credentials',
      () async {
    final backend = OAuthMemoryBackend();
    final store = SecureGoogleCredentialStore(backend);
    final httpClient = MockClient((request) async {
      expect(request.url.scheme, 'https');
      if (request.url.host == 'oauth2.googleapis.com') {
        expect(request.headers['Authorization'], isNull);
        expect(request.url.path, '/token');
        expect(request.bodyFields['client_id'],
            'desktop.apps.googleusercontent.com');
        expect(request.bodyFields.containsKey('client_secret'), isFalse);
        expect(request.bodyFields['grant_type'], 'authorization_code');
        expect(request.bodyFields['code_verifier'], isNotEmpty);
        return http.Response(
            jsonEncode({
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'expires_in': 3600,
              'scope': 'openid https://www.googleapis.com/auth/drive.appdata',
            }),
            200);
      }
      expect(request.url.host, 'openidconnect.googleapis.com');
      expect(request.headers['Authorization'], 'Bearer access-token');
      return http.Response('{"sub":"stable-account-subject"}', 200);
    });
    final oauth = DesktopGoogleOAuth(
      clientId: 'desktop.apps.googleusercontent.com',
      credentials: store,
      httpClient: httpClient,
      openBrowser: (uri) async {
        expect(uri.scheme, 'https');
        expect(uri.host, 'accounts.google.com');
        expect(uri.queryParameters['scope'],
            'openid https://www.googleapis.com/auth/drive.appdata');
        expect(uri.queryParameters['access_type'], 'offline');
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        expect(redirect.host, '127.0.0.1');
        expect(redirect.scheme, 'http');
        expect(redirect.path, isEmpty);
        await _completeLoopback(uri, code: 'authorization-code');
        return true;
      },
    );

    final credentials = await oauth.signIn();
    expect(credentials.accessToken, 'access-token');
    expect(credentials.refreshToken, 'refresh-token');
    expect(credentials.accountSubject, 'stable-account-subject');
    expect(await store.read(), isNotNull);
  });

  test('invalid state, rejected scopes, and failed OAuth requests do not save',
      () async {
    final backend = OAuthMemoryBackend();
    final store = SecureGoogleCredentialStore(backend);
    final client = MockClient((request) async => http.Response('{}', 400));
    final wrongState = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: store,
        httpClient: client,
        openBrowser: (uri) async {
          await _completeLoopback(uri,
              code: 'authorization-code', stateOverride: 'wrong-state');
          await _completeLoopback(uri, code: 'authorization-code');
          return true;
        });
    await expectLater(
        wrongState.signIn(), throwsA(isA<GoogleOAuthException>()));
    expect(backend.value, isNull);

    DesktopGoogleOAuth noClientId() => DesktopGoogleOAuth(
        clientId: 'not-a-google-client-id', credentials: store);
    expect(noClientId, throwsA(isA<GoogleOAuthException>()));
  });

  test('consent denial explains test-user setup without exposing provider text',
      () async {
    final store = SecureGoogleCredentialStore(OAuthMemoryBackend());
    final oauth = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: store,
        openBrowser: (uri) async {
          await _completeLoopback(uri, error: 'access_denied');
          return true;
        });

    await expectLater(
        oauth.signIn(),
        throwsA(isA<GoogleOAuthException>().having(
            (error) => error.reason,
            'reason',
            allOf(contains('Testing mode'),
                isNot(contains('error_description'))))));
    expect(await store.read(), isNull);
  });

  test('redirect mismatch explains desktop loopback requirements', () async {
    final store = SecureGoogleCredentialStore(OAuthMemoryBackend());
    final oauth = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: store,
        openBrowser: (uri) async {
          await _completeLoopback(uri, error: 'redirect_uri_mismatch');
          return true;
        });

    await expectLater(
        oauth.signIn(),
        throwsA(isA<GoogleOAuthException>().having((error) => error.reason,
            'reason', contains('OAuth client type is Desktop app'))));
    expect(await store.read(), isNull);
  });

  test('invalid OAuth client error gives desktop-client guidance only',
      () async {
    final store = SecureGoogleCredentialStore(OAuthMemoryBackend());
    final client = MockClient((request) async => http.Response(
        '{"error":"invalid_client","error_description":"private detail"}',
        401));
    final oauth = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: store,
        httpClient: client,
        openBrowser: (uri) async {
          await _completeLoopback(uri, code: 'authorization-code');
          return true;
        });

    await expectLater(
        oauth.signIn(),
        throwsA(isA<GoogleOAuthException>().having(
            (error) => error.reason,
            'reason',
            allOf(contains('Desktop app client'),
                isNot(contains('private detail'))))));
    expect(await store.read(), isNull);
  });

  test('oversized userinfo response is rejected without saving tokens',
      () async {
    final backend = OAuthMemoryBackend();
    final client = MockClient((request) async {
      if (request.url.path == '/token') {
        return http.Response(
            jsonEncode({
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'expires_in': 3600,
              'scope': 'openid https://www.googleapis.com/auth/drive.appdata',
            }),
            200);
      }
      return http.Response('x' * 65537, 200);
    });
    final oauth = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: SecureGoogleCredentialStore(backend),
        httpClient: client,
        openBrowser: (uri) async {
          await _completeLoopback(uri, code: 'authorization-code');
          return true;
        });
    await expectLater(oauth.signIn(), throwsA(isA<GoogleOAuthException>()));
    expect(backend.value, isNull);
  });

  test('expired credentials refresh over HTTPS and disconnect forgets them',
      () async {
    final backend = OAuthMemoryBackend();
    final store = SecureGoogleCredentialStore(backend);
    await store.write(GoogleCredentials(
        accessToken: 'old-access',
        refreshToken: 'saved-refresh',
        expiresAt: DateTime.utc(2020),
        accountSubject: 'account'));
    var revoked = false;
    final client = MockClient((request) async {
      expect(request.url.scheme, 'https');
      if (request.url.path == '/token') {
        expect(request.bodyFields['grant_type'], 'refresh_token');
        expect(request.bodyFields['refresh_token'], 'saved-refresh');
        return http.Response(
            '{"access_token":"fresh-access","expires_in":1800}', 200);
      }
      expect(request.url.path, '/revoke');
      expect(request.bodyFields['token'], 'saved-refresh');
      revoked = true;
      return http.Response('', 200);
    });
    final oauth = DesktopGoogleOAuth(
        clientId: 'desktop.apps.googleusercontent.com',
        credentials: store,
        httpClient: client);
    expect(await oauth.accessToken(now: DateTime.utc(2026)), 'fresh-access');
    expect((await store.read())!.refreshToken, 'saved-refresh');
    await oauth.disconnect();
    expect(revoked, isTrue);
    expect(await store.read(), isNull);
  });
}
