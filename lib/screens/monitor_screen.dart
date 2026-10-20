import 'dart:async';
import 'dart:io';
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
// MONITOR SCREEN (Kamera + Pemantauan Real-time)
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

  // Alert guard
  bool _isAlertShowing = false;
  static const int _alertCooldownSeconds = 10;

  // === Supabase Session Tracking ===
  String? _currentSessionId;
  DateTime? _sessionStartTime;
  int _drowsyCount = 0;
  int _yawnCount = 0;
  int _microsleepCount = 0;

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

      if ((isSleep || isExcessiveYawn) && !_isAlertShowing) {
        await _alert.playAlert();
        if (isSleep) {
          _triggerSafetyAlert(
            title: 'MATA TERPEJAM!\nISTIRAHAT SEKARANG',
            subtitle: '🚨 PERINGATAN MICROSLEEP',
            reason:
                'Mata terpejam melebihi ${Thresholds.eyeClosedLimit} detik. Segera cari tempat aman untuk berhenti.',
            resetYawnsOnDismiss: false,
          );
        } else {
          _triggerSafetyAlert(
            title: 'TERLALU SERING\nMENGUAP!',
            subtitle: '⚠️ INDIKASI KELELAHAN BERAT',
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
          avgSpeedKmh: 0,
          maxSpeedKmh: 0,
          distanceKm: 0,
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('🎉 Sesi Selesai!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Skor Keselamatan Anda: $score/100',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
              child: const Text('Nanti Saja'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF5722)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lihat Kartu', style: TextStyle(color: Colors.white)),
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

  void _togglePauseResume() {
    if (_drivingTimer?.isActive ?? false) {
      _pauseTimer();
      setState(() => _cameraMode = 'Dijeda');
    } else {
      _resumeTimer();
      setState(() => _cameraMode = 'ML Kit Aktif');
    }
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
    ).whenComplete(() {
      _alert.stop();
      _nearby.clearUrgent();
      Future.delayed(const Duration(seconds: _alertCooldownSeconds), () {
        if (mounted) setState(() => _isAlertShowing = false);
      });
    });
  }

  Color _statusColor(DriverStatus s) {
    switch (s) {
      case DriverStatus.awake:  return AppColors.success;
      case DriverStatus.yawn:   return AppColors.warning;
      case DriverStatus.drowsy: return AppColors.danger;
      case DriverStatus.sleep:  return Colors.red.shade900;
      case DriverStatus.noFace: return AppColors.textSecondary;
    }
  }

  double _awarenessLevel(DriverStatus s) {
    switch (s) {
      case DriverStatus.awake:  return 0.99;
      case DriverStatus.yawn:   return 0.70;
      case DriverStatus.drowsy: return 0.40;
      case DriverStatus.sleep:  return 0.05;
      case DriverStatus.noFace: return 0.0;
    }
  }

  int _fatigueScore(DriverStatus s) {
    switch (s) {
      case DriverStatus.sleep:  return 95;
      case DriverStatus.drowsy: return 60;
      case DriverStatus.yawn:   return 35;
      default:                  return 5;
    }
  }

  String _fatigueLabel(DriverStatus s) {
    switch (s) {
      case DriverStatus.sleep:  return 'Kritis';
      case DriverStatus.drowsy: return 'Lelah';
      case DriverStatus.yawn:   return 'Mengantuk';
      default:                  return 'Segar';
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _isMonitoring ? _statusColor(_result.status) : AppColors.textSecondary;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              const DrivingBuddyAppBar(),
              _buildCameraSection(),
              const SizedBox(height: 12),
              if (!_isMonitoring)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _startMonitoring,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                        shadowColor: AppColors.primary.withOpacity(0.35),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      label: const Text(
                        'Mulai Sesi Monitoring',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                )
              else
                _buildActionButtons(),
              _buildConditionStatus(statusColor),
              _buildMetricsGrid(),
              const SizedBox(height: 10),
              if (_isMonitoring) _buildInfoBanner(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      height: 200,
      decoration: BoxDecoration(
        color: AppColors.cameraBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Stack(
        children: [
          if (_cameraController != null && _cameraController!.value.isInitialized)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _cameraController!.value.previewSize?.height ?? 640,
                    height: _cameraController!.value.previewSize?.width ?? 480,
                    child: CameraPreview(_cameraController!),
                  ),
                ),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isMonitoring
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    size: 48,
                    color: Colors.white.withOpacity(_isMonitoring ? 0.3 : 0.15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isMonitoring
                        ? 'Memuat Kamera...'
                        : 'Pratinjau Kamera Langsung',
                    style: TextStyle(
                      color: Colors.white.withOpacity(_isMonitoring ? 0.35 : 0.2),
                      fontSize: 13,
                    ),
                  ),
                  if (!_isMonitoring) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Tekan "Mulai Sesi" untuk mengaktifkan',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.15),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          // Top-left label
          Positioned(
            top: 12,
            left: 12,
            child: Row(
              children: [
                Icon(Icons.memory_rounded,
                    color: Colors.white.withOpacity(0.6), size: 14),
                const SizedBox(width: 4),
                Text(
                  _isMonitoring ? 'ML Kit Face Mesh • Aktif' : 'ML Kit Face Mesh • Standby',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          // Top-right mode badge
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (_isMonitoring
                            ? AppColors.success
                            : AppColors.textSecondary)
                        .withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _cameraMode,
                style: TextStyle(
                  color: _isMonitoring
                      ? AppColors.success
                      : Colors.white.withOpacity(0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (_isMonitoring)
            Positioned(
              top: 14,
              left: 0,
              right: 0,
              child: Center(child: _RecordingDot()),
            ),
          // Bottom face detection badge
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _eyeDetected
                      ? AppColors.success.withOpacity(0.15)
                      : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _eyeDetected
                        ? AppColors.success.withOpacity(0.4)
                        : Colors.white.withOpacity(0.1),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _eyeDetected ? Icons.face_rounded : Icons.face_retouching_off_rounded,
                      color: _eyeDetected
                          ? AppColors.success
                          : Colors.white.withOpacity(0.3),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _eyeDetected ? 'WAJAH TERDETEKSI' : 'MENUNGGU DETEKSI',
                      style: TextStyle(
                        color: _eyeDetected
                            ? AppColors.success
                            : Colors.white.withOpacity(0.3),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConditionStatus(Color statusColor) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text(
                'KONDISI PENGEMUDI',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _isMonitoring ? _result.status.name.toUpperCase() : 'MENUNGGU',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: statusColor,
              letterSpacing: 1,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            _isMonitoring
                ? _result.subStatus
                : 'Tekan tombol di bawah untuk memulai sesi monitoring.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _isMonitoring ? AppColors.primaryLight : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_rounded,
                  color: _isMonitoring ? AppColors.primary : AppColors.textSecondary,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Tingkat Kewaspadaan: ${(_awarenessLevel(_result.status) * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _isMonitoring ? AppColors.primaryDark : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _MetricCard(
            label: 'WAKTU KEMUDI',
            value: _formatDuration(_elapsedSeconds),
            subtitle: _isMonitoring
                ? ((_drivingTimer?.isActive ?? false) ? 'Berjalan...' : 'Dijeda')
                : 'Belum mulai',
            icon: Icons.timer_outlined,
            iconColor: AppColors.primary,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'EAR MATA',
            value: _isMonitoring ? _result.ear.toStringAsFixed(2) : '0.00',
            subtitle: 'Ambang tutup: < ${Thresholds.earClosed}',
            icon: Icons.remove_red_eye_outlined,
            iconColor: Colors.blue,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'FREKUENSI KEDIP',
            value: '${_result.blinkCount}',
            subtitle: _isMonitoring ? '/mnt  (limit: ${Thresholds.highBlinkRate})' : '—',
            icon: Icons.visibility_rounded,
            iconColor: AppColors.accent,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'SKOR KELELAHAN',
            value: '${_fatigueScore(_result.status)}%',
            subtitle: _isMonitoring ? _fatigueLabel(_result.status) : '—',
            icon: Icons.battery_charging_full_rounded,
            iconColor: AppColors.success,
            dimmed: !_isMonitoring,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.memory_rounded,
              color: AppColors.primary.withOpacity(0.7), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '🤖 ML Kit Face Mesh Aktif (On-Device)\n'
              'Menguap ${_result.yawnCount}x · Kedip ${_result.blinkCount}/mnt · MAR ${_result.mar.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Rekomendasi pitstop dari Maps API: tombol di kanan = buka Google Maps,
          // ketuk kartu = daftar rest area / minimarket / hotel-motel / SPBU terdekat.
          SizedBox(
            width: double.infinity,
            child: PitstopCard(controller: _nearby),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  onPressed: _togglePauseResume,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 14),
                  ),
                  icon: Icon(
                    (_drivingTimer?.isActive ?? false)
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      (_drivingTimer?.isActive ?? false) ? 'Jeda' : 'Lanjut',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        title: const Text('Selesai Perjalanan?'),
                        content: Text(
                          'Durasi: ${_formatDuration(_elapsedSeconds)}\nSesi monitoring akan dihentikan.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Batal'),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _stopMonitoring();
                            },
                            child: const Text('Ya, Selesai'),
                          ),
                        ],
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 14),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 20),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Selesai Perjalanan',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- Recording Dot (animasi titik merah berkedip) ----
class _RecordingDot extends StatefulWidget {
  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: AppColors.danger,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.danger.withOpacity(0.5),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Metric Card Widget ----
class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final bool dimmed;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Opacity(
        opacity: dimmed ? 0.5 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: iconColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                      letterSpacing: 0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// PERINGATAN KRITIS (Alert Microsleep) — Full-screen Dialog
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
    this.title = 'ISTIRAHAT\nSEKARANG',
    this.subtitle = '⚡ SISTEM KESELAMATAN AKTIF',
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
  AlertImageMode _imageMode = AlertImageMode.defaultMeme;
  String? _customImagePath;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
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
              Color(0xFFFFF3E0),
              Color(0xFFFFE0B2),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.danger.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.danger.withOpacity(0.4)),
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
                    color: AppColors.danger,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.danger,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWarningVisual() {
    // Mode tanpa gambar
    if (_imageMode == AlertImageMode.none) {
      return ScaleTransition(
        scale: _pulseAnimation,
        child: Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            color: AppColors.danger.withOpacity(0.12),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.danger, width: 3),
          ),
          child: const Center(
            child: Icon(
              Icons.warning_amber_rounded,
              color: AppColors.danger,
              size: 64,
            ),
          ),
        ),
      );
    }

    // Mode kustom dari storage HP
    if (_imageMode == AlertImageMode.custom &&
        _customImagePath != null &&
        File(_customImagePath!).existsSync()) {
      return Container(
        height: 170,
        width: 170,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.danger, width: 3),
          boxShadow: [
            BoxShadow(
              color: AppColors.danger.withOpacity(0.25),
              blurRadius: 16,
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

    // Mode default meme tidur
    return Container(
      height: 170,
      width: 170,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.danger, width: 3),
        boxShadow: [
          BoxShadow(
            color: AppColors.danger.withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/images/meme_tidur.png',
        fit: BoxFit.cover,
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
            fontSize: 28,
            fontWeight: FontWeight.w900,
            color: Color(0xFFB71C1C),
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          widget.reason,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary,
            height: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildRecommendationCard() {
    final nearby = widget.nearby;
    if (nearby != null) {
      // Tempat berhenti terdekat dari server (mode darurat). Tombol navigasi kartu
      // sama dengan tombol "ARAHKAN KE REST AREA TERDEKAT" di bawah.
      return PitstopCard(
        controller: nearby,
        urgent: true,
        onNavigate: (_) {
          widget.onRestArea?.call();
          Navigator.of(context).pop();
        },
      );
    }
    final rest = dummyRestArea;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.local_parking_rounded,
                    color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'REKOMENDASI AMAN TERDEKAT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      rest.distance,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.location_on_rounded,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                rest.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: rest.facilities.map((f) {
              IconData icon;
              switch (f) {
                case 'SPBU':
                  icon = Icons.local_gas_station_rounded;
                  break;
                case 'Kopi':
                  icon = Icons.local_cafe_rounded;
                  break;
                case 'Istirahat':
                  icon = Icons.hotel_rounded;
                  break;
                default:
                  icon = Icons.place_rounded;
              }
              return Container(
                margin: const EdgeInsets.only(right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.chipBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: AppColors.primaryDark),
                    const SizedBox(width: 4),
                    Text(
                      f,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
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
          child: ElevatedButton.icon(
            onPressed: () {
              widget.onDismiss?.call();
              Navigator.of(context).pop();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
            label: const Text(
              'SAYA SUDAH AWAS (HENTIKAN ALARM)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              widget.onRestArea?.call();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.navigation_rounded, size: 20),
            label: const Text(
              'ARAHKAN KE REST AREA TERDEKAT',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}
