import 'dart:math' as math;

// ============================================================================
// GEO MATH — hitungan jarak & arah (tanpa package tambahan).
//
// Rumusnya SAMA dengan backend (nearby_places/geo.py) supaya angka yang
// dihitung ulang di HP (jarak "live" antar pembaruan server) konsisten dengan
// angka dari server.
// ============================================================================

/// Radius rata-rata bumi (IUGG), meter.
const double earthRadiusM = 6371008.8;

/// Selisih arah di bawah ini (derajat) dari arah gerak = "di depan".
const double aheadLimitDeg = 90.0;

/// Di bawah kecepatan ini (m/s, ~5 km/jam) arah dari GPS tidak bisa dipercaya.
const double minSpeedForHeadingMps = 1.5;

/// Satu titik di peta.
class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

/// True kalau [lat]/[lng] angka hingga dan berada di rentang yang sah.
bool isInRange(double lat, double lng) {
  return lat.isFinite &&
      lng.isFinite &&
      lat >= -90.0 &&
      lat <= 90.0 &&
      lng >= -180.0 &&
      lng <= 180.0;
}

/// (0, 0) hampir pasti bukan posisi sopir: itu nilai bawaan saat GPS belum dapat sinyal.
bool isNullIsland(double lat, double lng) {
  return lat.abs() < 1e-6 && lng.abs() < 1e-6;
}

/// Jarak garis lurus di permukaan bumi, dalam meter.
double haversineM(double lat1, double lng1, double lat2, double lng2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dPhi = p2 - p1;
  final dLambda = _rad(lng2 - lng1);
  final sinPhi = math.sin(dPhi / 2);
  final sinLambda = math.sin(dLambda / 2);
  final a = sinPhi * sinPhi + math.cos(p1) * math.cos(p2) * sinLambda * sinLambda;
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Arah dari titik 1 ke titik 2: 0 = utara, 90 = timur, 180 = selatan, 270 = barat (0 <= hasil < 360).
double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dLambda = _rad(lng2 - lng1);
  final y = math.sin(dLambda) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) -
      math.sin(p1) * math.cos(p2) * math.cos(dLambda);
  return (_deg(math.atan2(y, x)) + 360.0) % 360.0;
}

/// Selisih terkecil antara dua arah, 0..180.
double angleDiffDeg(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// Titik yang dicapai kalau berjalan [distanceM] meter ke arah [bearing] dari ([lat], [lng]).
GeoPoint destinationPoint(
  double lat,
  double lng,
  double bearing,
  double distanceM,
) {
  final ang = distanceM / earthRadiusM;
  final brg = _rad(bearing);
  final p1 = _rad(lat);
  final l1 = _rad(lng);
  final p2 = math.asin(
    math.sin(p1) * math.cos(ang) + math.cos(p1) * math.sin(ang) * math.cos(brg),
  );
  final l2 = l1 +
      math.atan2(
        math.sin(brg) * math.sin(ang) * math.cos(p1),
        math.cos(ang) - math.sin(p1) * math.sin(p2),
      );
  return GeoPoint(_deg(p2), (_deg(l2) + 540.0) % 360.0 - 180.0);
}

/// Apakah tempat di ([toLat], [toLng]) ada di depan kendaraan yang bergerak ke [headingDeg]?
/// `null` kalau arah gerak tidak diketahui.
bool? isAhead({
  required double fromLat,
  required double fromLng,
  required double toLat,
  required double toLng,
  required double? headingDeg,
}) {
  if (headingDeg == null) return null;
  final brg = bearingDeg(fromLat, fromLng, toLat, toLng);
  return angleDiffDeg(brg, headingDeg) < aheadLimitDeg;
}

/// Arah mata angin dalam bahasa Indonesia untuk [bearing] (derajat dari utara):
/// 'utara', 'timur laut', 'timur', 'tenggara', 'selatan', 'barat daya', 'barat', 'barat laut'.
String compassLabelId(num bearing) {
  const names = <String>[
    'utara',
    'timur laut',
    'timur',
    'tenggara',
    'selatan',
    'barat daya',
    'barat',
    'barat laut',
  ];
  final double b = bearing.isFinite ? bearing.toDouble() : 0.0;
  final double normalized = ((b % 360.0) + 360.0) % 360.0;
  final int index = (normalized + 22.5) ~/ 45.0;
  return names[index % 8];
}

/// '350 m', '2,3 km', '35 km' (koma desimal ala Indonesia). Sama dengan `format_distance` di backend.
String formatDistance(num meters) {
  final double d = (!meters.isFinite || meters < 0) ? 0.0 : meters.toDouble();
  final int rounded = (d / 10.0 + 0.5).floor() * 10;
  if (rounded < 1000) {
    return '${rounded < 10 ? 10 : rounded} m';
  }
  final km = d / 1000.0;
  if (km < 10) {
    var text = km.toStringAsFixed(1);
    if (text.endsWith('.0')) {
      text = text.substring(0, text.length - 2);
    }
    return '${text.replaceAll('.', ',')} km';
  }
  return '${(km + 0.5).floor()} km';
}
