import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

// ─────────────────────────────────────────────
//  DESIGN TOKENS
// ─────────────────────────────────────────────
class _C {
  static const bg       = Color(0xFF0A0E1A);
  static const surface  = Color(0xFF131929);
  static const card     = Color(0xFF1C2333);
  static const orange   = Color(0xFFFF5722);
  static const orangeL  = Color(0xFFFF8A65);
  static const green    = Color(0xFF00E676);
  static const yellow   = Color(0xFFFFD740);
  static const red      = Color(0xFFFF5252);
  static const blue     = Color(0xFF448AFF);
  static const purple   = Color(0xFFE040FB);
  static const white    = Colors.white;
  static const grey     = Color(0xFF8892A4);
  static const divider  = Color(0xFF252D3F);
}

// ─────────────────────────────────────────────
//  ACHIEVEMENT MODEL
// ─────────────────────────────────────────────
class Achievement {
  final String tag;
  final String emoji;
  final Color color;
  const Achievement(this.tag, this.emoji, this.color);
}

List<Achievement> computeAchievements({
  required int durationSeconds,
  required int drivingScore,
  required int totalMicrosleeps,
  required int totalDrowsy,
  required int totalYawns,
  required bool isFirstSession,
  DateTime? startedAt,
}) {
  final results = <Achievement>[];
  final h = startedAt?.hour ?? 12;

  if (isFirstSession)
    results.add(Achievement('#PerdanaBerkendara', '🚩', _C.yellow));

  if (drivingScore >= 95 && totalMicrosleeps == 0 && totalDrowsy == 0)
    results.add(Achievement('#PengemudiLegenda', '👑', _C.yellow));
  else if (drivingScore >= 90 && totalMicrosleeps == 0)
    results.add(Achievement('#PengemudiHandal', '🏆', _C.orange));
  else if (drivingScore >= 80)
    results.add(Achievement('#BerkendaraAman', '✅', _C.green));
  else if (drivingScore >= 65)
    results.add(Achievement('#PengemudiWaspada', '🛡️', _C.blue));

  if (totalMicrosleeps == 0 && durationSeconds > 300)
    results.add(Achievement('#ZeroMicrosleep', '👁️', _C.blue));
  if (totalDrowsy == 0 && totalYawns == 0 && durationSeconds > 300)
    results.add(Achievement('#FokusTotal', '🎯', _C.purple));

  if (durationSeconds >= 10800)
    results.add(Achievement('#MarathonDriver', '🚗💨', _C.orange));
  else if (durationSeconds >= 7200 && drivingScore >= 80)
    results.add(Achievement('#2JamAman', '⏱️', _C.orange));
  else if (durationSeconds >= 3600 && drivingScore >= 80)
    results.add(Achievement('#1JamAman', '⏳', _C.orangeL));

  if (h >= 22 || h < 5)
    results.add(Achievement('#NightDriver', '🌙', _C.purple));
  else if (h >= 4 && h < 7)
    results.add(Achievement('#EarlyBird', '🌅', _C.yellow));

  if (results.isEmpty)
    results.add(Achievement('#TerusBerkembang', '💪', _C.grey));

  return results.take(4).toList();
}

// ─────────────────────────────────────────────
//  SCORE RING PAINTER
// ─────────────────────────────────────────────
class _ScoreRingPainter extends CustomPainter {
  final double progress; // 0.0–1.0
  final Color color;
  _ScoreRingPainter(this.progress, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = (size.width - 12) / 2;

    // Track
    canvas.drawCircle(
      Offset(cx, cy), r,
      Paint()
        ..color = _C.divider
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke,
    );

    // Glow
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = color.withOpacity(0.15)
        ..strokeWidth = 16
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // Arc
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = color
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 1),
    );
  }

  @override
  bool shouldRepaint(_ScoreRingPainter old) => old.progress != progress;
}

