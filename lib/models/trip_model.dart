import 'package:flutter/material.dart';
import '../core/app_colors.dart';

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

  RestAreaRecommendation({
    required this.name,
    required this.distance,
    required this.facilities,
  });
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
// MOCK / DUMMY DATA — Untuk Riwayat & Cockpit (data historis, bukan real-time)
// ============================================================================

final List<TripRecord> dummyTripRecords = [
  TripRecord(
    routeName: 'Amphoreus (KM 72 – 120)',
    dateInfo: 'Malam ini',
    timeRange: '21:15 – 23:30',
    duration: '02:15:00',
    warningLabel: '1x Peringatan Ringan',
    warningColor: AppColors.warning,
    driverStatus: 'Kantuk halus m-34',
    avgEAR: 0.29,
    avgSpeed: 88,
    earGraphData: [0.32, 0.30, 0.28, 0.31, 0.27, 0.29, 0.26, 0.30, 0.28],
  ),
  TripRecord(
    routeName: 'Nodkrai – Snezhnaya (Eye of Graeae)',
    dateInfo: 'Kemarin',
    timeRange: '08:10 – 10:10',
    duration: '01:40:00',
    warningLabel: '0 Peringatan',
    warningColor: AppColors.success,
    driverStatus: 'Fokus Optimal',
    avgEAR: 0.35,
    avgSpeed: 78,
    earGraphData: [0.34, 0.35, 0.36, 0.34, 0.35, 0.33, 0.36, 0.35, 0.34],
  ),
  TripRecord(
    routeName: 'Monstadt – Liyue (Trans Star Rail)',
    dateInfo: '14 Okt',
    timeRange: '18:00 – 21:45',
    duration: '03:45:00',
    warningLabel: '2x Jeda Istirahat Direkomendasikan',
    warningColor: AppColors.danger,
    driverStatus: 'Rest Area KM 283',
    avgEAR: 0.27,
    avgSpeed: 94,
    earGraphData: [0.30, 0.28, 0.25, 0.27, 0.22, 0.26, 0.24, 0.28, 0.25],
  ),
  TripRecord(
    routeName: 'Amphoreus – Planarcadia',
    dateInfo: '12 Okt',
    timeRange: '06:30 – 08:45',
    duration: '02:15:00',
    warningLabel: '0 Peringatan',
    warningColor: AppColors.success,
    driverStatus: 'Fokus Optimal',
    avgEAR: 0.33,
    avgSpeed: 65,
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
  totalDuration: '100j 40m',
  safetyScore: 95,
  comparisonText: '↓ 3 sesi dibanding pekan lalu.',
);
