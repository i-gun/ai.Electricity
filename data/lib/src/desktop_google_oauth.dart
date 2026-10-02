import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'secure_credentials.dart';

const _driveScope = 'https://www.googleapis.com/auth/drive.appdata';
const _openidScope = 'openid';
const _authorizationEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
const _userinfoEndpoint = 'https://openidconnect.googleapis.com/v1/userinfo';
const _revokeEndpoint = 'https://oauth2.googleapis.com/revoke';
const _maxOAuthResponseBytes = 65536;

/// Sanitized authentication error; never contains provider response bodies.
class GoogleOAuthException implements Exception {
  const GoogleOAuthException(this.reason);

  final String reason;

  @override
  String toString() => 'GoogleOAuthException: $reason';
}

/// PKCE values for an installed-app authorization request.
class PkcePair {
  const PkcePair(this.verifier, this.challenge);

  final String verifier;
  final String challenge;
}

/// Desktop Google OAuth using an external browser and a loopback callback.
///
/// Supply the public desktop OAuth client ID from build/runtime configuration.
/// No client secret is accepted or persisted by this class.
class DesktopGoogleOAuth {
  DesktopGoogleOAuth({
    required this.clientId,
    required this.credentials,
    http.Client? httpClient,
    Future<bool> Function(Uri)? openBrowser,
  })  : _httpClient = httpClient ?? http.Client(),
        _openBrowser = openBrowser ??
            ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (!clientId.endsWith('.apps.googleusercontent.com')) {
      throw const GoogleOAuthException(
          'Set GOOGLE_OAUTH_DESKTOP_CLIENT_ID to a public desktop client ID');
    }
  }

  final String clientId;
  final SecureGoogleCredentialStore credentials;
  final http.Client _httpClient;
  final Future<bool> Function(Uri) _openBrowser;

  static Future<PkcePair> createPkcePair() async {
    final verifier = _base64Url(_randomBytes(32));
    final digest = await Sha256().hash(ascii.encode(verifier));
    return PkcePair(verifier, _base64Url(digest.bytes));
  }

  Future<GoogleCredentials> signIn() async {
    final callbackPath = '/oauth/${_base64Url(_randomBytes(18))}';
    final state = _base64Url(_randomBytes(32));
    final pkce = await createPkcePair();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: callbackPath);
    final responseFuture = _waitForCallback(server, callbackPath, state);
    final authorizationUri =
        Uri.parse(_authorizationEndpoint).replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'response_type': 'code',
      'scope': '$_openidScope $_driveScope',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
    });
    try {
      if (!await _openBrowser(authorizationUri)) {
        throw const GoogleOAuthException('Could not open system browser');
      }
      final parameters =
          await responseFuture.timeout(const Duration(minutes: 5));
      if (parameters['error'] != null) {
        throw const GoogleOAuthException('Authorization was declined');
      }
      final code = parameters['code'];
      if (code == null || code.isEmpty) {
        throw const GoogleOAuthException('Authorization response had no code');
      }
      final tokenJson = await _postForm(_tokenEndpoint, {
        'client_id': clientId,
        'code': code,
        'code_verifier': pkce.verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri.toString(),
      });
      final credential = await _credentialsFromTokenWithExpiry(tokenJson);
      await credentials.write(credential);
      return credential;
    } on TimeoutException {
      throw const GoogleOAuthException('Authorization timed out');
    } finally {
      await server.close(force: true);
    }
  }

  Future<String> accessToken({DateTime? now}) async {
    final saved = await credentials.read();
    if (saved == null) throw const GoogleOAuthException('Sign-in required');
    final currentTime = now ?? DateTime.now().toUtc();
    if (saved.expiresAt.isAfter(currentTime.add(const Duration(minutes: 1)))) {
      return saved.accessToken;
    }
    final refreshToken = saved.refreshToken;
    if (refreshToken == null) {
      throw const GoogleOAuthException(
          'Native Google authorization requires user interaction');
    }
    final tokenJson = await _postForm(_tokenEndpoint, {
      'client_id': clientId,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
    final access = tokenJson['access_token'];
    final expiresIn = tokenJson['expires_in'];
    if (access is! String ||
        access.isEmpty ||
        expiresIn is! int ||
        expiresIn <= 0) {
      throw const GoogleOAuthException('Invalid refresh response');
    }
    final updated = GoogleCredentials(
        accessToken: access,
        refreshToken: tokenJson['refresh_token'] as String? ?? refreshToken,
        expiresAt: currentTime.add(Duration(seconds: expiresIn)),
        accountSubject: saved.accountSubject);
    await credentials.write(updated);
    return updated.accessToken;
  }

  Future<void> disconnect() async {
    final saved = await credentials.read();
    if (saved == null) return;
    final refreshToken = saved.refreshToken;
    if (refreshToken == null) {
      await credentials.delete();
      throw const GoogleOAuthException(
          'Disconnect native Google authorization through its platform SDK');
    }
    try {
      final request = http.Request('POST', Uri.parse(_revokeEndpoint))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
        ..bodyFields = {'token': refreshToken};
      final response = await _httpClient.send(request);
      await response.stream.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const GoogleOAuthException('Google token revocation failed');
      }
    } finally {
      await credentials.delete();
    }
  }

  Future<Map<String, Object?>> _credentialsFromToken(
      Map<String, Object?> tokenJson) async {
    final access = tokenJson['access_token'];
    final refresh = tokenJson['refresh_token'];
    final expiresIn = tokenJson['expires_in'];
    final scope = tokenJson['scope'];
    if (access is! String ||
        refresh is! String ||
        expiresIn is! int ||
        scope is! String ||
        !scope.split(' ').contains(_driveScope) ||
        !scope.split(' ').contains(_openidScope)) {
      throw const GoogleOAuthException(
          'Required Drive or OpenID permission was not granted');
    }
    final userinfo = await _getUserInfo(access);
    return {
      'accessToken': access,
      'refreshToken': refresh,
      'expiresIn': expiresIn,
      'accountSubject': userinfo,
    };
  }

  Future<GoogleCredentials> _credentialsFromTokenWithExpiry(
      Map<String, Object?> tokenJson) async {
    final normalized = await _credentialsFromToken(tokenJson);
    return GoogleCredentials(
        accessToken: normalized['accessToken'] as String,
        refreshToken: normalized['refreshToken'] as String,
        expiresAt: DateTime.now()
            .toUtc()
            .add(Duration(seconds: normalized['expiresIn'] as int)),
        accountSubject: normalized['accountSubject'] as String);
  }

  Future<String> _getUserInfo(String accessToken) async {
    final uri = Uri.parse(_userinfoEndpoint);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $accessToken';
    final response = await _httpClient.send(request);
    if (response.statusCode != HttpStatus.ok) {
      await response.stream.drain<void>();
      throw const GoogleOAuthException('Could not verify Google account');
    }
    final body = await _readBounded(response);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final subject = decoded['sub'];
    if (subject is! String || subject.isEmpty) {
      throw const GoogleOAuthException('Google account has no stable subject');
    }
    return subject;
  }

  Future<Map<String, Object?>> _postForm(
      String endpoint, Map<String, String> values) async {
    final uri = Uri.parse(endpoint);
    if (uri.scheme != 'https') {
      throw const GoogleOAuthException('Insecure OAuth endpoint rejected');
    }
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
      ..bodyFields = values;
    final response = await _httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw const GoogleOAuthException('Google authorization request failed');
    }
    final body = await _readBounded(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const GoogleOAuthException('Invalid Google authorization response');
    }
    return decoded;
  }

  Future<String> _readBounded(http.StreamedResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > _maxOAuthResponseBytes) {
        throw const GoogleOAuthException('Google response exceeds size limit');
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes());
  }

  Future<Map<String, String>> _waitForCallback(
      HttpServer server, String expectedPath, String expectedState) async {
    final completer = Completer<Map<String, String>>();
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) async {
      final isLoopback =
          request.connectionInfo?.remoteAddress.isLoopback ?? false;
      final uri = request.uri;
      if (!isLoopback || uri.path != expectedPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (uri.queryParameters['state'] != expectedState) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response
            .write('Authorization response rejected. Return to the app.');
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!doctype html><title>ai.Electricity</title>'
          '<p>Authorization received. Return to ai.Electricity.</p>');
      await request.response.close();
      if (!completer.isCompleted) completer.complete(uri.queryParameters);
      await subscription.cancel();
    });
    return completer.future;
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(256));
  }

  static String _base64Url(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
