import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@pragma('vm:entry-point')
Future<void> quickRideFirebaseBackgroundHandler(RemoteMessage message) async {
  // Background delivery is handled by the operating system for notification
  // messages. Keep this entry point initialized for data-only message support.
  if (Firebase.apps.isEmpty) {
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if (apiKey.isNotEmpty && appId.isNotEmpty && senderId.isNotEmpty && projectId.isNotEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: senderId,
          projectId: projectId,
        ),
      );
    }
  }
}

class QuickRideNotifications {
  QuickRideNotifications._();

  static bool _initialized = false;
  static bool _inboxLoaded = false;
  static final ValueNotifier<List<Map<String, dynamic>>> inbox =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  static String? _appRole;
  static FirebaseMessaging? _messaging;
  static StreamSubscription<AuthState>? _authSubscription;
  static StreamSubscription<String>? _tokenSubscription;
  static StreamSubscription<String>? _unregisteredSubscription;
  static String? _currentInstallationId;
  static StreamSubscription<RemoteMessage>? _openedSubscription;
  static StreamSubscription<RemoteMessage>? _foregroundSubscription;
  static RemoteMessage? _initialMessage;
  static final StreamController<RemoteMessage> _openedMessages =
      StreamController<RemoteMessage>.broadcast();
  static final StreamController<RemoteMessage> _foregroundMessages =
      StreamController<RemoteMessage>.broadcast();

  static Stream<RemoteMessage> get openedMessages => _openedMessages.stream;
  static Stream<RemoteMessage> get foregroundMessages => _foregroundMessages.stream;

