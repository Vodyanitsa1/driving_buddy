import '../logic/geo_math.dart' as geo;
import 'place_category.dart';

// ============================================================================
// MODEL TEMPAT — cermin dari `PlaceOut` / `NearbyResponse` di backend
// (nearby_places/schemas.py). Parsing sengaja toleran: field aneh/hilang pada
// SATU tempat hanya membuat tempat itu dilewati, bukan membuat seluruh
// pencarian gagal.
// ============================================================================

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value is String ? value : value.toString();
}

/// Angka hingga atau null (NaN/Infinity ditolak supaya `.round()` tidak pernah melempar).
double? _asDouble(Object? value) {
  final double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value);
  } else {
    parsed = null;
  }
  return (parsed != null && parsed.isFinite) ? parsed : null;
}

bool? _asBool(Object? value) => value is bool ? value : null;

class NearbyPlace {
  const NearbyPlace({
    required this.id,
    required this.name,
    required this.categoryKey,
    required this.lat,
    required this.lng,
    required this.distanceM,
    this.categoryLabel = '',
    this.address = '',
    this.bearingDeg = 0,
    this.ahead,
    this.openNow,
    this.rating,
    this.mapsUrl = '',
    this.navigateUrl = '',
    this.source = '',
  });

  /// ID dari provider (Google: place id).
  final String id;
  final String name;

  /// Nilai mentah `category` dari server (rest_area | minimarket | lodging | spbu).
  final String categoryKey;

  /// Label dari server (cadangan kalau [category] tidak dikenal).
  final String categoryLabel;

  /// Bisa kosong (data OpenStreetMap sering tidak punya alamat).
  final String address;
  final double lat;
  final double lng;

  /// Jarak garis lurus dari pengemudi (BUKAN jarak lewat jalan), meter.
  final int distanceM;

  /// Arah tempat itu dari pengemudi, derajat dari utara (0 = utara, 90 = timur).
  final int bearingDeg;

  /// true = di depan kendaraan, false = di belakang, null = arah gerak tidak diketahui.
  final bool? ahead;

  /// Hanya terisi kalau server memakai field Google yang lebih mahal. null = tidak diketahui.
  final bool? openNow;
  final double? rating;

  /// Halaman tempat itu (Google Maps / OpenStreetMap).
  final String mapsUrl;

  /// Link Google Maps langsung ke mode navigasi mobil.
  final String navigateUrl;

  /// google | osm | mock
  final String source;

  PlaceCategory? get category => PlaceCategory.fromApi(categoryKey);

  /// Nama kategori untuk ditampilkan.
  String get categoryText {
    final known = category;
    if (known != null) return known.label;
    return categoryLabel.isEmpty ? 'Tempat' : categoryLabel;
  }

  /// '350 m', '2,3 km', '35 km'.
  String get distanceText => geo.formatDistance(distanceM);

