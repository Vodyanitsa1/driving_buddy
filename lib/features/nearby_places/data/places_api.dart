import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/nearby_place.dart';
import '../models/place_category.dart';
import 'places_config.dart';

// ============================================================================
// KLIEN API — memanggil modul `nearby_places` di server.py:
//   POST {baseUrl}/places/nearby     GET {baseUrl}/places/health
// Semua kegagalan dibungkus PlacesApiException dengan pesan bahasa Indonesia
// yang siap tampil. Fitur ini TIDAK boleh membuat deteksi kantuk berhenti.
// ============================================================================

enum PlacesApiErrorKind {
  /// Server tidak terjangkau (alamat salah, beda jaringan, server mati, tanpa internet).
  unreachable,

  /// Server tidak menjawab dalam batas waktu.
  timeout,

  /// 404 (modul belum dipasang di server.py) atau 503 (belum dikonfigurasi).
  notConfigured,

  /// 429: terlalu banyak permintaan.
  rateLimited,

  /// 422: koordinat/parameter ditolak server.
  invalidRequest,

  /// 5xx lainnya.
  server,

  /// Jawaban bukan JSON yang diharapkan.
  badResponse,
}

class PlacesApiException implements Exception {
  const PlacesApiException(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  final PlacesApiErrorKind kind;

  /// Bahasa Indonesia, siap ditampilkan ke pengguna.
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  /// Layak dicoba lagi nanti secara otomatis? (jaringan putus, timeout, server error, kena batas).
  /// Salah konfigurasi / permintaan salah: tidak.
  bool get isTransient =>
      kind == PlacesApiErrorKind.unreachable ||
      kind == PlacesApiErrorKind.timeout ||
      kind == PlacesApiErrorKind.rateLimited ||
      kind == PlacesApiErrorKind.server;

  @override
  String toString() => 'PlacesApiException(${kind.name}, $statusCode): $message';
}

/// Kontrak klien — dipisah supaya controller bisa dites dengan versi palsu.
abstract class PlacesApi {
  /// Cari tempat terdekat. [category] `null` = semua kategori.
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
  });

  /// Status modul di server (`deep: true` = tes koneksi + API key ke provider, memakai 1 jatah).
  Future<Map<String, dynamic>> health({bool deep = false});

  void close();
}

class HttpPlacesApi implements PlacesApi {
  HttpPlacesApi({
    PlacesConfig? config,
    http.Client? client,
    // Harus lebih lama dari batas total server (PLACES_OSM_DEADLINE_S, bawaan 20 dtk), supaya app tidak
    // menyerah duluan saat server sedang mencoba server Overpass cadangan.
    this.timeout = const Duration(seconds: 30),
  })  : config = config ?? PlacesConfig.shared,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final PlacesConfig config;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  Uri _uri(String path) {
    try {
      return Uri.parse('${config.baseUrl}$path');
    } on FormatException {
      throw PlacesApiException(
        PlacesApiErrorKind.unreachable,
        'Alamat server tidak valid: ${config.baseUrl}',
      );
    }
  }

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
    final body = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'category': category?.apiValue ?? 'all',
      'limit': limit,
      'prefer_ahead': preferAhead,
      if (radiusM != null) 'radius_m': radiusM,
      if (headingDeg != null) 'heading_deg': headingDeg,
      if (speedMps != null) 'speed_mps': speedMps,
      if (accuracyM != null) 'accuracy_m': accuracyM,
    };
    await config.load();
    // POST (bukan GET) supaya koordinat pengemudi tidak tercatat di access log / URL.
    final response = await _send(
      () => _client.post(
        _uri('/places/nearby'),
        headers: const {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw const PlacesApiException(
        PlacesApiErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
      );
    }
    try {
      return NearbyResult.fromJson(decoded);
    } on FormatException {
      throw PlacesApiException(
        PlacesApiErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> health({bool deep = false}) async {
    await config.load();
    final response = await _send(
      () => _client.get(
        _uri(deep ? '/places/health?deep=true' : '/places/health'),
        headers: const {'Accept': 'application/json'},
      ),
    );
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw const PlacesApiException(
        PlacesApiErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
      );
    }
    return decoded;
  }

  /// Kirim request, terjemahkan kegagalan jaringan, dan tolak status non-200.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on PlacesApiException {
      rethrow;
    } on TimeoutException {
      throw const PlacesApiException(
        PlacesApiErrorKind.timeout,
        'Server terlalu lama menjawab.',
      );
    } on SocketException {
      throw PlacesApiException(PlacesApiErrorKind.unreachable, _unreachableText());
    } on HandshakeException {
      throw PlacesApiException(
        PlacesApiErrorKind.unreachable,
        'Koneksi aman (HTTPS) ke server gagal. Cek alamat server.',
      );
    } on http.ClientException {
      throw PlacesApiException(PlacesApiErrorKind.unreachable, _unreachableText());
    }

    if (response.statusCode == 200) return response;
    throw _errorFor(response);
  }

  String _unreachableText() =>
      'Tidak bisa terhubung ke server (${config.baseUrl}). '
      'Pastikan server jalan dan HP satu jaringan dengan laptop.';

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  PlacesApiException _errorFor(http.Response response) {
    final code = response.statusCode;
    final detail = _detailMessage(_decode(response));
    switch (code) {
      case 404:
        return PlacesApiException(
          PlacesApiErrorKind.notConfigured,
          'Server belum punya fitur tempat terdekat. '
          'Pasang modul nearby_places di server.py lalu jalankan ulang.',
          statusCode: code,
        );
      case 422:
        return PlacesApiException(
          PlacesApiErrorKind.invalidRequest,
          detail ?? 'Lokasi ditolak server.',
          statusCode: code,
        );
      case 429:
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        return PlacesApiException(
          PlacesApiErrorKind.rateLimited,
          'Terlalu sering mencari. Coba lagi sebentar lagi.',
          statusCode: code,
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
        );
      case 503:
        return PlacesApiException(
          PlacesApiErrorKind.notConfigured,
          detail ?? 'Fitur tempat terdekat belum dikonfigurasi di server.',
          statusCode: code,
        );
      default:
        if (code >= 500) {
          return PlacesApiException(
            PlacesApiErrorKind.server,
            'Server bermasalah (kode $code).',
            statusCode: code,
          );
        }
        return PlacesApiException(
          PlacesApiErrorKind.badResponse,
          'Permintaan ditolak server (kode $code).',
          statusCode: code,
        );
    }
  }

  /// Ambil pesan manusiawi dari `{"detail": ...}` (bentuk FastAPI).
  String? _detailMessage(Object? decoded) {
    if (decoded is! Map) return null;
    final detail = decoded['detail'];
    if (detail is String) return detail;
    if (detail is Map) {
      final message = detail['message'];
      if (message is String && message.isNotEmpty) return message;
      return null;
    }
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map) {
        final msg = first['msg'];
        if (msg is String && msg.isNotEmpty) {
          return msg.replaceFirst('Value error, ', '');
        }
      }
    }
    return null;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
