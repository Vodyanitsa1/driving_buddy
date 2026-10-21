import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/location_provider.dart';
import '../data/places_api.dart';
import '../data/direct_osm_places_api.dart';
import '../models/nearby_place.dart';
import '../models/place_category.dart';
import 'geo_math.dart';
import 'place_launcher.dart';

// ============================================================================
// NEARBY PLACES CONTROLLER — otak fitur "tempat terdekat".
//
// Tugasnya:
//  * minta izin lokasi & mengikuti posisi pengemudi selama sesi berkendara
//  * memanggil server SESEDIKIT mungkin (hemat kuota Google): daftar tempat
//    diambil sekali lalu jaraknya dihitung ulang di HP setiap GPS bergerak
//  * menentukan SATU rekomendasi pitstop ([best]) untuk kartu di layar
//  * mode darurat saat alarm kantuk bunyi: cari tempat berhenti terdekat, apa pun jenisnya
//
// Aturan emas: fitur ini TIDAK PERNAH boleh mengganggu deteksi kantuk.
// Semua error ditangkap di sini dan berubah jadi state yang bisa ditampilkan.
// ============================================================================

/// Keadaan yang ditampilkan kartu Pitstop.
enum NearbyStatus {
  /// Belum dimulai (sesi belum jalan).
  idle,

  /// Izin lokasi belum diberikan (masih boleh diminta).
  needPermission,

  /// Izin lokasi ditolak permanen: harus lewat Pengaturan aplikasi.
  permissionBlocked,

  /// GPS di HP mati.
  gpsOff,

  /// Menunggu pembacaan posisi pertama.
  locating,

  /// Menunggu jawaban server (belum ada hasil sama sekali).
  loading,

  /// Ada rekomendasi.
  ready,

  /// Server menjawab, tapi tidak ada tempat di sekitar.
  empty,

  /// Gagal dan belum ada data lama untuk ditampilkan.
  error,
}

/// Semua angka kebijakan ada di sini supaya gampang dituning.
class NearbyPolicy {
  const NearbyPolicy({
    this.limit = 6,
    this.autoRefreshEvery = const Duration(minutes: 10),
    this.autoRefreshAfterMovingM = 10000,
    this.freshFor = const Duration(minutes: 3),
    this.freshWithinM = 2000,
    this.minGapBetweenRequests = const Duration(seconds: 20),
    this.retryAfterFailure = const Duration(minutes: 1),
    this.retryAfterConfigProblem = const Duration(minutes: 5),
    this.retryWhenNothingAhead = const Duration(minutes: 2),
    this.fixTimeout = const Duration(seconds: 12),
    this.urgentFixTimeout = const Duration(seconds: 8),
    this.notifyEvery = const Duration(seconds: 1),
    this.recheckAccessEvery = const Duration(seconds: 20),
  });

  /// Maksimal tempat PER kategori yang diminta ke server.
  final int limit;

  /// Ambil ulang daftar rest area otomatis tiap sekian lama...
  final Duration autoRefreshEvery;

  /// ...atau setelah pindah sejauh ini (meter) dari titik pengambilan terakhir.
  final double autoRefreshAfterMovingM;

  /// Hasil dianggap masih segar (untuk buka tab di daftar) selama ini...
  final Duration freshFor;

  /// ...dan selama posisi belum bergeser lebih jauh dari ini (meter).
  final double freshWithinM;

  /// Jarak minimal antar permintaan ke kategori yang sama (kecuali dipaksa).
  final Duration minGapBetweenRequests;

  /// Tunggu segini lama sebelum mencoba lagi setelah gagal karena jaringan/server.
  final Duration retryAfterFailure;

  /// Idem, tapi untuk salah konfigurasi (404/503/422) — tidak perlu sering.
  final Duration retryAfterConfigProblem;

  /// Semua rest area di daftar sudah terlewat: ambil ulang setelah selang ini.
  final Duration retryWhenNothingAhead;

  /// Batas tunggu pembacaan posisi pertama.
  final Duration fixTimeout;

  /// Batas tunggu pembacaan posisi saat mode darurat.
  final Duration urgentFixTimeout;

  /// Pembaruan tampilan dibatasi sekali per selang ini (GPS bisa datang tiap detik).
  final Duration notifyEvery;

