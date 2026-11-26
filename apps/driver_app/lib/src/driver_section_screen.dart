import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quick_ride_notifications/quick_ride_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_ride_auth/quick_ride_auth.dart';
import 'package:quick_ride_backend/quick_ride_backend.dart';
import 'driver_bottom_navigation.dart';
import 'driver_theme.dart';

class DriverSectionScreen extends StatefulWidget {
  const DriverSectionScreen({super.key, required this.section});
  final String section;

  @override
  State<DriverSectionScreen> createState() => _DriverSectionScreenState();
}

class _DriverSectionScreenState extends State<DriverSectionScreen> {
  late Future<dynamic> _data;
  bool _signInBusy = false;
  ThemeMode _themeMode = DriverThemeController.mode.value;
  bool _notificationsBusy = false;
  bool _deletingAccount = false;
  String _notificationStatus = 'Not checked';
  String _locationStatus = 'Not checked';

  static const _copy = <String, ({String title, String intro, List<String> details})>{
    'rides': (
      title: 'My rides',
      intro: 'Review your recent and active driver trips.',
      details: ['Active trips', 'Completed trips', 'Ride status and fare history'],
    ),
    'earnings': (
      title: 'Earnings',
      intro: 'Review completed-trip earnings and settlement information.',
      details: ['Completed ride earnings', 'Payment and settlement records', 'Recent earnings summary'],
    ),
    'documents': (
      title: 'Documents',
      intro: 'Manage the verification documents required before going online.',
      details: ['Driving licence', 'Vehicle registration certificate', 'Vehicle insurance'],
    ),
    'profile': (
      title: 'Driver profile',
      intro: 'Your driver and vehicle details are used for verification and ride operations.',
      details: ['Driver verification status', 'Registered vehicle details', 'Approved service area'],
    ),
    'settings': (
      title: 'Settings',
      intro: 'Manage the preferences used by Alvzyo Driver.',
      details: ['Notification and sound preferences', 'Location permission and GPS', 'Account security and sign-out'],
    ),
    'support': (
      title: 'Help & support',
      intro: 'Guidance for using Alvzyo Driver.',
      details: ['Keep GPS and notifications enabled while online', 'Use the ride-linked safety controls during an active trip', 'For account or document problems, use the driver support channel provided by Alvzyo operations'],
    ),
    'privacy': (
      title: 'Privacy policy',
      intro: 'Alvzyo processes driver information to provide and protect driver services.',
      details: [
        'Account and vehicle details are used for driver onboarding and identity verification.',
        'Location is shared while online and during active trips to support dispatch, navigation and customer tracking.',
        'Driver documents are stored for verification and reviewed by authorized operations staff.',
        'Ride, fare and settlement records are used for trip history and operational accounting.',
        'Push notification tokens are used for ride offers and account alerts.',
        'Map services process location and route requests to provide maps and directions.',
        'Access to driver records is controlled by authenticated account roles and database policies.',
      ],
    ),
    'terms': (
      title: 'Terms and conditions',
      intro: 'These terms describe the basic conditions for using Alvzyo Driver.',
      details: [
        'Only the verified account holder may use the Driver app to accept and complete rides.',
        'Keep your identity, driving licence, vehicle registration and insurance information accurate and current.',
        'Do not share your account, authentication codes or ride/customer information with unauthorized people.',
        'Go online only when you are available, physically fit to drive and operating within a serviceable area.',
        'Follow applicable traffic laws and use the in-app safety controls when required.',
        'Fares, commissions, subscriptions and settlements are governed by the active commercial rules shown by Alvzyo.',
        'Alvzyo may restrict access when verification, safety or account-security requirements are not met.',
      ],
    ),
    'about': (
      title: 'About Alvzyo Driver',
      intro: 'Alvzyo Driver helps approved driver partners receive, manage and complete customer trips.',
      details: ['Go online only when you are ready to accept requests.', 'Review pickup and fare details before accepting a trip.', 'Keep your vehicle and verification documents up to date.'],
    ),
  };

  @override
  void initState() {
    super.initState();
    _data = _load();
    DriverThemeController.mode.addListener(_syncThemeMode);
    if (widget.section == 'settings') _refreshPermissionStatus();
  }

  void _syncThemeMode() {
    if (mounted) setState(() => _themeMode = DriverThemeController.mode.value);
  }

