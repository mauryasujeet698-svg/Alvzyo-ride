import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'src/admin_home_screen.dart';
import 'src/admin_dashboard_screen.dart';
import 'src/operations_screen.dart';
import 'src/notification_center_screen.dart';
import 'src/admin_navigation_drawer.dart';
import 'src/admin_access.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Render Flutter immediately. Backend/plugin startup must never leave the
  // Android launch window sitting on a blank screen.
  runApp(const ProviderScope(child: QuickRideAdminBootstrap()));
}

class QuickRideAdminBootstrap extends StatefulWidget {
  const QuickRideAdminBootstrap({super.key});

  @override
  State<QuickRideAdminBootstrap> createState() =>
      _QuickRideAdminBootstrapState();
}

class _QuickRideAdminBootstrapState extends State<QuickRideAdminBootstrap> {
  bool _ready = false;
  bool _busy = true;
  String? _error;
  StreamSubscription<dynamic>? _openedSubscription;
  StreamSubscription<dynamic>? _foregroundSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }

    try {
      final environment = QuickRideEnvironment.fromBuildDefines();
      await QuickRideBackend.initialize(environment);
      if (!QuickRideBackend.isInitialized) {
        throw StateError(
          'Alvzyo could not initialize its backend. Check the app configuration and try again.',
        );
      }

      // Existing sessions are rechecked against the protected Admin API.
      // A non-Admin Google account is signed out before the Admin UI loads.
      if (QuickRideAuth.currentUser != null) {
        try {
          if (!await AdminAccess.verify()) await QuickRideAuth.signOut();
        } catch (error) {
          debugPrint('Admin role check deferred (${error.runtimeType}).');
        }
      }

      // Show the dashboard as soon as Supabase is ready. FCM startup is
      // independent and runs in the background.
      unawaited(_initializePushNotifications());
      if (mounted) {
        setState(() {
          _ready = true;
          _busy = false;
        });
      }
    } catch (error) {
      debugPrint('Alvzyo Admin startup failed (' + error.runtimeType.toString() + ').');
      if (mounted) {
        setState(() {
          // Keep the complete read-only Admin preview navigable even if the
          // backend is temporarily unavailable. Live actions remain protected.
          _error = 'Connection unavailable. You can still explore Admin in read-only mode.';
          _ready = true;
          _busy = false;
        });
      }
    }
  }


  Future<void> _initializePushNotifications() async {
    try {
      await QuickRideNotifications.initialize(appRole: 'admin')
          .timeout(const Duration(seconds: 8));
      if (!QuickRideBackend.isInitialized) return;
      QuickRideAuth.beforeSignOutCleanup =
          QuickRideNotifications.unregisterCurrentDevice;
      await _openedSubscription?.cancel();
      _openedSubscription =
          QuickRideNotifications.openedMessages.listen((message) {
        unawaited(QuickRideNotifications.recordMessage(message));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          QuickRideAdminApp.router.go('/operations');
        });
      });
      await _foregroundSubscription?.cancel();
      _foregroundSubscription =
          QuickRideNotifications.foregroundMessages.listen((message) {
        unawaited(QuickRideNotifications.recordMessage(message));
        final notification = message.notification;
        if (notification == null) return;
        QuickRideAdminApp.messengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              '${notification.title ?? 'Alvzyo'}\n'
              '${notification.body ?? 'You have an operations update.'}',
            ),
            action: SnackBarAction(
              label: 'OPEN',
              onPressed: () => QuickRideAdminApp.router.go('/operations'),
            ),
          ),
        );
      });
      final initial = await QuickRideNotifications.consumeInitialMessage()
          .timeout(const Duration(seconds: 3));
      if (initial != null) {
        unawaited(QuickRideNotifications.recordMessage(initial));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          QuickRideAdminApp.router.go('/operations');
        });
      }
    } catch (error) {
      debugPrint('Admin push setup deferred (${error.runtimeType}).');
    }
  }

  @override
  void dispose() {
    _openedSubscription?.cancel();
    _foregroundSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const QuickRideAdminApp();

    return MaterialApp(
      title: 'Alvzyo Admin',
      theme: QuickRideTheme.light(),
      darkTheme: QuickRideTheme.dark(),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.admin_panel_settings_outlined, size: 52),
                    const SizedBox(height: 20),
                    Text(
                      _error == null
                          ? 'Starting Alvzyo Admin'
                          : 'Admin could not start',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    if (_busy) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      const Text('Connecting securely to Alvzyo…'),
                    ] else ...[
                      Text(
                        _error ?? 'Something went wrong during startup.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _initialize,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class QuickRideAdminApp extends StatelessWidget {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  const QuickRideAdminApp({super.key});

  static final router = GoRouter(
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Admin page unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: const Text('This Admin page could not be opened. Return to the dashboard and try again.', textAlign: TextAlign.center),
        ),
      ),
    ),
    routes: [
    GoRoute(path: '/', builder: (_, __) => const AdminDashboardScreen()),
    GoRoute(path: '/dashboard', builder: (_, __) => const AdminDashboardScreen()),
    GoRoute(path: '/operations', builder: (_, __) => const AdminOperationsScreen()),
    GoRoute(path: '/service-areas', builder: (_, __) => const AdminHomeScreen()),
    GoRoute(path: '/notifications', builder: (_, __) => const AdminNotificationCenterScreen()),
    GoRoute(
      path: '/info/:section',
      builder: (_, state) => AdminInfoScreen(
        section: state.pathParameters['section'] ?? 'about',
      ),
    ),
    ],
  );

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        scaffoldMessengerKey: messengerKey,
        title: 'Alvzyo Admin',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
