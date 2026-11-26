import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_core/quick_ride_core.dart';
import 'package:quick_ride_design_system/quick_ride_design_system.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';

import 'src/home_screen.dart';
import 'src/navigation_screen.dart';
import 'src/offer_screen.dart';
import 'src/driver_section_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: QuickRideDriverBootstrap()));
}

class QuickRideDriverBootstrap extends StatefulWidget {
  const QuickRideDriverBootstrap({super.key});

  @override
  State<QuickRideDriverBootstrap> createState() =>
      _QuickRideDriverBootstrapState();
}

class _QuickRideDriverBootstrapState extends State<QuickRideDriverBootstrap> {
  bool _ready = false;
  String? _startupError;
  StreamSubscription<dynamic>? _openedSubscription;
  StreamSubscription<dynamic>? _foregroundSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      QuickRideMaps.configure();
      final environment = QuickRideEnvironment.fromBuildDefines();
      await QuickRideBackend.initialize(environment);
      if (QuickRideBackend.isInitialized) {
        // FCM setup is optional and must not delay the driver's ride screen.
        unawaited(_initializePushNotifications());
      }
    } catch (error) {
      debugPrint('Alvzyo Driver startup failed (' + error.runtimeType.toString() + ').');
      _startupError = 'Connection unavailable. Preview mode is active.';
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }


  Future<void> _initializePushNotifications() async {
    try {
      await QuickRideNotifications.initialize(appRole: 'driver')
          .timeout(const Duration(seconds: 8));
      if (!QuickRideBackend.isInitialized) return;
      QuickRideAuth.beforeSignOutCleanup =
          QuickRideNotifications.unregisterCurrentDevice;
      _openedSubscription =
          QuickRideNotifications.openedMessages.listen(_handleOpenedMessage);
      _foregroundSubscription =
          QuickRideNotifications.foregroundMessages.listen(_handleForegroundMessage);
      final initial = await QuickRideNotifications.consumeInitialMessage()
          .timeout(const Duration(seconds: 3));
      if (initial != null) _handleOpenedMessage(initial);
    } catch (error) {
      debugPrint('Driver push setup deferred (${error.runtimeType}).');
    }
  }

  void _openMessage(dynamic message) {
    final data = message.data;
    final offerId = data['offer_id'];
    if (data['type'] == 'ride_offer' &&
        offerId is String &&
        offerId.isNotEmpty) {
      QuickRideDriverApp.router.go('/offer/${Uri.encodeComponent(offerId)}');
      return;
    }
    final rideId = data['ride_id'];
    if (rideId is String && rideId.isNotEmpty) {
      QuickRideDriverApp.router.go(
        '/ride/${Uri.encodeComponent(rideId)}/navigation',
      );
    }
  }

  void _handleOpenedMessage(dynamic message) {
    unawaited(QuickRideNotifications.recordMessage(message));
    WidgetsBinding.instance.addPostFrameCallback((_) => _openMessage(message));
  }

  void _handleForegroundMessage(dynamic message) {
    unawaited(QuickRideNotifications.recordMessage(message));
    final isRideOffer = message.data['type'] == 'ride_offer';
    if (isRideOffer) {
      unawaited(SystemSound.play(SystemSoundType.alert));
    }
    final notification = message.notification;
    if (notification == null) return;
    QuickRideDriverApp.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          '${notification.title ?? 'Alvzyo'}\n'
          '${notification.body ?? 'You have an update.'}',
        ),
        action: SnackBarAction(
          label: isRideOffer ? 'VIEW OFFER' : 'OPEN',
          onPressed: () => _openMessage(message),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  void dispose() {
    _openedSubscription?.cancel();
    _foregroundSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return MaterialApp(
        title: 'Alvzyo Driver',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 14),
                Text('Starting Alvzyo Driver…'),
              ],
            ),
          ),
        ),
      );
    }
    if (_startupError != null && !QuickRideBackend.isInitialized) {
      debugPrint('Driver app continues in preview mode: $_startupError');
    }
    return const QuickRideDriverApp();
  }
}

class QuickRideDriverApp extends StatelessWidget {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  const QuickRideDriverApp({super.key});

  static final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const DriverHomeScreen()),
    GoRoute(
      path: '/section/:section',
      builder: (_, state) => DriverSectionScreen(
        section: state.pathParameters['section'] ?? 'about',
      ),
    ),
    GoRoute(
      path: '/offer/:offerId',
      builder: (_, state) => DriverOfferScreen(
        offerId: state.pathParameters['offerId']!,
      ),
    ),
    GoRoute(
      path: '/ride/:rideId/navigation',
      builder: (_, state) => DriverRideNavigationScreen(
        rideId: state.pathParameters['rideId']!,
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        scaffoldMessengerKey: messengerKey,
        title: 'Alvzyo Driver',
        theme: QuickRideTheme.light(),
        darkTheme: QuickRideTheme.dark(),
        routerConfig: router,
      );
}
