import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../logic/geo_math.dart';
import 'places_config.dart';

// ============================================================================
// LOKASI — pembungkus tipis di atas `geolocator` supaya logika di controller
// bisa dites tanpa GPS sungguhan (ganti dengan LocationProvider palsu).
// ============================================================================

/// Hasil pengecekan izin + layanan lokasi.
enum LocationAccess {
  /// Izin diberikan dan GPS menyala.
  granted,

  /// Izin belum diberikan / ditolak (masih boleh diminta lagi).
  denied,

  /// Ditolak permanen: hanya bisa diubah lewat Pengaturan aplikasi.
  deniedForever,

  /// Layanan lokasi (GPS) di HP mati.
  serviceDisabled,
}

/// Satu pembacaan posisi pengemudi.
class DriverFix {
  const DriverFix({
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.headingDeg,
    this.speedMps,
    this.accuracyM,
  });

  final double lat;
  final double lng;
  final DateTime timestamp;

  /// Arah gerak (derajat dari utara) kalau sensor memberikannya; null = tidak diketahui.
  final double? headingDeg;

  /// Kecepatan m/s; null = tidak diketahui.
  final double? speedMps;

  /// Akurasi horizontal (meter); null = tidak diketahui.
  final double? accuracyM;

  /// Koordinat sah dan bukan (0, 0) (tanda GPS belum dapat sinyal).
  bool get isValid => isInRange(lat, lng) && !isNullIsland(lat, lng);

  /// Arah gerak yang boleh dipercaya: kosong kalau kendaraan hampir diam
  /// (arah dari GPS saat diam hanya noise).
  double? get trustedHeadingDeg {
    final h = headingDeg;
    if (h == null || !h.isFinite || h < 0 || h > 360) return null;
    final s = speedMps;
    if (s != null && s < minSpeedForHeadingMps) return null;
    return h % 360.0;
  }
}

abstract class LocationProvider {
  /// Cek tanpa memunculkan dialog izin.
  Future<LocationAccess> checkAccess();

  /// Minta izin (memunculkan dialog sistem kalau perlu).
  Future<LocationAccess> requestAccess();

  /// Satu pembacaan posisi; null kalau gagal/timeout.
  Future<DriverFix?> currentFix({Duration timeout = const Duration(seconds: 10)});

  /// Aliran pembaruan posisi selama berkendara.
  Stream<DriverFix> fixes();

  Future<void> openLocationSettings();
  Future<void> openAppSettings();
}

/// Implementasi sungguhan memakai paket `geolocator`.
class GeolocatorLocationProvider implements LocationProvider {
  GeolocatorLocationProvider({this.distanceFilterM = 25});

  /// Pembaruan baru dikirim setiap pindah sekian meter (hemat baterai).
  final int distanceFilterM;

  LocationAccess _fromPermission(LocationPermission permission) {
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      return LocationAccess.granted;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationAccess.deniedForever;
    }
    return LocationAccess.denied;
  }

  @override
  Future<LocationAccess> checkAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceDisabled;
    }
    return _fromPermission(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> requestAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return _fromPermission(permission);
  }

  DriverFix _toFix(Position p) {
    final heading = p.heading;
    final speed = p.speed;
    final accuracy = p.accuracy;
    // `hasXxx` = HP benar-benar melaporkan nilainya; kalau false, angkanya cuma 0.0 pengisi.
    return DriverFix(
      lat: p.latitude,
      lng: p.longitude,
      timestamp: DateTime.now(),
      headingDeg: (p.hasHeading && heading.isFinite && heading >= 0 && heading <= 360)
          ? heading
          : null,
      speedMps: (p.hasSpeed && speed.isFinite && speed >= 0) ? speed : null,
      accuracyM: (p.hasAccuracy && accuracy.isFinite && accuracy >= 0)
          ? accuracy
          : null,
    );
  }

  @override
  Future<DriverFix?> currentFix({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: timeout,
      );
      return _toFix(position);
    } catch (_) {
      // Timeout, GPS mati, izin dicabut, dll. Pemanggil memutuskan apa yang ditampilkan.
      return null;
    }
  }

  @override
  Stream<DriverFix> fixes() {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterM,
      ),
    ).map(_toFix);
  }

  @override
  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  @override
  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }
}

/// Lokasi tetap — dipakai untuk demo di meja (`--dart-define=PLACES_DEMO_LOCATION=...`)
/// dan tes. Tidak pernah dipakai di build rilis.
class FixedLocationProvider implements LocationProvider {
  FixedLocationProvider(
    this.point, {
    this.headingDeg,
    this.speedMps,
    this.interval = const Duration(seconds: 5),
  });

  final GeoPoint point;
  final double? headingDeg;
  final double? speedMps;
  final Duration interval;

  DriverFix _fix() => DriverFix(
        lat: point.lat,
        lng: point.lng,
        timestamp: DateTime.now(),
        headingDeg: headingDeg,
        speedMps: speedMps,
        accuracyM: 5,
      );

  @override
  Future<LocationAccess> checkAccess() async => LocationAccess.granted;

  @override
  Future<LocationAccess> requestAccess() async => LocationAccess.granted;

  @override
  Future<DriverFix?> currentFix({
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      _fix();

  @override
  Stream<DriverFix> fixes() => Stream<DriverFix>.periodic(interval, (_) => _fix());

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<void> openAppSettings() async {}
}

/// Pilih penyedia lokasi: lokasi demo kalau diset lewat dart-define (hanya debug/profile),
/// kalau tidak GPS sungguhan.
LocationProvider createDefaultLocationProvider() {
  final demo = PlacesConfig.demoLocation();
  if (demo != null) {
    return FixedLocationProvider(demo);
  }
  return GeolocatorLocationProvider();
}