  /// Selama izin/GPS belum beres, cek ulang diam-diam tiap selang ini.
  final Duration recheckAccessEvery;
}

/// Data satu kategori (null = semua kategori).
class _Slot {
  NearbyResult? result;
  List<NearbyPlace> places = const <NearbyPlace>[];
  PlacesApiException? error;
  bool loading = false;
  DateTime? fetchedAt;
  DateTime? attemptedAt;
  GeoPoint? fetchedAtPoint;
  Future<void>? inflight;
}

class NearbyPlacesController extends ChangeNotifier {
  NearbyPlacesController({
    PlacesApi? api,
    LocationProvider? location,
    NearbyPolicy policy = const NearbyPolicy(),
    DateTime Function()? clock,
  })  : _api = api ?? DirectOsmPlacesApi(),
        _ownsApi = api == null,
        _location = location ?? createDefaultLocationProvider(),
        _policy = policy,
        _now = clock ?? DateTime.now;

  final PlacesApi _api;
  final bool _ownsApi;
  final LocationProvider _location;
  final NearbyPolicy _policy;
  final DateTime Function() _now;

  final Map<PlaceCategory?, _Slot> _slots = <PlaceCategory?, _Slot>{};
  final Set<PlaceCategory?> _pendingLoads = <PlaceCategory?>{};

  NearbyStatus _status = NearbyStatus.idle;
  LocationAccess _access = LocationAccess.denied;
  DriverFix? _fix;
  StreamSubscription<DriverFix>? _fixSub;
  Timer? _recheckTimer;
  bool _active = false;
  bool _track = true;
  bool _autoRefresh = true;
  bool _urgent = false;
  bool _disposed = false;

  /// Naik setiap start/stop/dispose; alur async lama yang masih jalan berhenti sendiri.
  int _generation = 0;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // ------------------------------------------------------------------ state

  NearbyStatus get status => _status;

  /// Sesi pencarian sedang berjalan (sudah [start], belum [stop]).
  bool get isActive => _active;

  /// Mode darurat (alarm kantuk): rekomendasi = tempat berhenti terdekat apa pun jenisnya.
  bool get urgent => _urgent;

  /// Posisi terakhir yang diketahui.
  DriverFix? get fix => _fix;

  LocationAccess get access => _access;

  /// Rekomendasi pitstop utama (untuk kartu). `null` kalau belum ada.
  NearbyPlace? get best {
    final all = placesFor(null);
    final rest = placesFor(PlaceCategory.restArea);
    return _pick(all, rest);
  }

  /// Kegagalan terakhir yang relevan untuk kartu (kategori utama dulu).
  PlacesApiException? get lastError =>
      _slots[null]?.error ?? _slots[PlaceCategory.restArea]?.error;

  /// Ada rekomendasi, tapi pembaruan terakhir gagal (data bisa sudah lama).
  bool get isStale => best != null && lastError != null;

  /// Ada permintaan ke server yang sedang berjalan.
  bool get isBusy => _slots.values.any((s) => s.loading);

  /// Pesan singkat untuk snackbar / teks status.
  String get statusMessage {
    return switch (_status) {
      NearbyStatus.idle => 'Pencarian tempat terdekat belum dimulai.',
      NearbyStatus.needPermission => 'Izin lokasi belum diberikan.',
      NearbyStatus.permissionBlocked =>
        'Izin lokasi diblokir. Aktifkan lewat Pengaturan aplikasi.',
      NearbyStatus.gpsOff => 'GPS belum menyala. Nyalakan lokasi di HP.',
      NearbyStatus.locating => 'Mencari posisimu…',
      NearbyStatus.loading => 'Mencari tempat terdekat…',
      NearbyStatus.ready => '',
      NearbyStatus.empty => 'Belum ada rest area atau tempat lain di dekat sini.',
      NearbyStatus.error =>
        lastError?.message ?? 'Gagal memuat tempat terdekat.',
    };
  }

  // ----- akses per kategori (dipakai daftar "Tempat Terdekat"); null = semua -----

  List<NearbyPlace> placesFor(PlaceCategory? category) {
    final explicit = _slots[category]?.places;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (category != null) {
      final all = _slots[null]?.places;
      if (all != null && all.isNotEmpty) {
        final matched = all.where((p) => p.category == category).toList();
        if (matched.isNotEmpty) return matched;
      }
    } else {
      final combined = <NearbyPlace>[];
      for (final slot in _slots.values) {
        combined.addAll(slot.places);
      }
      if (combined.isNotEmpty) {
        return _rank(combined.toSet().toList());
      }
    }
    return explicit ?? const <NearbyPlace>[];
  }

