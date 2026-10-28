import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/detection_result.dart';
import 'llm_chat_config.dart';
import 'llm_chat_models.dart';

// ============================================================================
// KLIEN API — memanggil modul `llm_chat` di server.py:
//   POST {baseUrl}/chat     GET {baseUrl}/chat/health     DELETE {baseUrl}/chat/{id}
// Aplikasi TIDAK memanggil Groq/LLM langsung; API key hanya di .env server.
// Semua kegagalan dibungkus LlmChatException dengan pesan bahasa Indonesia.
// Fitur ini TIDAK boleh membuat deteksi kantuk/alarm berhenti.
// ============================================================================

enum LlmChatErrorKind {
  /// Server tidak terjangkau (alamat salah, beda Wi-Fi, server mati, tanpa internet).
  unreachable,

  /// Server tidak menjawab dalam batas waktu.
  timeout,

  /// 404 (modul belum dipasang di server.py) atau 503 (API key/model belum diisi di .env).
  notConfigured,

  /// 429: terlalu banyak pesan.
  rateLimited,

  /// 422: pesan/session_id ditolak server.
  invalidRequest,

  /// 5xx lainnya.
  server,

  /// Jawaban bukan JSON yang diharapkan.
  badResponse,
}

class LlmChatException implements Exception {
  const LlmChatException(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  final LlmChatErrorKind kind;

  /// Bahasa Indonesia, siap ditampilkan ke pengguna.
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => 'LlmChatException(${kind.name}, $statusCode): $message';
}

class LlmChatApi {
  LlmChatApi({
    LlmChatConfig? config,
    http.Client? client,
    // Harus lebih lama dari batas server (LLM_TIMEOUT_S bawaan 8 dtk, ditambah 1x ulang
    // untuk error jaringan), supaya app tidak menyerah duluan.
    this.timeout = const Duration(seconds: 25),
  }) : config = config ?? LlmChatConfig.shared,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final LlmChatConfig config;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  static const int maxMessageChars = 500;
  static final RegExp _sessionIdPattern = RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$');

  /// Balasan darurat kalau server tidak bisa dipakai. Sama dengan FALLBACK_REPLIES di server.
  static const List<String> offlineReplies = [
    'Maaf, aku lagi susah nyambung. Tetap fokus ke jalan ya, nanti kita ngobrol lagi.',
    'Maaf, koneksiku lagi bermasalah. Kamu kelihatan mulai ngantuk, cari tempat aman buat berhenti dan istirahat sebentar ya.',
    'Kamu kelihatan sangat ngantuk. Segera menepi di tempat yang aman dan istirahat dulu ya.',
  ];

  // Sama dengan _SLEEPY_WORDS di llm_chat/prompts.py.
  static const List<String> _sleepyWords = [
    'ngantuk',
    'mengantuk',
    'kantuk',
    'capek',
    'lelah',
    'letih',
    'lemes',
    'lemas',
    'mau tidur',
    'pengen tidur',
    'tertidur',
    'sleepy',
    'tired',
    'drowsy',
  ];

  /// Ubah id apa pun (mis. uid Firebase, email) jadi session_id yang diterima server.
  static String sanitizeSessionId(String raw) {
    var id = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.:\-]'), '_');
    if (id.isEmpty) id = 'anon';
    return id.length > 64 ? id.substring(0, 64) : id;
  }

