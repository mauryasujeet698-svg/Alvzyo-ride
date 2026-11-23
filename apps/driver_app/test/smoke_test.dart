import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_ride_maps/quick_ride_maps.dart';
import 'package:quick_ride_driver/src/home_screen.dart';

void main() {
  testWidgets('captain can explore the read-only preview before backend setup',
      (tester) async {
    QuickRideMaps.mapWidgetOverride = (_, __) => const ColoredBox(
          key: ValueKey('alvzyo-driver-map-test-placeholder'),
          color: Colors.transparent,
        );
    addTearDown(() {
      QuickRideMaps.mapWidgetOverride = null;
    });

    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen()));
    await tester.pump();

    expect(find.text('Alvzyo Driver'), findsOneWidget);
    expect(find.text('Ready to accept rides?'), findsNothing);
    expect(find.textContaining('Preview mode · Read only'), findsNothing);
    expect(find.byKey(const ValueKey('alvzyo-driver-map-test-placeholder')), findsOneWidget);
    expect(find.text('Sign in to go online and receive nearby ride requests.'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('My Rides'), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('Quick-Ride backend is not configured.'), findsNothing);
  });
}
