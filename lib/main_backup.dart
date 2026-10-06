import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as imglib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================================
// MAIN ENTRY POINT
// ============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const DrivingBuddyApp());
}

// ============================================================================
// TEMA & WARNA
// ============================================================================

class AppColors {
  static const Color primary = Color(0xFFD4842A);
  static const Color primaryDark = Color(0xFFB5691E);
  static const Color primaryLight = Color(0xFFF5E6D0);
  static const Color accent = Color(0xFFF5A623);
  static const Color background = Color(0xFFF8F5F0);
  static const Color surface = Colors.white;
  static const Color cardBg = Colors.white;
  static const Color textPrimary = Color(0xFF2D2D2D);
  static const Color textSecondary = Color(0xFF7A7A7A);
  static const Color cameraBg = Color(0xFF1A1A2E);
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color danger = Color(0xFFE53935);
  static const Color chipBg = Color(0xFFFFF8E1);
}

// ============================================================================
// KONFIGURASI DETEKSI KANTUK (On-Device — ported dari demo_pretrained.py)
// ============================================================================

const double kEyeClosedThresh    = 0.30;  // eyeOpenProbability < 0.30 = mata tertutup
const double kMarYawnThresh      = 0.35;  // MAR > 0.35 = menguap
const double kHeadDropDegrees    = 15.0;  // eulerX angle (nodding) > 15 deg = nunduk
const double kEyeClosedTimeLimit = 1.60;  // detik mata terpejam → trigger SLEEP
const double kYawnTimeLimit      = 1.20;  // detik menguap → dicatat sebagai yawn
const double kHeadDropTimeLimit  = 2.00;  // detik kepala nunduk → trigger Drowsy
const double kYawnCooldownSec    = 3.5;   // jeda min antar yawn
const int    kYawnWindowSec      = 300;   // jendela 5 menit untuk akumulasi yawn
const int    kYawnAlertFreq      = 4;     // >= 4x yawn dalam 5 mnt → Drowsy
const int    kHighBlinkRateLimit = 35;    // kedipan/mnt → Drowsy
const double kMinBlinkInterval   = 0.20;  // debounce blink (cegah noise kamera)

// ============================================================================
// ACCOUNT CONFIG — Simpan profil user secara lokal
// ============================================================================

class AccountConfig {
  static const _keyName  = 'account_name';
  static const _keyEmail = 'account_email';

  static Future<Map<String, String>> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name':  prefs.getString(_keyName)  ?? '',
      'email': prefs.getString(_keyEmail) ?? '',
    };
  }

  static Future<void> saveProfile(String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyName, name);
    await prefs.setString(_keyEmail, email);
  }

  static Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyName);
    await prefs.remove(_keyEmail);
  }
}

// ============================================================================
// DATA MODELS
// ============================================================================

class TripRecord {
  final String routeName;
  final String dateInfo;
  final String timeRange;
  final String duration;
  final String warningLabel;
  final Color warningColor;
  final String driverStatus;
  final double avgEAR;
  final int avgSpeed;
  final List<double> earGraphData;

  TripRecord({
    required this.routeName,
    required this.dateInfo,
    required this.timeRange,
    required this.duration,
    required this.warningLabel,
    required this.warningColor,
    required this.driverStatus,
    required this.avgEAR,
    required this.avgSpeed,
    required this.earGraphData,
  });
}

class RestAreaRecommendation {
  final String name;
  final String distance;
  final List<String> facilities;
  RestAreaRecommendation({required this.name, required this.distance, required this.facilities});
}

class WeeklySummary {
  int totalSessions;
  String totalDuration;
  int safetyScore;
  String comparisonText;
  WeeklySummary({
    required this.totalSessions,
    required this.totalDuration,
    required this.safetyScore,
    required this.comparisonText,
  });
}

// ============================================================================
// DUMMY DATA — Data historis (bukan real-time)
// ============================================================================

final List<TripRecord> dummyTripRecords = [
  TripRecord(
    routeName: 'Nodkrai - Snezhnaya (KM 72 – 120)',
    dateInfo: 'Malam ini', timeRange: '21:15 – 23:30', duration: '02:15:00',
    warningLabel: '1x Peringatan Ringan', warningColor: AppColors.warning,
    driverStatus: 'Kantuk halus m-34', avgEAR: 0.29, avgSpeed: 88,
    earGraphData: [0.32, 0.30, 0.28, 0.31, 0.27, 0.29, 0.26, 0.30, 0.28],
  ),
  TripRecord(
    routeName: 'Pluto – Jupiter',
    dateInfo: 'Kemarin', timeRange: '08:10 – 10:10', duration: '01:40:00',
    warningLabel: '0 Peringatan', warningColor: AppColors.success,
    driverStatus: 'Fokus Optimal', avgEAR: 0.35, avgSpeed: 78,
    earGraphData: [0.34, 0.35, 0.36, 0.34, 0.35, 0.33, 0.36, 0.35, 0.34],
  ),
  TripRecord(
    routeName: 'Bumi – Mars (Starship Avalon)',
    dateInfo: '14 Okt', timeRange: '18:00 – 21:45', duration: '03:45:00',
    warningLabel: '2x Jeda Istirahat Direkomendasikan', warningColor: AppColors.danger,
    driverStatus: 'Rest Area KM 283', avgEAR: 0.27, avgSpeed: 94,
    earGraphData: [0.30, 0.28, 0.25, 0.27, 0.22, 0.26, 0.24, 0.28, 0.25],
  ),
  TripRecord(
    routeName: 'Amphoreus – Planarcadia (Star Rail Express)',
    dateInfo: '12 Okt', timeRange: '06:30 – 08:45', duration: '02:15:00',
    warningLabel: '0 Peringatan', warningColor: AppColors.success,
    driverStatus: 'Fokus Optimal', avgEAR: 0.33, avgSpeed: 65,
    earGraphData: [0.33, 0.34, 0.32, 0.35, 0.33, 0.34, 0.33, 0.32, 0.34],
  ),
];

