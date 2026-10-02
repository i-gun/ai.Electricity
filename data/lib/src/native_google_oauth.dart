import 'package:google_sign_in/google_sign_in.dart';

import 'desktop_google_oauth.dart' show GoogleOAuthException;
import 'secure_credentials.dart';

const _driveAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';
const _nativeTokenLifetime = Duration(minutes: 50);

/// Minimal identity needed by the platform-neutral native OAuth coordinator.
class NativeGoogleAccount {
  const NativeGoogleAccount(this.subject);

  final String subject;
}

/// Injectable boundary for Android/iOS Google Sign-In SDK integration.
abstract interface class NativeGoogleAuthBackend {
  Future<void> initialize();
  Future<NativeGoogleAccount> authenticate();
  Future<NativeGoogleAccount?> restoreAccount();
  Future<String?> authorizationForScopes(String subject, List<String> scopes);
  Future<String> authorizeScopes(String subject, List<String> scopes);
  Future<void> disconnect();
}

/// Android/iOS adapter over the maintained Google Sign-In SDK.
///
/// macOS desktop deliberately uses [DesktopGoogleOAuth] to avoid the
/// Keychain-sharing entitlement required by Google's macOS native SDK.
class GoogleSignInNativeBackend implements NativeGoogleAuthBackend {
  GoogleSignInNativeBackend({
    required this.clientId,
    required this.serverClientId,
    GoogleSignIn? googleSignIn,
  }) : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  factory GoogleSignInNativeBackend.fromEnvironment(
          {GoogleSignIn? googleSignIn}) =>
      GoogleSignInNativeBackend(
          clientId: const String.fromEnvironment('GOOGLE_OAUTH_CLIENT_ID'),
          serverClientId:
              const String.fromEnvironment('GOOGLE_OAUTH_WEB_CLIENT_ID'),
          googleSignIn: googleSignIn);

  final String clientId;
  final String serverClientId;
  final GoogleSignIn _googleSignIn;
  GoogleSignInAccount? _currentAccount;
  Future<void>? _initialization;

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (clientId.isEmpty || serverClientId.isEmpty) {
      throw const GoogleOAuthException(
          'Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_WEB_CLIENT_ID');
    }
    await _googleSignIn.initialize(
        clientId: clientId, serverClientId: serverClientId);
    _googleSignIn.authenticationEvents.listen((event) {
      switch (event) {
        case GoogleSignInAuthenticationEventSignIn(:final user):
          _currentAccount = user;
        case GoogleSignInAuthenticationEventSignOut():
          _currentAccount = null;
      }
    }, onError: (Object _) {
      _currentAccount = null;
    });
    final attempt = _googleSignIn.attemptLightweightAuthentication();
    if (attempt != null) _currentAccount = await attempt;
  }

  @override
  Future<NativeGoogleAccount> authenticate() async {
    await initialize();
    final account =
        await _googleSignIn.authenticate(scopeHint: const [_driveAppDataScope]);
    _currentAccount = account;
    return NativeGoogleAccount(account.id);
  }

  @override
  Future<NativeGoogleAccount?> restoreAccount() async {
    await initialize();
    if (_currentAccount != null) {
      return NativeGoogleAccount(_currentAccount!.id);
    }
    final attempt = _googleSignIn.attemptLightweightAuthentication();
    if (attempt == null) return null;
    final account = await attempt;
    _currentAccount = account;
    return account == null ? null : NativeGoogleAccount(account.id);
  }

  GoogleSignInAccount _accountFor(String subject) {
    final account = _currentAccount;
    if (account == null || account.id != subject) {
      throw const GoogleOAuthException(
          'Google account must be restored or selected again');
    }
    return account;
  }

  @override
  Future<String?> authorizationForScopes(
      String subject, List<String> scopes) async {
    await initialize();
    final account = _accountFor(subject);
    final authorization =
        await account.authorizationClient.authorizationForScopes(scopes);
    return authorization?.accessToken;
  }

  @override
  Future<String> authorizeScopes(String subject, List<String> scopes) async {
    await initialize();
    final account = _accountFor(subject);
    final authorization =
        await account.authorizationClient.authorizeScopes(scopes);
    return authorization.accessToken;
  }

  @override
  Future<void> disconnect() async {
    await initialize();
    await _googleSignIn.disconnect();
    _currentAccount = null;
  }
}

/// Coordinates SDK-managed access-token renewal and secure local caching.
class NativeGoogleOAuth {
  NativeGoogleOAuth(this.backend, this.credentials);

  final NativeGoogleAuthBackend backend;
  final SecureGoogleCredentialStore credentials;

  Future<void> initialize() => backend.initialize();

  /// Must be called from an explicit user interaction.
  Future<GoogleCredentials> signIn() async {
    await backend.initialize();
    final account = await backend.authenticate();
    final accessToken = await backend
        .authorizeScopes(account.subject, const [_driveAppDataScope]);
    final credential = _credential(account.subject, accessToken);
    await credentials.write(credential);
    return credential;
  }

  Future<String> accessToken({DateTime? now}) async {
    await backend.initialize();
    final saved = await credentials.read();
    if (saved == null) throw const GoogleOAuthException('Sign-in required');
    final currentTime = now ?? DateTime.now().toUtc();
    final account = await backend.restoreAccount();
    if (account == null || account.subject != saved.accountSubject) {
      throw const GoogleOAuthException(
          'User interaction is required to sign in');
    }
    final accessToken = await backend
        .authorizationForScopes(account.subject, const [_driveAppDataScope]);
    if (accessToken == null) {
      throw const GoogleOAuthException(
          'User interaction is required to renew access');
    }
    final refreshed =
        _credential(account.subject, accessToken, now: currentTime);
    await credentials.write(refreshed);
    return refreshed.accessToken;
  }

  /// Reauthorizes expired or revoked access from a foreground user action.
  Future<GoogleCredentials> reauthorize() => signIn();

  Future<void> disconnect() async {
    try {
      await backend.disconnect();
    } finally {
      await credentials.delete();
    }
  }

  GoogleCredentials _credential(String subject, String accessToken,
          {DateTime? now}) =>
      GoogleCredentials(
          accessToken: accessToken,
          refreshToken: null,
          expiresAt: (now ?? DateTime.now().toUtc()).add(_nativeTokenLifetime),
          accountSubject: subject);
}
