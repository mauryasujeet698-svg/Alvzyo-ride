import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

export 'package:latlong2/latlong.dart';

class _CacheEntry {
  const _CacheEntry(this.value, this.expiresAt);
  final Object? value;
  final DateTime expiresAt;
}

/// OpenStreetMap tiles, Nominatim search/geocoding and OSRM driving routes.
class QuickRideMaps {
  QuickRideMaps._();
  static const defaultLanguage = 'en';
  static const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const _userAgent = 'AlvzyoRide/0.1 (com.alvzyo.ride.customer)';
  static final _http = http.Client();
  static final Map<String, _CacheEntry> _cache = {};
  static final Map<String, Future<dynamic>> _pending = {};
  static DateTime _nextNominatimAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool get isConfigured => true;
  static void configure() {}
  static Widget Function(BuildContext context, QuickRideMapView view)? mapWidgetOverride;

  static Future<T> _remember<T>(String key, Duration ttl, Future<T> Function() load) async {
    final cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) return cached.value as T;
    _cache.remove(key);
    final pending = _pending[key];
    if (pending != null) return await pending as T;
    final future = load();
    _pending[key] = future;
    try {
      final value = await future;
      _cache[key] = _CacheEntry(value, DateTime.now().add(ttl));
      if (_cache.length > 250) {
        _cache.removeWhere((_, entry) => !entry.expiresAt.isAfter(DateTime.now()));
        while (_cache.length > 250) { _cache.remove(_cache.keys.first); }
      }
      return value;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  static Future<void> _nominatimSlot() async {
    final now = DateTime.now();
    final start = _nextNominatimAt.isAfter(now) ? _nextNominatimAt : now;
    _nextNominatimAt = start.add(const Duration(milliseconds: 1100));
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static String? _postal(String value) =>
      RegExp(r'(?<![0-9])[1-9][0-9]{5}(?![0-9])').firstMatch(value)?.group(0);

  static Future<geo.Position> currentPosition() => _remember(
    'device-current-location', const Duration(seconds: 20), () async {
      if (!await geo.Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services are disabled. Enable GPS and try again.');
      }
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever) {
        throw StateError('Location permission was not granted. You can still search for a pickup location.');
      }
      return geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high, timeLimit: Duration(seconds: 15),
        ),
      );
    },
  );

  static Stream<geo.Position> watchDriverPosition() => geo.Geolocator.getPositionStream(
    locationSettings: geo.AndroidSettings(
      accuracy: geo.LocationAccuracy.high, distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const geo.ForegroundNotificationConfig(
        notificationTitle: 'Alvzyo ride Captain location',
        notificationText: 'Location is shared while you are online or completing a ride.',
        enableWakeLock: true,
      ),
    ),
  );

  static Future<List<QuickRideSearchResult>> searchSuggestions({
    required String query, LatLng? proximity, String language = defaultLanguage,
  }) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    return _remember('search:${q.toLowerCase()}:$language', const Duration(minutes: 10), () async {
      await _nominatimSlot();
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': q, 'format': 'jsonv2', 'addressdetails': '1', 'limit': '8',
        'countrycodes': 'in', 'accept-language': language,
        if (proximity != null)
          'viewbox': '${proximity.longitude - 0.25},${proximity.latitude + 0.25},${proximity.longitude + 0.25},${proximity.latitude - 0.25}',
      });
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/json', 'User-Agent': _userAgent,
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw StateError('OpenStreetMap place search failed (${response.statusCode}).');
      final rows = jsonDecode(response.body) as List<dynamic>;
      return rows.whereType<Map>().map((raw) {
        final item = Map<String, dynamic>.from(raw);
        final address = _map(item['address']);
        final display = (item['display_name'] ?? item['name'] ?? 'Location').toString();
        final name = (item['name'] ?? address['road'] ?? address['suburb'] ??
          address['city'] ?? address['town'] ?? display.split(',').first).toString();
        final lat = double.tryParse(item['lat']?.toString() ?? '') ?? 0;
        final lon = double.tryParse(item['lon']?.toString() ?? '') ?? 0;
        return QuickRideSearchResult(
          placeId: (item['place_id'] ?? '${lat}_${lon}').toString(),
          point: LatLng(lat, lon), name: name, address: display,
          resultType: (item['type'] ?? item['class'] ?? '').toString(),
          postalCode: address['postcode']?.toString() ?? _postal(display),
        );
      }).where((item) => item.point.latitude != 0 || item.point.longitude != 0).toList(growable: false);
    });
  }

  /// Nominatim search results already include their coordinates.
  static Future<QuickRidePlace> retrieveSuggestion(QuickRideSearchResult suggestion) async =>
    QuickRidePlace(
      point: suggestion.point, name: suggestion.name, address: suggestion.address,
      postalCode: suggestion.postalCode ?? _postal(suggestion.address),
    );

  static Future<String> reverseGeocode(LatLng point, {String language = defaultLanguage}) =>
    _remember('reverse:${point.latitude.toStringAsFixed(5)}:${point.longitude.toStringAsFixed(5)}:$language',
      const Duration(hours: 12), () async {
        await _nominatimSlot();
        final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
          'lat': point.latitude.toString(), 'lon': point.longitude.toString(),
          'format': 'jsonv2', 'addressdetails': '1', 'accept-language': language,
        });
        final response = await _http.get(uri, headers: const {
          'Accept': 'application/json', 'User-Agent': _userAgent,
        }).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) throw StateError('OpenStreetMap address lookup failed (${response.statusCode}).');
        final payload = _map(jsonDecode(response.body));
        return (payload['display_name'] ??
          'Selected location (${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})').toString();
      });

  static Future<QuickRideRoute> drivingRoute({
    required LatLng origin, required LatLng destination, bool includeSteps = false,
  }) => _remember(
    'route:${origin.latitude.toStringAsFixed(5)}:${origin.longitude.toStringAsFixed(5)}:${destination.latitude.toStringAsFixed(5)}:${destination.longitude.toStringAsFixed(5)}:$includeSteps',
    const Duration(minutes: 5), () async {
      final coordinates = '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
      final uri = Uri.https('router.project-osrm.org', '/route/v1/driving/$coordinates', {
        'alternatives': 'false', 'overview': 'full', 'geometries': 'geojson',
        'steps': includeSteps ? 'true' : 'false',
      });
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/json', 'User-Agent': _userAgent,
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw StateError('OpenStreetMap route service failed (${response.statusCode}).');
      final payload = _map(jsonDecode(response.body));
      if (payload['code'] != 'Ok') throw StateError((payload['message'] ?? 'No drivable route found.').toString());
      final routes = payload['routes'] as List<dynamic>? ?? const [];
      if (routes.isEmpty) throw StateError('OpenStreetMap returned no drivable route.');
      final route = _map(routes.first);
      final geometry = _map(route['geometry']);
      final raw = geometry['coordinates'] as List<dynamic>? ?? const [];
      final points = raw.whereType<List<dynamic>>()
        .where((p) => p.length >= 2 && p[0] is num && p[1] is num)
        .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
        .toList(growable: false);
      if (points.length < 2) throw StateError('OpenStreetMap returned an incomplete route.');
      final steps = <QuickRideRouteStep>[];
      if (includeSteps) {
        for (final rawLeg in route['legs'] as List<dynamic>? ?? const []) {
          for (final rawStep in _map(rawLeg)['steps'] as List<dynamic>? ?? const []) {
            final step = _map(rawStep);
            final maneuver = _map(step['maneuver']);
            final location = maneuver['location'] as List<dynamic>? ?? const [];
            final type = (maneuver['type'] ?? 'continue').toString().replaceAll('_', ' ');
            final modifier = (maneuver['modifier'] ?? '').toString();
            final road = (step['name'] ?? '').toString();
            var instruction = type.isEmpty ? 'Continue' : type[0].toUpperCase() + type.substring(1);
            if (modifier.isNotEmpty) instruction += ' $modifier';
            if (road.isNotEmpty) instruction += ' onto $road';
            steps.add(QuickRideRouteStep(
              instruction: instruction,
              location: location.length >= 2 && location[0] is num && location[1] is num
                ? LatLng((location[1] as num).toDouble(), (location[0] as num).toDouble()) : null,
              distanceMeters: (step['distance'] as num?)?.toDouble() ?? 0,
              durationSeconds: (step['duration'] as num?)?.toDouble() ?? 0,
            ));
          }
        }
      }
      return QuickRideRoute(
        points: points, distanceMeters: (route['distance'] as num).toDouble(),
        durationSeconds: (route['duration'] as num).toDouble(), steps: steps,
      );
    });

}

