import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AdminBottomNavigationBar extends StatelessWidget {
  const AdminBottomNavigationBar({super.key, required this.currentIndex});

  final int currentIndex;

  static const _routes = <String>[
    '/dashboard',
    '/operations',
    '/service-areas',
    '/notifications',
  ];

  @override
  Widget build(BuildContext context) => NavigationBar(
        selectedIndex: currentIndex.clamp(0, 3),
        onDestinationSelected: (index) => context.go(_routes[index]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), selectedIcon: Icon(Icons.monitor_heart), label: 'Operations'),
          NavigationDestination(icon: Icon(Icons.location_city_outlined), selectedIcon: Icon(Icons.location_city), label: 'Areas'),
          NavigationDestination(icon: Icon(Icons.notifications_outlined), selectedIcon: Icon(Icons.notifications), label: 'Alerts'),
        ],
      );
}