// ─────────────────────────────────────────────
//  ROUTE PAINTER — dekoratif seperti Strava
// ─────────────────────────────────────────────
class _RoutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Shadow/glow path
    final glowPaint = Paint()
      ..color = _C.orange.withOpacity(0.18)
      ..strokeWidth = 12
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final linePaint = Paint()
      ..color = _C.orange
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final dotPaint = Paint()..color = _C.orange;

    // Route path
    final path = Path()
      ..moveTo(w * 0.08, h * 0.78)
      ..cubicTo(w * 0.18, h * 0.30, w * 0.35, h * 0.85, w * 0.50, h * 0.45)
      ..cubicTo(w * 0.60, h * 0.15, w * 0.70, h * 0.70, w * 0.82, h * 0.35)
      ..lineTo(w * 0.92, h * 0.22);

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, linePaint);

    // Start dot
    canvas.drawCircle(Offset(w * 0.08, h * 0.78), 6, dotPaint);
    canvas.drawCircle(Offset(w * 0.08, h * 0.78), 10,
        Paint()..color = _C.orange.withOpacity(0.25));

    // End dot  
    canvas.drawCircle(Offset(w * 0.92, h * 0.22), 5,
        Paint()..color = _C.green);
    canvas.drawCircle(Offset(w * 0.92, h * 0.22), 9,
        Paint()..color = _C.green.withOpacity(0.25));

    // Dashed grid lines (subtle)
    final gridPaint = Paint()
      ..color = _C.white.withOpacity(0.04)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, h * i / 4), Offset(w, h * i / 4), gridPaint);
      canvas.drawLine(Offset(w * i / 4, 0), Offset(w * i / 4, h), gridPaint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

// ─────────────────────────────────────────────
//  MAIN SCREEN
// ─────────────────────────────────────────────
class DrivingCardScreen extends StatefulWidget {
  final int durationSeconds;
  final int drivingScore;
  final int totalMicrosleeps;
  final int totalDrowsy;
  final int totalYawns;
  final double distanceKm;
  final double avgSpeedKmh;
  final bool isFirstSession;
  final DateTime? startedAt;

  const DrivingCardScreen({
    super.key,
    required this.durationSeconds,
    required this.drivingScore,
    required this.totalMicrosleeps,
    required this.totalDrowsy,
    required this.totalYawns,
    this.distanceKm = 0,
    this.avgSpeedKmh = 0,
    this.isFirstSession = false,
    this.startedAt,
  });

  @override
  State<DrivingCardScreen> createState() => _DrivingCardScreenState();
}

class _DrivingCardScreenState extends State<DrivingCardScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scoreAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _scoreAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── helpers ──────────────────────────────
  String _dur(int s) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    if (h > 0) return '${h}j ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  String _date(DateTime dt) {
    final d = dt.toLocal();
    const months = ['Jan','Feb','Mar','Apr','Mei','Jun',
                    'Jul','Agu','Sep','Okt','Nov','Des'];
    return '${d.day} ${months[d.month - 1]} ${d.year}  '
           '${d.hour.toString().padLeft(2,'0')}:'
           '${d.minute.toString().padLeft(2,'0')}';
  }

  Color get _scoreColor {
    final s = widget.drivingScore;
    if (s >= 85) return _C.green;
    if (s >= 65) return _C.yellow;
    return _C.red;
  }

  String get _scoreLabel {
    final s = widget.drivingScore;
    if (s >= 95) return 'LUAR BIASA';
    if (s >= 85) return 'SANGAT AMAN';
    if (s >= 75) return 'AMAN';
    if (s >= 60) return 'WASPADA';
    return 'BERBAHAYA';
  }

  // ── build ─────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final achievements = computeAchievements(
      durationSeconds: widget.durationSeconds,
      drivingScore: widget.drivingScore,
      totalMicrosleeps: widget.totalMicrosleeps,
      totalDrowsy: widget.totalDrowsy,
      totalYawns: widget.totalYawns,
      isFirstSession: widget.isFirstSession,
      startedAt: widget.startedAt,
    );

    return Scaffold(
      backgroundColor: _C.bg,
      body: Stack(children: [
        // ── ambient glow ──
        Positioned(
          top: -120, right: -80,
          child: _Glow(color: _C.orange, size: 350, opacity: 0.06),
        ),
        Positioned(
          bottom: -100, left: -60,
          child: _Glow(color: _scoreColor, size: 280, opacity: 0.07),
        ),

        SafeArea(
          child: Column(children: [
            _buildTopBar(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                child: Column(children: [
                  _buildBrand(),
                  const SizedBox(height: 20),
                  _buildRouteCard(),
                  const SizedBox(height: 20),
                  _buildStatsRow(),
                  const SizedBox(height: 20),
                  _buildScoreSection(achievements),
                  const SizedBox(height: 20),
                  _buildEventRow(),
                  const SizedBox(height: 24),
                  _buildShareButton(),
                  const SizedBox(height: 16),
                  if (widget.startedAt != null)
                    Text(
                      _date(widget.startedAt!),
                      style: const TextStyle(color: _C.grey, fontSize: 11),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ── top bar ──────────────────────────────
  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(children: [
        _IconBtn(
          icon: Icons.close_rounded,
          onTap: () => Navigator.pop(context),
        ),
        const Spacer(),
        const Text('Kartu Berkendara',
            style: TextStyle(
                color: _C.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3)),
        const Spacer(),
        _IconBtn(
          icon: Icons.ios_share_rounded,
          color: _C.orange,
          onTap: _onShare,
        ),
      ]),
    );
  }

  // ── brand ────────────────────────────────
  Widget _buildBrand() {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [_C.orange, _C.orangeL],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.directions_car_rounded,
            color: _C.white, size: 18),
      ),
      const SizedBox(width: 10),
      const Text.rich(
        TextSpan(children: [
          TextSpan(
            text: 'DRIVING',
            style: TextStyle(
                color: _C.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 3),
          ),
          TextSpan(
            text: ' BUDDY',
            style: TextStyle(
                color: _C.orange,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 3),
          ),
        ]),
      ),
    ]);
  }

  // ── route card ───────────────────────────
  Widget _buildRouteCard() {
    return Container(
      height: 180,
      width: double.infinity,
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _C.divider, width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(children: [
        // Route paint
        Positioned.fill(
          child: CustomPaint(painter: _RoutePainter()),
        ),
        // GPS badge
        Positioned(
          top: 12, right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _C.bg.withOpacity(0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _C.divider),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.gps_fixed_rounded, size: 11, color: _C.orange),
              SizedBox(width: 4),
              Text('GPS Segera Hadir',
                  style: TextStyle(
                      color: _C.grey, fontSize: 10, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
    );
  }

  // ── stats row ────────────────────────────
  Widget _buildStatsRow() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _C.divider),
      ),
      child: Row(children: [
        _StatCol(
          label: 'WAKTU',
          value: _dur(widget.durationSeconds),
          icon: Icons.timer_outlined,
          iconColor: _C.orangeL,
        ),
        _VLine(),
        _StatCol(
          label: 'JARAK',
          value: widget.distanceKm > 0
              ? '${widget.distanceKm.toStringAsFixed(1)} km'
              : '—',
          sub: widget.distanceKm > 0 ? null : 'GPS belum aktif',
          icon: Icons.straighten_rounded,
          iconColor: _C.blue,
        ),
        _VLine(),
        _StatCol(
          label: 'KECEPATAN',
          value: widget.avgSpeedKmh > 0
              ? '${widget.avgSpeedKmh.toStringAsFixed(0)}'
              : '—',
          sub: widget.avgSpeedKmh > 0 ? 'km/h avg' : 'GPS belum aktif',
          icon: Icons.speed_rounded,
          iconColor: _C.green,
        ),
      ]),
    );
  }

  // ── score + achievements ─────────────────
  Widget _buildScoreSection(List<Achievement> achievements) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // Animated score ring
      AnimatedBuilder(
        animation: _scoreAnim,
        builder: (_, __) {
          final progress = _scoreAnim.value * widget.drivingScore / 100;
          return SizedBox(
            width: 120, height: 120,
            child: Stack(alignment: Alignment.center, children: [
              CustomPaint(
                size: const Size(120, 120),
                painter: _ScoreRingPainter(progress, _scoreColor),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  '${(widget.drivingScore * _scoreAnim.value).round()}',
                  style: TextStyle(
                    color: _scoreColor,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                Text(
                  _scoreLabel,
                  style: const TextStyle(
                    color: _C.grey,
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ]),
            ]),
          );
        },
      ),

      const SizedBox(width: 18),

      // Achievements
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('PENCAPAIAN',
              style: TextStyle(
                  color: _C.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: achievements.map((a) => _BadgeChip(a)).toList(),
          ),
        ]),
      ),
    ]);
  }

  // ── event row ────────────────────────────
  Widget _buildEventRow() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _C.divider),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _EventTile(
            icon: Icons.bedtime_outlined,
            label: 'Microsleep',
            value: '${widget.totalMicrosleeps}×',
            ok: widget.totalMicrosleeps == 0,
          ),
          _EVLine(),
          _EventTile(
            icon: Icons.warning_amber_rounded,
            label: 'Kantuk',
            value: '${widget.totalDrowsy}×',
            ok: widget.totalDrowsy == 0,
          ),
          _EVLine(),
          _EventTile(
            icon: Icons.air_rounded,
            label: 'Menguap',
            value: '${widget.totalYawns}×',
            ok: widget.totalYawns <= 2,
          ),
        ],
      ),
    );
  }

  // ── share button ─────────────────────────
  Widget _buildShareButton() {
    return GestureDetector(
      onTap: _onShare,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [_C.orange, _C.orangeL],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: _C.orange.withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.ios_share_rounded, color: _C.white, size: 20),
            SizedBox(width: 10),
            Text('Bagikan Kartu Berkendara',
                style: TextStyle(
                    color: _C.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3)),
          ],
        ),
      ),
    );
  }

  void _onShare() {
    Share.share(
      '🚗 Sesi berkendara selesai!\n'
      '⏱ Waktu: ${_dur(widget.durationSeconds)}\n'
      '🏆 Skor: ${widget.drivingScore}/100 — $_scoreLabel\n'
      '😴 Microsleep: ${widget.totalMicrosleeps}×\n\n'
      'Pantau keselamatanmu dengan DrivingBuddy!',
    );
  }
}