class QuickRideMapController {
  QuickRideMapController._(this._map);
  final fm.MapController _map;
  void moveTo(LatLng point, {double? zoom}) {
    _map.move(point, zoom ?? 15);
  }
  void fitRoute(List<LatLng> points, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(36, 175, 36, 250),
  }) {
    if (points.length >= 2) {
      _map.fitCamera(fm.CameraFit.coordinates(coordinates: points, padding: padding));
    }
  }
  void rotate(double degrees) {
    _map.rotate(degrees);
  }
}

class QuickRideSearchResult {
  const QuickRideSearchResult({
    required this.placeId, required this.point, required this.name,
    required this.address, required this.resultType, this.sessionToken, this.postalCode,
  });
  /// Nominatim place identifier.
  final String placeId;
  final String? sessionToken;
  final LatLng point;
  final String name;
  final String address;
  final String resultType;
  final String? postalCode;
}

class QuickRidePlace {
  const QuickRidePlace({required this.point, required this.name, required this.address, this.postalCode});
  final LatLng point;
  final String name;
  final String address;
  final String? postalCode;
}

class QuickRideRoute {
  const QuickRideRoute({required this.points, required this.distanceMeters, required this.durationSeconds, this.steps = const []});
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<QuickRideRouteStep> steps;
}