  bool isLoading(PlaceCategory? category) {
    if (category != null && placesFor(category).isNotEmpty) return false;
    return _slots[category]?.loading ?? false;
  }

  PlacesApiException? errorFor(PlaceCategory? category) =>
      _slots[category]?.error;

  NearbyResult? resultFor(PlaceCategory? category) => _slots[category]?.result;

  /// Sudah pernah diminta ke server (berhasil atau gagal)?
  bool hasRequested(PlaceCategory? category) {
    if (_slots[category]?.attemptedAt != null) return true;
    if (category != null && placesFor(category).isNotEmpty) return true;
    return false;
  }

  // ------------------------------------------------------------- lifecycle

  /// Mulai sesi. Aman dipanggil tanpa `await`: semua error ditangkap di dalam.
  ///
  /// * [askPermission] true = langsung munculkan dialog izin kalau belum diberikan.
  ///   (Di layar pemantauan sebaiknya false: pengguna menekan tombol "Izinkan Lokasi" di kartu.)
  /// * [track] true = ikuti posisi terus-menerus (sesi berkendara); false = cukup satu kali (daftar).
  /// * [autoRefresh] true = ambil/ perbarui rekomendasi pitstop otomatis.
  Future<void> start({
    bool askPermission = false,
    bool track = true,
    bool autoRefresh = true,
  }) async {
    if (_disposed) return;
    final gen = ++_generation;
    _active = true;
    _track = track;
    _autoRefresh = autoRefresh;
    _recompute();
    _notify(force: true);
    await _checkAccess(ask: askPermission, gen: gen);
  }

