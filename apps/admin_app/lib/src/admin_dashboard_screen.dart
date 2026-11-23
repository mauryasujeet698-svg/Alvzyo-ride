import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';

import 'admin_bottom_navigation.dart';
import 'admin_navigation_drawer.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Map<String, dynamic>? _summary;
  bool _loading = false;
  bool _signInBusy = false;
  String? _message;
  StreamSubscription<dynamic>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (QuickRideBackend.isInitialized) {
      unawaited(_load());
      _authSubscription = QuickRideAuth.authStateChanges.listen((_) {
        if (!mounted) return;
        if (QuickRideAuth.currentUser == null) {
          setState(() {
            _summary = null;
            _message = null;
          });
        } else {
          unawaited(_load());
        }
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      if (mounted) setState(() => _summary = null);
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final response = await QuickRideBackend.invoke(
        'admin-service-areas',
        body: const {'action': 'dashboard_summary'},
      );
      if (!mounted) return;
      setState(() => _summary = Map<String, dynamic>.from(response.data as Map));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _summary = null;
        _message = 'Live dashboard requires an authorized Admin account.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signIn() async {
    if (_signInBusy) return;
    if (!QuickRideBackend.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alvzyo sign-in service is not initialized. Check the connection and app configuration.')),
      );
      return;
    }
    setState(() => _signInBusy = true);
    try {
      await QuickRideAuth.signInWithGoogle(
        redirectTo: 'com.alvzyo.ride.admin://login-callback',
      );
    } catch (error) {
      if (mounted) {
        final details = error.toString();
        final safeDetails = details.length > 180 ? details.substring(0, 180) : details;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google sign-in failed: $safeDetails')),
        );
      }
    } finally {
      if (mounted) setState(() => _signInBusy = false);
    }
  }

  Widget _metric(String label, String value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 24),
              const SizedBox(height: 14),
              Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(label),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final signedIn = QuickRideBackend.isInitialized && QuickRideAuth.currentUser != null;
    return Scaffold(
      drawer: const AdminNavigationDrawer(),
      appBar: AppBar(
        title: const Text('Admin dashboard'),
        actions: [
          if (signedIn)
            IconButton(
              tooltip: 'Refresh dashboard',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            )
          else
            IconButton(
              tooltip: 'Sign in with Google',
              onPressed: _signInBusy ? null : _signIn,
              icon: const Icon(Icons.login_rounded),
            ),
        ],
      ),
      bottomNavigationBar: const AdminBottomNavigationBar(currentIndex: 0),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text('Platform overview', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              summary == null
                  ? 'Explore the Admin app and its navigation without signing in. Live figures are only shown to an authorized administrator.'
                  : 'Live platform figures from the protected Supabase operations service.',
            ),
            if (!signedIn || summary == null) ...[
              const SizedBox(height: 14),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Preview mode · No customer, driver, ride or financial records are exposed in this preview.'),
                ),
              ),
            ],
            if (_loading) const Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: CircularProgressIndicator()),
            ),
            if (_message != null) Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.55,
              children: [
                _metric('Total rides', summary?['rides_total']?.toString() ?? '—', Icons.route_outlined),
                _metric('Active rides', summary?['rides_active']?.toString() ?? '—', Icons.directions_car_outlined),
                _metric('Completed rides', summary?['rides_completed']?.toString() ?? '—', Icons.check_circle_outline),
                _metric('Registered drivers', summary?['drivers_total']?.toString() ?? '—', Icons.people_outline),
                _metric('Pending reviews', summary?['drivers_pending_review']?.toString() ?? '—', Icons.fact_check_outlined),
                _metric('Active pincodes', summary?['pincodes_active']?.toString() ?? '—', Icons.location_on_outlined),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('Operations centre'),
                subtitle: const Text('Driver approvals, rides, support and safety queues'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/operations'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.location_city_outlined),
                title: const Text('Service areas and fares'),
                subtitle: const Text('Pincodes, vehicle categories and commercial rules'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/service-areas'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
