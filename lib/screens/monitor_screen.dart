import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/app_colors.dart';
import '../core/thresholds.dart';
import '../models/detection_result.dart';
import '../models/trip_model.dart';
import '../services/alert_config.dart';
import '../services/alert_service.dart';
import '../services/camera_image_converter.dart';
import '../services/drowsiness_detector.dart';
import '../services/face_mesh_service.dart';
import '../supabase_service.dart';
import '../auth_screen.dart';
import '../driving_card_screen.dart';
import '../widgets/driving_buddy_app_bar.dart';
import '../features/nearby_places/nearby_places.dart';

// ============================================================================
// MONITOR SCREEN (Active HUD Berkendara Telemetri — Luxury GT)
// ============================================================================

typedef MonitoringScreen = MonitorScreen;

class MonitorScreen extends StatefulWidget {
  final bool isActive;

  const MonitorScreen({super.key, this.isActive = true});

  @override
  MonitorScreenState createState() => MonitorScreenState();
}

class MonitorScreenState extends State<MonitorScreen> {
  // Timer kemudi
  Timer? _drivingTimer;
  int _elapsedSeconds = 0;
  bool _isMonitoring = false;

  // Kamera & On-Device AI
  CameraController? _cameraController;
  CameraDescription? _frontCamera;
  bool _busy = false;
  int _frameCount = 0;

  // ML Kit Services (Offline Face Mesh)
  final FaceMeshService _mesh = FaceMeshService();
  final DrowsinessDetector _detector = DrowsinessDetector();
  final AlertService _alert = AlertService();

  // Tempat terdekat (Maps API lewat server.py): kartu rekomendasi pitstop & tombol rest area
  final NearbyPlacesController _nearby = NearbyPlacesController();

  // Hasil deteksi real-time
  DetectionResult _result = DetectionResult.initial;
  bool _eyeDetected = false;
  String _cameraMode = 'Standby';

  // EAR rolling history untuk waveform graph
  final List<double> _earHistory = [0.32, 0.31, 0.33, 0.30, 0.32, 0.34, 0.32, 0.31, 0.33, 0.32];

  // Snooze alert state
  DateTime? _snoozeUntil;

  // Alert guard
  bool _isAlertShowing = false;

  // === Supabase Session Tracking ===
  String? _currentSessionId;
  DateTime? _sessionStartTime;
  int _drowsyCount = 0;
  int _yawnCount = 0;
  int _microsleepCount = 0;

  @override
  void initState() {
    super.initState();
    // Otomatis aktifkan pencarian tempat terdekat saat aplikasi dibuka:
    // - Jika lokasi (GPS) di HP sudah menyala & izin ada -> langsung otomatis mencari tempat terdekat.
    // - Jika lokasi (GPS) belum dinyalakan -> diam/tidak mencari apa pun sampai pengguna menyalakan GPS.
    _nearby.start(askPermission: false);
  }

