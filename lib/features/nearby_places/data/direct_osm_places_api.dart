import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../logic/geo_math.dart';
import '../models/nearby_place.dart';
import '../models/place_category.dart';
import 'places_api.dart';

// ============================================================================
// DIRECT OPENSTREETMAP (OSM) PLACES API — Panggil OSM Langsung dari HP
//
// Tidak perlu menjalankan `server.py` di laptop.
// 1. Mengirim permintaan Overpass QL langsung ke server OpenStreetMap via HTTPS.
// 2. Jika server Overpass publik sibuk (429/timeout) atau HP offline, otomatis
//    fallback ke data snapshot lokal (places_snapshot.json) agar tidak pernah gagal.
// ============================================================================

class DirectOsmPlacesApi implements PlacesApi {
  DirectOsmPlacesApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  // Daftar server Overpass publik (dicoba berurutan jika ada yang lambat/penuh)
  static const List<String> _overpassEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const String _userAgent =
      'DrivingBuddyApp/1.0 (Mobile; OpenStreetMap Client)';

  // Cache data snapshot agar tidak membaca asset berulang-ulang
  List<dynamic>? _cachedSnapshotElements;

  @override
  Future<NearbyResult> nearby({
    required double lat,
    required double lng,
    PlaceCategory? category,
    int limit = 5,
    int? radiusM,
    double? headingDeg,
    double? speedMps,
    double? accuracyM,
    bool preferAhead = false,
  }) async {
    final effectiveRadius = radiusM ?? _defaultRadiusFor(category);

    // 1. Coba panggil Overpass API langsung lewat Internet
    try {
      final elements = await _queryOverpassWithFallback(
        lat: lat,
        lng: lng,
        category: category,
        radiusM: effectiveRadius,
      );

      if (elements.isNotEmpty) {
        final places = _processElements(
          elements: elements,
          userLat: lat,
          userLng: lng,
          requestedCategory: category,
          headingDeg: headingDeg,
          preferAhead: preferAhead,
          sourceName: 'osm',
        );

        if (places.isNotEmpty) {
          final limited = places.take(limit).toList();
          return NearbyResult(
            places: limited,
            category: category?.apiValue ?? 'all',
            provider: 'osm',
            summary: ' tempat ditemukan',
          );
        }
      }
    } catch (e) {
      // Abaikan dan lanjut ke fallback snapshot lokal
    }

    // 2. Fallback: Baca data dari snapshot lokal jika Overpass lambat/offline
    try {
      final snapshotElements = await _loadSnapshotElements();
      if (snapshotElements.isNotEmpty) {
        final places = _processElements(
          elements: snapshotElements,
          userLat: lat,
          userLng: lng,
          requestedCategory: category,
          headingDeg: headingDeg,
          preferAhead: preferAhead,
          maxRadiusM: effectiveRadius.toDouble(),
          sourceName: 'snapshot',
        );

        if (places.isNotEmpty) {
          final limited = places.take(limit).toList();
          return NearbyResult(
            places: limited,
            category: category?.apiValue ?? 'all',
            provider: 'snapshot (offline)',
            summary: ' tempat ditemukan (offline)',
            warnings: const [
              'Data tempat diambil dari snapshot offline (tanpa server)',
            ],
          );
        }
      }
    } catch (_) {}

    // 3. Jika benar-benar kosong di sekitar koordinat tersebut
    return NearbyResult(
      places: const [],
      category: category?.apiValue ?? 'all',
      provider: 'osm',
      summary: 'Tidak ada tempat di sekitar',
    );
  }

