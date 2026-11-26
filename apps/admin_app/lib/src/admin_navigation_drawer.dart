import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'admin_bottom_navigation.dart';
import 'admin_access.dart';

class AdminNavigationDrawer extends StatelessWidget {
  const AdminNavigationDrawer({super.key});

  Widget _entry(
    BuildContext context,
    IconData icon,
    String label,
    String route,
  ) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () {
          final router = GoRouter.of(context);
          Navigator.of(context).pop();
          router.push(route);
        },
      );

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFF173B2D)),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  'Alvzyo Admin',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            _entry(context, Icons.dashboard_outlined, 'Dashboard', '/dashboard'),
            _entry(context, Icons.monitor_heart_outlined, 'Operations', '/operations'),
            _entry(context, Icons.location_city_outlined, 'Service areas & fares', '/service-areas'),
            _entry(context, Icons.notifications_active_outlined, 'Notifications', '/notifications'),
            const Divider(),
            _entry(context, Icons.admin_panel_settings_outlined, 'Control centre', '/info/profile'),
            _entry(context, Icons.settings_outlined, 'Settings', '/info/settings'),
            _entry(context, Icons.support_agent_outlined, 'Help & support', '/info/support'),
            _entry(context, Icons.privacy_tip_outlined, 'Privacy policy', '/info/privacy'),
            _entry(context, Icons.info_outline_rounded, 'About Alvzyo Admin', '/info/about'),
            const Divider(),
            if (user == null)
              ListTile(
                leading: const Icon(Icons.login_rounded),
                title: const Text('Sign in with Google'),
                enabled: QuickRideBackend.isInitialized,
                onTap: !QuickRideBackend.isInitialized
                    ? null
                    : () async {
                        Navigator.of(context).pop();
                        try {
                          await AdminAccess.signIn();
                        } catch (error) {
                          if (context.mounted) {
                            final details = error.toString();
                            final safeDetails = details.length > 140
                                ? details.substring(0, 140)
                                : details;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Admin sign-in failed: $safeDetails')),
                            );
                          }
                        }
                      },
              )
            else
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Log out'),
                onTap: () {
                  Navigator.of(context).pop();
                  QuickRideAuth.signOut();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class AdminInfoScreen extends StatelessWidget {
  const AdminInfoScreen({super.key, required this.section});
  final String section;

  @override
  Widget build(BuildContext context) {
    if (section == 'profile') return const AdminControlCenterScreen();
    final pages = <String, ({String title, String intro, List<String> points})>{
      'profile': (
        title: 'Admin profile',
        intro: 'Administrator access is limited to approved accounts and verified server-side roles.',
        points: [
          'Signed-in account: ${QuickRideAuth.currentUser?.email ?? 'Not signed in'}',
          'Only authorized administrator accounts can perform live management actions.',
          'Read-only exploration does not grant access to customer, driver or financial records.',
        ],
      ),
      'settings': (
        title: 'Settings',
        intro: 'Administrative preferences and platform controls.',
        points: [
          'Platform configuration is managed from the authenticated Operations Centre.',
          'Changes to fares, service areas, driver approvals and dispatch settings are audited.',
          'Sign out when using a shared device.',
        ],
      ),
      'support': (
        title: 'Help & support',
        intro: 'Use the Operations Centre to review support tickets and operational issues.',
        points: [
          'Customer and driver support requests are linked to their ride where available.',
          'Safety events must be reviewed carefully; recording a review does not contact emergency services.',
          'Live support actions require an authorized administrator session.',
        ],
      ),
      'privacy': (
        title: 'Privacy policy',
        intro: 'Alvzyo uses information needed to provide and protect ride services.',
        points: [
          'Account details are used for sign-in, account security and service communication.',
          'Location is used to set pickup points, calculate routes and support active-trip tracking.',
          'Ride details, service selections and transaction records are used for booking, support and operational records.',
          'Driver applicants may submit vehicle and verification documents for review.',
          'Push notification tokens are used to deliver ride and account alerts.',
          'Map services process location and route requests to display maps and calculate directions.',
          'Access to operational records is restricted by authenticated roles and database access policies.',
          'Users can request account deletion through the supported account controls; certain records may be retained where legally or operationally required.',
        ],
      ),
      'about': (
        title: 'About Alvzyo Admin',
        intro: 'Alvzyo is a ride-booking platform connecting customers with independent driver partners.',
        points: [
          'Customer, Driver and Admin apps share the same protected ride and service infrastructure.',
          'Service availability and vehicle categories depend on the configured operating area.',
          'Displayed fares and availability are refreshed from the live booking service.',
        ],
      ),
    };
    final page = pages[section] ?? pages['about']!;
    const selectedTab = 4;
    return Scaffold(
      bottomNavigationBar: AdminBottomNavigationBar(currentIndex: selectedTab),
      appBar: AppBar(
        title: Text(page.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(page.intro, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          ...page.points.map((point) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline_rounded, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(point)),
                  ],
                ),
              )),
          if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Preview mode · Live administrative information and actions require an authorized sign-in.'),
            ),
        ],
      ),
    );
  }
}

