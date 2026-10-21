import 'dart:async';

import 'package:flutter/material.dart';

import '../data/places_api.dart';
import '../logic/geo_math.dart';
import '../logic/nearby_controller.dart';
import '../logic/place_launcher.dart';
import '../models/nearby_place.dart';
import '../models/place_category.dart';
import 'places_style.dart';

// ============================================================================
// DAFTAR "TEMPAT TERDEKAT" — lembar yang naik dari bawah.
//   chip kategori: Semua | Rest Area | Minimarket | Hotel/Motel | SPBU
//   tiap baris   : nama, jarak, di depan/belakang, buka/tutup, rating, alamat
//                  + tombol navigasi (Google Maps mode mobil)
//
// Dipakai dari:
//  * kartu Pitstop (ketuk kartu)            -> pakai controller yang sama dengan kartu
//  * tombol "Cari Rest Area" di beranda      -> tanpa controller: lembar membuat
//    sendiri, meminta izin lokasi, dan membersihkannya saat ditutup
// ============================================================================

/// Buka daftar tempat terdekat. [controller] `null` = lembar mengurus controller sendiri.
Future<void> showNearbyPlacesSheet(
  BuildContext context, {
  NearbyPlacesController? controller,
  PlaceCategory? initialCategory,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => NearbyPlacesSheet(
      controller: controller,
      initialCategory: initialCategory,
    ),
  );
}

class NearbyPlacesSheet extends StatefulWidget {
  const NearbyPlacesSheet({
    super.key,
    this.controller,
    this.initialCategory,
  });

  /// `null` = buat sendiri (dan dibuang saat lembar ditutup).
  final NearbyPlacesController? controller;

  /// Kategori awal; `null` = "Semua".
  final PlaceCategory? initialCategory;

  @override
  State<NearbyPlacesSheet> createState() => _NearbyPlacesSheetState();
}

