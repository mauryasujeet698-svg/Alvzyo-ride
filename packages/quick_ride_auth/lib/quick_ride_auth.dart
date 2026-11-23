import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class QuickRideAuth {
  QuickRideAuth._();

  static const String _googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static Future<void>? _googleInitialization;

  /// Optional app-provided cleanup for push registrations before sign-out.
  /// Keeping this callback avoids coupling authentication to a push provider.
  static Future<void> Function()? beforeSignOutCleanup;

  static User? get currentUser =>
      QuickRideBackend.isInitialized
          ? QuickRideBackend.client.auth.currentUser
          : null;

  static Stream<AuthState> get authStateChanges =>
      QuickRideBackend.client.auth.onAuthStateChange;

  /// Native Google account selection followed by a Supabase ID-token exchange.
  ///
  /// [redirectTo] remains in the signature for existing app callers. It is
  /// intentionally unused: native authentication returns directly to the app.
  static Future<AuthResponse> signInWithGoogle({
    required String redirectTo,
  }) async {
    if (!QuickRideBackend.isInitialized) {
      throw const AuthException('Alvzyo could not connect to its sign-in service.');
    }
    if (_googleWebClientId.isEmpty) {
      throw const AuthException(
        'Google sign-in is not configured. Add the GOOGLE_WEB_CLIENT_ID build secret.',
      );
    }
    try {
      _googleInitialization ??= _googleSignIn.initialize(
        serverClientId: _googleWebClientId,
      );
      await _googleInitialization!;

      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthException(
          'Native Google sign-in is not supported on this device.',
        );
      }

      GoogleSignInAccount googleAccount;
      try {
        googleAccount = await _googleSignIn.authenticate();
      } catch (error) {
        final details = error.toString().toLowerCase();
        if (details.contains('account reauth failed')) {
          throw const AuthException(
            'Google could not verify this installed app build. Check the Android OAuth client package name and the SHA-1 fingerprint of the APK signing certificate.',
          );
        }
        rethrow;
      }

      final idToken = googleAccount.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthException(
          'Google did not return an ID token. Check the Android OAuth client configuration.',
        );
      }

      return await QuickRideBackend.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
    } catch (error, stack) {
      debugPrint('Alvzyo Google sign-in failed (${error.runtimeType}): $error');
      debugPrintStack(stackTrace: stack);
      _googleInitialization = null;
      rethrow;
    }
  }

  static Future<void> signOut() async {
    // Clear the native Google/Credential Manager session first. Otherwise a
    // later authenticate() can be treated as a broken account re-auth attempt.
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Local Supabase sign-out must still complete if Google cleanup fails.
    }
    try {
      await beforeSignOutCleanup?.call();
    } catch (_) {
      // A push-token cleanup failure must not leave the user signed in.
    }
    await QuickRideBackend.client.auth.signOut();
  }
}