class AdminControlCenterScreen extends StatefulWidget {
  const AdminControlCenterScreen({super.key});

  @override
  State<AdminControlCenterScreen> createState() => _AdminControlCenterScreenState();
}

class _AdminControlCenterScreenState extends State<AdminControlCenterScreen> {
  late Future<bool> _authorization;
  bool _signingIn = false;

  @override
  void initState() {
    super.initState();
    _authorization = AdminAccess.verify();
  }

  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    try {
      await AdminAccess.signIn();
      if (mounted) setState(() => _authorization = AdminAccess.verify());
    } catch (error) {
      if (mounted) {
        final details = error.toString().replaceFirst('Bad state: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(details.length > 180 ? details.substring(0, 180) : details)),
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Widget _shortcut(BuildContext context, IconData icon, String title,
      String subtitle, String route) => Card(
        child: ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(route),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final user = QuickRideAuth.currentUser;
    return Scaffold(
      drawer: const AdminNavigationDrawer(),
      appBar: AppBar(
        title: const Text('Admin control centre'),
        actions: [
          IconButton(
            tooltip: 'Recheck administrator access',
            onPressed: () => setState(() => _authorization = AdminAccess.verify()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: const AdminBottomNavigationBar(currentIndex: 4),
      body: FutureBuilder<bool>(
        future: _authorization,
        builder: (context, snapshot) {
          final authorized = snapshot.data == true;
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const CircleAvatar(radius: 28, child: Icon(Icons.admin_panel_settings_outlined, size: 30)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Platform administrator', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text(user?.email ?? 'No administrator account signed in'),
                            const SizedBox(height: 6),
                            Text(
                              snapshot.connectionState == ConnectionState.waiting
                                  ? 'Checking server authorization…'
                                  : authorized
                                      ? 'Authorized administrator'
                                      : snapshot.hasError
                                          ? 'Unable to verify Admin access. Check your connection and retry.'
                                          : user == null
                                              ? 'Sign in with the approved administrator account'
                                              : 'This account is not authorized for Admin operations',
                              style: TextStyle(
                                color: authorized ? Colors.green : Theme.of(context).colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('Platform management', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              _shortcut(context, Icons.monitor_heart_outlined, 'Operations centre', 'Driver reviews, rides, support and safety queues', '/operations'),
              _shortcut(context, Icons.location_city_outlined, 'Service areas and fares', 'Operating areas, pincode boundaries, vehicle categories and fare rules', '/service-areas'),
              _shortcut(context, Icons.notifications_active_outlined, 'Notification control', 'Send test messages and review delivery results', '/notifications'),
              const SizedBox(height: 18),
              Text('Security and account', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.verified_user_outlined),
                      title: Text('Server-side role enforcement'),
                      subtitle: Text('Admin actions require an active Admin role in Supabase. Google sign-in alone does not grant access.'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.manage_accounts_outlined),
                      title: const Text('Authorized account'),
                      subtitle: Text(user?.email ?? 'Not signed in'),
                    ),
                    if (!authorized)
                      ListTile(
                        leading: const Icon(Icons.login_rounded),
                        title: Text(_signingIn ? 'Verifying account…' : snapshot.hasError ? 'Retry authorization check' : 'Sign in with approved Admin account'),
                        onTap: _signingIn
                            ? null
                            : snapshot.hasError
                                ? () => setState(() => _authorization = AdminAccess.verify())
                                : _signIn,
                      )
                    else
                      ListTile(
                        leading: const Icon(Icons.logout_rounded),
                        title: const Text('Sign out'),
                        onTap: () async {
                          await QuickRideAuth.signOut();
                          if (mounted) setState(() => _authorization = AdminAccess.verify());
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('Platform information', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              _shortcut(context, Icons.support_agent_outlined, 'Help and support', 'Operational support and issue handling', '/info/support'),
              _shortcut(context, Icons.privacy_tip_outlined, 'Privacy policy', 'How Alvzyo protects account and ride information', '/info/privacy'),
              _shortcut(context, Icons.info_outline, 'About Alvzyo Admin', 'Platform and Admin app information', '/info/about'),
            ],
          );
        },
      ),
    );
  }
}
