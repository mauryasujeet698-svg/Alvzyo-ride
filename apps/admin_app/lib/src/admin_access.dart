import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminAccess {
  /// Verify authority through the protected backend. The client never grants
  /// itself administrator permissions.
  static Future<bool> verify() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      return false;
    }
    try {
      await QuickRideBackend.invoke(
        'admin-service-areas',
        body: const {'action': 'dashboard_summary'},
      );
      return true;
    } on FunctionException catch (error) {
      if (error.status == 401 || error.status == 403) return false;
      rethrow;
    }
  }

  /// Google authentication alone is not Admin authorization. Reject and
  /// sign out any account the protected backend does not recognize as Admin.
  static Future<void> signIn() async {
    await QuickRideAuth.signInWithGoogle(
      redirectTo: 'com.alvzyo.ride.admin://login-callback',
    );
    bool allowed;
    try {
      allowed = await verify();
    } catch (_) {
      await QuickRideAuth.signOut();
      rethrow;
    }
    if (!allowed) {
      await QuickRideAuth.signOut();
      throw StateError(
        'This Google account is not authorized for Alvzyo Admin. Sign in with the approved administrator account.',
      );
    }
  }
}
