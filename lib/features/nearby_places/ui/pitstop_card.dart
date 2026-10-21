import 'package:flutter/material.dart';

import '../logic/nearby_controller.dart';
import '../models/nearby_place.dart';
import 'nearby_sheet.dart';
import 'places_style.dart';

// ============================================================================
// KARTU "REKOMENDASI PITSTOP" — sesuai rancangan Stitch (layar Berkendara):
//   [kotak ikon]  REKOMENDASI PITSTOP •          [tombol navigasi]
//                 Rest Area KM 57
//                 4,2 km lagi • Rest Area
//
//  * ketuk tombol navigasi  -> buka Google Maps (mode mobil) ke tempat itu
//  * ketuk bagian lain      -> daftar "Tempat Terdekat" (rest area, minimarket,
//                              hotel/motel, SPBU)
//  * saat alarm kantuk (controller.urgent) kartu berubah merah + "ISTIRAHAT
//    SEKARANG" dan menampilkan tempat berhenti terdekat APA PUN jenisnya
//
// Kartu hanya MENAMPILKAN keadaan controller; semua error sudah jadi teks
// siap tampil. Tidak ada satu pun yang boleh melempar exception ke layar.
// ============================================================================

/// Aksi yang dipicu tombol di sisi kanan kartu.
enum PitstopAction {
  /// Tidak ada tombol (sedang memuat / belum aktif).
  none,

  /// Buka navigasi ke [PitstopView.place].
  navigate,

  /// Minta izin lokasi / buka pengaturan lokasi atau aplikasi.
  requestPermission,

  /// Coba ambil ulang dari server.
  retry,

  /// Buka daftar tempat terdekat.
  openList,
}

/// Teks, ikon, dan aksi kartu untuk satu keadaan controller.
/// Dipisah dari widget supaya mudah dites tanpa menggambar layar.
@immutable
class PitstopView {
  const PitstopView({
    required this.label,
    required this.title,
    required this.subtitle,
    this.icon = Icons.local_cafe_rounded,
    this.action = PitstopAction.none,
    this.actionIcon = Icons.navigation_rounded,
    this.actionLabel = '',
    this.busy = false,
    this.pulse = false,
    this.urgent = false,
    this.place,
  });

  /// Kapital kecil di atas judul.
  final String label;
  final String title;
  final String subtitle;
  final IconData icon;
  final PitstopAction action;
  final IconData actionIcon;

  /// Label untuk pembaca layar (TalkBack) pada tombol aksi.
  final String actionLabel;

  /// Sedang menunggu (tampilkan indikator, bukan tombol).
  final bool busy;

  /// Titik berkedip di samping label.
  final bool pulse;
  final bool urgent;

  /// Tempat yang direkomendasikan (hanya saat [action] == navigate).
  final NearbyPlace? place;

