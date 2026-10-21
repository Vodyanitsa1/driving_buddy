import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../driving_card_screen.dart';
import '../supabase_service.dart';
import '../widgets/driving_buddy_app_bar.dart';

// ============================================================================
// HISTORY SCREEN (Riwayat Perjalanan Telemetri — Luxury GT)
// ============================================================================

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _sessions = [];
  bool _isLoading = true;
  String? _userName;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final sessions = await SessionService.getUserSessions();
      final name = await AuthService.getUserName();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _userName = name;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error load history: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDuration(int seconds) {
    if (seconds == 0) return '0 mnt';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}j ${m}m';
    return '${m}m';
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return '-';
    final dt = DateTime.tryParse(isoDate)?.toLocal();
    if (dt == null) return '-';
    final now = DateTime.now();
    final diff = now.difference(dt).inDays;
    if (diff == 0) return 'Hari ini';
    if (diff == 1) return 'Kemarin';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Color _scoreColor(int score) {
    if (score >= 80) return const Color(0xFF059669);
    if (score >= 50) return const Color(0xFFE5A938);
    return const Color(0xFFD94126);
  }

  int get _totalSeconds =>
      _sessions.fold(0, (sum, s) => sum + ((s['duration_seconds'] as num?)?.toInt() ?? 0));

  int get _avgScore {
    if (_sessions.isEmpty) return 96;
    final total =
        _sessions.fold(0, (sum, s) => sum + ((s['driving_score'] as num?)?.toInt() ?? 100));
    return (total / _sessions.length).round();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          const DrivingBuddyAppBar(title: 'Riwayat Perjalanan'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadData,
              color: const Color(0xFFE57A38),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  // 1. Summary Card with Dial
                  SliverToBoxAdapter(child: _buildSummaryCard()),

                  // 2. Section Header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Daftar Sesi Perjalanan',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFFED7AA)),
                                ),
                                child: Text(
                                  '${_sessions.length} Sesi',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFFC25E21),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh_rounded, color: Color(0xFFE57A38), size: 20),
                            onPressed: _loadData,
                            tooltip: 'Perbarui',
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 3. Loading / Empty / List
                  if (_isLoading)
                    const SliverFillRemaining(
                      child: Center(
                        child: CircularProgressIndicator(color: Color(0xFFE57A38)),
                      ),
                    )
                  else if (_sessions.isEmpty)
                    SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.directions_car_outlined,
                              size: 56,
                              color: const Color(0xFF64748B).withOpacity(0.35),
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              'Belum Ada Sesi Perjalanan',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Mulai sesi berkendara untuk merekam telemetri Anda.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverList.builder(
                        itemCount: _sessions.length,
                        itemBuilder: (context, index) {
                          return _buildSessionCard(_sessions[index]);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFFFFBF8)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFED7AA)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE57A38).withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'TELEMETRI KUMULATIF',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: Color(0xFFC25E21),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Ringkasan Keseluruhan Sesi',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (_userName != null) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: Text(
                      _userName!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFC25E21),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // 3-Column Strava metrics
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFFFEDD5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'TOTAL SESI',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${_sessions.length}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                        ),
                      ),
                      const Text('perjalanan', style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                Container(height: 36, width: 1, color: const Color(0xFFFFEDD5)),
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'TOTAL WAKTU',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _formatDuration(_totalSeconds),
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                        ),
                      ),
                      const Text('kemudi', style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                Container(height: 36, width: 1, color: const Color(0xFFFFEDD5)),
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'RATA SKOR',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$_avgScore%',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _scoreColor(_avgScore)),
                        ),
                      ),
                      const Text('kewaspadaan', style: TextStyle(fontSize: 10, color: Color(0xFF059669))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(Map<String, dynamic> session) {
    final score = (session['driving_score'] as num?)?.toInt() ?? 100;
    final duration = (session['duration_seconds'] as num?)?.toInt() ?? 0;
    final drowsy = (session['total_drowsy_events'] as num?)?.toInt() ?? 0;
    final yawn = (session['total_yawns'] as num?)?.toInt() ?? 0;
    final micro = (session['total_microsleeps'] as num?)?.toInt() ?? 0;
    final date = _formatDate(session['started_at'] as String?);
    final startedAt = session['started_at'] as String?;
    String timeStr = '-';
    if (startedAt != null) {
      final dt = DateTime.tryParse(startedAt)?.toLocal();
      if (dt != null) {
        timeStr =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
    }

    final scoreColor = _scoreColor(score);
    final totalEvents = drowsy + yawn + micro;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
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
            color: const Color(0xFFE57A38).withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: scoreColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scoreColor.withOpacity(0.3)),
                    ),
                    child: Text(
                      'Skor $score%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: scoreColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$date • $timeStr',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              if (micro > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Text(
                    '${micro}x Microsleep',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFD94126),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Mini Sparkline Waveform
          Container(
            height: 32,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFEDD5)),
            ),
            child: CustomPaint(
              painter: _HistorySparklinePainter(color: scoreColor),
            ),
          ),
          const SizedBox(height: 10),

          // 3-Stat metrics
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('DURASI', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                    const SizedBox(height: 2),
                    Text(_formatDuration(duration), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('EVENT KANTUK', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                    const SizedBox(height: 2),
                    Text('$totalEvents Terdeteksi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: totalEvents > 0 ? const Color(0xFFE57A38) : const Color(0xFF059669))),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('MENGUAP', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                    const SizedBox(height: 2),
                    Text('$yawn kali', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Button Buka Kartu Berkendara
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DrivingCardScreen(
                      durationSeconds: duration,
                      drivingScore: score,
                      totalMicrosleeps: micro,
                      totalDrowsy: drowsy,
                      totalYawns: yawn,
                      startedAt: session['started_at'] != null
                          ? DateTime.tryParse(session['started_at'] as String)
                          : null,
                    ),
                  ),
                );
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFFED7AA)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                backgroundColor: const Color(0xFFFFF7ED),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.workspace_premium_rounded, size: 16, color: Color(0xFFE57A38)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Lihat Kartu Pencapaian',
                      style: const TextStyle(
                        color: Color(0xFFE57A38),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySparklinePainter extends CustomPainter {
  final Color color;

  _HistorySparklinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    path.moveTo(0, size.height * 0.7);
    path.cubicTo(
      size.width * 0.25, size.height * 0.8,
      size.width * 0.45, size.height * 0.2,
      size.width * 0.65, size.height * 0.4,
    );
    path.cubicTo(
      size.width * 0.8, size.height * 0.6,
      size.width * 0.9, size.height * 0.1,
      size.width, size.height * 0.3,
    );

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..color = color.withOpacity(0.12)
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(_HistorySparklinePainter old) => old.color != color;
}
