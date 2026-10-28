import '../../models/detection_result.dart';

// ============================================================================
// MODEL — bentuk data untuk endpoint chat di server.py (lihat README_LLM.md).
// ============================================================================

/// Kondisi pengemudi yang ikut dikirim ke Buddy sebagai konteks.
/// Angka sensor tidak dibacakan LLM, hanya dipakai untuk menyesuaikan nada balasan.
class LlmDriverState {
  const LlmDriverState({
    this.status,
    this.yawnCount,
    this.blinkCount,
    this.tripMinutes,
  });

  /// Ambil langsung dari hasil DrowsinessDetector.
  factory LlmDriverState.fromDetection(
    DetectionResult result, {
    int? tripMinutes,
  }) => LlmDriverState(
    status: result.status,
    yawnCount: result.yawnCount,
    blinkCount: result.blinkCount,
    tripMinutes: tripMinutes,
  );

  final DriverStatus? status;

  /// Menguap dalam 5 menit terakhir.
  final int? yawnCount;

  /// Kedipan dalam 60 detik terakhir.
  final int? blinkCount;

  /// Sudah berapa menit menyetir.
  final int? tripMinutes;

  /// Nama status seperti yang dikenal server.
  static String statusName(DriverStatus status) {
    switch (status) {
      case DriverStatus.awake:
        return 'Awake';
      case DriverStatus.yawn:
        return 'Yawn';
      case DriverStatus.drowsy:
        return 'Drowsy';
      case DriverStatus.sleep:
        return 'Sleep';
      case DriverStatus.noFace:
        return 'No Face';
    }
  }

  Map<String, dynamic> toJson() => {
    if (status != null) 'status': statusName(status!),
    if (yawnCount != null) 'yawnCount': yawnCount,
    if (blinkCount != null) 'blinkCount': blinkCount,
    if (tripMinutes != null) 'tripMinutes': tripMinutes,
  };
}

/// Balasan Buddy. [reply] sudah teks polos pendek, aman langsung dibacakan TTS.
class LlmReply {
  const LlmReply({
    required this.reply,
    required this.sessionId,
    required this.provider,
    required this.model,
    required this.latencyMs,
    this.fallback = false,
    this.error,
  });

  factory LlmReply.fromJson(Map<String, dynamic> json) {
    final reply = json['reply'];
    if (reply is! String || reply.trim().isEmpty) {
      throw const FormatException('reply kosong');
    }
    return LlmReply(
      reply: reply,
      sessionId: json['session_id'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      model: json['model'] as String? ?? '',
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
      fallback: json['fallback'] == true,
      error: json['error'] as String?,
    );
  }

  final String reply;
  final String sessionId;

  /// groq | gemini | openai | custom | mock | offline (dibuat di aplikasi, server tidak terjangkau).
  final String provider;
  final String model;
  final int latencyMs;

  /// `true` = LLM gagal dan [reply] adalah balasan darurat bawaan (bukan dari LLM).
  final bool fallback;

  /// Penyebab fallback: timeout, network, rate_limited, auth, upstream, ...
  final String? error;
}

/// Hasil GET /chat/health.
class LlmHealth {
  const LlmHealth({
    required this.configured,
    required this.provider,
    this.model,
    this.problem,
    this.reachable,
    this.modelAvailable,
    this.error,
  });

  factory LlmHealth.fromJson(Map<String, dynamic> json) => LlmHealth(
    configured: json['status'] == 'ok',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String?,
    problem: json['problem'] as String?,
    reachable: json['reachable'] as bool?,
    modelAvailable: json['model_available'] as bool?,
    error: json['error'] as String?,
  );

  /// Server punya konfigurasi LLM yang lengkap (API key, model).
  final bool configured;
  final String provider;
  final String? model;

  /// Kalau belum dikonfigurasi: apa yang kurang (bahasa Indonesia dari server).
  final String? problem;

  /// Hanya terisi untuk `deep: true`: provider bisa dihubungi dengan API key itu?
  final bool? reachable;

  /// Hanya terisi untuk `deep: true`: nama model masih tersedia di provider?
  final bool? modelAvailable;
  final String? error;
}
