import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

class AdminAccess {
  /// Ask the protected Supabase Edge Function to verify the active user's
  /// administrator role. The client never grants itself admin permissions.
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
    } catch (_) {
      return false;
    }
  }
}