final RestAreaRecommendation dummyRestArea = RestAreaRecommendation(
  name: 'Rest Area KM 57',
  distance: '750 m ke depan',
  facilities: ['SPBU', 'Kopi', 'Istirahat'],
);

WeeklySummary dummyWeeklySummary = WeeklySummary(
  totalSessions: 12,
  totalDuration: '24j 40m',
  safetyScore: 95,
  comparisonText: '↓ 3 sesi dibanding pekan lalu.',
);

// ============================================================================
// APP ROOT
// ============================================================================

class DrivingBuddyApp extends StatelessWidget {
  const DrivingBuddyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DrivingBuddy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        primaryColor: AppColors.primary,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
          primary: AppColors.primary,
          surface: AppColors.surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardBg,
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.primary, width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
      ),
      home: const MainShell(),
    );
  }
}

// ============================================================================
// MAIN SHELL — 3-Tab BottomNavigationBar
// ============================================================================

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  void _switchToTab(int index) => setState(() => _currentIndex = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          CockpitScreen(onStartMonitoring: () => _switchToTab(1)),
          MonitorScreen(isActive: _currentIndex == 1),
          const HistoryScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, -2))],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(icon: Icons.dashboard_rounded, label: 'Cockpit', index: 0),
                _buildNavItem(icon: Icons.videocam_rounded, label: 'Monitor', index: 1, isCenter: true),
                _buildNavItem(icon: Icons.history_rounded, label: 'Riwayat', index: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({required IconData icon, required String label, required int index, bool isCenter = false}) {
    final isActive = _currentIndex == index;
    if (isCenter) {
      return GestureDetector(
        onTap: () => setState(() => _currentIndex = index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                gradient: isActive ? const LinearGradient(colors: [AppColors.primary, AppColors.accent]) : null,
                color: isActive ? null : Colors.grey.shade200,
                shape: BoxShape.circle,
                boxShadow: isActive ? [BoxShadow(color: AppColors.primary.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4))] : [],
              ),
              child: Icon(icon, color: isActive ? Colors.white : AppColors.textSecondary, size: 26),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: isActive ? FontWeight.w800 : FontWeight.w500, color: isActive ? AppColors.primary : AppColors.textSecondary)),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 70,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isActive ? AppColors.primary : AppColors.textSecondary, size: 25),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: isActive ? FontWeight.w800 : FontWeight.w500, color: isActive ? AppColors.primary : AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// SHARED APP BAR — dengan tombol ke AccountSettingsScreen
// ============================================================================

class DrivingBuddyAppBar extends StatelessWidget {
  final List<Widget>? trailing;
  const DrivingBuddyAppBar({super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.primary, AppColors.accent]),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.remove_red_eye_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('DrivingBuddy', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const Spacer(),
          // Badge AI On-Device
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.primary.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                const Text('On-Device AI', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primaryDark)),
              ],
            ),
          ),
          if (trailing != null) ...trailing!,
          const SizedBox(width: 6),
          // Tombol Account Settings
          Builder(
            builder: (ctx) => GestureDetector(
              onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const AccountSettingsScreen())),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: const Icon(Icons.person_rounded, color: AppColors.textSecondary, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// LAYAR 1 — COCKPIT
// ============================================================================

class CockpitScreen extends StatelessWidget {
  final VoidCallback onStartMonitoring;
  const CockpitScreen({super.key, required this.onStartMonitoring});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              const DrivingBuddyAppBar(),
              const SizedBox(height: 12),
              _buildSystemReadyCard(),
              const SizedBox(height: 12),
              _buildStartMonitoringButton(context),
              const SizedBox(height: 16),
              _buildQuickStatsRow(),
              const SizedBox(height: 16),
              _buildLastTripCard(),
              const SizedBox(height: 16),
              _buildSafetyTipsCard(),
              const SizedBox(height: 16),
              _buildRestAreaButton(context),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSystemReadyCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1A1A2E), Color(0xFF2D2B55)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: const Color(0xFF1A1A2E).withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.psychology_rounded, color: AppColors.success, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI On-Device Siap', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text('Tidak perlu server atau internet. Deteksi kantuk berjalan langsung di HP kamu.', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6), height: 1.4)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildCheckRow(Icons.camera_alt_rounded, 'Kamera Depan', 'Standby — siap diaktifkan'),
          const SizedBox(height: 8),
          _buildCheckRow(Icons.psychology_rounded, 'MediaPipe ML Kit', 'On-device, tanpa internet'),
          const SizedBox(height: 8),
          _buildCheckRow(Icons.shield_rounded, 'Privasi Terjaga', 'Data tidak keluar dari HP'),
        ],
      ),
    );
  }

  Widget _buildCheckRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Icon(icon, color: AppColors.success, size: 16),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
        const SizedBox(width: 8),
        Expanded(child: Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.45)), textAlign: TextAlign.right)),
      ],
    );
  }

  Widget _buildStartMonitoringButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onStartMonitoring,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 4,
            shadowColor: AppColors.primary.withOpacity(0.35),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_rounded, size: 24),
              SizedBox(width: 10),
              Text('Mulai Monitoring', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickStatsRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _QuickStatCard(icon: Icons.route_rounded, iconColor: AppColors.primary, value: '${dummyWeeklySummary.totalSessions}', label: 'Sesi Pekan Ini'),
          const SizedBox(width: 10),
          _QuickStatCard(icon: Icons.access_time_rounded, iconColor: Colors.blue, value: dummyWeeklySummary.totalDuration, label: 'Total Waktu'),
          const SizedBox(width: 10),
          _QuickStatCard(icon: Icons.verified_rounded, iconColor: AppColors.success, value: '${dummyWeeklySummary.safetyScore}%', label: 'Skor Aman'),
        ],
      ),
    );
  }

  Widget _buildLastTripCard() {
    if (dummyTripRecords.isEmpty) return const SizedBox.shrink();
    final last = dummyTripRecords.first;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              const Text('Perjalanan Terakhir', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const Spacer(),
              Text(last.dateInfo, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(last.routeName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(last.timeRange, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(10)),
                child: Text(last.duration, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: AppColors.primaryDark)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: last.warningColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: last.warningColor.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(last.warningColor == AppColors.success ? Icons.check_circle_rounded : Icons.warning_amber_rounded, size: 12, color: last.warningColor),
                const SizedBox(width: 4),
                Text(last.warningLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: last.warningColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyTipsCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.local_cafe_rounded, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tips Keselamatan', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
                SizedBox(height: 3),
                Text('Istirahat 15 menit setiap 2 jam berkendara. Minum kopi atau cuci muka untuk membantu kewaspadaan.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRestAreaButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mencari Rest Area terdekat...'), behavior: SnackBarBehavior.floating)),
          icon: const Icon(Icons.local_parking_rounded, size: 18),
          label: const Text('Cari Rest Area Terdekat'),
        ),
      ),
    );
  }
}