// ─────────────────────────────────────────────
//  HELPER WIDGETS
// ─────────────────────────────────────────────

class _Glow extends StatelessWidget {
  final Color color;
  final double size, opacity;
  const _Glow({required this.color, required this.size, required this.opacity});
  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(opacity),
        ),
      );
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _IconBtn(
      {required this.icon, required this.onTap, this.color = _C.grey});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: _C.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _C.divider),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
      );
}

class _StatCol extends StatelessWidget {
  final String label, value;
  final String? sub;
  final IconData icon;
  final Color iconColor;
  const _StatCol(
      {required this.label,
      required this.value,
      required this.icon,
      required this.iconColor,
      this.sub});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Icon(icon, color: iconColor, size: 16),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(
                  color: _C.grey,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: _C.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1)),
          if (sub != null)
            Text(sub!,
                style: const TextStyle(color: _C.grey, fontSize: 9)),
        ]),
      );
}

class _VLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 52, color: _C.divider);
}

class _EVLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 44, color: _C.divider);
}

class _EventTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final bool ok;
  const _EventTile(
      {required this.icon,
      required this.label,
      required this.value,
      required this.ok});
  @override
  Widget build(BuildContext context) {
    final c = ok ? _C.green : _C.red;
    return Column(children: [
      Icon(icon, color: c, size: 22),
      const SizedBox(height: 4),
      Text(value,
          style: TextStyle(
              color: c, fontSize: 16, fontWeight: FontWeight.w800)),
      Text(label,
          style: const TextStyle(color: _C.grey, fontSize: 10)),
    ]);
  }
}

class _BadgeChip extends StatelessWidget {
  final Achievement a;
  const _BadgeChip(this.a);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: a.color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: a.color.withOpacity(0.35), width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(a.emoji, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 5),
          Text(a.tag,
              style: TextStyle(
                  color: a.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2)),
        ]),
      );
}