  /// Terjemahkan keadaan [controller] jadi isi kartu.
  /// [urgent] `null` = ikuti `controller.urgent`.
  factory PitstopView.from(NearbyPlacesController controller, {bool? urgent}) {
    final isUrgent = urgent ?? controller.urgent;
    final label = isUrgent ? 'ISTIRAHAT SEKARANG' : 'REKOMENDASI PITSTOP';
    final what = isUrgent ? 'tempat berhenti' : 'tempat terdekat';

    switch (controller.status) {
      case NearbyStatus.idle:
        return PitstopView(
          label: label,
          title: 'Pitstop siaga',
          subtitle: 'Mulai sesi untuk mencari $what terdekat',
          urgent: isUrgent,
        );
      case NearbyStatus.needPermission:
        return PitstopView(
          label: label,
          title: 'Aktifkan lokasi',
          subtitle: 'Izinkan lokasi agar $what terdekat bisa dicari',
          icon: Icons.location_searching_rounded,
          action: PitstopAction.requestPermission,
          actionIcon: Icons.my_location_rounded,
          actionLabel: 'Izinkan akses lokasi',
          urgent: isUrgent,
        );
      case NearbyStatus.permissionBlocked:
        return PitstopView(
          label: label,
          title: 'Lokasi diblokir',
          subtitle: 'Buka Pengaturan lalu izinkan lokasi untuk aplikasi ini',
          icon: Icons.location_disabled_rounded,
          action: PitstopAction.requestPermission,
          actionIcon: Icons.settings_rounded,
          actionLabel: 'Buka pengaturan aplikasi',
          urgent: isUrgent,
        );
      case NearbyStatus.gpsOff:
        return PitstopView(
          label: label,
          title: 'GPS belum menyala',
          subtitle: 'Nyalakan lokasi di HP untuk mencari $what',
          icon: Icons.location_off_rounded,
          action: PitstopAction.requestPermission,
          actionIcon: Icons.settings_rounded,
          actionLabel: 'Buka pengaturan lokasi',
          urgent: isUrgent,
        );
      case NearbyStatus.locating:
        return PitstopView(
          label: label,
          title: 'Mencari posisimu…',
          subtitle: 'Menunggu sinyal GPS',
          icon: Icons.gps_not_fixed_rounded,
          busy: true,
          urgent: isUrgent,
        );
      case NearbyStatus.loading:
        return PitstopView(
          label: label,
          title: isUrgent ? 'Mencari tempat berhenti…' : 'Mencari tempat terdekat…',
          subtitle: 'Mencari rest area, SPBU, minimarket, atau hotel',
          busy: true,
          urgent: isUrgent,
        );
      case NearbyStatus.ready:
        {
          final place = controller.best;
          if (place == null) {
            // Seharusnya tidak terjadi (status ready berarti ada rekomendasi); tetap aman.
            return PitstopView(
              label: label,
              title: 'Mencari $what…',
              subtitle: 'Menghubungi server tempat terdekat',
              busy: true,
              urgent: isUrgent,
            );
          }
          return PitstopView(
            label: label,
            title: place.name,
            subtitle: readySubtitle(place, stale: controller.isStale),
            icon: place.category?.icon ?? Icons.place_rounded,
            action: PitstopAction.navigate,
            actionIcon: Icons.navigation_rounded,
            actionLabel: 'Arahkan ke ${place.name}',
            pulse: true,
            urgent: isUrgent,
            place: place,
          );
        }
      case NearbyStatus.empty:
        return PitstopView(
          label: label,
          title: isUrgent ? 'Belum ada tempat berhenti' : 'Belum ada tempat terdekat',
          subtitle: 'Tidak ada rest area, SPBU, minimarket, atau hotel di sekitar sini.',
          icon: Icons.search_off_rounded,
          action: PitstopAction.openList,
          actionIcon: Icons.search_rounded,
          actionLabel: 'Cari tempat lain',
          urgent: isUrgent,
        );
      case NearbyStatus.error:
        return PitstopView(
          label: label,
          title: isUrgent ? 'Gagal mencari tempat berhenti' : 'Gagal memuat tempat',
          subtitle: controller.statusMessage,
          icon: Icons.cloud_off_rounded,
          action: PitstopAction.retry,
          actionIcon: Icons.refresh_rounded,
          actionLabel: 'Coba lagi',
          urgent: isUrgent,
        );
    }
  }

  /// '4,2 km lagi • Rest Area' (atau '… di belakang' untuk yang sudah terlewat).
  static String readySubtitle(NearbyPlace place, {bool stale = false}) {
    final parts = <String>[
      place.ahead == false
          ? '${place.distanceText} di belakang'
          : '${place.distanceText} lagi',
      place.categoryText,
    ];
    if (place.openNow == true) parts.add('Buka');
    if (place.openNow == false) parts.add('Tutup');
    if (stale) parts.add('data lama');
    return parts.join(' • ');
  }
}

class PitstopCard extends StatefulWidget {
  const PitstopCard({
    super.key,
    required this.controller,
    this.urgent,
    this.onNavigate,
    this.onOpenList,
    this.animate = true,
  });

  final NearbyPlacesController controller;

  /// `null` = ikuti `controller.urgent`; `true`/`false` = paksa tampilan.
  final bool? urgent;

  /// Ganti perilaku tombol navigasi (bawaan: buka Google Maps).
  final void Function(NearbyPlace place)? onNavigate;

  /// Ganti perilaku ketukan kartu (bawaan: buka daftar tempat terdekat).
  final VoidCallback? onOpenList;

  /// false = tanpa animasi (titik berkedip & indikator) — untuk tes widget.
  final bool animate;

  @override
  State<PitstopCard> createState() => _PitstopCardState();
}