  static Future<bool> initialize({required String appRole}) async {
    if (!const {'customer', 'driver', 'admin'}.contains(appRole)) {
      throw ArgumentError.value(appRole, 'appRole', 'Unsupported Quick-Ride app role');
    }
    // Local inbox hydration is not required for app startup.
    unawaited(_loadInbox());
    if (_initialized) return true;
    if (!QuickRideBackend.isInitialized) return false;

    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if (apiKey.isEmpty || appId.isEmpty || senderId.isEmpty || projectId.isEmpty) {
      debugPrint('Quick-Ride push notifications are not configured for this build.');
      return false;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: apiKey,
            appId: appId,
            messagingSenderId: senderId,
            projectId: projectId,
          ),
        );
      }

      _appRole = appRole;
      _messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(quickRideFirebaseBackgroundHandler);

      // firebase_messaging 17 registers a Firebase Installation ID (FID).
      // The server sends this through FCM HTTP v1's message.fid target.
      // ignore: deprecated_member_use
      _tokenSubscription ??= _messaging!.onRegistered.listen((installationId) {
        _currentInstallationId = installationId;
        final user = QuickRideBackend.client.auth.currentUser;
        if (user != null) {
          unawaited(_saveToken(user.id, installationId));
        }
      });
      _unregisteredSubscription ??=
          _messaging!.onUnregistered.listen((installationId) {
        _currentInstallationId = null;
        if (!QuickRideBackend.isInitialized) return;
        unawaited(
          QuickRideBackend.client
              .from('device_push_tokens')
              .delete()
              .eq('token', installationId),
        );
      });

      _openedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
        _openedMessages.add,
      );
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen(
        _foregroundMessages.add,
      );
      _initialMessage = await _messaging!.getInitialMessage()
          .timeout(const Duration(seconds: 4), onTimeout: () => null);

      _authSubscription ??= QuickRideBackend.client.auth.onAuthStateChange.listen(
        (state) {
          final user = state.session?.user;
          if (user != null) {
            unawaited(_registerToken());
          }
        },
      );
      _initialized = true;
      final user = QuickRideBackend.client.auth.currentUser;
      // Permission prompts and FID registration must never block startup.
      if (user != null) unawaited(_registerToken());
      return true;
    } catch (error, stack) {
      debugPrint('Quick-Ride push initialization failed: $error\n$stack');
      return false;
    }
  }

  static Future<String?> requestPermission() async {
    final messaging = _messaging;
    if (messaging == null) return null;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus.name;
  }

  static Future<void> _loadInbox() async {
    if (_inboxLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final values = prefs.getStringList('quick_ride_notification_inbox') ?? const [];
    final messages = <Map<String, dynamic>>[];
    for (final value in values) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) messages.add(Map<String, dynamic>.from(decoded));
      } catch (_) {
        // Ignore one damaged local entry without losing the rest of the inbox.
      }
    }
    inbox.value = messages.take(50).toList(growable: false);
    _inboxLoaded = true;
  }

  static Future<void> _saveInbox() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'quick_ride_notification_inbox',
      inbox.value.map(jsonEncode).toList(growable: false),
    );
  }

  static Future<void> recordMessage(RemoteMessage message) async {
    await _loadInbox();
    final id = message.messageId ??
        '${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}-${message.hashCode}';
    final data = Map<String, dynamic>.from(message.data);
    final entry = <String, dynamic>{
      'id': id,
      'title': message.notification?.title ?? 'Quick Ride',
      'body': message.notification?.body ?? 'You have an update.',
      'data': data,
      'received_at': DateTime.now().toIso8601String(),
      'is_read': false,
    };
    inbox.value = [
      entry,
      ...inbox.value.where((item) => item['id'] != id),
    ].take(50).toList(growable: false);
    await _saveInbox();
  }

  static Future<void> markRead(String id) async {
    await _loadInbox();
    inbox.value = inbox.value
        .map((item) => item['id'] == id
            ? <String, dynamic>{...item, 'is_read': true}
            : item)
        .toList(growable: false);
    await _saveInbox();
  }

  static Future<void> clearInbox() async {
    inbox.value = const [];
    _inboxLoaded = true;
    await _saveInbox();
  }

  static Future<RemoteMessage?> consumeInitialMessage() async {
    final value = _initialMessage;
    _initialMessage = null;
    return value;
  }

  static Future<void> _registerToken() async {
    final messaging = _messaging;
    if (messaging == null || !QuickRideBackend.isInitialized) return;
    try {
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return;
      }
      // Firebase Messaging 17 registers the FID. The send-push Edge Function
      // persists and uses this FID with the FCM HTTP v1 message.fid target.
      await messaging.register();
    } catch (error) {
      debugPrint('Quick-Ride could not register this device for push: $error');
    }
  }

  static Future<void> _saveToken(String userId, String token) async {
    if (!QuickRideBackend.isInitialized || _appRole == null) return;
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    try {
      await QuickRideBackend.client.from('device_push_tokens').upsert({
        'user_id': userId,
        'token': token,
        'app_role': _appRole,
        'platform': platform,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');
      debugPrint('Alvzyo push installation registered for app role: $_appRole');
    } catch (error) {
      debugPrint('Alvzyo push installation could not be saved for $_appRole: $error');
    }
  }

  static Future<void> unregisterCurrentDevice() async {
    if (!_initialized || !QuickRideBackend.isInitialized) return;
    final user = QuickRideBackend.client.auth.currentUser;
    if (user == null) return;
    try {
      // ignore: deprecated_member_use
      final installationId = _currentInstallationId;
      if (installationId == null) return;
      await QuickRideBackend.client
          .from('device_push_tokens')
          .delete()
          .eq('user_id', user.id)
          .eq('token', installationId);
      await _messaging?.unregister();
      _currentInstallationId = null;
    } catch (error) {
      debugPrint('Quick-Ride could not unregister this device: $error');
    }
  }

  static Future<void> dispose() async {
    await _authSubscription?.cancel();
    await _tokenSubscription?.cancel();
    await _unregisteredSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    _authSubscription = null;
    _tokenSubscription = null;
    _unregisteredSubscription = null;
    _currentInstallationId = null;
    _openedSubscription = null;
    _foregroundSubscription = null;
    _messaging = null;
    _appRole = null;
    _initialized = false;
  }
}