class QuickRideRouteStep {
  const QuickRideRouteStep({required this.instruction, required this.location, required this.distanceMeters, required this.durationSeconds});
  final String instruction;
  final LatLng? location;
  final double distanceMeters;
  final double durationSeconds;
}

class QuickRideMapView extends StatefulWidget {
  const QuickRideMapView({
    super.key, this.initialCenter, this.initialZoom = 13, this.showUserLocation = true,
    this.currentPosition, this.cameraTarget, this.pickup, this.destination,
    this.routePoints = const [], this.onMapCreated, this.onTap,
    this.followCurrentPosition = false, this.navigationCamera = false,
    this.recenterSignal = 0, this.fitRouteBottomInset = 300,
    this.userAgentPackageName = 'com.alvzyo.ride.customer',
  });
  final LatLng? initialCenter;
  final double initialZoom;
  final bool showUserLocation;
  final LatLng? currentPosition;
  final LatLng? cameraTarget;
  final LatLng? pickup;
  final LatLng? destination;
  final List<LatLng> routePoints;
  final ValueChanged<QuickRideMapController>? onMapCreated;
  final ValueChanged<LatLng>? onTap;
  final bool followCurrentPosition;
  final bool navigationCamera;
  final int recenterSignal;
  final double fitRouteBottomInset;
  final String userAgentPackageName;
  @override
  State<QuickRideMapView> createState() => _QuickRideMapViewState();
}

class _QuickRideMapViewState extends State<QuickRideMapView> {
  late final fm.MapController _mapController;
  QuickRideMapController? _controller;
  bool _mapReady = false;
  LatLng get _initial => widget.currentPosition ?? widget.initialCenter ?? const LatLng(25.4358, 81.8463);

  @override
  void initState() {
    super.initState();
    _mapController = fm.MapController();
  }

  void _onMapReady() {
    if (!mounted || _mapReady) return;
    _controller = QuickRideMapController._(_mapController);
    setState(() { _mapReady = true; });
    widget.onMapCreated?.call(_controller!);
  }