  /// Hentikan sesi (pelacakan GPS dimatikan). Hasil lama tetap disimpan.
  void stop() {
    if (_disposed) return;
    _generation++;
    _active = false;
    _urgent = false;
    _fix = null;
    _pendingLoads.clear();
    _fixSub?.cancel();
    _fixSub = null;
    _recheckTimer?.cancel();
    _recheckTimer = null;
    _recompute();
    _notify(force: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _fixSub?.cancel();
    _fixSub = null;
    _recheckTimer?.cancel();
    _recheckTimer = null;
    if (_ownsApi) _api.close();
    super.dispose();
  }

  /// Dipanggil saat aplikasi kembali ke layar (mis. setelah pengguna ke Pengaturan).
  void onAppResumed() {
    if (_disposed || !_active) return;
    if (_access != LocationAccess.granted) {
      unawaited(_checkAccess(ask: false, gen: _generation));
    }
  }

  /// Tombol "Izinkan Lokasi" / "Buka Pengaturan" / "Nyalakan GPS" di kartu.
  Future<void> requestPermission() async {
    if (_disposed) return;
    if (!_active) {
      await start(askPermission: true);
      return;
    }
    if (_access == LocationAccess.serviceDisabled) {
      await _ignoreErrors(_location.openLocationSettings);
      return;
    }
    if (_access == LocationAccess.deniedForever) {
      await _ignoreErrors(_location.openAppSettings);
      return;
    }
    await _checkAccess(ask: true, gen: _generation);
  }

  Future<void> _ignoreErrors(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  Future<void> _checkAccess({required bool ask, required int gen}) async {
    LocationAccess access;
    try {
      access =
          ask ? await _location.requestAccess() : await _location.checkAccess();
    } catch (_) {
      access = LocationAccess.denied;
    }
    if (_disposed || gen != _generation) return;
    _access = access;

    _recheckTimer?.cancel();
    _recheckTimer = null;
    if (access != LocationAccess.granted) {
      _recompute();
      _notify(force: true);
      // Izin/GPS belum beres: cek ulang pelan-pelan (mis. pengguna menyalakan GPS dari panel notifikasi).
      _recheckTimer = Timer(_policy.recheckAccessEvery, () {
        if (_disposed || gen != _generation) return;
        unawaited(_checkAccess(ask: false, gen: gen));
      });
      return;
    }
    await _beginLocating(gen);
  }

  Future<void> _beginLocating(int gen) async {
    _recompute();
    _notify(force: true);

    if (_track && _fixSub == null) {
      _fixSub = _location.fixes().listen(
            _onFix,
            onError: (Object error) => _onFixError(gen),
            cancelOnError: false,
          );
    }

    final first = await _location.currentFix(timeout: _policy.fixTimeout);
    if (_disposed || gen != _generation) return;
    if (first != null) _onFix(first);
  }

  void _onFixError(int gen) {
    if (_disposed || gen != _generation) return;
    // GPS dimatikan / izin dicabut di tengah jalan: berhenti mendengarkan, lalu cek keadaan sekarang.
    _fixSub?.cancel();
    _fixSub = null;
    unawaited(_checkAccess(ask: false, gen: gen));
  }

  // -------------------------------------------------------------- posisi

  void _onFix(DriverFix fix) {
    if (_disposed || !_active || !fix.isValid) return;
    final previous = _fix;
    if (previous != null && fix.timestamp.isBefore(previous.timestamp)) return;
    _fix = fix;
    _relocateSlots(fix);

    final firstFix = previous == null;
    if (firstFix && _pendingLoads.isNotEmpty) {
      final wanted = _pendingLoads.toList();
      _pendingLoads.clear();
      for (final category in wanted) {
        unawaited(loadCategory(category));
      }
    }
    if (_autoRefresh) _maybeAutoRefresh();

    _recompute();
    _notify(force: firstFix);
  }

  /// Hitung ulang jarak/arah semua tempat dari posisi baru (tanpa panggilan ke server).
  void _relocateSlots(DriverFix fix) {
    final heading = fix.trustedHeadingDeg;
    for (final slot in _slots.values) {
      if (slot.places.isEmpty) continue;
      slot.places = _rank(<NearbyPlace>[
        for (final p in slot.places)
          p.relativeTo(fix.lat, fix.lng, headingDeg: heading),
      ]);
    }
  }

  // ---------------------------------------------------------- pengambilan

  _Slot _slot(PlaceCategory? category) =>
      _slots.putIfAbsent(category, () => _Slot());

  /// Ambil/perbarui rekomendasi pitstop: ambil tempat terdekat dari SEMUA
  /// kategori (rest area, SPBU, minimarket, hotel) sehingga kartu menampilkan
  /// rekomendasi tempat yang benar-benar terdekat.
  Future<void> refreshPitstop({bool force = false}) async {
    await _fetch(null, force: force);
  }

  /// Muat satu kategori untuk daftar (null = semua). Dilewati kalau datanya masih segar.
  Future<void> loadCategory(PlaceCategory? category, {bool force = false}) async {
    if (_disposed) return;
    if (_fix == null) {
      // Posisi belum ada: kerjakan begitu posisi pertama masuk.
      _pendingLoads.add(category);
      return;
    }
    if (!force && category != null) {
      final slot = _slot(category);
      if (slot.places.isNotEmpty && _isFresh(slot)) return;
      final allSlot = _slot(null);
      if (_isFresh(allSlot)) {
        final matched = allSlot.places.where((p) => p.category == category).toList();
        if (matched.isNotEmpty) {
          slot.fetchedAt = allSlot.fetchedAt;
          slot.fetchedAtPoint = allSlot.fetchedAtPoint;
          slot.result = allSlot.result;
          slot.places = matched;
          return;
        }
      }
    }
    if (!force && _isFresh(_slot(category))) return;
    await _fetch(category, force: force);
  }

  bool _isFresh(_Slot slot) {
    final fetched = slot.fetchedAt;
    final fix = _fix;
    if (fetched == null || fix == null || slot.error != null) return false;
    if (_now().difference(fetched) >= _policy.freshFor) return false;
    final origin = slot.fetchedAtPoint;
    if (origin == null) return false;
    return haversineM(origin.lat, origin.lng, fix.lat, fix.lng) <
        _policy.freshWithinM;
  }

  void _maybeAutoRefresh() {
    final slot = _slot(null);
    if (slot.inflight != null || _fix == null) return;
    if (_isDueForRefresh(slot)) unawaited(refreshPitstop());
  }

  bool _isDueForRefresh(_Slot slot) {
    final attempted = slot.attemptedAt;
    if (attempted == null) return true;
    final now = _now();
    final sinceAttempt = now.difference(attempted);

    final error = slot.error;
    if (error != null) {
      var wait = error.isTransient
          ? _policy.retryAfterFailure
          : _policy.retryAfterConfigProblem;
      final retryAfter = error.retryAfter;
      if (retryAfter != null && retryAfter > wait) wait = retryAfter;
      return sinceAttempt >= wait;
    }

    final fetched = slot.fetchedAt;
    if (fetched == null) return true;
    if (now.difference(fetched) >= _policy.autoRefreshEvery) return true;

    final origin = slot.fetchedAtPoint;
    final fix = _fix;
    if (origin != null &&
        fix != null &&
        haversineM(origin.lat, origin.lng, fix.lat, fix.lng) >=
            _policy.autoRefreshAfterMovingM) {
      return true;
    }
    // Ada daftar, tapi semuanya sudah terlewat (di belakang).
    if (slot.places.isNotEmpty &&
        !slot.places.any((p) => p.ahead != false) &&
        sinceAttempt >= _policy.retryWhenNothingAhead) {
      return true;
    }
    return false;
  }

  Future<void> _fetch(PlaceCategory? category, {required bool force}) {
    final slot = _slot(category);
    final running = slot.inflight;
    if (running != null) return running;
    final fix = _fix;
    if (fix == null || _disposed) return Future<void>.value();
    final attempted = slot.attemptedAt;
    if (!force &&
        attempted != null &&
        _now().difference(attempted) < _policy.minGapBetweenRequests) {
      return Future<void>.value();
    }
    // `inflight` dibersihkan SETELAH future-nya dipasang (whenComplete selalu jalan
    // belakangan), jadi tidak ada risiko tertinggal "sedang berjalan" selamanya.
    final future = _runFetch(slot, category, fix).whenComplete(() {
      slot.inflight = null;
    });
    slot.inflight = future;
    return future;
  }

  Future<void> _runFetch(_Slot slot, PlaceCategory? category, DriverFix fix) async {
    slot.loading = true;
    slot.attemptedAt = _now();
    _recompute();
    _notify(force: true);
    try {
      final heading = fix.trustedHeadingDeg;
      final fetchLimit = category == null ? 25 : _policy.limit;
      final result = await _api.nearby(
        lat: fix.lat,
        lng: fix.lng,
        category: category,
        limit: fetchLimit,
        headingDeg: heading,
        speedMps: fix.speedMps,
        accuracyM: fix.accuracyM,
        preferAhead: heading != null,
      );
      if (_disposed) return;
      // Posisi bisa sudah bergeser selama menunggu jawaban: hitung dari posisi terbaru.
      final current = _fix ?? fix;
      slot.result = result;
      slot.error = null;
      slot.fetchedAt = _now();
      slot.fetchedAtPoint = GeoPoint(fix.lat, fix.lng);
      slot.places = _rank(<NearbyPlace>[
        for (final p in result.places)
          p.relativeTo(current.lat, current.lng,
              headingDeg: current.trustedHeadingDeg),
      ]);

      // Jika kategori 'Semua', otomatis isi slot kategori per jenis tempat agar saat tab ditekan langsung muncul tanpa loading
      if (category == null) {
        for (final cat in PlaceCategory.values) {
          final catPlaces = result.places.where((p) => p.category == cat).toList();
          if (catPlaces.isNotEmpty) {
            final catSlot = _slot(cat);
            if (catSlot.places.isEmpty) {
              catSlot.fetchedAt = slot.fetchedAt;
              catSlot.fetchedAtPoint = slot.fetchedAtPoint;
              catSlot.result = slot.result;
              catSlot.places = _rank(<NearbyPlace>[
                for (final p in catPlaces)
                  p.relativeTo(current.lat, current.lng,
                      headingDeg: current.trustedHeadingDeg),
              ]);
            }
          }
        }
      }
    } on PlacesApiException catch (e) {
      if (_disposed) return;
      slot.error = e; // data lama (kalau ada) tetap ditampilkan
    } catch (e) {
      if (_disposed) return;
      slot.error = PlacesApiException(
        PlacesApiErrorKind.badResponse,
        'Terjadi kesalahan tak terduga: $e',
      );
    } finally {
      slot.loading = false;
    }
    if (_disposed) return;
    _recompute();
    _notify(force: true);
  }

  // ------------------------------------------------------- mode darurat

  /// Alarm kantuk bunyi: ambil tempat berhenti terdekat (semua kategori) SEKARANG,
  /// dan ubah kartu jadi mode darurat. Mengembalikan rekomendasinya (atau null).
  Future<NearbyPlace?> requestUrgent() async {
    if (_disposed) return null;
    _urgent = true;
    _recompute();
    _notify(force: true);
    if (!_active) return best;

    if (_fix == null && _access == LocationAccess.granted) {
      final fix = await _location.currentFix(timeout: _policy.urgentFixTimeout);
      if (_disposed) return null;
      if (fix != null) _onFix(fix);
    }
    if (_fix != null) {
      await _fetch(null, force: true);
    }
    return _disposed ? null : best;
  }

  /// Alarm sudah ditutup: kembali ke mode normal.
  void clearUrgent() {
    if (_disposed || !_urgent) return;
    _urgent = false;
    _recompute();
    _notify(force: true);
  }

  // ------------------------------------------------------------ navigasi

  /// Buka Google Maps ke rekomendasi utama. Kalau belum ada, cari dulu.
  /// `false` kalau tidak ada tempat / tidak ada aplikasi yang bisa membuka peta.
  Future<bool> navigateToBest({UrlOpener? opener}) async {
    var target = best;
    if (target == null) {
      final wasUrgent = _urgent;
      target = await requestUrgent();
      if (!wasUrgent) clearUrgent();
    }
    if (target == null) return false;
    return PlaceLauncher.navigate(target, opener: opener);
  }

  Future<bool> navigateTo(NearbyPlace place, {UrlOpener? opener}) {
    return PlaceLauncher.navigate(place, opener: opener);
  }

  // ------------------------------------------------------------- internal

  /// Tempat terbaik: yang di depan (atau arahnya belum diketahui) dulu, lalu yang di belakang.
  static NearbyPlace? _pick(List<NearbyPlace> primary, List<NearbyPlace> fallback) {
    for (final p in primary) {
      if (p.ahead != false) return p;
    }
    for (final p in fallback) {
      if (p.ahead != false) return p;
    }
    if (primary.isNotEmpty) return primary.first;
    if (fallback.isNotEmpty) return fallback.first;
    return null;
  }

  /// Urutan tampil: di depan/belum diketahui dulu, lalu yang di belakang; tiap kelompok dari yang terdekat.
  static List<NearbyPlace> _rank(List<NearbyPlace> places) {
    final sorted = List<NearbyPlace>.of(places);
    sorted.sort((a, b) {
      final groupA = a.ahead == false ? 1 : 0;
      final groupB = b.ahead == false ? 1 : 0;
      if (groupA != groupB) return groupA - groupB;
      final byDistance = a.distanceM.compareTo(b.distanceM);
      if (byDistance != 0) return byDistance;
      return a.id.compareTo(b.id);
    });
    return List<NearbyPlace>.unmodifiable(sorted);
  }

  /// Turunkan [_status] dari keadaan sekarang.
  void _recompute() {
    if (!_active) {
      _status = NearbyStatus.idle;
      return;
    }
    switch (_access) {
      case LocationAccess.deniedForever:
        _status = NearbyStatus.permissionBlocked;
        return;
      case LocationAccess.denied:
        _status = NearbyStatus.needPermission;
        return;
      case LocationAccess.serviceDisabled:
        _status = NearbyStatus.gpsOff;
        return;
      case LocationAccess.granted:
        break;
    }
    if (_fix == null) {
      _status = NearbyStatus.locating;
      return;
    }
    if (best != null) {
      _status = NearbyStatus.ready;
      return;
    }
    final all = _slots[null];
    final rest = _slots[PlaceCategory.restArea];
    final primary = all ?? rest;
    if (primary == null ||
        primary.attemptedAt == null ||
        primary.loading ||
        (all?.loading ?? false)) {
      _status = NearbyStatus.loading;
    } else if (primary.error != null && primary.result == null) {
      _status = NearbyStatus.error;
    } else {
      _status = NearbyStatus.empty;
    }
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    final now = _now();
    if (!force && now.difference(_lastNotify) < _policy.notifyEvery) return;
    _lastNotify = now;
    notifyListeners();
  }
}