class _NearbyPlacesSheetState extends State<NearbyPlacesSheet>
    with WidgetsBindingObserver {
  late final NearbyPlacesController _controller;
  late final bool _ownsController;
  PlaceCategory? _selected;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = widget.initialCategory;
    final given = widget.controller;
    _ownsController = given == null;
    _controller = given ?? NearbyPlacesController();
    // Jangan memicu notifyListeners() selagi pohon widget dibangun.
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  void _begin() {
    if (!mounted) return;
    if (!_controller.isActive) {
      unawaited(
        _controller.start(askPermission: true, track: true, autoRefresh: false),
      );
    }
    unawaited(_controller.loadCategory(_selected));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller.onAppResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (_ownsController) {
      controller.dispose();
    }
    // Jika controller dioper dari layar luar (seperti PitstopCard), jangan dimatikan
    // agar kartu di layar tetap terus melacak GPS dan menampilkan tempat terdekat.
    super.dispose();
  }

  // ------------------------------------------------------------------ aksi

  void _select(PlaceCategory? category) {
    if (_selected == category) return;
    setState(() {
      _selected = category;
      _notice = null;
    });
    unawaited(_controller.loadCategory(category));
  }

  void _refresh() {
    setState(() => _notice = null);
    unawaited(_controller.loadCategory(_selected, force: true));
  }



  Future<void> _navigate(NearbyPlace place) async {
    final opened = await _controller.navigateTo(place);
    if (!mounted) return;
    setState(() => _notice = opened ? null : _noMapsMessage);
  }

  Future<void> _openPlacePage(NearbyPlace place) async {
    final opened = await PlaceLauncher.openPlacePage(place);
    if (!mounted) return;
    setState(() => _notice = opened ? null : _noMapsMessage);
  }

  static const String _noMapsMessage =
      'Tidak bisa membuka Google Maps. Pasang aplikasi peta atau browser.';

  // ---------------------------------------------------------------- tampilan

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.82;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Material(
        color: PlacesStyle.pageBg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _GrabHandle(),
              _buildHeader(),
              const SizedBox(height: 12),
              _CategoryChips(selected: _selected, onSelected: _select),
              const SizedBox(height: 8),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _InfoBanner(
                    key: const Key('sheet_notice'),
                    icon: Icons.info_outline_rounded,
                    text: _notice!,
                    onClose: () => setState(() => _notice = null),
                  ),
                ),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final c = _controller;
    final String sub;
    if (c.fix != null) {
      sub = 'Diurutkan dari yang terdekat';
    } else if (c.status == NearbyStatus.locating) {
      sub = 'Mencari posisimu…';
    } else {
      sub = 'Rest area, minimarket, hotel/motel & SPBU';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
              border: Border.all(color: PlacesStyle.orange200),
              boxShadow: PlacesStyle.hairShadow,
            ),
            child: const Icon(
              Icons.near_me_rounded,
              size: 22,
              color: PlacesStyle.copper,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'TEMPAT TERDEKAT',
                  style: PlacesStyle.labelCaps
                      .copyWith(color: PlacesStyle.copperDark),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate600),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('sheet_refresh'),
            tooltip: 'Muat ulang',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded, color: PlacesStyle.slate600),
          ),

        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = _controller;
    switch (c.status) {
      case NearbyStatus.idle:
        return const _LoadingPanel(message: 'Menyiapkan pencarian…');
      case NearbyStatus.needPermission:
        return _MessagePanel(
          icon: Icons.my_location_rounded,
          title: 'Izinkan akses lokasi',
          message:
              'Driving Buddy butuh lokasimu untuk mencari rest area, minimarket, '
              'dan hotel di sekitar. Lokasi hanya dipakai saat mencari.',
          actions: <Widget>[
            _PanelButton(
              key: const Key('panel_permission'),
              label: 'Izinkan Lokasi',
              icon: Icons.location_on_rounded,
              primary: true,
              onPressed: c.requestPermission,
            ),
          ],
        );
      case NearbyStatus.permissionBlocked:
        return _MessagePanel(
          icon: Icons.location_disabled_rounded,
          title: 'Izin lokasi diblokir',
          message:
              'Buka Pengaturan aplikasi, pilih Izin > Lokasi, lalu izinkan. '
              'Setelah itu kembali ke sini.',
          actions: <Widget>[
            _PanelButton(
              key: const Key('panel_permission'),
              label: 'Buka Pengaturan',
              icon: Icons.settings_rounded,
              primary: true,
              onPressed: c.requestPermission,
            ),
          ],
        );
      case NearbyStatus.gpsOff:
        return _MessagePanel(
          icon: Icons.location_off_rounded,
          title: 'GPS belum menyala',
          message: 'Nyalakan layanan lokasi di HP, lalu kembali ke sini.',
          actions: <Widget>[
            _PanelButton(
              key: const Key('panel_permission'),
              label: 'Buka Pengaturan Lokasi',
              icon: Icons.settings_rounded,
              primary: true,
              onPressed: c.requestPermission,
            ),
          ],
        );
      case NearbyStatus.locating:
        return const _LoadingPanel(message: 'Mencari posisimu…');
      case NearbyStatus.loading:
      case NearbyStatus.ready:
      case NearbyStatus.empty:
      case NearbyStatus.error:
        return _buildCategoryBody(context);
    }
  }

  String get _selectedLabel => _selected?.label ?? 'tempat';

  Widget _buildCategoryBody(BuildContext context) {
    final c = _controller;
    final places = c.placesFor(_selected);
    final error = c.errorFor(_selected);
    final result = c.resultFor(_selected);
    final waiting = c.isLoading(_selected) || !c.hasRequested(_selected);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    if (places.isEmpty) {
      if (waiting) {
        return _LoadingPanel(message: 'Mencari $_selectedLabel terdekat…');
      }
      if (error != null) return _buildErrorPanel(error);
      return _MessagePanel(
        icon: Icons.search_off_rounded,
        title: 'Tidak ada $_selectedLabel di dekat sini',
        message: (result != null && result.degraded)
            ? 'Pencarian di server sempat gagal (${describeProviderErrors(result.errors)}). '
                'Coba lagi sebentar lagi.'
            : 'Coba kategori lain, atau cari lagi nanti.',
        actions: <Widget>[
          _PanelButton(
            key: const Key('panel_retry'),
            label: 'Cari lagi',
            icon: Icons.refresh_rounded,
            onPressed: _refresh,
          ),
        ],
      );
    }

    final banners = <Widget>[
      if (error != null)
        _InfoBanner(
          key: const Key('banner_stale'),
          icon: Icons.cloud_off_rounded,
          warning: true,
          text: 'Gagal memperbarui: ${error.message} Menampilkan data terakhir.',
        ),
      if (result != null && result.fallbackUsed)
        const _InfoBanner(
          key: Key('banner_fallback'),
          icon: Icons.layers_rounded,
          text: 'Sebagian hasil dari OpenStreetMap (cadangan). Data bisa kurang lengkap.',
        ),
      if (result != null)
        for (var i = 0; i < result.warnings.length; i++)
          _InfoBanner(
            key: Key('banner_warning_$i'),
            icon: Icons.info_outline_rounded,
            warning: true,
            text: result.warnings[i],
          ),
      if (result != null && result.degraded)
        _InfoBanner(
          key: const Key('banner_degraded'),
          icon: Icons.warning_amber_rounded,
          warning: true,
          text: 'Sebagian pencarian di server gagal '
              '(${describeProviderErrors(result.errors)}). Hasil mungkin tidak lengkap.',
        ),
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + bottomInset),
      children: <Widget>[
        for (final banner in banners)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: banner),
        for (final place in places)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PlaceTile(
              key: Key('tile_${place.id}'),
              place: place,
              onNavigate: () => _navigate(place),
              onOpen: () => _openPlacePage(place),
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Jarak berupa garis lurus, bukan jarak tempuh. '
          'Di jalan tol, pastikan tempatnya ada di jalurmu.',
          textAlign: TextAlign.center,
          style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate500),
        ),
      ],
    );
  }

  Widget _buildErrorPanel(PlacesApiException error) {
    final IconData icon;
    final String title;
        switch (error.kind) {
      case PlacesApiErrorKind.unreachable:
        icon = Icons.wifi_off_rounded;
        title = 'Server tidak terjangkau';
              case PlacesApiErrorKind.timeout:
        icon = Icons.hourglass_bottom_rounded;
        title = 'Server lambat menjawab';
              case PlacesApiErrorKind.notConfigured:
        icon = Icons.build_circle_rounded;
        title = 'Fitur belum aktif di server';
              case PlacesApiErrorKind.rateLimited:
        icon = Icons.speed_rounded;
        title = 'Terlalu sering mencari';
              case PlacesApiErrorKind.invalidRequest:
        icon = Icons.location_off_rounded;
        title = 'Lokasi ditolak server';
              case PlacesApiErrorKind.server:
        icon = Icons.cloud_off_rounded;
        title = 'Server bermasalah';
              case PlacesApiErrorKind.badResponse:
        icon = Icons.report_problem_rounded;
        title = 'Jawaban server tidak dikenali';
            }
    return _MessagePanel(
      icon: icon,
      title: title,
      message: error.message,
      actions: <Widget>[
        _PanelButton(
          key: const Key('panel_retry'),
          label: 'Coba lagi',
          icon: Icons.refresh_rounded,
          primary: true,
          onPressed: _refresh,
        ),

      ],
    );
  }
}