  factory NearbyPlace.fromJson(Map<String, dynamic> json) {
    final id = _asString(json['id']);
    final name = _asString(json['name']).trim();
    final lat = _asDouble(json['lat']);
    final lng = _asDouble(json['lng']);
    final distance = _asDouble(json['distance_m']);
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Tempat tanpa id atau nama');
    }
    if (lat == null || lng == null || !geo.isInRange(lat, lng)) {
      throw const FormatException('Koordinat tempat tidak valid');
    }
    if (distance == null || !distance.isFinite || distance < 0) {
      throw const FormatException('Jarak tempat tidak valid');
    }
    return NearbyPlace(
      id: id,
      name: name,
      categoryKey: _asString(json['category']),
      categoryLabel: _asString(json['category_label']),
      address: _asString(json['address']).trim(),
      lat: lat,
      lng: lng,
      distanceM: distance.round(),
      bearingDeg: (_asDouble(json['bearing_deg'])?.round() ?? 0) % 360,
      ahead: _asBool(json['ahead']),
      openNow: _asBool(json['open_now']),
      rating: _asDouble(json['rating']),
      mapsUrl: _asString(json['maps_url']),
      navigateUrl: _asString(json['navigate_url']),
      source: _asString(json['source']),
    );
  }

  /// Salinan dengan jarak/arah dihitung ulang dari posisi pengemudi yang baru.
  /// Dipakai supaya "4,2 km lagi" ikut berkurang saat mobil bergerak, tanpa
  /// memanggil server lagi. Kalau [headingDeg] tidak diketahui, status
  /// [ahead] dari server dipertahankan.
  NearbyPlace relativeTo(double fromLat, double fromLng, {double? headingDeg}) {
    final dist = geo.haversineM(fromLat, fromLng, lat, lng);
    final brg = geo.bearingDeg(fromLat, fromLng, lat, lng);
    return NearbyPlace(
      id: id,
      name: name,
      categoryKey: categoryKey,
      categoryLabel: categoryLabel,
      address: address,
      lat: lat,
      lng: lng,
      distanceM: dist.round(),
      bearingDeg: brg.round() % 360,
      ahead: headingDeg == null
          ? ahead
          : geo.angleDiffDeg(brg, headingDeg) < geo.aheadLimitDeg,
      openNow: openNow,
      rating: rating,
      mapsUrl: mapsUrl,
      navigateUrl: navigateUrl,
      source: source,
    );
  }

  @override
  String toString() => 'NearbyPlace($name, $distanceText, ahead=$ahead)';
}

/// Jawaban lengkap satu pencarian (`NearbyResponse`).
class NearbyResult {
  const NearbyResult({
    required this.places,
    this.summary = '',
    this.category = 'all',
    this.provider = '',
    this.cached = false,
    this.degraded = false,
    this.fallbackUsed = false,
    this.errors = const <String, String>{},
    this.warnings = const <String>[],
    this.latencyMs = 0,
  });

  final List<NearbyPlace> places;

  /// Ringkasan singkat siap dibacakan (suara).
  final String summary;
  final String category;
  final String provider;

  /// true = seluruh hasil dari cache server (tidak ada panggilan ke Google/OSM).
  final bool cached;

  /// true = sebagian/seluruh pencarian di server gagal (lihat [errors]); HTTP tetap 200.
  final bool degraded;

  /// true = sebagian hasil dari provider cadangan (OpenStreetMap).
  final bool fallbackUsed;

  /// kategori -> penyebab gagal (timeout, network, rate_limited, auth, budget_exhausted, ...).
  final Map<String, String> errors;
  final List<String> warnings;
  final int latencyMs;

  bool get hasPlaces => places.isNotEmpty;

  factory NearbyResult.fromJson(Map<String, dynamic> json) {
    final raw = json['results'];
    if (raw is! List) {
      throw const FormatException('Jawaban server tidak punya daftar "results"');
    }
    final places = <NearbyPlace>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        places.add(NearbyPlace.fromJson(Map<String, dynamic>.from(item)));
      } on FormatException {
        continue; // satu tempat rusak tidak boleh menggagalkan semuanya
      }
    }

    final errors = <String, String>{};
    final rawErrors = json['errors'];
    if (rawErrors is Map) {
      for (final entry in rawErrors.entries) {
        errors[entry.key.toString()] = entry.value.toString();
      }
    }
    final warnings = <String>[];
    final rawWarnings = json['warnings'];
    if (rawWarnings is List) {
      for (final w in rawWarnings) {
        warnings.add(w.toString());
      }
    }

    return NearbyResult(
      places: List<NearbyPlace>.unmodifiable(places),
      summary: _asString(json['summary']),
      category: _asString(json['category'], 'all'),
      provider: _asString(json['provider']),
      cached: _asBool(json['cached']) ?? false,
      degraded: _asBool(json['degraded']) ?? false,
      fallbackUsed: _asBool(json['fallback_used']) ?? false,
      errors: Map<String, String>.unmodifiable(errors),
      warnings: List<String>.unmodifiable(warnings),
      latencyMs: _asDouble(json['latency_ms'])?.round() ?? 0,
    );
  }
}
