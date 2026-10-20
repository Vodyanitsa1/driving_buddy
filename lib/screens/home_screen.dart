import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../models/trip_model.dart';
import '../routes/app_routes.dart';
import '../widgets/driving_buddy_app_bar.dart';
import '../features/nearby_places/nearby_places.dart';

// ============================================================================
// HOME SCREEN / COCKPIT (Dashboard Beranda — Tanpa Kamera)
// ============================================================================

typedef HomeScreen = CockpitScreen;

class CockpitScreen extends StatelessWidget {
  final VoidCallback? onStartMonitoring;

  const CockpitScreen({super.key, this.onStartMonitoring});

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
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A2E), Color(0xFF2D2B55)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1A1A2E).withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.psychology_rounded,
                    color: AppColors.success, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI On-Device Siap',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tidak perlu server atau internet. Deteksi kantuk berjalan langsung di HP kamu.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.6),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildCheckRow(Icons.camera_alt_rounded, 'Kamera Depan',
              'Standby — siap diaktifkan'),
          const SizedBox(height: 8),
          _buildCheckRow(Icons.psychology_rounded, 'ML Kit Face Mesh',
              'On-device, tanpa internet'),
          const SizedBox(height: 8),
          _buildCheckRow(Icons.shield_rounded, 'Privasi Terjaga',
              'Data tidak keluar dari HP'),
        ],
      ),
    );
  }

  Widget _buildCheckRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Icon(icon, color: AppColors.success, size: 16),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.45),
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _buildStartMonitoringButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () {
            if (onStartMonitoring != null) {
              onStartMonitoring!();
            } else {
              Navigator.pushNamed(context, AppRoutes.monitor);
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 4,
            shadowColor: AppColors.primary.withOpacity(0.35),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_rounded, size: 24),
              SizedBox(width: 10),
              Text(
                'Mulai Monitoring',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
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
          _QuickStatCard(
            icon: Icons.route_rounded,
            iconColor: AppColors.primary,
            value: '${dummyWeeklySummary.totalSessions}',
            label: 'Sesi Pekan Ini',
          ),
          const SizedBox(width: 10),
          _QuickStatCard(
            icon: Icons.access_time_rounded,
            iconColor: Colors.blue,
            value: dummyWeeklySummary.totalDuration,
            label: 'Total Waktu',
          ),
          const SizedBox(width: 10),
          _QuickStatCard(
            icon: Icons.verified_rounded,
            iconColor: AppColors.success,
            value: '${dummyWeeklySummary.safetyScore}%',
            label: 'Skor Aman',
          ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded,
                  color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Perjalanan Terakhir',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                last.dateInfo,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      last.routeName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      last.timeRange,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  last.duration,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: last.warningColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: last.warningColor.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  last.warningColor == AppColors.success
                      ? Icons.check_circle_rounded
                      : Icons.warning_amber_rounded,
                  size: 12,
                  color: last.warningColor,
                ),
                const SizedBox(width: 4),
                Text(
                  last.warningLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: last.warningColor,
                  ),
                ),
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
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.local_cafe_rounded,
                color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tips Keselamatan',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryDark,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Istirahat 15 menit setiap 2 jam berkendara. Minum kopi atau cuci muka untuk membantu kewaspadaan.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
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
          // Daftar tempat terdekat dari Maps API (rest area, minimarket, hotel/motel, SPBU).
          onPressed: () => showNearbyPlacesSheet(context),
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

  const _QuickStatCard({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
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
        child: Column(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