/// Kode kegagalan dari server (`errors` di jawaban) -> kalimat singkat.
/// Dibuka ke publik supaya bisa dites.
String describeProviderErrors(Map<String, String> errors) {
  if (errors.isEmpty) return 'penyebab tidak diketahui';
  final reasons = <String>{};
  for (final code in errors.values) {
    reasons.add(describeProviderError(code));
  }
  return reasons.join(', ');
}

String describeProviderError(String code) {
  switch (code) {
    case 'timeout':
      return 'penyedia peta lambat menjawab';
    case 'network':
      return 'penyedia peta tidak terjangkau dari server';
    case 'rate_limited':
      return 'terlalu banyak permintaan ke penyedia peta';
    case 'auth':
      return 'API key ditolak, cek konfigurasi server';
    case 'bad_request':
      return 'permintaan ditolak penyedia peta';
    case 'upstream':
      return 'penyedia peta sedang bermasalah';
    case 'bad_response':
      return 'jawaban penyedia peta tidak dikenali';
    case 'budget_exhausted':
      return 'jatah pencarian harian atau bulanan habis';
    default:
      return 'kode: $code';
  }
}

// ---------------------------------------------------------------------------
// Bagian-bagian kecil
// ---------------------------------------------------------------------------

class _GrabHandle extends StatelessWidget {
  const _GrabHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: PlacesStyle.slate300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});

  final PlaceCategory? selected;
  final ValueChanged<PlaceCategory?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          _CategoryChip(
            key: const Key('chip_all'),
            label: 'Semua',
            icon: Icons.apps_rounded,
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final category in PlaceCategory.values)
            _CategoryChip(
              key: Key('chip_${category.apiValue}'),
              label: category.label,
              icon: category.icon,
              selected: selected == category,
              onTap: () => onSelected(category),
            ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : PlacesStyle.slate700;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: selected ? PlacesStyle.copper : Colors.white,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? PlacesStyle.copper : PlacesStyle.orange200,
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: PlacesStyle.chip.copyWith(color: foreground),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    super.key,
    required this.place,
    required this.onNavigate,
    required this.onOpen,
  });

  final NearbyPlace place;
  final VoidCallback onNavigate;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
        side: const BorderSide(color: PlacesStyle.orange100),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: PlacesStyle.orange50,
                  borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
                  border: Border.all(color: PlacesStyle.orange200),
                ),
                child: Icon(
                  place.category?.icon ?? Icons.place_rounded,
                  size: 22,
                  color: PlacesStyle.copper,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _details()),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: 'Arahkan ke ${place.name}',
                excludeSemantics: true,
                child: Material(
                  color: PlacesStyle.copper,
                  borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: Key('tile_nav_${place.id}'),
                    onTap: onNavigate,
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.navigation_rounded,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details() {
    final ahead = place.ahead;
    final rating = place.rating;
    final address = place.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          place.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: PlacesStyle.bodyMd.copyWith(
            fontWeight: FontWeight.w700,
            color: PlacesStyle.ink,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              place.distanceText,
              style: PlacesStyle.bodyMd.copyWith(
                fontWeight: FontWeight.w800,
                color: PlacesStyle.copperDark,
              ),
            ),
            if (ahead == true)
              const _Pill(
                text: 'DI DEPAN',
                icon: Icons.arrow_upward_rounded,
                color: PlacesStyle.emerald,
                background: PlacesStyle.emerald50,
              )
            else if (ahead == false)
              const _Pill(
                text: 'DI BELAKANG',
                icon: Icons.arrow_downward_rounded,
                color: PlacesStyle.slate600,
                background: PlacesStyle.slate100,
              )
            else
              _Pill(
                text: 'ARAH ${compassLabelId(place.bearingDeg).toUpperCase()}',
                icon: Icons.explore_rounded,
                color: PlacesStyle.slate600,
                background: PlacesStyle.slate100,
              ),
            if (place.openNow == true)
              const _Pill(
                text: 'BUKA',
                color: PlacesStyle.emerald,
                background: PlacesStyle.emerald50,
              )
            else if (place.openNow == false)
              const _Pill(
                text: 'TUTUP',
                color: PlacesStyle.vermilionDark,
                background: PlacesStyle.vermilion50,
              ),
            if (rating != null)
              _Pill(
                text: rating.toStringAsFixed(1).replaceAll('.', ','),
                icon: Icons.star_rounded,
                color: const Color(0xFF9A6A0B),
                background: const Color(0xFFFFF6DC),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          address.isEmpty ? place.categoryText : '${place.categoryText} • $address',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate500),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.color,
    required this.background,
    this.icon,
  });

  final String text;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final iconData = icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (iconData != null) ...<Widget>[
            Icon(iconData, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: PlacesStyle.labelCaps.copyWith(
              fontSize: 10,
              letterSpacing: 0.4,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    super.key,
    required this.icon,
    required this.text,
    this.warning = false,
    this.onClose,
  });

  final IconData icon;
  final String text;
  final bool warning;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tone = warning ? PlacesStyle.vermilionDark : PlacesStyle.copperDark;
    final background = warning ? PlacesStyle.vermilion50 : PlacesStyle.orange50;
    final border = warning ? PlacesStyle.vermilion300 : PlacesStyle.orange200;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PlacesStyle.radiusLg),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: tone),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate700),
            ),
          ),
          if (onClose != null)
            InkWell(
              onTap: onClose,
              customBorder: const CircleBorder(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.close_rounded, size: 16, color: PlacesStyle.slate500),
              ),
            ),
        ],
      ),
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: PlacesStyle.copper,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: PlacesStyle.bodyMd.copyWith(color: PlacesStyle.slate600),
          ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: PlacesStyle.orange50,
                shape: BoxShape.circle,
                border: Border.all(color: PlacesStyle.orange200),
              ),
              child: Icon(icon, size: 30, color: PlacesStyle.copper),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: PlacesStyle.headlineSm.copyWith(
                fontSize: 18,
                color: PlacesStyle.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: PlacesStyle.bodyMd.copyWith(color: PlacesStyle.slate600),
            ),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PlacesStyle.radiusXl),
    );
    if (primary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: PlacesStyle.copper,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 44),
          shape: shape,
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: PlacesStyle.copperDark,
        side: const BorderSide(color: PlacesStyle.orange300),
        minimumSize: const Size(0, 44),
        shape: shape,
      ),
    );
  }
}