  @override
  void didUpdateWidget(covariant DriverSectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _data = _load();
      if (widget.section == 'settings') _refreshPermissionStatus();
    }
  }

  @override
  void dispose() {
    DriverThemeController.mode.removeListener(_syncThemeMode);
    super.dispose();
  }

  Future<void> _refreshPermissionStatus() async {
    try {
      final permission = await Geolocator.checkPermission();
      final enabled = await Geolocator.isLocationServiceEnabled();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _locationStatus = enabled ? permission.name : 'GPS disabled';
        _notificationStatus = prefs.getString('alvzyo_driver_notification_status') ?? 'Tap Enable to check';
      });
    } catch (_) {
      if (mounted) setState(() => _locationStatus = 'Unavailable');
    }
  }

  Future<void> _enableNotifications() async {
    if (_notificationsBusy) return;
    setState(() => _notificationsBusy = true);
    try {
      final status = await QuickRideNotifications.requestPermission();
      final value = status ?? 'Unavailable';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('alvzyo_driver_notification_status', value);
      if (mounted) setState(() => _notificationStatus = value);
    } catch (_) {
      if (mounted) setState(() => _notificationStatus = 'Permission request failed');
    } finally {
      if (mounted) setState(() => _notificationsBusy = false);
    }
  }

  Future<void> _openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete your Alvzyo account?'),
        content: const Text('This permanently blocks sign-in. If your account has ride, payment, safety or support history, those records are retained where required and your personal profile is anonymized. This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete account')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deletingAccount = true);
    try {
      await QuickRideBackend.invoke('delete-account', body: const {});
      await QuickRideAuth.signOut();
      if (mounted) context.go('/');
    } catch (error) {
      if (mounted) {
        final details = error.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account deletion could not be completed: ${details.length > 150 ? details.substring(0, 150) : details}')));
      }
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  Future<void> _signIn() async {
    if (!QuickRideBackend.isInitialized || _signInBusy) return;
    setState(() => _signInBusy = true);
    try {
      await QuickRideAuth.signInWithGoogle(
        redirectTo: 'com.alvzyo.ride.driver://login-callback',
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

  Future<dynamic> _load() async {
    if (!QuickRideBackend.isInitialized || QuickRideAuth.currentUser == null) {
      return null;
    }
    final user = QuickRideAuth.currentUser!;
    switch (widget.section) {
      case 'rides':
        return QuickRideBackend.client
            .from('rides')
            .select('id,status,estimated_fare,final_fare,created_at')
            .eq('driver_id', user.id)
            .order('created_at', ascending: false)
            .limit(50);
      case 'profile':
        final rows = await Future.wait([
          QuickRideBackend.client.from('profiles')
              .select('full_name,phone_e164,account_status').eq('id', user.id).maybeSingle(),
          QuickRideBackend.client.from('driver_profiles')
              .select('verification_status,vehicle_make,vehicle_model,vehicle_registration,vehicle_color,active_pincode_id')
              .eq('user_id', user.id).maybeSingle(),
        ]);
        return {'profile': rows[0], 'driver': rows[1]};
      case 'documents':
        final response = await QuickRideBackend.invoke(
          'driver-ride-actions',
          body: const {'action': 'list_documents'},
        );
        return response.data;
      case 'earnings':
        final response = await QuickRideBackend.invoke(
          'driver-ride-actions',
          body: const {'action': 'get_earnings'},
        );
        return response.data;
      default:
        return null;
    }
  }

  String _money(dynamic value) {
    final number = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    return number == null ? '—' : '₹' + number.toStringAsFixed(2);
  }

  Widget _liveContent(dynamic value) {
    switch (widget.section) {
      case 'rides':
        final rows = value is List ? value : const [];
        if (rows.isEmpty) return const Text('No rides found for this account yet.');
        return Column(
          children: rows.map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = row['id'].toString();
            return Card(
              child: ListTile(
                leading: const Icon(Icons.route_outlined),
                title: Text('Ride ' + id.substring(0, id.length < 8 ? id.length : 8)),
                subtitle: Text(row['status'].toString().replaceAll('_', ' ')),
                trailing: Text(_money(row['final_fare'] ?? row['estimated_fare'])),
              ),
            );
          }).toList(),
        );
      case 'profile':
        if (value is! Map) return const Text('Driver profile has not been created yet.');
        final profile = Map<String, dynamic>.from(value['profile'] as Map? ?? const {});
        final row = Map<String, dynamic>.from(value['driver'] as Map? ?? const {});
        final user = QuickRideAuth.currentUser;
        return Column(
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                    title: Text((profile['full_name'] ?? user?.userMetadata?['full_name'] ?? 'Driver partner').toString()),
                    subtitle: Text(user?.email ?? 'Email unavailable'),
                  ),
                  ListTile(title: const Text('Phone'), subtitle: Text((profile['phone_e164'] ?? 'Not provided').toString())),
                  ListTile(title: const Text('Account status'), subtitle: Text((profile['account_status'] ?? 'active').toString())),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  ListTile(title: const Text('Driver verification'), subtitle: Text((row['verification_status'] ?? 'not submitted').toString())),
                  ListTile(title: const Text('Vehicle'), subtitle: Text([row['vehicle_make'], row['vehicle_model']].where((v) => v != null).join(' ').trim().isEmpty ? 'Not provided' : [row['vehicle_make'], row['vehicle_model']].where((v) => v != null).join(' '))),
                  ListTile(title: const Text('Registration'), subtitle: Text((row['vehicle_registration'] ?? 'Not provided').toString())),
                  ListTile(title: const Text('Colour'), subtitle: Text((row['vehicle_color'] ?? 'Not provided').toString())),
                ],
              ),
            ),
          ],
        );
      case 'documents':
        final data = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
        final docs = data['documents'] as List<dynamic>? ?? [];
        if (docs.isEmpty) return const Text('No driver documents have been uploaded yet.');
        return Column(
          children: docs.map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            return Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(row['document_type'].toString().replaceAll('_', ' ')),
                subtitle: Text((row['verification_status'] ?? 'pending').toString().replaceAll('_', ' ')),
              ),
            );
          }).toList(),
        );
      case 'earnings':
        final data = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
        final totals = data['totals'] as Map<String, dynamic>? ?? {};
        final inr = totals['INR'] as Map<String, dynamic>? ?? {};
        return Card(
          child: Column(
            children: [
              ListTile(title: const Text('Completed rides'), trailing: Text((data['completed_ride_count'] ?? 0).toString())),
              ListTile(title: const Text('Total earnings'), trailing: Text(_money(inr['after_commission'] ?? inr['gross_fare']))),
              ListTile(title: const Text('Recent rides'), trailing: Text((data['recent_window_ride_count'] ?? 0).toString())),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

    Widget _settingsContent() => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('App preferences', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: DropdownButtonFormField<ThemeMode>(
                initialValue: _themeMode,
                decoration: const InputDecoration(labelText: 'App theme', border: InputBorder.none),
                items: const [
                  DropdownMenuItem(value: ThemeMode.system, child: Text('System default')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _themeMode = value);
                  await DriverThemeController.set(value);
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Permissions', style: Theme.of(context).textTheme.titleLarge),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Push notifications'),
                  subtitle: Text(_notificationStatus),
                  trailing: _notificationsBusy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(onPressed: _enableNotifications, child: const Text('Enable')),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: const Text('Location and GPS'),
                  subtitle: Text(_locationStatus),
                  trailing: TextButton(onPressed: _refreshPermissionStatus, child: const Text('Refresh')),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_applications_outlined),
                  title: const Text('Open device app settings'),
                  onTap: _openAppSettings,
                ),
                ListTile(
                  leading: const Icon(Icons.my_location_outlined),
                  title: const Text('Open GPS settings'),
                  onTap: Geolocator.openLocationSettings,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('Account security', style: Theme.of(context).textTheme.titleLarge),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.logout_rounded),
                  title: const Text('Log out'),
                  onTap: () async {
                    await QuickRideAuth.signOut();
                    if (mounted) context.go('/');
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                  title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  subtitle: const Text('Permanently block sign-in and request account deletion'),
                  trailing: _deletingAccount ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                  onTap: _deletingAccount ? null : _deleteAccount,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('Information', style: Theme.of(context).textTheme.titleLarge),
          Card(
            child: Column(
              children: [
                ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: const Text('Privacy policy'), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/section/privacy')),
                ListTile(leading: const Icon(Icons.article_outlined), title: const Text('Terms and conditions'), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/section/terms')),
                ListTile(leading: const Icon(Icons.info_outline), title: const Text('About Alvzyo Driver'), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/section/about')),
                ListTile(leading: const Icon(Icons.support_agent_outlined), title: const Text('Help and support'), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/section/support')),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Center(child: Text('Alvzyo Driver', style: TextStyle(fontWeight: FontWeight.w600))),
          const Center(child: Text('Driver partner app')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final page = _copy[widget.section] ?? _copy['about']!;
    final signedIn = QuickRideBackend.isInitialized && QuickRideAuth.currentUser != null;
    final needsData = const {'rides', 'earnings', 'documents', 'profile'}.contains(widget.section);
    final selectedTab = switch (widget.section) {
      'rides' => 1,
      'earnings' => 2,
      'profile' => 3,
      _ => 3,
    };
    return Scaffold(
      bottomNavigationBar: DriverBottomNavigationBar(currentIndex: selectedTab),
      appBar: AppBar(
        title: Text(page.title),
      ),
      body: widget.section == 'settings' ? _settingsContent() : ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(page.intro, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          if (needsData && signedIn)
            FutureBuilder<dynamic>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  ));
                }
                if (snapshot.hasError) {
                  return const Text('This information is temporarily unavailable. Please try again.');
                }
                return _liveContent(snapshot.data);
              },
            )
          else if (needsData)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Preview mode · Sign in to view your private ' + page.title.toLowerCase() + ' information.'),
              ),
            ),
          if (!needsData || !signedIn || widget.section == 'settings' || widget.section == 'support' || widget.section == 'privacy' || widget.section == 'about') ...[
            ...page.details.map((detail) => Padding(
                  padding: const EdgeInsets.only(bottom: 13),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 19),
                      const SizedBox(width: 10),
                      Expanded(child: Text(detail)),
                    ],
                  ),
                )),
          ],
          if (widget.section == 'profile') ...[
            const SizedBox(height: 18),
            Text('App information', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Documents'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/section/documents'),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/section/settings'),
            ),
            ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('Help & support'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/section/support'),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy policy'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/section/privacy'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('About Alvzyo Driver'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/section/about'),
            ),
          ],
          if (!signedIn && needsData)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.icon(
                onPressed: QuickRideBackend.isInitialized && !_signInBusy ? _signIn : null,
                icon: _signInBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login_rounded),
                label: Text(_signInBusy ? 'Signing in…' : 'Sign in with Google'),
              ),
            ),
        ],
      ),
    );
  }
}
