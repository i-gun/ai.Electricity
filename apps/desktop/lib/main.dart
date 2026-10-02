import 'package:ai_electricity_ui/ui.dart';
import 'package:ai_electricity_data/data.dart';
import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';

void main() {
  final database = openElectricityDatabase();
  final secureBackend = FlutterSecureCredentialBackend();
  final credentialStore = SecureGoogleCredentialStore(secureBackend);
  final keyCache = SecureVaultKeyCache(secureBackend);
  final clientId =
      const String.fromEnvironment('GOOGLE_OAUTH_DESKTOP_CLIENT_ID');
  DesktopGoogleOAuth? oauth;
  DesktopGoogleOAuth createOAuth() => oauth ??=
      DesktopGoogleOAuth(clientId: clientId, credentials: credentialStore);
  final driveStore = GoogleDriveEncryptedStore.withAccessToken(
      () => createOAuth().accessToken());
  final syncSession = GoogleDriveSyncSession(
      database: database,
      credentials: credentialStore,
      keyCache: keyCache,
      store: driveStore);
  runApp(DesktopApp(
      readingRepository: DriftMeterReadingRepository(database),
      zoneRepository: DriftTariffZoneRepository(database),
      rateRepository: DriftTariffRateRepository(database),
      locationRepository: DriftLocationRepository(database),
      isGoogleConnected: () async => await credentialStore.read() != null,
      hasGoogleVault: () async => await syncSession.hasUnlockedVault,
      loadSyncConflicts: () async => [
            for (final conflict
                in await DriftSyncJournal(database).unresolvedConflicts())
              SyncConflictItem(
                  id: conflict.id,
                  entityKind: conflict.entityKind,
                  entityId: conflict.entityId,
                  reason: conflict.reason,
                  candidateSummaries: syncConflictCandidateSummaries(conflict),
                  resolutionChoices: syncConflictResolutionChoices(conflict)),
          ],
      listGoogleVaults: () async => [
            for (final vault in await syncSession.discoverVaults())
              SyncVaultChoice(fileId: vault.fileId, vaultId: vault.vaultId),
          ],
      onGoogleConnect: () async {
        try {
          await createOAuth().signIn();
        } on GoogleOAuthException catch (error) {
          throw SyncUiException(error.reason);
        }
      },
      onGoogleReauthorize: () async {
        try {
          await createOAuth().signIn();
        } on GoogleOAuthException catch (error) {
          throw SyncUiException(error.reason);
        }
      },
      onGoogleDisconnect: () async {
        try {
          await createOAuth().disconnect();
        } finally {
          await syncSession.forgetVaultKey();
        }
      },
      onGoogleCreateVault: (secret) async {
        await syncSession.createVault(secret);
      },
      onGoogleUnlockVault: (fileId, secret) =>
          syncSession.unlockVault(fileId, secret),
      onGoogleSyncNow: () async {
        final result = await syncSession.syncNow();
        return SyncRunSummary(
            uploaded: result.uploaded,
            applied: result.applied,
            duplicates: result.duplicates,
            conflicts: result.conflicts,
            otherVault: result.otherVault);
      },
      onGoogleResolveConflict: syncSession.resolveConflict));
}

class DesktopApp extends StatelessWidget {
  const DesktopApp(
      {super.key,
      this.readingRepository,
      this.zoneRepository,
      this.rateRepository,
      this.locationRepository,
      this.isGoogleConnected,
      this.hasGoogleVault,
      this.loadSyncConflicts,
      this.listGoogleVaults,
      this.onGoogleConnect,
      this.onGoogleReauthorize,
      this.onGoogleDisconnect,
      this.onGoogleCreateVault,
      this.onGoogleUnlockVault,
      this.onGoogleSyncNow,
      this.onGoogleResolveConflict});
  final MeterReadingRepository? readingRepository;
  final TariffZoneRepository? zoneRepository;
  final TariffRateRepository? rateRepository;
  final LocationRepository? locationRepository;
  final Future<bool> Function()? isGoogleConnected;
  final Future<bool> Function()? hasGoogleVault;
  final Future<List<SyncConflictItem>> Function()? loadSyncConflicts;
  final Future<List<SyncVaultChoice>> Function()? listGoogleVaults;
  final Future<void> Function()? onGoogleConnect;
  final Future<void> Function()? onGoogleReauthorize;
  final Future<void> Function()? onGoogleDisconnect;
  final Future<void> Function(String recoverySecret)? onGoogleCreateVault;
  final Future<void> Function(String fileId, String recoverySecret)?
      onGoogleUnlockVault;
  final Future<SyncRunSummary> Function()? onGoogleSyncNow;
  final Future<void> Function(String conflictId, int candidateIndex)?
      onGoogleResolveConflict;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai.Electricity',
      theme: lightTheme(),
      darkTheme: darkTheme(),
      home: SharedHome(
          readingRepository: readingRepository,
          zoneRepository: zoneRepository,
          rateRepository: rateRepository,
          locationRepository: locationRepository,
          isGoogleConnected: isGoogleConnected,
          hasGoogleVault: hasGoogleVault,
          loadSyncConflicts: loadSyncConflicts,
          listGoogleVaults: listGoogleVaults,
          onGoogleConnect: onGoogleConnect,
          onGoogleReauthorize: onGoogleReauthorize,
          onGoogleDisconnect: onGoogleDisconnect,
          onGoogleCreateVault: onGoogleCreateVault,
          onGoogleUnlockVault: onGoogleUnlockVault,
          onGoogleSyncNow: onGoogleSyncNow,
          onGoogleResolveConflict: onGoogleResolveConflict),
    );
  }
}

class PlaceholderHome extends StatelessWidget {
  const PlaceholderHome({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: Text('Workspace bootstrap complete.')),
    );
  }
}
