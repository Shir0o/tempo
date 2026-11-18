import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:tempo/core/sync/google_drive_sync_service.dart';
import 'package:tempo/data/database/tempo_database.dart';

/// Stands in for the native Google Sign-In SDK so a "relaunch" can be simulated
/// without an account sheet: a real relaunch calls the lightweight path, which
/// silently returns a previously authorized account, and never [authenticate].
class _FakeGoogleSignIn extends GoogleSignInPlatform {
  AuthenticationResults? lightweightResult;
  AuthenticationResults? interactiveResult;
  ClientAuthorizationTokenData? clientTokens;

  int lightweightCalls = 0;
  int authenticateCalls = 0;
  int signOutCalls = 0;
  bool? sawPromptForConsent;

  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) {
    lightweightCalls++;
    return Future.value(lightweightResult);
  }

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    authenticateCalls++;
    return interactiveResult!;
  }

  @override
  bool authorizationRequiresUserInteraction() => true;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    sawPromptForConsent = params.request.promptIfUnauthorized;
    return clientTokens;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<void> signOut(SignOutParams params) async {
    signOutCalls++;
  }

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

const _signedInAccount = AuthenticationResults(
  user: GoogleSignInUserData(id: 'google-user-1', email: 'person@example.com'),
  authenticationTokens: AuthenticationTokenData(idToken: 'id-token'),
);

void main() {
  final fake = _FakeGoogleSignIn();
  late TempoDatabase database;

  setUpAll(() async {
    GoogleSignInPlatform.instance = fake;
    await GoogleSignIn.instance.initialize(serverClientId: 'test-client');
  });

  setUp(() async {
    database = await TempoDatabase.openInMemory();
    fake
      ..lightweightResult = _signedInAccount
      ..interactiveResult = _signedInAccount
      ..clientTokens = const ClientAuthorizationTokenData(
        accessToken: 'restored-token',
      )
      ..lightweightCalls = 0
      ..authenticateCalls = 0
      ..signOutCalls = 0
      ..sawPromptForConsent = null;
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'a relaunch stays signed in without showing the account sheet',
    () async {
      await database.setSetting(
        GoogleDriveSyncService.connectedSetting,
        'true',
      );

      // A fresh service stands in for opening the app again.
      final service = GoogleDriveSyncService(database: database);

      expect(await service.restorePreviousSession(), isTrue);
      expect(service.isSignedIn, isTrue);
      expect(service.lastError, isNull);
      expect(
        fake.authenticateCalls,
        0,
        reason: 'restore must never open interactive sign-in',
      );
      expect(fake.sawPromptForConsent, isFalse);
    },
  );

  test('restoring twice asks Google once', () async {
    await database.setSetting(GoogleDriveSyncService.connectedSetting, 'true');
    final service = GoogleDriveSyncService(database: database);

    // main() starts the restore and Settings may await it too.
    final first = service.restorePreviousSession();
    final second = service.restorePreviousSession();

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(fake.lightweightCalls, 1);
  });

  test('never touches Google for someone who never connected Drive', () async {
    final service = GoogleDriveSyncService(database: database);

    expect(await service.restorePreviousSession(), isFalse);
    expect(service.isSignedIn, isFalse);
    expect(
      fake.lightweightCalls,
      0,
      reason: 'Android falls back to an account sheet when no session exists',
    );
    expect(fake.authenticateCalls, 0);
  });

  test('no remembered Google account leaves the service signed out', () async {
    await database.setSetting(GoogleDriveSyncService.connectedSetting, 'true');
    fake.lightweightResult = null;
    final service = GoogleDriveSyncService(database: database);

    expect(await service.restorePreviousSession(), isFalse);
    expect(service.isSignedIn, isFalse);
    expect(fake.authenticateCalls, 0);
  });

  test('a restored account without Drive consent reports reconnect', () async {
    await database.setSetting(GoogleDriveSyncService.connectedSetting, 'true');
    fake.clientTokens = null;
    final service = GoogleDriveSyncService(database: database);

    expect(await service.restorePreviousSession(), isFalse);
    expect(service.isSignedIn, isFalse);
    expect(service.lastError, isNotNull);
    expect(fake.authenticateCalls, 0);
  });

  test('connecting is remembered and disconnecting is remembered', () async {
    final service = GoogleDriveSyncService(database: database);

    expect(await service.signIn(), isTrue);
    expect(
      await database.getSetting(GoogleDriveSyncService.connectedSetting),
      'true',
    );

    await service.signOut();
    expect(
      await database.getSetting(GoogleDriveSyncService.connectedSetting),
      'false',
    );
    expect(fake.signOutCalls, 1);
  });
}