class _QuickStatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;
  const _QuickStatCard({required this.icon, required this.iconColor, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 2))]),
        child: Column(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// LAYAR 2 — MONITOR (On-Device ML Kit — tanpa server)
// ============================================================================

class MonitorScreen extends StatefulWidget {
  final bool isActive;
  const MonitorScreen({super.key, required this.isActive});
  @override
  MonitorScreenState createState() => MonitorScreenState();
}

class MonitorScreenState extends State<MonitorScreen> {
  // Timer kemudi
  Timer? _drivingTimer;
  int _elapsedSeconds = 0;
  bool _isMonitoring = false;

  // Kamera
  CameraController? _cameraController;
  CameraDescription? _frontCamera;
  bool _isProcessingFrame = false;

  // TFLite Face Landmark Detector (tanpa Play Services)
  Interpreter? _interpreter;
  Timer? _processingTimer; // Timer untuk takePicture() berkala

  // Metrik tampilan real-time
  double _eyeOpenness = 0.00;   // 0 = tertutup, 1 = terbuka (dari ML Kit)
  int _blinkFrequency = 0;
  int _fatigueScore = 0;
  String _fatigueLabel = '—';
  String _driverCondition = 'MENUNGGU';
  String _conditionDescription = 'Tekan tombol di bawah untuk memulai sesi monitoring.';
  double _awarenessLevel = 0.0;
  String _cameraMode = 'Standby';
  bool _eyeDetected = false;

  // State drowsiness (ported dari demo_pretrained.py)
  double? _eyeClosedStartTime;
  double? _yawnStartTime;
  double? _headDropStartTime;
  double _lastYawnTime = 0;
  double _yawnDisplayUntil = 0;
  bool _yawnCountedThisCycle = false;
  double _lastBlinkTime = 0;
  bool _isEyeCurrentlyClosed = false;

  final Queue<double> _blinkHistory = Queue<double>();
  final Queue<double> _yawnHistory  = Queue<double>();

  // Alert guard
  bool _isAlertShowing = false;
  static const int _alertCooldownSeconds = 10;

  double get _now => DateTime.now().millisecondsSinceEpoch / 1000.0;

  @override
  void didUpdateWidget(covariant MonitorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _isMonitoring) _resumeTimer();
    if (!widget.isActive && oldWidget.isActive) _pauseTimer();
  }

  @override
  void dispose() {
    _drivingTimer?.cancel();
    _processingTimer?.cancel();
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  // ---------- Runtime Camera Permission ----------
  Future<bool> _requestCameraPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    if (status.isDenied) return (await Permission.camera.request()).isGranted;
    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Izin kamera ditolak permanen. Buka Pengaturan > Aplikasi.'),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(label: 'Buka', textColor: Colors.white, onPressed: () => openAppSettings()),
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
      _cameraMode = 'AI On-Device Aktif';
      _driverCondition = 'MEMUAT KAMERA...';
      _conditionDescription = 'Menginisialisasi kamera & model AI...';
    });

    // 1. Permission kamera
    final hasPermission = await _requestCameraPermission();
    if (!hasPermission) {
      if (mounted) setState(() { _isMonitoring = false; _driverCondition = 'IZIN DITOLAK'; _conditionDescription = 'Izin kamera dibutuhkan.'; });
      return;
    }

    try {
      // 2. Load TFLite model (bundled di APK — tanpa Play Services)
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/face_landmark.tflite',
        options: options,
      );
      _interpreter!.allocateTensors(); // WAJIB: inisialisasi tensor sebelum inferensi

      // 3. Siapkan kamera depan
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('Tidak ada kamera tersedia.');
      _frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        _frontCamera!,
        ResolutionPreset.low,
        enableAudio: false,
      );
      await _cameraController!.initialize();

      if (mounted) setState(() {});

      // 4. Mulai timer kemudi & loop TFLite
      _resumeTimer();
      _startFaceProcessingLoop();

    } catch (e) {
      debugPrint('Init gagal: $e');
      if (mounted) {
        setState(() {
          _isMonitoring = false;
          _driverCondition = 'GAGAL MEMUAT';
          _conditionDescription = 'Error: $e';
        });
      }
    }
  }

  // ---------- Loop takePicture() → TFLite (setiap 500ms) ----------
  // 100% on-device, tanpa Play Services, bekerja di semua Android.
  void _startFaceProcessingLoop() {
    _processingTimer?.cancel();
    _processingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!_isProcessingFrame && _isMonitoring &&
          _interpreter != null && _cameraController != null &&
          (_cameraController?.value.isInitialized ?? false)) {
        _isProcessingFrame = true;
        String? tempPath;
        try {
          final XFile photo = await _cameraController!.takePicture();
          tempPath = photo.path;
          final eyeOpenness = await _runTFLiteLandmark(tempPath);
          if (mounted) _updateDrowsinessState(eyeOpenness);
        } catch (e) {
          debugPrint('TFLite error: $e');
        } finally {
          _isProcessingFrame = false;
          if (tempPath != null) {
            try { await File(tempPath).delete(); } catch (_) {}
          }
        }
      }
    });
  }

  // ---------- TFLite Inference — MediaPipe Face Landmark ----------
  // Input : [1, 192, 192, 3] float32, nilai [0.0, 1.0]
  // Output: [1, 1404] float32 = 468 landmark × (x, y, z) dalam piksel [0..192]
  // Indices mata (MediaPipe Face Mesh standard):
  //   Mata kiri  : [362, 385, 387, 263, 373, 380]
  //   Mata kanan : [33,  160, 158, 133, 153, 144]
  static const List<int> _leftEyeIdx  = [362, 385, 387, 263, 373, 380];
  static const List<int> _rightEyeIdx = [33,  160, 158, 133, 153, 144];

  Future<double?> _runTFLiteLandmark(String imagePath) async {
    // Tangkap referensi sebelum await (cegah null setelah async gap)
    final interp = _interpreter;
    if (interp == null) return null;
    try {
      // 1. Decode JPEG
      final bytes = await File(imagePath).readAsBytes();
      final img   = imglib.decodeImage(bytes);
      if (img == null) return null;

      // 2. Crop bujur sangkar, lalu resize ke 192×192
      final sz    = img.width < img.height ? img.width : img.height;
      final cropX = (img.width  - sz) ~/ 2;
      final cropY = (img.height - sz) ~/ 4;  // geser ke atas — wajah biasanya di atas
      final rsz   = imglib.copyResize(
        imglib.copyCrop(img, x: cropX, y: cropY, width: sz, height: sz),
        width: 192, height: 192,
      );

      // 3. Input shape: [1, 192, 192, 3]
      final input = List.generate(1, (_) =>
        List.generate(192, (y) =>
          List.generate(192, (x) {
            final p = rsz.getPixel(x, y);
            return [
              p.r.toDouble() / 255.0,
              p.g.toDouble() / 255.0,
              p.b.toDouble() / 255.0
            ];
          })
        )
      );

      // 4. Output: model ini punya 2 output tensor
      //    - index 0: landmarks [1, 1, 1, 1404]
      //    - index 1: face presence score [1, 1]
      final landmarksOutput = List.generate(1, (_) =>
        List.generate(1, (_) =>
          List.generate(1, (_) =>
            List.filled(1404, 0.0)
          )
        )
      );
      final scoreOutput = List.generate(1, (_) => List.filled(1, 0.0));
      
      final outputs = <int, Object>{
        0: landmarksOutput,
        1: scoreOutput
      };

      // 5. Jalankan inferensi
      interp.runForMultipleInputs([input], outputs);

      // 6. Cek face presence score (output 1)
      final faceScore = scoreOutput[0][0];
      if (faceScore < 0.5) return null;

      // 7. Hitung EAR dari landmark (landmark i → offset i*3 = [x, y, z])
      final landmarksFlat = landmarksOutput[0][0][0];
      final leftEAR  = _computeEARList(landmarksFlat, _leftEyeIdx);
      final rightEAR = _computeEARList(landmarksFlat, _rightEyeIdx);
      final avgEAR   = (leftEAR + rightEAR) / 2.0;

      // EAR terbuka ~0.25–0.35, tertutup ~0.05–0.10 → normalisasi ke [0,1]
      return (avgEAR / 0.30).clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('Landmark error: $e');
      return null;
    }
  }

  // Helper compute EAR khusus list biasa (karena sekarang List<double>, bukan Float32List)
  double _computeEARList(List<double> lm, List<int> idx) {
    double d(int a, int b) {
      final ax = lm[idx[a] * 3],     ay = lm[idx[a] * 3 + 1];
      final bx = lm[idx[b] * 3],     by = lm[idx[b] * 3 + 1];
      return sqrt(pow(ax - bx, 2) + pow(ay - by, 2));
    }
    final num_ = d(1, 5) + d(2, 4);
    final den  = 2.0 * d(0, 3);
    return den < 1e-6 ? 0.0 : num_ / den;
  }


  // ---------- Update drowsiness dari hasil TFLite (eyeOpenness 0–1) ----------
  void _updateDrowsinessState(double? eyeOpenness) {
    final currentTime = _now;

    // Bersihkan history kadaluarsa
    while (_yawnHistory.isNotEmpty  && (currentTime - _yawnHistory.first)  > kYawnWindowSec) _yawnHistory.removeFirst();
    while (_blinkHistory.isNotEmpty && (currentTime - _blinkHistory.first) > 60) _blinkHistory.removeFirst();

    if (eyeOpenness == null) {
      setState(() {
        _eyeDetected = false;
        _driverCondition = 'WAJAH TIDAK TERDETEKSI';
        _conditionDescription = 'Pastikan wajah terlihat jelas oleh kamera depan.';
        _awarenessLevel = 0.0;
        _eyeOpenness = 0.0;
        _blinkFrequency = _blinkHistory.length;
      });
      return;
    }

    // Konversi eyeOpenness [0,1] ke threshold: < 0.30 dianggap mata tertutup
    // (dalam skala ternormalisasi: EAR 0.09 / 0.30 ≈ 0.30)
    final avgEyeOpen = eyeOpenness;
    final eyeClosed  = avgEyeOpen < kEyeClosedThresh;

    // --- Blink detection ---
    double eyeCloseDur = 0.0;
    if (eyeClosed) {
      if (!_isEyeCurrentlyClosed) {
        _isEyeCurrentlyClosed = true;
        if ((currentTime - _lastBlinkTime) >= kMinBlinkInterval) {
          _blinkHistory.add(currentTime);
          _lastBlinkTime = currentTime;
        }
      }
      _eyeClosedStartTime ??= currentTime;
      eyeCloseDur = currentTime - _eyeClosedStartTime!;
    } else {
      _isEyeCurrentlyClosed = false;
      _eyeClosedStartTime = null;
      eyeCloseDur = 0.0;
    }

    // --- Status ---
    String status;
    String subStatus;
    double awareness;

    if (eyeCloseDur >= kEyeClosedTimeLimit) {
      status    = 'SLEEP';
      subStatus = 'BAHAYA: MATA TERPEJAM (${eyeCloseDur.toStringAsFixed(1)}s)!';
      awareness = 0.05;
      _triggerMicrosleepAlert();

    } else if (_blinkHistory.length >= kHighBlinkRateLimit) {
      status    = 'DROWSY';
      subStatus = 'LELAH: Frekuensi Kedip Tinggi (${_blinkHistory.length}/mnt)';
      awareness = 0.40;

    } else {
      status    = 'AWAKE';
      subStatus = 'Pengemudi Fokus & Segar';
      awareness = 0.99;
    }

    int fatigue;
    String fatigueLabel;
    if      (status == 'SLEEP')   { fatigue = 95; fatigueLabel = 'Kritis'; }
    else if (status == 'DROWSY')  { fatigue = 60; fatigueLabel = 'Lelah'; }
    else                          { fatigue = 5;  fatigueLabel = 'Segar'; }

    setState(() {
      _eyeDetected        = true;
      _eyeOpenness        = avgEyeOpen;
      _blinkFrequency     = _blinkHistory.length;
      _driverCondition    = status;
      _conditionDescription = subStatus;
      _awarenessLevel     = awareness;
      _fatigueScore       = fatigue;
      _fatigueLabel       = fatigueLabel;
    });
  }



  void _resumeTimer() {
    _drivingTimer?.cancel();
    _drivingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  void _pauseTimer() => _drivingTimer?.cancel();

  Future<void> _stopMonitoring() async {
    _pauseTimer();
    _processingTimer?.cancel();
    _processingTimer = null;
    _cameraController?.dispose();
    _cameraController = null;
    _interpreter?.close();
    _interpreter = null;

    // Reset semua state
    _eyeClosedStartTime = null;
    _yawnStartTime = null;
    _headDropStartTime = null;
    _lastYawnTime = 0;
    _yawnDisplayUntil = 0;
    _yawnCountedThisCycle = false;
    _lastBlinkTime = 0;
    _isEyeCurrentlyClosed = false;
    _blinkHistory.clear();
    _yawnHistory.clear();

    setState(() {
      _isMonitoring        = false;
      _elapsedSeconds      = 0;
      _eyeOpenness         = 0.0;
      _blinkFrequency      = 0;
      _fatigueScore        = 0;
      _fatigueLabel        = '—';
      _driverCondition     = 'MENUNGGU';
      _conditionDescription = 'Tekan tombol di bawah untuk memulai sesi monitoring.';
      _awarenessLevel      = 0.0;
      _cameraMode          = 'Standby';
      _eyeDetected         = false;
      _isAlertShowing      = false;
    });
  }

  void _togglePauseResume() {
    if (_drivingTimer?.isActive ?? false) {
      _pauseTimer();
      setState(() => _cameraMode = 'Dijeda');
    } else {
      _resumeTimer();
      setState(() => _cameraMode = 'AI On-Device Aktif');
    }
  }

  String _formatDuration(int totalSeconds) {
    final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _triggerMicrosleepAlert() {
    if (_isAlertShowing) return;
    _isAlertShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (_) => const MicrosleepAlertDialog(),
    ).whenComplete(() {
      Future.delayed(Duration(seconds: _alertCooldownSeconds), () {
        if (mounted) setState(() => _isAlertShowing = false);
      });
    });
  }

  // ============ BUILD ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              const DrivingBuddyAppBar(),
              _buildCameraSection(),
              _buildConditionStatus(),
              _buildMetricsGrid(),
              const SizedBox(height: 10),
              if (_isMonitoring) _buildInfoBanner(),
              const SizedBox(height: 16),
              _buildActionButtons(),
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
              child: SizedBox.expand(child: CameraPreview(_cameraController!)),
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_isMonitoring ? Icons.videocam_rounded : Icons.videocam_off_rounded, size: 48, color: Colors.white.withOpacity(_isMonitoring ? 0.3 : 0.15)),
                  const SizedBox(height: 8),
                  Text(_isMonitoring ? 'Memuat Kamera...' : 'Pratinjau Kamera Langsung', style: TextStyle(color: Colors.white.withOpacity(_isMonitoring ? 0.35 : 0.2), fontSize: 13)),
                  if (!_isMonitoring) ...[
                    const SizedBox(height: 4),
                    Text('Tekan "Mulai Sesi" untuk mengaktifkan', style: TextStyle(color: Colors.white.withOpacity(0.15), fontSize: 11)),
                  ],
                ],
              ),
            ),
          // Top-left
          Positioned(
            top: 12, left: 12,
            child: Row(
              children: [
                Icon(Icons.memory_rounded, color: Colors.white.withOpacity(0.6), size: 14),
                const SizedBox(width: 4),
                Text(_isMonitoring ? 'On-Device AI • Aktif' : 'On-Device AI • Standby', style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
              ],
            ),
          ),
          // Top-right
          Positioned(
            top: 12, right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: (_isMonitoring ? AppColors.success : AppColors.textSecondary).withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
              child: Text(_cameraMode, style: TextStyle(color: _isMonitoring ? AppColors.success : Colors.white.withOpacity(0.5), fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
          if (_isMonitoring) Positioned(top: 14, left: 0, right: 0, child: Center(child: _RecordingDot())),
          // Bottom badge
          Positioned(
            bottom: 12, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _eyeDetected ? AppColors.success.withOpacity(0.15) : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _eyeDetected ? AppColors.success.withOpacity(0.4) : Colors.white.withOpacity(0.1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_eyeDetected ? Icons.face_rounded : Icons.face_retouching_off_rounded, color: _eyeDetected ? AppColors.success : Colors.white.withOpacity(0.3), size: 14),
                    const SizedBox(width: 6),
                    Text(_eyeDetected ? 'WAJAH TERDETEKSI' : 'MENUNGGU DETEKSI', style: TextStyle(color: _eyeDetected ? AppColors.success : Colors.white.withOpacity(0.3), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConditionStatus() {
    final Color statusColor = _isMonitoring ? AppColors.success : AppColors.textSecondary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))]),
      child: Column(
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text('KONDISI PENGEMUDI', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 1)),
            ],
          ),
          const SizedBox(height: 10),
          Text(_driverCondition, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: statusColor, letterSpacing: 1), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(_conditionDescription, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: _isMonitoring ? AppColors.primaryLight : Colors.grey.shade100, borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_rounded, color: _isMonitoring ? AppColors.primary : AppColors.textSecondary, size: 16),
                const SizedBox(width: 8),
                Text(
                  'Tingkat Kewaspadaan: ${(_awarenessLevel * 100).toInt()}%',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _isMonitoring ? AppColors.primaryDark : AppColors.textSecondary),
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
            subtitle: _isMonitoring ? ((_drivingTimer?.isActive ?? false) ? 'Berjalan...' : 'Dijeda') : 'Belum mulai',
            icon: Icons.timer_outlined,
            iconColor: AppColors.primary,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'KETERBUKAAN MATA',
            value: _isMonitoring ? _eyeOpenness.toStringAsFixed(2) : '0.00',
            subtitle: _isMonitoring ? '0=Tutup · 1=Terbuka${_eyeDetected ? '\nAmbang: > 0.30' : ''}' : 'Ambang: > 0.30',
            icon: Icons.remove_red_eye_outlined,
            iconColor: Colors.blue,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'FREKUENSI KEDIP.',
            value: '$_blinkFrequency',
            subtitle: _isMonitoring ? '/mnt' : '—',
            icon: Icons.visibility_rounded,
            iconColor: AppColors.accent,
            dimmed: !_isMonitoring,
          ),
          _MetricCard(
            label: 'SKOR KELELAH.',
            value: '$_fatigueScore%',
            subtitle: _isMonitoring ? _fatigueLabel : '—',
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
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
      child: Row(
        children: [
          Icon(Icons.memory_rounded, color: AppColors.primary.withOpacity(0.7), size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '🤖 On-Device AI Aktif\nDeteksi kantuk berjalan langsung di HP — tidak butuh internet.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4),
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
          if (!_isMonitoring) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startMonitoring,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                  shadowColor: AppColors.primary.withOpacity(0.35),
                ),
                icon: const Icon(Icons.play_arrow_rounded, size: 24),
                label: const Text('Mulai Sesi Monitoring', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mencari Rest Area terdekat...'), behavior: SnackBarBehavior.floating)),
                icon: const Icon(Icons.local_parking_rounded, size: 18),
                label: const Text('Cari Rest Area Terdekat'),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _togglePauseResume,
                    icon: Icon((_drivingTimer?.isActive ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 20),
                    label: Text((_drivingTimer?.isActive ?? false) ? 'Jeda' : 'Lanjut', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: const Text('Selesai Perjalanan?'),
                        content: Text('Durasi: ${_formatDuration(_elapsedSeconds)}\nSesi monitoring akan dihentikan.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
                          ElevatedButton(
                            onPressed: () { Navigator.pop(ctx); _stopMonitoring(); },
                            child: const Text('Ya, Selesai'),
                          ),
                        ],
                      ),
                    ),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger, padding: const EdgeInsets.symmetric(vertical: 14)),
                    icon: const Icon(Icons.stop_rounded, size: 20),
                    label: const Text('Selesai Perjalanan', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---- Recording Dot ----
class _RecordingDot extends StatefulWidget {
  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}
class _RecordingDotState extends State<_RecordingDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _ctrl,
    child: Container(width: 10, height: 10, decoration: BoxDecoration(color: AppColors.danger, shape: BoxShape.circle, boxShadow: [BoxShadow(color: AppColors.danger.withOpacity(0.5), blurRadius: 6)])),
  );
}

// ---- Metric Card ----
class _MetricCard extends StatelessWidget {
  final String label, value, subtitle;
  final IconData icon;
  final Color iconColor;
  final bool dimmed;
  const _MetricCard({required this.label, required this.value, required this.subtitle, required this.icon, required this.iconColor, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 2))]),
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
                Expanded(child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.5), overflow: TextOverflow.ellipsis)),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
            Text(subtitle, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MICROSLEEP ALERT DIALOG
// ============================================================================

class MicrosleepAlertDialog extends StatefulWidget {
  const MicrosleepAlertDialog({super.key});
  @override
  State<MicrosleepAlertDialog> createState() => _MicrosleepAlertDialogState();
}

class _MicrosleepAlertDialogState extends State<MicrosleepAlertDialog> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _pulseAnimation  = Tween<double>(begin: 1.0, end: 1.15).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() { _pulseController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFF3E0), Color(0xFFFFE0B2), Colors.white])),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.1), blurRadius: 12, offset: const Offset(0, 4))]),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.primary, width: 2)),
                        child: const CircleAvatar(radius: 18, backgroundColor: AppColors.primaryLight, child: Icon(Icons.remove_red_eye_rounded, color: AppColors.primary, size: 18)),
                      ),
                      const SizedBox(width: 12),
                      const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('DrivingBuddy — Peringatan Kritis', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        Text('Sistem Keselamatan Aktif', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                // Pulsing icon
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (_, child) => Transform.scale(scale: _pulseAnimation.value, child: child),
                  child: Container(
                    width: 90, height: 90,
                    decoration: BoxDecoration(shape: BoxShape.circle, gradient: const LinearGradient(colors: [AppColors.primary, AppColors.accent]), boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.35), blurRadius: 24, spreadRadius: 4)]),
                    child: const Icon(Icons.warning_rounded, color: Colors.white, size: 44),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                  child: const Text('⚡ SISTEM KESELAMATAN AKTIF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primaryDark, letterSpacing: 0.5)),
                ),
                const SizedBox(height: 16),
                const Text('ISTIRAHAT\nSEKARANG', textAlign: TextAlign.center, style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.textPrimary, height: 1.1, letterSpacing: 1)),
                const SizedBox(height: 12),
                RichText(
                  textAlign: TextAlign.center,
                  text: const TextSpan(style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5), children: [
                    TextSpan(text: 'Microsleep terdeteksi (mata terpejam ≥ '),
                    TextSpan(text: '1.6 detik', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
                    TextSpan(text: ').\nSegera cari tempat aman untuk berhenti.'),
                  ]),
                ),
                const SizedBox(height: 24),
                // Rest area
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4))]),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.local_parking_rounded, color: AppColors.primary, size: 22)),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('REKOMENDASI AMAN TERDEKAT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.5)),
                            const SizedBox(height: 2),
                            Text(dummyRestArea.distance, style: TextStyle(fontSize: 12, color: AppColors.textSecondary.withOpacity(0.7))),
                          ])),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(children: [const Icon(Icons.location_on_rounded, color: AppColors.primary, size: 20), const SizedBox(width: 8), Text(dummyRestArea.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary))]),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
                    label: const Text('SAYA SUDAH AWAS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.navigation_rounded, size: 20),
                    label: const Text('ARAHKAN KE REST AREA', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// LAYAR 3 — RIWAYAT
// ============================================================================

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _selectedFilter = 0;
  final List<String> _filters = ['Semua (${dummyTripRecords.length})', 'Catatan Kantuk (3)', 'Malam Hari (5)'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            const SliverToBoxAdapter(child: DrivingBuddyAppBar()),
            SliverToBoxAdapter(child: _buildWeeklySummary()),
            SliverToBoxAdapter(child: _buildFilterChips()),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.builder(
                itemCount: dummyTripRecords.length,
                itemBuilder: (context, index) => Padding(padding: const EdgeInsets.only(bottom: 12), child: _TripCard(trip: dummyTripRecords[index])),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text('Semua rekaman tersimpan lokal dan terenkripsi\nuntuk privasi pengemudi.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.textSecondary.withOpacity(0.6), height: 1.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeeklySummary() {
    final summary = dummyWeeklySummary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('📊  Ringkasan Pekan Ini', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(12)),
                child: const Text('1 - 16 Okt', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primaryDark)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _SummaryStatItem(value: '${summary.totalSessions}', label: 'Sesi Nyetir'),
              Container(width: 1, height: 40, color: Colors.grey.shade200, margin: const EdgeInsets.symmetric(horizontal: 4)),
              _SummaryStatItem(value: summary.totalDuration, label: 'Total Waktu'),
              Container(width: 1, height: 40, color: Colors.grey.shade200, margin: const EdgeInsets.symmetric(horizontal: 4)),
              Expanded(
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${summary.safetyScore}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: AppColors.success)),
                        const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('%', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.success))),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text('Skor Aman', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    return SizedBox(
      height: 42,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _filters.length,
        itemBuilder: (context, index) {
          final isSelected = _selectedFilter == index;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _selectedFilter = index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isSelected ? AppColors.primary : Colors.grey.shade300),
                ),
                child: Center(child: Text(_filters[index], style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isSelected ? Colors.white : AppColors.textSecondary))),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SummaryStatItem extends StatelessWidget {
  final String value, label;
  const _SummaryStatItem({required this.value, required this.label});
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    ),
  );
}

