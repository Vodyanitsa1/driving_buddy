import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/geo_math.dart';

// ============================================================================
// KONFIGURASI — alamat server FastAPI (server.py) yang menjalankan modul
// `nearby_places`. KUNCI Google TIDAK ADA di aplikasi: kunci hanya di .env server.
//
// Urutan prioritas alamat server:
//   1. alamat yang disimpan lewat dialog "Atur server" (SharedPreferences)
//   2. --dart-define=PLACES_API_BASE_URL=http://192.168.1.10:8000 saat build/run
//   3. bawaan: emulator Android -> http://10.0.2.2:8000 (= laptop host),
//      lainnya -> http://127.0.0.1:8000
// ============================================================================

class PlacesConfig {
  /// Tanpa argumen = konfigurasi aplikasi (alamat tersimpan > dart-define > bawaan).
  /// Dengan [baseUrl] = alamat tetap yang tidak ditimpa penyimpanan (dipakai untuk "Tes koneksi" dan tes).
  PlacesConfig({String? baseUrl})
      : _baseUrl = (baseUrl == null ? null : normalizeBaseUrl(baseUrl)) ??
            defaultBaseUrl(),
        _loaded = baseUrl != null;

  /// Satu konfigurasi bersama untuk seluruh aplikasi.
  static final PlacesConfig shared = PlacesConfig();

  static const String _prefKey = 'places_api_base_url';
  static const String _defineUrl = String.fromEnvironment('PLACES_API_BASE_URL');
  static const String _defineDemo = String.fromEnvironment('PLACES_DEMO_LOCATION');

  String _baseUrl;
  bool _loaded;

  /// Alamat server tanpa garis miring di akhir, mis. `http://192.168.1.10:8000`.
  String get baseUrl => _baseUrl;

  /// Alamat bawaan (tanpa override dari pengguna).
  static String defaultBaseUrl() {
    final fromBuild = normalizeBaseUrl(_defineUrl);
    if (fromBuild != null) return fromBuild;
    if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:8000';
    return 'http://127.0.0.1:8000';
  }

  /// Rapikan alamat ketikan pengguna. `null` kalau tidak valid.
  ///
  /// "192.168.1.10:8000" -> "http://192.168.1.10:8000"; garis miring di akhir dan
  /// bagian "/places..." (kalau yang ditempel alamat endpoint lengkap) dibuang.
  static String? normalizeBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    var path = uri.path;
    final placesAt = path.indexOf('/places');
    if (placesAt >= 0) path = path.substring(0, placesAt);
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '${uri.scheme}://${uri.authority}$path';
  }

  /// Baca alamat yang pernah disimpan pengguna. Aman dipanggil berkali-kali.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null) {
        final normalized = normalizeBaseUrl(saved);
        if (normalized != null) _baseUrl = normalized;
      }
    } catch (_) {
      // Penyimpanan bermasalah: pakai alamat bawaan, jangan ganggu pemantauan.
    }
  }

  /// Simpan alamat baru. `false` kalau alamatnya tidak valid (tidak disimpan).
  Future<bool> save(String raw) async {
    final normalized = normalizeBaseUrl(raw);
    if (normalized == null) return false;
    _baseUrl = normalized;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, normalized);
    } catch (_) {
      // Tetap dipakai selama aplikasi hidup walau gagal disimpan.
    }
    return true;
  }

  /// Hapus override pengguna dan kembali ke alamat bawaan.
  Future<void> reset() async {
    _baseUrl = defaultBaseUrl();
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  /// Lokasi palsu untuk demo/tes di meja, dari `--dart-define=PLACES_DEMO_LOCATION=-7.1405,110.4020` (Ungaran, Semarang).
  /// Selalu diabaikan di build rilis.
  static GeoPoint? demoLocation() {
    if (kReleaseMode) return null;
    return parseDemoLocation(_defineDemo);
  }

  /// "lat,lng" -> titik, `null` kalau kosong/tidak valid/(0,0).
  static GeoPoint? parseDemoLocation(String raw) {
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) return null;
    if (!isInRange(lat, lng) || isNullIsland(lat, lng)) return null;
    return GeoPoint(lat, lng);
  }
}