  @override
  Future<Map<String, dynamic>> health({bool deep = false}) async {
    return {
      'status': 'ok',
      'mode': 'direct_osm',
      'provider': 'OpenStreetMap Direct (Tanpa server.py)',
    };
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INTERNAL: Overpass Query
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<dynamic>> _queryOverpassWithFallback({
    required double lat,
    required double lng,
    required PlaceCategory? category,
    required int radiusM,
  }) async {
    final query = _buildOverpassQuery(lat, lng, category, radiusM);

    for (final endpoint in _overpassEndpoints) {
      try {
        final response = await _client.post(
          Uri.parse(endpoint),
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          },
          body: {'data': query},
        ).timeout(timeout);

        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map<String, dynamic> && decoded['elements'] is List) {
            return decoded['elements'] as List<dynamic>;
          }
        }
      } catch (_) {
        // Coba endpoint alternatif berikutnya
        continue;
      }
    }
    return [];
  }

  String _buildOverpassQuery(
    double lat,
    double lng,
    PlaceCategory? category,
    int radiusM,
  ) {
    final around = '(around:$radiusM,${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)})';
    final lines = <String>[];

    final categoriesToQuery = category == null
        ? PlaceCategory.values
        : [category];

    for (final cat in categoriesToQuery) {
      switch (cat) {
        case PlaceCategory.restArea:
          lines.add('node["highway"~"^(rest_area|services)\$"]$around;');
          lines.add('way["highway"~"^(rest_area|services)\$"]$around;');
          break;
        case PlaceCategory.minimarket:
          lines.add('node["shop"="convenience"]$around;');
          lines.add('way["shop"="convenience"]$around;');
          break;
        case PlaceCategory.lodging:
          lines.add('node["tourism"~"^(hotel|motel|guest_house|hostel)\$"]$around;');
          lines.add('way["tourism"~"^(hotel|motel|guest_house|hostel)\$"]$around;');
          break;
        case PlaceCategory.spbu:
          lines.add('node["amenity"="fuel"]$around;');
          lines.add('way["amenity"="fuel"]$around;');
          break;
      }
    }

    return '[out:json][timeout:10];\n(\n  ${lines.join("\n  ")}\n);\nout center 50;';
  }

  int _defaultRadiusFor(PlaceCategory? category) {
    if (category == null) return 20000;
    switch (category) {
      case PlaceCategory.restArea:
        return 35000;
      case PlaceCategory.minimarket:
        return 5000;
      case PlaceCategory.lodging:
        return 25000;
      case PlaceCategory.spbu:
        return 10000;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INTERNAL: Parsing & Filtering
  // ──────────────────────────────────────────────────────────────────────────

  List<NearbyPlace> _processElements({
    required List<dynamic> elements,
    required double userLat,
    required double userLng,
    required PlaceCategory? requestedCategory,
    required double? headingDeg,
    required bool preferAhead,
    double? maxRadiusM,
    required String sourceName,
  }) {
    final list = <NearbyPlace>[];

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final type = el['type'] as String?;
      final idNum = el['id'];
      if (type == null || idNum == null) continue;

      double? pLat;
      double? pLng;

      if (type == 'node') {
        pLat = (el['lat'] as num?)?.toDouble();
        pLng = (el['lon'] as num?)?.toDouble();
      } else if (type == 'way' && el['center'] is Map) {
        final center = el['center'] as Map<String, dynamic>;
        pLat = (center['lat'] as num?)?.toDouble();
        pLng = (center['lon'] as num?)?.toDouble();
      }

      if (pLat == null || pLng == null || !isInRange(pLat, pLng)) continue;

      final tags = (el['tags'] is Map<String, dynamic>)
          ? el['tags'] as Map<String, dynamic>
          : <String, dynamic>{};

      // Tentukan kategori tempat
      final detectedCat = _detectCategory(tags);
      if (detectedCat == null) continue;
      if (requestedCategory != null && detectedCat != requestedCategory) continue;

      // Filter nama bengkel / salah tag
      if (detectedCat == PlaceCategory.restArea && _isInvalidRestArea(tags)) {
        continue;
      }

      final distM = haversineM(userLat, userLng, pLat, pLng).round();
      if (maxRadiusM != null && distM > maxRadiusM) continue;

      final brg = bearingDeg(userLat, userLng, pLat, pLng).round();
      final ahead = isAhead(
        fromLat: userLat,
        fromLng: userLng,
        toLat: pLat,
        toLng: pLng,
        headingDeg: headingDeg,
      );

      final name = _resolveName(tags, detectedCat);
      final address = _resolveAddress(tags);

      final placeId = 'osm:$type/$idNum';
      final navUrl = 'google.navigation:q=$pLat,$pLng&mode=d';
      final mapsUrl = 'https://www.google.com/maps/search/?api=1&query=$pLat,$pLng';

      list.add(
        NearbyPlace(
          id: placeId,
          name: name,
          categoryKey: detectedCat.apiValue,
          categoryLabel: detectedCat.label,
          lat: pLat,
          lng: pLng,
          distanceM: distM,
          bearingDeg: brg,
          ahead: ahead,
          address: address,
          mapsUrl: mapsUrl,
          navigateUrl: navUrl,
          source: sourceName,
        ),
      );
    }

    // Urutkan: preferAhead jika aktif dan arah gerak diketahui, lalu jarak terdekat
    list.sort((a, b) {
      if (preferAhead && headingDeg != null) {
        final aAhead = a.ahead ?? false;
        final bAhead = b.ahead ?? false;
        if (aAhead != bAhead) {
          return aAhead ? -1 : 1;
        }
      }
      return a.distanceM.compareTo(b.distanceM);
    });

    return list;
  }

  PlaceCategory? _detectCategory(Map<String, dynamic> tags) {
    final highway = tags['highway']?.toString().toLowerCase();
    if (highway == 'rest_area' || highway == 'services') {
      return PlaceCategory.restArea;
    }
    final shop = tags['shop']?.toString().toLowerCase();
    if (shop == 'convenience') {
      return PlaceCategory.minimarket;
    }
    final tourism = tags['tourism']?.toString().toLowerCase();
    if (tourism == 'hotel' ||
        tourism == 'motel' ||
        tourism == 'guest_house' ||
        tourism == 'hostel') {
      return PlaceCategory.lodging;
    }
    final amenity = tags['amenity']?.toString().toLowerCase();
    if (amenity == 'fuel') {
      return PlaceCategory.spbu;
    }
    return null;
  }

  bool _isInvalidRestArea(Map<String, dynamic> tags) {
    final shop = tags['shop']?.toString().toLowerCase();
    if (shop == 'car_repair' ||
        shop == 'motorcycle_repair' ||
        shop == 'tyres' ||
        shop == 'car_parts') {
      return true;
    }
    final name = (tags['name'] ?? tags['brand'] ?? tags['operator'] ?? '')
        .toString()
        .toLowerCase();
    if (name.contains('bengkel') ||
        name.contains('ahass') ||
        name.contains('tambal ban') ||
        name.contains('cuci motor') ||
        name.contains('cuci mobil')) {
      return true;
    }
    return false;
  }

  String _resolveName(Map<String, dynamic> tags, PlaceCategory cat) {
    for (final key in ['name', 'name:id', 'brand', 'operator']) {
      final val = tags[key]?.toString().trim();
      if (val != null && val.isNotEmpty) {
        return val;
      }
    }
    return cat.label;
  }

  String _resolveAddress(Map<String, dynamic> tags) {
    final full = tags['addr:full']?.toString().trim();
    if (full != null && full.isNotEmpty) return full;

    final street = tags['addr:street']?.toString().trim() ?? '';
    final city = tags['addr:city']?.toString().trim() ??
        tags['addr:town']?.toString().trim() ??
        '';

    final parts = [street, city].where((s) => s.isNotEmpty).toList();
    return parts.join(', ');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INTERNAL: Snapshot Loader
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<dynamic>> _loadSnapshotElements() async {
    if (_cachedSnapshotElements != null) {
      return _cachedSnapshotElements!;
    }
    try {
      final jsonString = await rootBundle.loadString('places_snapshot.json');
      final data = jsonDecode(jsonString);
      if (data is Map<String, dynamic> && data['elements'] is List) {
        _cachedSnapshotElements = data['elements'] as List<dynamic>;
        return _cachedSnapshotElements!;
      }
    } catch (_) {}
    return [];
  }
}