  List<fm.Marker> _markers() {
    final result = <fm.Marker>[];
    void add(LatLng? point, Color color, double diameter) {
      if (point == null) return;
      result.add(fm.Marker(
        point: point, width: diameter + 6, height: diameter + 6,
        child: Center(child: Container(
          width: diameter, height: diameter,
          decoration: BoxDecoration(
            color: color, shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3)],
          ),
        )),
      ));
    }
    final current = widget.showUserLocation ? widget.currentPosition : null;
    if (current != null) {
      add(LatLng(current.latitude + 0.00010, current.longitude), const Color(0xFF159B65), 16);
      add(current, const Color(0xFF2463EB), 12);
    }
    final pickup = widget.pickup;
    if (pickup != null && (current == null || pickup != current)) {
      add(pickup, const Color(0xFF159B65), 16);
    }
    add(widget.destination, const Color(0xFFD94747), 16);
    return result;
  }

  @override
  void didUpdateWidget(covariant QuickRideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final recenter = widget.recenterSignal != oldWidget.recenterSignal ||
      (widget.followCurrentPosition && oldWidget.currentPosition != widget.currentPosition) ||
      widget.navigationCamera != oldWidget.navigationCamera;
    if (_mapReady && recenter) {
      final point = widget.cameraTarget ?? widget.currentPosition ?? widget.initialCenter;
      if (point != null) _controller?.moveTo(point, zoom: widget.navigationCamera ? 17 : 15.5);
    }
    if (_mapReady && !widget.navigationCamera &&
        !listEquals(oldWidget.routePoints, widget.routePoints) && widget.routePoints.length >= 2) {
      _controller?.fitRoute(widget.routePoints,
        padding: EdgeInsets.fromLTRB(36, 175, 36, widget.fitRouteBottomInset));
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final override = QuickRideMaps.mapWidgetOverride;
    if (override != null) return override(context, widget);
    return Stack(fit: StackFit.expand, children: [
      fm.FlutterMap(
        mapController: _mapController,
        options: fm.MapOptions(
          initialCenter: _initial, initialZoom: widget.initialZoom,
          minZoom: 3, maxZoom: 19, onMapReady: _onMapReady,
          onTap: (_, point) => widget.onTap?.call(point),
        ),
        children: [
          fm.TileLayer(
            urlTemplate: QuickRideMaps.tileUrl,
            userAgentPackageName: widget.userAgentPackageName,
            maxZoom: 19,
            errorTileCallback: (tile, error, stackTrace) {
              if (mounted && !_tileError) setState(() => _tileError = true);
              debugPrint('Alvzyo OSM tile request failed (${error.runtimeType}).');
            },
          ),
          if (widget.routePoints.length >= 2)
            fm.PolylineLayer(polylines: [fm.Polyline(
              points: widget.routePoints, color: const Color(0xFF2167D5), strokeWidth: 5,
            )]),
          if (widget.showUserLocation && widget.currentPosition != null)
            fm.PolylineLayer(polylines: [fm.Polyline(
              points: [widget.currentPosition!,
                LatLng(widget.currentPosition!.latitude + 0.00010, widget.currentPosition!.longitude)],
              color: const Color(0xFF263238), strokeWidth: 2.5,
            )]),
          fm.MarkerLayer(markers: _markers()),
          fm.RichAttributionWidget(
            alignment: fm.AttributionAlignment.bottomRight,
            attributions: const [fm.TextSourceAttribution('© OpenStreetMap contributors')],
          ),
        ],
      ),
      if (!_mapReady) const IgnorePointer(child: Center(child: CircularProgressIndicator())),
      if (_tileError)
        Positioned(left: 12, right: 12, top: 12, child: Material(
          elevation: 2, color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
          child: Padding(padding: const EdgeInsets.all(10), child: Text(
            'Map tiles are temporarily unavailable. Check your connection and retry.',
            maxLines: 3, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
          )),
        )),
    ]);
  }
}
