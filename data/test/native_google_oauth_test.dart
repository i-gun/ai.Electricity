import 'package:ai_electricity_data/data.dart';
import 'package:flutter_test/flutter_test.dart';

class NativeOAuthMemoryBackend implements SecureCredentialBackend {
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

class FakeNativeGoogleBackend implements NativeGoogleAuthBackend {
  String? subject = 'google-user';
  String? silentToken;
  String interactiveToken = 'interactive-token';
  int authenticateCalls = 0;
  int silentCalls = 0;
  int authorizeCalls = 0;
  int disconnectCalls = 0;
  int initializationCalls = 0;

  @override
  Future<void> initialize() async {
    initializationCalls++;
  }

  @override
  Future<NativeGoogleAccount> authenticate() async {
    authenticateCalls++;
    return NativeGoogleAccount(subject!);
  }

  @override
  Future<NativeGoogleAccount?> restoreAccount() async =>
      subject == null ? null : NativeGoogleAccount(subject!);

  @override
  Future<String?> authorizationForScopes(
      String subject, List<String> scopes) async {
    silentCalls++;
    return silentToken;
  }

  @override
  Future<String> authorizeScopes(String subject, List<String> scopes) async {
    authorizeCalls++;
    return interactiveToken;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    subject = null;
  }
}

void main() {
  test('native sign-in stores access token without inventing refresh token',
      () async {
    final backend = FakeNativeGoogleBackend();
    final secureBackend = NativeOAuthMemoryBackend();
    final store = SecureGoogleCredentialStore(secureBackend);
    final oauth = NativeGoogleOAuth(backend, store);

    final credentials = await oauth.signIn();
    expect(credentials.accessToken, 'interactive-token');
    expect(credentials.refreshToken, isNull);
    expect(credentials.accountSubject, 'google-user');
    expect((await store.read())!.refreshToken, isNull);
    expect(backend.authenticateCalls, 1);
    expect(backend.authorizeCalls, 1);
  });

  test('native token is retrieved from SDK rather than trusting cache',
      () async {
    final backend = FakeNativeGoogleBackend()..silentToken = 'silent-token';
    final store = SecureGoogleCredentialStore(NativeOAuthMemoryBackend());
    final oauth = NativeGoogleOAuth(backend, store);
    final now = DateTime.utc(2026, 10, 1);
    await store.write(GoogleCredentials(
        accessToken: 'cached-token',
        expiresAt: now.add(const Duration(minutes: 40)),
        accountSubject: 'google-user'));
    expect(await oauth.accessToken(now: now), 'silent-token');
    expect((await store.read())!.accessToken, 'silent-token');
    expect((await store.read())!.refreshToken, isNull);
    expect(backend.silentCalls, 1);
  });

  test('requires foreground reauthorization when token cannot renew silently',
      () async {
    final backend = FakeNativeGoogleBackend();
    final store = SecureGoogleCredentialStore(NativeOAuthMemoryBackend());
    final oauth = NativeGoogleOAuth(backend, store);
    final now = DateTime.utc(2026, 10, 1);
    await store.write(GoogleCredentials(
        accessToken: 'expired-token',
        expiresAt: now.subtract(const Duration(seconds: 1)),
        accountSubject: 'google-user'));

    await expectLater(
        oauth.accessToken(now: now), throwsA(isA<GoogleOAuthException>()));
    expect((await oauth.reauthorize()).accessToken, 'interactive-token');
    expect(backend.authenticateCalls, 1);
    expect(backend.authorizeCalls, 1);
  });

  test('account mismatch blocks silent renewal and disconnect removes tokens',
      () async {
    final backend = FakeNativeGoogleBackend()
      ..subject = 'different-google-user'
      ..silentToken = 'must-not-be-used';
    final store = SecureGoogleCredentialStore(NativeOAuthMemoryBackend());
    final oauth = NativeGoogleOAuth(backend, store);
    await store.write(GoogleCredentials(
        accessToken: 'expired-token',
        expiresAt: DateTime.utc(2020),
        accountSubject: 'original-user'));

    await expectLater(oauth.accessToken(now: DateTime.utc(2026)),
        throwsA(isA<GoogleOAuthException>()));
    expect(backend.silentCalls, 0);
    await oauth.disconnect();
    expect(backend.disconnectCalls, 1);
    expect(await store.read(), isNull);
  });
}