class _TripCard extends StatelessWidget {
  final TripRecord trip;
  const _TripCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(trip.routeName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('${trip.dateInfo} · ${trip.timeRange}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(trip.duration, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: trip.warningColor.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: trip.warningColor.withOpacity(0.3))),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(trip.warningColor == AppColors.success ? Icons.check_circle_rounded : Icons.warning_amber_rounded, size: 12, color: trip.warningColor),
                    const SizedBox(width: 4),
                    Text(trip.warningLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: trip.warningColor)),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(8)),
                child: Text(trip.driverStatus, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primaryDark)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _EarGraphPlaceholder(data: trip.earGraphData),
          const SizedBox(height: 14),
          Row(
            children: [
              _TripStatChip(label: 'Rata-rata Mata', value: trip.avgEAR.toStringAsFixed(2), icon: Icons.remove_red_eye_outlined),
              const Spacer(),
              _TripStatChip(label: 'Kecepatan', value: '${trip.avgSpeed}', unit: 'km/j', icon: Icons.speed_rounded),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripStatChip extends StatelessWidget {
  final String label, value;
  final String? unit;
  final IconData icon;
  const _TripStatChip({required this.label, required this.value, this.unit, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            Row(
              children: [
                Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
                if (unit != null) ...[const SizedBox(width: 3), Text(unit!, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))],
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _EarGraphPlaceholder extends StatelessWidget {
  final List<double> data;
  const _EarGraphPlaceholder({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60, width: double.infinity,
      decoration: BoxDecoration(color: AppColors.primaryLight.withOpacity(0.3), borderRadius: BorderRadius.circular(10)),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: CustomPaint(painter: _EarLinePainter(data: data))),
    );
  }
}

class _EarLinePainter extends CustomPainter {
  final List<double> data;
  _EarLinePainter({required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final double minVal = data.reduce(min) - 0.05;
    final double maxVal = data.reduce(max) + 0.05;
    final double range  = maxVal - minVal;
    if (range == 0) return;

    final fillPaint = Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [AppColors.primary.withOpacity(0.20), AppColors.primary.withOpacity(0.02)]).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    final linePaint = Paint()..color = AppColors.primary..strokeWidth = 2.2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;

    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - minVal) / range) * size.height;
      if (i == 0) { path.moveTo(x, y); fillPath.moveTo(x, size.height); fillPath.lineTo(x, y); }
      else {
        final prevX = ((i - 1) / (data.length - 1)) * size.width;
        final prevY = size.height - ((data[i - 1] - minVal) / range) * size.height;
        final cpX = prevX + (x - prevX) / 2;
        path.cubicTo(cpX, prevY, cpX, y, x, y);
        fillPath.cubicTo(cpX, prevY, cpX, y, x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    final dotPaint = Paint()..color = AppColors.primary;
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - minVal) / range) * size.height;
      canvas.drawCircle(Offset(x, y), 3, dotPaint);
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ============================================================================
// ACCOUNT SETTINGS SCREEN — Manajemen Profil
// ============================================================================

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});
  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _nameController  = TextEditingController();
  final _emailController = TextEditingController();
  bool _isSaving    = false;
  bool _isLoggedIn  = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await AccountConfig.getProfile();
    if (mounted) {
      setState(() {
        _nameController.text  = profile['name']  ?? '';
        _emailController.text = profile['email'] ?? '';
        _isLoggedIn = profile['name']!.isNotEmpty || profile['email']!.isNotEmpty;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final name  = _nameController.text.trim();
    final email = _emailController.text.trim();
    setState(() => _isSaving = true);
    await AccountConfig.saveProfile(name, email);
    setState(() { _isSaving = false; _isLoggedIn = name.isNotEmpty || email.isNotEmpty; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Profil tersimpan'), backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _signOut() async {
    await AccountConfig.clearProfile();
    _nameController.clear();
    _emailController.clear();
    setState(() => _isLoggedIn = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Berhasil keluar'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Akun & Profil', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Avatar
          Center(
            child: Column(
              children: [
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [AppColors.primary, AppColors.accent]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 6))],
                  ),
                  child: Center(
                    child: Text(
                      _nameController.text.isNotEmpty ? _nameController.text[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _isLoggedIn ? (_nameController.text.isNotEmpty ? _nameController.text : 'Pengemudi') : 'Belum Masuk',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isLoggedIn ? AppColors.success.withOpacity(0.1) : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _isLoggedIn ? '● Aktif' : '○ Belum masuk',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _isLoggedIn ? AppColors.success : AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // Info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                const Icon(Icons.psychology_rounded, color: AppColors.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'DrivingBuddy berjalan sepenuhnya On-Device. Data tidak dikirim ke server manapun.',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7), height: 1.4),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Form Profil
          const Text('Nama Pengemudi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          _buildTextField(controller: _nameController, hint: 'Masukkan nama kamu', icon: Icons.person_rounded),

          const SizedBox(height: 16),

          const Text('Email', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          _buildTextField(controller: _emailController, hint: 'email@contoh.com', icon: Icons.email_rounded, keyboardType: TextInputType.emailAddress),

          const SizedBox(height: 20),

          // Tombol Simpan
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveProfile,
              icon: _isSaving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(_isSaving ? 'Menyimpan...' : 'Simpan Profil'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),

          const SizedBox(height: 12),

          // Masuk dengan Google (placeholder)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('🔜 Google Sign-In akan hadir di versi berikutnya'), behavior: SnackBarBehavior.floating),
              ),
              icon: const Icon(Icons.g_mobiledata_rounded, size: 24),
              label: const Text('Masuk dengan Google'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),

          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // App Info
          const Text('Informasi Aplikasi', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          _buildInfoRow(Icons.memory_rounded, 'AI Engine', 'Google ML Kit Face Detection (On-Device)'),
          const SizedBox(height: 8),
          _buildInfoRow(Icons.security_rounded, 'Privasi', 'Tidak ada data yang dikirim ke server'),
          const SizedBox(height: 8),
          _buildInfoRow(Icons.info_outline_rounded, 'Versi', 'DrivingBuddy v1.0.0 — Capstone UIUX'),

          const SizedBox(height: 24),

          // Tombol Keluar
          if (_isLoggedIn) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout_rounded, size: 18, color: AppColors.danger),
                label: const Text('Keluar dari Akun', style: TextStyle(color: AppColors.danger)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.danger),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }

  Widget _buildTextField({required TextEditingController controller, required String hint, required IconData icon, TextInputType? keyboardType}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6, offset: const Offset(0, 2))]),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w400),
          prefixIcon: Icon(icon, color: AppColors.primary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onChanged: (_) => setState(() {}), // Update avatar inisial
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 1))]),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