class _PitstopCardState extends State<PitstopCard>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      lowerBound: 0.35,
      upperBound: 1.0,
      value: 1.0,
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant PitstopCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncPulse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    if (widget.animate) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1.0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pengguna balik dari Pengaturan (izin/GPS): cek ulang tanpa menunggu.
    if (state == AppLifecycleState.resumed) widget.controller.onAppResumed();
  }

  // ------------------------------------------------------------------ aksi

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _onAction(PitstopView view) async {
    final controller = widget.controller;
    switch (view.action) {
      case PitstopAction.none:
        return;
      case PitstopAction.navigate:
        final place = view.place;
        if (place == null) return;
        final handler = widget.onNavigate;
        if (handler != null) {
          handler(place);
          return;
        }
        final opened = await controller.navigateTo(place);
        if (!opened) {
          _toast('Tidak bisa membuka Google Maps. Pasang aplikasi peta atau browser.');
        }
        return;
      case PitstopAction.requestPermission:
        await controller.requestPermission();
        return;
      case PitstopAction.retry:
        await controller.refreshPitstop(force: true);
        return;
      case PitstopAction.openList:
        _openList();
        return;
    }
  }

  void _openList() {
    final handler = widget.onOpenList;
    if (handler != null) {
      handler();
      return;
    }
    showNearbyPlacesSheet(context, controller: widget.controller);
  }

  // ---------------------------------------------------------------- tampilan

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final view = PitstopView.from(widget.controller, urgent: widget.urgent);
        return _buildCard(view);
      },
    );
  }

  Widget _buildCard(PitstopView view) {
    final urgent = view.urgent;
    final accent = urgent ? PlacesStyle.vermilion : PlacesStyle.copper;
    final labelColor = urgent ? PlacesStyle.vermilionDark : PlacesStyle.copperDark;
    final radius = BorderRadius.circular(PlacesStyle.radiusLg);

    return DecoratedBox(
      key: const Key('pitstop_card'),
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: PlacesStyle.softShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: urgent
                ? PlacesStyle.urgentGradient
                : PlacesStyle.pitstopGradient,
            borderRadius: radius,
            border: Border.all(
              color: urgent ? PlacesStyle.vermilion300 : PlacesStyle.orange300,
            ),
          ),
          child: Stack(
            children: <Widget>[
              Positioned(
                top: -28,
                right: -28,
                width: 112,
                height: 112,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          accent.withValues(alpha: 0.16),
                          accent.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: _openList,
                child: Padding(
                  padding: const EdgeInsets.all(PlacesStyle.spaceMd),
                  child: Row(
                    children: <Widget>[
                      _leadingIcon(view, accent),
                      const SizedBox(width: PlacesStyle.spaceMd),
                      Expanded(child: _texts(view, labelColor, accent)),
                      const SizedBox(width: PlacesStyle.spaceSm),
                      _trailing(view, accent),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leadingIcon(PitstopView view, Color accent) {
    return Container(
      width: PlacesStyle.actionSize,
      height: PlacesStyle.actionSize,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
        border: Border.all(
          color: (view.urgent ? PlacesStyle.vermilion300 : PlacesStyle.orange200)
              .withValues(alpha: 0.9),
        ),
        boxShadow: PlacesStyle.hairShadow,
      ),
      child: Icon(view.icon, size: 26, color: accent),
    );
  }

  Widget _texts(PitstopView view, Color labelColor, Color accent) {
    final multiLine = view.place == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                view.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PlacesStyle.labelCaps.copyWith(color: labelColor),
              ),
            ),
            const SizedBox(width: 6),
            _PulseDot(
              animation: _pulse,
              color: accent,
              visible: view.pulse || view.urgent,
            ),
          ],
        ),
        Semantics(
          liveRegion: view.urgent,
          child: Text(
            view.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PlacesStyle.headlineSm.copyWith(color: PlacesStyle.ink),
          ),
        ),
        Text(
          view.subtitle,
          maxLines: multiLine ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate600),
        ),
      ],
    );
  }

  Widget _trailing(PitstopView view, Color accent) {
    if (view.busy) {
      return SizedBox(
        width: PlacesStyle.actionSize,
        height: PlacesStyle.actionSize,
        child: Center(
          child: widget.animate
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: accent,
                  ),
                )
              : Icon(Icons.hourglass_top_rounded, size: 22, color: accent),
        ),
      );
    }
    if (view.action == PitstopAction.none) return const SizedBox.shrink();

    return Semantics(
      button: true,
      label: view.actionLabel,
      excludeSemantics: true,
      child: Material(
        color: accent,
        elevation: 1.5,
        shadowColor: accent.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('pitstop_action'),
          onTap: () => _onAction(view),
          child: SizedBox(
            width: PlacesStyle.actionSize,
            height: PlacesStyle.actionSize,
            child: Icon(view.actionIcon, size: 24, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Titik kecil berkedip di samping label (desain: `animate-pulse`).
class _PulseDot extends StatelessWidget {
  const _PulseDot({
    required this.animation,
    required this.color,
    required this.visible,
  });

  final Animation<double> animation;
  final Color color;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: 6, height: 6);
    return FadeTransition(
      opacity: animation,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
