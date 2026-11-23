import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class DriverBottomNavigationBar extends StatelessWidget {
  const DriverBottomNavigationBar({super.key, required this.currentIndex});

  final int currentIndex;

  static const _routes = <String>[
    '/',
    '/section/rides',
    '/section/earnings',
    '/section/profile',
  ];

  @override
  Widget build(BuildContext context) => NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) => context.go(_routes[index]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'My Rides'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Earnings'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      );
}
