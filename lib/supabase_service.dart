import 'package:supabase_flutter/supabase_flutter.dart';
// Re-export agar main.dart tetap dapat mengakses supabaseUrl & supabaseAnonKey
export 'supabase_config.dart';

SupabaseClient get supabase => Supabase.instance.client;

// ============================================================================
// AUTH SERVICE
// ============================================================================

class AuthService {
  /// Register dengan email & password
  static Future<AuthResponse> register({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final response = await supabase.auth.signUp(
      email: email,
      password: password,
      data: {'full_name': fullName},
    );
    // Update nama di tabel profiles
    if (response.user != null) {
      await supabase
          .from('profiles')
          .update({'full_name': fullName})
          .eq('id', response.user!.id);
    }
    return response;
  }

  /// Login dengan email & password
  static Future<AuthResponse> login({
    required String email,
    required String password,
  }) async {
    return await supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Logout
  static Future<void> logout() async {
    await supabase.auth.signOut();
  }

  /// Cek apakah user sudah login
  static bool get isLoggedIn => supabase.auth.currentUser != null;

  /// Ambil user yang sedang login
  static User? get currentUser => supabase.auth.currentUser;

  /// Ambil nama user langsung dari metadata
  static String? get currentUserName =>
      currentUser?.userMetadata?['full_name'] as String?;

  /// Ambil nama user dari profiles
  static Future<String> getUserName() async {
    final user = currentUser;
    if (user == null) return 'Pengemudi';
    final data = await supabase
        .from('profiles')
        .select('full_name')
        .eq('id', user.id)
        .single();
    return data['full_name'] ?? user.email ?? 'Pengemudi';
  }
}

// ============================================================================
// SESSION SERVICE — Simpan & ambil data sesi mengemudi
// ============================================================================

class SessionService {
  /// Mulai sesi baru, return session ID
  static Future<String?> startSession() async {
    final user = AuthService.currentUser;
    if (user == null) return null;

    final data = await supabase
        .from('driving_sessions')
        .insert({
          'user_id': user.id,
          'started_at': DateTime.now().toIso8601String(),
        })
        .select('id')
        .single();

    return data['id'] as String?;
  }

  /// Simpan hasil akhir sesi
  static Future<void> endSession({
    required String sessionId,
    required int durationSeconds,
    required double avgSpeedKmh,
    required double maxSpeedKmh,
    required double distanceKm,
    required int drivingScore,
    required double avgBlinkRate,
    required int totalYawns,
    required int totalDrowsyEvents,
    required int totalMicrosleeps,
  }) async {
    await supabase.from('driving_sessions').update({
      'ended_at': DateTime.now().toIso8601String(),
      'duration_seconds': durationSeconds,
      'avg_speed_kmh': avgSpeedKmh,
      'max_speed_kmh': maxSpeedKmh,
      'distance_km': distanceKm,
      'driving_score': drivingScore,
      'avg_blink_rate': avgBlinkRate,
      'total_yawns': totalYawns,
      'total_drowsy_events': totalDrowsyEvents,
      'total_microsleeps': totalMicrosleeps,
    }).eq('id', sessionId);
  }

  /// Simpan satu titik GPS
  static Future<void> addGpsPoint({
    required String sessionId,
    required double latitude,
    required double longitude,
    required double speedKmh,
  }) async {
    await supabase.from('gps_tracks').insert({
      'session_id': sessionId,
      'latitude': latitude,
      'longitude': longitude,
      'speed_kmh': speedKmh,
    });
  }

  /// Log event kantuk
  static Future<void> logEvent({
    required String sessionId,
    required String eventType, // 'drowsy' | 'yawn' | 'microsleep'
  }) async {
    await supabase.from('detection_events').insert({
      'session_id': sessionId,
      'event_type': eventType,
    });
  }

  /// Ambil semua sesi milik user yang login (untuk riwayat)
  static Future<List<Map<String, dynamic>>> getUserSessions() async {
    final user = AuthService.currentUser;
    if (user == null) return [];

    final data = await supabase
        .from('driving_sessions')
        .select()
        .eq('user_id', user.id)
        .not('ended_at', 'is', null)
        .order('started_at', ascending: false);

    return List<Map<String, dynamic>>.from(data);
  }

  /// Ambil titik GPS untuk satu sesi (untuk peta rute)
  static Future<List<Map<String, dynamic>>> getGpsTracks(
      String sessionId) async {
    final data = await supabase
        .from('gps_tracks')
        .select()
        .eq('session_id', sessionId)
        .order('recorded_at', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
}