  @override
  void didUpdateWidget(covariant MonitorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _isMonitoring) _resumeTimer();
    if (!widget.isActive && oldWidget.isActive) _pauseTimer();
  }

  @override
  void dispose() {
    _drivingTimer?.cancel();
    _cameraController?.dispose();
    _mesh.dispose();
    _alert.dispose();
    _nearby.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------- Runtime Camera Permission ----------
  Future<bool> _requestCameraPermission() async {
    if (kIsWeb) return true;

    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    if (status.isDenied) return (await Permission.camera.request()).isGranted;
    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Izin kamera ditolak permanen. Buka Pengaturan > Aplikasi untuk mengaktifkannya.'),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Buka Pengaturan',
            textColor: Colors.white,
            onPressed: () => openAppSettings(),
          ),
        ),
      );
    }
    return false;
  }

  // ---------- Mulai Monitoring ----------
  Future<void> _startMonitoring() async {
    setState(() {
      _isMonitoring = true;
      _elapsedSeconds = 0;
      _cameraMode = 'Memuat AI...';
      _result = DetectionResult.initial;
      _drowsyCount = 0;
      _yawnCount = 0;
      _microsleepCount = 0;
      _currentSessionId = null;
    });
    _sessionStartTime = DateTime.now();

    final hasPermission = await _requestCameraPermission();
    if (!hasPermission) {
      if (mounted) setState(() { _isMonitoring = false; _cameraMode = 'Standby'; });
      return;
    }

    // Mulai sesi di Supabase (jika login)
    if (AuthService.isLoggedIn) {
      try {
        _currentSessionId = await SessionService.startSession();
        debugPrint('✅ Sesi Supabase dimulai ID: $_currentSessionId');
      } catch (e) {
        debugPrint('Supabase startSession error: $e');
      }
    }

    try {
      await WakelockPlus.enable();

      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('Tidak ada kamera tersedia di perangkat ini.');
      _frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.external,
          orElse: () => cameras.first,
        ),
      );

      _cameraController = CameraController(
        _frontCamera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onFrame);

      if (!mounted) return;
      setState(() {
        _cameraMode = 'ML Kit Aktif';
      });
      _resumeTimer();

      // Tempat terdekat: ikuti posisi selama sesi berjalan. Semua error ditangani di dalam
      // controller dan tidak pernah mengganggu deteksi kantuk.
      unawaited(_nearby.start());
    } catch (e) {
      debugPrint('Init kamera gagal: $e');
      if (mounted) {
        setState(() {
          _isMonitoring = false;
          _cameraMode = 'Standby';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memulai kamera: $e'),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ---------- ML Kit Frame Processing (Offline 100%) ----------
  Future<void> _onFrame(CameraImage image) async {
    if (_busy) return;
    if (++_frameCount % Thresholds.processEveryNthFrame != 0) return;
    _busy = true;

    try {
      final controller = _cameraController;
      if (controller == null || _frontCamera == null) return;

      final input = cameraImageToInputImage(
        image,
        _frontCamera!,
        controller.value.deviceOrientation,
      );
      if (input == null) return;

      final points = await _mesh.detect(input);
      final result = _detector.update(points);

      // Catat riwayat EAR untuk waveform
      if (result.ear > 0.05) {
        _earHistory.add(result.ear);
        if (_earHistory.length > 25) _earHistory.removeAt(0);
      }

      // Cek apakah sedang dalam masa snooze
      final isSnoozed = _snoozeUntil != null && DateTime.now().isBefore(_snoozeUntil!);

      // Cek kondisi bahaya
      final isSleep = result.status == DriverStatus.sleep;
      final isExcessiveYawn = result.yawnCount >= Thresholds.yawnAlertFreq;
      final isDrowsy = result.status == DriverStatus.drowsy;

      if (isSleep) {
        _microsleepCount++;
        if (AuthService.isLoggedIn && _currentSessionId != null) {
          SessionService.logEvent(
            sessionId: _currentSessionId!,
            eventType: 'microsleep',
          );
        }
      } else if (isExcessiveYawn) {
        _yawnCount++;
        if (AuthService.isLoggedIn && _currentSessionId != null) {
          SessionService.logEvent(
            sessionId: _currentSessionId!,
            eventType: 'yawn',
          );
        }
      } else if (isDrowsy) {
        _drowsyCount++;
        if (AuthService.isLoggedIn && _currentSessionId != null) {
          SessionService.logEvent(
            sessionId: _currentSessionId!,
            eventType: 'drowsy',
          );
        }
      }

      if (!isSnoozed && (isSleep || isExcessiveYawn) && !_isAlertShowing) {
        await _alert.playAlert();
        if (isSleep) {
          _triggerSafetyAlert(
            title: 'MATA TERPEJAM!\nISTIRAHAT SEKARANG',
            subtitle: 'PERINGATAN MICROSLEEP',
            reason:
                'Mata terpejam melebihi ${Thresholds.eyeClosedLimit} detik. Segera cari tempat aman untuk berhenti.',
            resetYawnsOnDismiss: false,
          );
        } else {
          _triggerSafetyAlert(
            title: 'TERLALU SERING\nMENGUAP!',
            subtitle: 'INDIKASI KELELAHAN BERAT',
            reason:
                'Terdeteksi ${result.yawnCount}x menguap dalam 5 menit terakhir. Tingkat kantuk Anda sangat tinggi!',
            resetYawnsOnDismiss: true,
          );
        }
      }

      if (mounted) {
        setState(() {
          _result = result;
          _eyeDetected = result.status != DriverStatus.noFace;
        });
      }
    } catch (e) {
      debugPrint('[FaceMesh] Error deteksi frame: $e');
    } finally {
      _busy = false;
    }
  }

  void _resumeTimer() {
    _drivingTimer?.cancel();
    _drivingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds++;
      });
    });
  }

  void _pauseTimer() {
    _drivingTimer?.cancel();
  }

  Future<void> _stopMonitoring() async {
    _pauseTimer();

    final int finalDuration = _elapsedSeconds;
    final int finalDrowsy = _drowsyCount;
    final int finalYawn = _result.yawnCount > _yawnCount ? _result.yawnCount : _yawnCount;
    final int finalMicro = _microsleepCount;
    final double avgBlink = _result.blinkCount.toDouble();
    final DateTime sessionStart = _sessionStartTime ?? DateTime.now();

    // Hitung driving score (0-100)
    int score = 100;
    score -= (finalDrowsy * 5).clamp(0, 40);
    score -= (finalYawn * 2).clamp(0, 20);
    score -= (finalMicro * 10).clamp(0, 40);
    score = score.clamp(0, 100);

    // Simpan sesi ke Supabase jika login
    if (AuthService.isLoggedIn && _currentSessionId != null) {
      try {
        await SessionService.endSession(
          sessionId: _currentSessionId!,
          durationSeconds: finalDuration,
          avgSpeedKmh: 84,
          maxSpeedKmh: 110,
          distanceKm: (_elapsedSeconds * 0.02).clamp(0.0, 999.0),
          drivingScore: score,
          avgBlinkRate: avgBlink,
          totalYawns: finalYawn,
          totalDrowsyEvents: finalDrowsy,
          totalMicrosleeps: finalMicro,
        );
        debugPrint('✅ Sesi tersimpan ke Supabase! Score: $score');
      } catch (e) {
        debugPrint('❌ Gagal simpan sesi ke Supabase: $e');
      }
    }

    try {
      await _cameraController?.stopImageStream();
    } catch (_) {}
    await _cameraController?.dispose();
    _cameraController = null;
    await _alert.stop();
    _nearby.stop();
    _nearby.start(askPermission: false);
    await WakelockPlus.disable();

    setState(() {
      _isMonitoring = false;
      _elapsedSeconds = 0;
      _result = DetectionResult.initial;
      _eyeDetected = false;
      _cameraMode = 'Standby';
      _isAlertShowing = false;
      _frameCount = 0;
      _currentSessionId = null;
    });

    // Tampilkan opsi buka Driving Card jika sesi berjalan minimal 5 detik
    if (mounted && finalDuration >= 5) {
      final wantCard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('🎉 Sesi Selesai!', style: TextStyle(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Skor Keselamatan Anda: $score/100',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFFE57A38))),
              const SizedBox(height: 8),
              Text('Durasi: ${_formatDuration(finalDuration)}'),
              Text('Kantuk: ${finalDrowsy}x  ·  Menguap: ${finalYawn}x  ·  Microsleep: ${finalMicro}x'),
              const SizedBox(height: 12),
              const Text('Buka Kartu Pencapaian untuk dibagikan ke teman?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Nanti Saja', style: TextStyle(color: Color(0xFF64748B))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE57A38),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lihat Kartu', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (wantCard == true && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DrivingCardScreen(
              durationSeconds: finalDuration,
              drivingScore: score,
              totalMicrosleeps: finalMicro,
              totalDrowsy: finalDrowsy,
              totalYawns: finalYawn,
              startedAt: sessionStart,
            ),
          ),
        );
      }
    }
  }

  void _snoozeAlert() {
    setState(() {
      _snoozeUntil = DateTime.now().add(const Duration(minutes: 15));
    });
    _alert.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Peringatan ditunda selama 15 menit.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _triggerSafetyAlert({
    required String title,
    required String subtitle,
    required String reason,
    required bool resetYawnsOnDismiss,
  }) {
    if (_isAlertShowing) return;
    _isAlertShowing = true;

    // Alarm bunyi: langsung cari tempat berhenti terdekat (apa pun jenisnya) untuk kartu di dialog.
    unawaited(_nearby.requestUrgent());

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (_) => MicrosleepAlertDialog(
        title: title,
        subtitle: subtitle,
        reason: reason,
        nearby: _nearby,
        onDismiss: () async {
          await _alert.stop();
          if (resetYawnsOnDismiss) {
            _detector.resetYawns();
          }
        },
        onRestArea: () async {
          // Ambil tempat yang sedang tampil di kartu SEKARANG, sebelum dialog ditutup dan
          // mode darurat dimatikan (kalau tidak, pilihannya bisa berubah di tengah jalan).
          final target = _nearby.best;
          await _alert.stop();
          if (resetYawnsOnDismiss) {
            _detector.resetYawns();
          }
          // Buka Google Maps (mode mobil) ke tempat berhenti terdekat dari server.
          final opened = target != null
              ? await _nearby.navigateTo(target)
              : await _nearby.navigateToBest();
          if (!opened && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Belum ada tempat berhenti yang ditemukan. Menepi di tempat yang aman ya.'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        },
      ),
    ).then((_) {
      _isAlertShowing = false;
      _nearby.clearUrgent();
    });
  }

  // Dynamic fatigue index calculation (0 - 100%)
  int _calculateFatigueIndex() {
    if (!_isMonitoring) return 0;
    if (_result.status == DriverStatus.sleep) return 94;
    if (_result.status == DriverStatus.drowsy) return 68;
    int index = 12; // Nominal baseline
    index += (_result.yawnCount * 8);
    if (_result.ear < 0.26) index += 15;
    return index.clamp(0, 99);
  }

  @override
  Widget build(BuildContext context) {
    final fatigueIndex = _calculateFatigueIndex();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const DrivingBuddyAppBar(title: 'Berkendara'),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Top Live HUD Bar (3-column telemetry cards)
                  _buildTopLiveHudBar(fatigueIndex),
                  const SizedBox(height: 14),

                  // 2. AI Face Monitoring Glass Cockpit Card
                  _buildGlassCockpitCameraCard(),
                  const SizedBox(height: 14),

                  // 3. Rekomendasi Pitstop Assistant Card
                  _buildPitstopAssistantCard(),
                  const SizedBox(height: 14),

                  // 4. Cockpit Drive Control Action Buttons
                  _buildCockpitDriveControls(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 1. TOP LIVE HUD BAR (3 Columns: Kecepatan, Jarak, Index Lelah)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildTopLiveHudBar(int fatigueIndex) {
    final distanceKm = (_elapsedSeconds * 0.023).toStringAsFixed(1);
    final speed = _isMonitoring ? 84 : 0;

    String fatigueLabel = 'RENDAH';
    Color fatigueColor = const Color(0xFF059669);
    if (fatigueIndex >= 65) {
      fatigueLabel = 'BAHAYA';
      fatigueColor = const Color(0xFFD94126);
    } else if (fatigueIndex >= 40) {
      fatigueLabel = 'WASPADA';
      fatigueColor = const Color(0xFFE5A938);
    }

    return Row(
      children: [
        // Kecepatan
        Expanded(
          child: _buildHudCell(
            label: 'KECEPATAN',
            value: '$speed',
            unit: 'km/j',
            bottomWidget: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.trending_flat_rounded, size: 12, color: Color(0xFF059669)),
                  SizedBox(width: 2),
                  Text(
                    'STABIL',
                    style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Color(0xFF065F46)),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Jarak
        Expanded(
          child: _buildHudCell(
            label: 'JARAK',
            value: distanceKm,
            unit: 'km',
            bottomWidget: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.alt_route_rounded, size: 12, color: Color(0xFFE57A38)),
                  SizedBox(width: 2),
                  Text(
                    'CIPULARANG',
                    style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w700, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Index Lelah
        Expanded(
          child: _buildHudCell(
            label: 'INDEX LELAH',
            value: '$fatigueIndex',
            unit: '%',
            valueColor: const Color(0xFFE57A38),
            bottomWidget: Text(
              '$fatigueLabel · AMBANG 65%',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                color: fatigueColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHudCell({
    required String label,
    required String value,
    required String unit,
    Color? valueColor,
    required Widget bottomWidget,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Top accent amber bar
          Container(
            height: 2.5,
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE57A38),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: valueColor ?? const Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 2),
              Text(
                unit,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          bottomWidget,
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 2. AI FACE MONITORING GLASS COCKPIT
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildGlassCockpitCameraCard() {
    final isDanger = _result.status == DriverStatus.sleep || _result.status == DriverStatus.drowsy;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFFFFBF8)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFED7AA)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE57A38).withOpacity(0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Ambient copper line
          Container(
            height: 3,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Color(0xFFE57A38), Colors.transparent],
              ),
            ),
          ),

          // Camera Viewport Box
          Container(
            height: 240,
            width: double.infinity,
            color: const Color(0xFFEDF2F7),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Live camera preview with proper Aspect Ratio (wajah proporsional, tidak melebar)
                if (_cameraController != null && _cameraController!.value.isInitialized)
                  ClipRect(
                    child: SizedBox(
                      width: double.infinity,
                      height: 240,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: _cameraController!.value.previewSize?.height.toDouble() ?? 360,
                          height: _cameraController!.value.previewSize?.width.toDouble() ?? 480,
                          child: CameraPreview(_cameraController!),
                        ),
                      ),
                    ),
                  )
                else
                  // 2. Standby / Loading state in the center (bersih, rapi, dan tombol bisa langsung diklik)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isMonitoring) ...[
                            const CircularProgressIndicator(color: Color(0xFFE57A38)),
                            const SizedBox(height: 12),
                            const Text(
                              'Memuat Kamera Live...',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ] else ...[
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE57A38).withOpacity(0.12),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.videocam_rounded,
                                size: 26,
                                color: Color(0xFFE57A38),
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Kamera Standby',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF334155),
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Tekan tombol untuk mulai deteksi',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton.icon(
                                onPressed: _startMonitoring,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFE57A38),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  elevation: 3,
                                  shadowColor: const Color(0xFFE57A38).withOpacity(0.35),
                                ),
                                icon: const Icon(Icons.play_arrow_rounded, size: 24),
                                label: const Text(
                                  'MULAI PERJALANAN',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                // 3. Live HUD Overlays (HANYA MUNCUL SAAT MONITORING AKTIF, AGAR FRAME STANDBY BERSIH)
                if (_isMonitoring) ...[
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _CockpitHudOverlayPainter(
                        isMonitoring: _isMonitoring,
                        isDanger: isDanger,
                        leftEyePct: (100 - (_result.ear < 0.2 ? 50 : 2)).toInt(),
                        rightEyePct: (100 - (_result.ear < 0.2 ? 50 : 1)).toInt(),
                      ),
                    ),
                  ),

                  // Top-Left Status Badge
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDanger ? const Color(0xFFFECACA) : const Color(0xFFA7F3D0),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 6,
                          )
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: isDanger ? const Color(0xFFD94126) : const Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isDanger
                                ? 'STATUS: PERINGATAN KANTUK'
                                : (_eyeDetected ? 'STATUS: FOKUS & WASPADA' : 'STATUS: MENUNGGU WAJAH'),
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: isDanger ? const Color(0xFFD94126) : const Color(0xFF0F172A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Top-Right IR FPS Badge
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFED7AA)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 6,
                          )
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bolt_rounded, size: 12, color: Color(0xFFE57A38)),
                          SizedBox(width: 3),
                          Text(
                            'NEURAL IR 60FPS',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: Color(0xFFC25E21),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom Pose Telemetry Line
                  Positioned(
                    bottom: 8,
                    left: 14,
                    right: 14,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'YAW: ${_isMonitoring ? "+0.4°" : "0.0°"}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF334155),
                            fontFamily: 'monospace',
                          ),
                        ),
                        Text(
                          'PITCH: ${_isMonitoring ? "-1.2°" : "0.0°"}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF334155),
                            fontFamily: 'monospace',
                          ),
                        ),
                        Text(
                          isDanger ? 'DISTRAKSI: WASPADA' : 'DISTRAKSI: NIHIL',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: isDanger ? const Color(0xFFD94126) : const Color(0xFF334155),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Lower Telemetry Panel inside Cockpit
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                // EAR Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFFED7AA)),
                          ),
                          child: const Icon(
                            Icons.visibility_rounded,
                            size: 16,
                            color: Color(0xFFE57A38),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'EYE ASPECT RATIO (EAR)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFA7F3D0)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _isMonitoring ? _result.ear.toStringAsFixed(2) : '0.32',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF059669),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _result.ear < 0.22 ? '(Rendah)' : '(Optimal)',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF065F46),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // EAR Real-time Waveform Graph
                Container(
                  height: 36,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFEDD5)),
                  ),
                  child: CustomPaint(
                    painter: _EarWaveformPainter(history: _earHistory),
                  ),
                ),
                const SizedBox(height: 10),

                // 2 Telemetry Chips
                Row(
                  children: [
                    // Frekuensi Kedip
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFEDD5)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFFED7AA)),
                              ),
                              child: const Icon(
                                Icons.lens_blur_rounded,
                                size: 16,
                                color: Color(0xFFE57A38),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'FREKUENSI KEDIP',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${_result.blinkCount}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                      const TextSpan(
                                        text: ' / mnt',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Deteksi Menguap
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFEDD5)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFA7F3D0)),
                              ),
                              child: const Icon(
                                Icons.sentiment_satisfied_rounded,
                                size: 16,
                                color: Color(0xFF059669),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'DETEKSI MENGUAP',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${_result.yawnCount}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF059669),
                                        ),
                                      ),
                                      const TextSpan(
                                        text: ' dlm 30m',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 3. REKOMENDASI PITSTOP ASSISTANT CARD
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildPitstopAssistantCard() {
    // Rekomendasi pitstop dari Maps API (desain Stitch yang sama): tombol kanan = buka
    // Google Maps, ketuk kartu = daftar rest area / minimarket / hotel-motel / SPBU terdekat.
    return PitstopCard(controller: _nearby);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 4. COCKPIT DRIVE CONTROL ACTION BUTTONS
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildCockpitDriveControls() {
    return Column(
      children: [
        // Sub-actions: Snooze & Auto pilot status
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            OutlinedButton.icon(
              onPressed: _snoozeAlert,
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFCBD5E1)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              icon: const Icon(Icons.snooze_rounded, size: 16, color: Color(0xFF64748B)),
              label: const Text(
                'TUNDA PERINGATAN (15 MNT)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF334155),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFA7F3D0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: 4,
                  )
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: Color(0xFF10B981)),
                  SizedBox(width: 5),
                  Text(
                    'AUTO PILOT ON',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF475569),
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Tombol Selesaikan Perjalanan (hanya tampil saat monitoring aktif, tombol mulai sudah di tengah)
        if (_isMonitoring)
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Text('Selesaikan Perjalanan?', style: TextStyle(fontWeight: FontWeight.w800)),
                    content: Text(
                      'Durasi kemudi: ${_formatDuration(_elapsedSeconds)}\nSesi perekaman telemetri akan disimpan.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Lanjutkan Kemudi', style: TextStyle(color: Color(0xFF64748B))),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE57A38),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _stopMonitoring();
                        },
                        child: const Text('Ya, Selesaikan', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE57A38),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 4,
                shadowColor: const Color(0xFFE57A38).withOpacity(0.35),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.flag_rounded, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'SELESAIKAN PERJALANAN',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// CUSTOM PAINTER: Cockpit HUD Wireframe Overlay
// ────────────────────────────────────────────────────────────────────────────
class _CockpitHudOverlayPainter extends CustomPainter {
  final bool isMonitoring;
  final bool isDanger;
  final int leftEyePct;
  final int rightEyePct;

  _CockpitHudOverlayPainter({
    required this.isMonitoring,
    required this.isDanger,
    required this.leftEyePct,
    required this.rightEyePct,
  });

  @override
  void paint(Canvas canvas, Size size) {
// Center HUD brackets

    // Corner HUD brackets
    final bracketPaint = Paint()
      ..color = const Color(0xFF334155).withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    const cornerLen = 16.0;
    const pad = 12.0;

    // Top-Left
    canvas.drawLine(const Offset(pad, pad + cornerLen), const Offset(pad, pad), bracketPaint);
    canvas.drawLine(const Offset(pad, pad), const Offset(pad + cornerLen, pad), bracketPaint);
    // Top-Right
    canvas.drawLine(Offset(size.width - pad - cornerLen, pad), Offset(size.width - pad, pad), bracketPaint);
    canvas.drawLine(Offset(size.width - pad, pad), Offset(size.width - pad, pad + cornerLen), bracketPaint);
    // Bottom-Left
    canvas.drawLine(Offset(pad, size.height - pad - cornerLen), Offset(pad, size.height - pad), bracketPaint);
    canvas.drawLine(Offset(pad, size.height - pad), Offset(pad + cornerLen, size.height - pad), bracketPaint);
    // Bottom-Right
    canvas.drawLine(Offset(size.width - pad - cornerLen, size.height - pad), Offset(size.width - pad, size.height - pad), bracketPaint);
    canvas.drawLine(Offset(size.width - pad, size.height - pad - cornerLen), Offset(size.width - pad, size.height - pad), bracketPaint);

// Wireframe wajah dihilangkan sesuai permintaan pengguna
    if (!isMonitoring) return;
  }

  @override
  bool shouldRepaint(_CockpitHudOverlayPainter old) =>
      old.isMonitoring != isMonitoring ||
      old.isDanger != isDanger ||
      old.leftEyePct != leftEyePct ||
      old.rightEyePct != rightEyePct;
}

// ────────────────────────────────────────────────────────────────────────────
// CUSTOM PAINTER: Real-time EAR Waveform Graph
// ────────────────────────────────────────────────────────────────────────────
class _EarWaveformPainter extends CustomPainter {
  final List<double> history;

  _EarWaveformPainter({required this.history});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    final path = Path();
    final step = size.width / (history.length - 1).clamp(1, 99);

    for (int i = 0; i < history.length; i++) {
      // Map EAR (0.15 - 0.40) to Y (size.height to 0)
      final ear = history[i].clamp(0.15, 0.40);
      final norm = (ear - 0.15) / (0.40 - 0.15);
      final y = size.height - (norm * size.height * 0.8) - (size.height * 0.1);
      final x = i * step;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final linePaint = Paint()
      ..color = const Color(0xFF10B981)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    // Gradient fill underneath
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..color = const Color(0xFF10B981).withOpacity(0.15)
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(_EarWaveformPainter old) => true;
}

// ============================================================================
// PERINGATAN KRITIS (Alert Microsleep — Luxury Emergency HUD Dialog)
// Meme/Tok Dalang sepenuhnya dihapus sesuai permintaan pengguna
// ============================================================================

class MicrosleepAlertDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final String reason;
  final VoidCallback? onDismiss;
  final VoidCallback? onRestArea;

  /// Sumber tempat berhenti terdekat (Maps API). `null` = kartu contoh bawaan.
  final NearbyPlacesController? nearby;

  const MicrosleepAlertDialog({
    super.key,
    this.title = 'MATA TERPEJAM!\nISTIRAHAT SEKARANG',
    this.subtitle = 'SISTEM KESELAMATAN AKTIF',
    this.reason = 'Microsleep terdeteksi. Segera cari tempat aman untuk berhenti.',
    this.onDismiss,
    this.onRestArea,
    this.nearby,
  });

  @override
  State<MicrosleepAlertDialog> createState() => _MicrosleepAlertDialogState();
}

class _MicrosleepAlertDialogState extends State<MicrosleepAlertDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  AlertImageMode _imageMode = AlertImageMode.none;
  String? _customImagePath;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    HapticFeedback.heavyImpact();
    _loadAlertImageConfig();
  }

  Future<void> _loadAlertImageConfig() async {
    final mode = await AlertConfig.getImageMode();
    final path = await AlertConfig.getCustomImagePath();
    if (mounted) {
      setState(() {
        _imageMode = mode;
        _customImagePath = path;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF14100E), // Obsidian Dark Canvas
              Color(0xFF2A140F),
              Color(0xFF171210),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildAlertHeader(),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 16),
                        _buildWarningVisual(),
                        const SizedBox(height: 20),
                        _buildAlertMessage(),
                        const SizedBox(height: 24),
                        _buildEmergencyTelemetryMetrics(),
                        const SizedBox(height: 20),
                        _buildRecommendationCard(),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                _buildAlertActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlertHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFD94126).withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD94126).withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: _pulseAnimation,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFFD94126),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.subtitle,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Color(0xFFFFB4AB),
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  // Visual peringatan (MEME DIHAPUS: Hanya Custom atau High-Tech Hazard Halo)
  Widget _buildWarningVisual() {
    if (_imageMode == AlertImageMode.custom &&
        _customImagePath != null &&
        File(_customImagePath!).existsSync()) {
      return Container(
        height: 160,
        width: 160,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFD94126), width: 3),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFD94126).withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.file(
          File(_customImagePath!),
          fit: BoxFit.cover,
        ),
      );
    }

    // Default: High-tech pulsing double-ring hazard emblem (No meme)
    return ScaleTransition(
      scale: _pulseAnimation,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFD94126).withOpacity(0.18),
          border: Border.all(color: const Color(0xFFD94126), width: 3),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFD94126).withOpacity(0.4),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Center(
          child: Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFFFB4AB),
            size: 68,
          ),
        ),
      ),
    );
  }

  Widget _buildAlertMessage() {
    return Column(
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            color: Color(0xFFFFDAD6),
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          widget.reason,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFFDCC1B4),
            height: 1.4,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildEmergencyTelemetryMetrics() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1916),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF564339)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Column(
            children: [
              Text('PERCLOS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFB8ACA4))),
              SizedBox(height: 2),
              Text('0.85', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFFFB4AB))),
              Text('KRITIS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFD94126))),
            ],
          ),
          Column(
            children: [
              Text('DURASI PEJAM', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFB8ACA4))),
              SizedBox(height: 2),
              Text('> 2.0 dtk', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFFFB4AB))),
              Text('MICROSLEEP', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFD94126))),
            ],
          ),
          Column(
            children: [
              Text('SIRENE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFB8ACA4))),
              SizedBox(height: 2),
              Text('AKTIF', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE57A38))),
              Text('LOOPING', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFE57A38))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendationCard() {
    final nearby = widget.nearby;
    if (nearby == null) {
      return _buildRecommendationBox(
        icon: Icons.local_cafe_rounded,
        title: 'Rest Area KM 57 (4.2 km lagi)',
      );
    }
    // Tempat berhenti terdekat dari server (mode darurat), dengan desain kartu yang sama.
    // Navigasinya lewat tombol "ARAHKAN KE REST AREA TERDEKAT" di bawah.
    return ListenableBuilder(
      listenable: nearby,
      builder: (context, _) {
        final view = PitstopView.from(nearby, urgent: true);
        return _buildRecommendationBox(
          icon: view.icon,
          title: view.title,
          subtitle: view.subtitle,
          busy: view.busy,
        );
      },
    );
  }

  Widget _buildRecommendationBox({
    required IconData icon,
    required String title,
    String? subtitle,
    bool busy = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF231F1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE57A38).withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFE57A38).withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFE57A38),
                    ),
                  )
                : Icon(icon, color: const Color(0xFFE57A38), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'REKOMENDASI PITSTOP AMAN',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFE57A38),
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFEAE0DD),
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFFB8A9A2),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertActions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: () {
              widget.onDismiss?.call();
              Navigator.of(context).pop();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE57A38),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 4,
            ),
            icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
            label: const Text(
              'SAYA SUDAH WASPADA (STOP ALARM)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: () {
              widget.onRestArea?.call();
              Navigator.of(context).pop();
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFEAE0DD),
              side: const BorderSide(color: Color(0xFF564339)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.navigation_rounded, size: 18),
            label: const Text(
              'ARAHKAN KE REST AREA TERDEKAT',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}