  /// Kirim ucapan pengemudi, terima balasan Buddy.
  ///
  /// Kalau LLM di server gagal, server tetap menjawab dengan `fallback: true`.
  /// Exception hanya dilempar kalau server.py sendiri tidak bisa dipakai.
  Future<LlmReply> send({
    required String sessionId,
    required String message,
    LlmDriverState? driverState,
    bool reset = false,
  }) async {
    final text = message.trim();
    if (text.isEmpty || text.length > maxMessageChars) {
      throw const LlmChatException(
        LlmChatErrorKind.invalidRequest,
        'Pesan harus 1 sampai $maxMessageChars karakter.',
      );
    }
    if (!_sessionIdPattern.hasMatch(sessionId)) {
      throw const LlmChatException(
        LlmChatErrorKind.invalidRequest,
        'session_id tidak valid. Pakai LlmChatApi.sanitizeSessionId().',
      );
    }
    final body = <String, dynamic>{
      'session_id': sessionId,
      'message': text,
      if (driverState != null) 'driver_state': driverState.toJson(),
      if (reset) 'reset': true,
    };
    await config.load();
    final response = await _send(
      () => _client.post(
        _uri('/chat'),
        headers: const {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw const LlmChatException(
        LlmChatErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
      );
    }
    try {
      return LlmReply.fromJson(decoded);
    } on FormatException {
      throw LlmChatException(
        LlmChatErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
        statusCode: response.statusCode,
      );
    } on TypeError {
      throw LlmChatException(
        LlmChatErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
        statusCode: response.statusCode,
      );
    }
  }

  /// Seperti [send], tapi TIDAK PERNAH melempar error: kalau server tidak bisa dipakai,
  /// hasilnya balasan darurat (`fallback: true`, provider `offline`) yang tetap membawa
  /// pesan keselamatan. Cocok untuk langsung dibacakan TTS.
  Future<LlmReply> sendSafe({
    required String sessionId,
    required String message,
    LlmDriverState? driverState,
    bool reset = false,
  }) async {
    try {
      return await send(
        sessionId: sessionId,
        message: message,
        driverState: driverState,
        reset: reset,
      );
    } on LlmChatException catch (e) {
      return LlmReply(
        reply: offlineReply(driverState, message),
        sessionId: sessionId,
        provider: 'offline',
        model: '',
        latencyMs: 0,
        fallback: true,
        error: e.kind.name,
      );
    }
  }

  /// Balasan darurat berdasarkan tingkat kantuk (0 aman, 1 mulai ngantuk, 2 bahaya).
  static String offlineReply(LlmDriverState? state, [String message = '']) {
    final status = state?.status;
    if (status == DriverStatus.sleep) return offlineReplies[2];
    if (status == DriverStatus.drowsy || status == DriverStatus.yawn) {
      return offlineReplies[1];
    }
    final low = message.toLowerCase();
    return _sleepyWords.any(low.contains)
        ? offlineReplies[1]
        : offlineReplies[0];
  }

  /// Status modul LLM di server. `deep: true` = sekalian tes API key + nama model ke provider
  /// (tidak memakai token, hasilnya di-cache server 30 dtk).
  Future<LlmHealth> health({bool deep = false}) async {
    await config.load();
    final response = await _send(
      () => _client.get(
        _uri(deep ? '/chat/health?deep=true' : '/chat/health'),
        headers: const {'Accept': 'application/json'},
      ),
    );
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw const LlmChatException(
        LlmChatErrorKind.badResponse,
        'Jawaban server tidak dikenali.',
      );
    }
    return LlmHealth.fromJson(decoded);
  }

  /// Lupakan riwayat percakapan satu sesi (mis. saat perjalanan selesai).
  /// `true` kalau server memang menyimpan riwayat untuk sesi itu.
  Future<bool> clear(String sessionId) async {
    await config.load();
    final response = await _send(
      () => _client.delete(
        _uri('/chat/${Uri.encodeComponent(sessionId)}'),
        headers: const {'Accept': 'application/json'},
      ),
    );
    final decoded = _decode(response);
    return decoded is Map<String, dynamic> && decoded['cleared'] == true;
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Uri _uri(String path) {
    try {
      return Uri.parse('${config.baseUrl}$path');
    } on FormatException {
      throw LlmChatException(
        LlmChatErrorKind.unreachable,
        'Alamat server tidak valid: ${config.baseUrl}',
      );
    }
  }

  /// Kirim request, terjemahkan kegagalan jaringan, dan tolak status non-200.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on LlmChatException {
      rethrow;
    } on TimeoutException {
      throw const LlmChatException(
        LlmChatErrorKind.timeout,
        'Buddy terlalu lama menjawab.',
      );
    } on SocketException {
      throw LlmChatException(LlmChatErrorKind.unreachable, _unreachableText());
    } on HandshakeException {
      throw const LlmChatException(
        LlmChatErrorKind.unreachable,
        'Koneksi aman (HTTPS) ke server gagal. Cek alamat server.',
      );
    } on http.ClientException {
      throw LlmChatException(LlmChatErrorKind.unreachable, _unreachableText());
    }

    if (response.statusCode == 200) return response;
    throw _errorFor(response);
  }

  String _unreachableText() =>
      'Tidak bisa terhubung ke server Buddy (${config.baseUrl}). '
      'Pastikan server.py jalan dan HP satu jaringan dengan laptop.';

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  LlmChatException _errorFor(http.Response response) {
    final code = response.statusCode;
    final detail = _decode(response);
    switch (code) {
      case 404:
        return LlmChatException(
          LlmChatErrorKind.notConfigured,
          'Server belum punya fitur chat. '
          'Pasang modul llm_chat di server.py lalu jalankan ulang.',
          statusCode: code,
        );
      case 422:
        return LlmChatException(
          LlmChatErrorKind.invalidRequest,
          'Pesan ditolak server.',
          statusCode: code,
        );
      case 429:
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        return LlmChatException(
          LlmChatErrorKind.rateLimited,
          'Terlalu sering ngobrol. Coba lagi sebentar lagi.',
          statusCode: code,
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
        );
      case 503:
        return LlmChatException(
          LlmChatErrorKind.notConfigured,
          _detailMessage(detail) ?? 'Chat LLM belum dikonfigurasi di server.',
          statusCode: code,
        );
      default:
        return LlmChatException(
          code >= 500 ? LlmChatErrorKind.server : LlmChatErrorKind.badResponse,
          'Server bermasalah (HTTP $code).',
          statusCode: code,
        );
    }
  }

  /// FastAPI: {"detail": {"error": "...", "message": "..."}} atau {"detail": "..."}.
  String? _detailMessage(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final detail = decoded['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is Map<String, dynamic>) {
      final message = detail['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return null;
  }
}
