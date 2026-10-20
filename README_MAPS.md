# Tempat Terdekat (Maps API) - Driving Buddy

Kartu Trello: **[BE] Integrasi Maps API**.
Menambah `POST /places/nearby` ke `server.py`: dari posisi pengemudi, cari **rest area, minimarket, hotel/motel** terdekat
(plus SPBU sebagai bonus), urut dari yang paling dekat, lengkap dengan jarak, arah, dan link buka navigasi Google Maps.

Prinsip: **alarm kantuk tidak boleh bergantung ke fitur ini.** Kalau Google/OSM error, jatah habis, atau konfigurasi salah,
endpoint tetap menjawab dengan jelas (HTTP 200 + `degraded: true`, atau 503 kalau memang belum dikonfigurasi) dan `server.py`
tetap nyala, `/ws` jalan normal. Kalau modulnya gagal dimuat, `server.py` cuma mencetak `[WARN]`.

## Isi paket

```
maps_nearby_integration/
  salin_ke_repo/                    disalin ke root repo (cp -R; hanya menambah file/folder baru)
    nearby_places/                  backend: modul FastAPI untuk server.py
    tests_places/                   tes backend (offline)
    lib/features/nearby_places/     Flutter: controller, kartu pitstop, daftar tempat, klien API
    requirements-maps.txt  README_MAPS.md
  patch/integrasi_maps_backend.patch   server.py (+ .gitignore)
  patch/integrasi_maps_flutter.patch   monitor_screen.dart, home_screen.dart, AndroidManifest.xml, Info.plist
```

Urutan kerja: **backend dulu** (bisa dites pakai `curl`), baru Flutter.

## Provider data (pilih lewat `.env`)

| `PLACES_PROVIDER` | Data | Butuh | Cocok untuk |
|---|---|---|---|
| `mock` | tempat palsu, namanya diakhiri "(contoh)" | tidak butuh apa-apa | ngerjain UI tanpa internet. **Ini bawaan kalau `.env` kosong.** |
| `osm` | OpenStreetMap (server Overpass publik) | tanpa key, tanpa kartu | demo dan development. Fair use ketat (sekitar 100 query/hari), bukan untuk rilis. |
| `snapshot` | salinan OpenStreetMap di file (offline) | file `places_snapshot.json` (lihat "Data offline") | demo saat server Overpass publik penuh. Instan, tanpa internet, tapi datanya tidak live. |
| `google` | Google Places API (New) | API key + billing aktif | data paling lengkap. Ini yang dimaksud kartu "Maps API". |

`PLACES_FALLBACK_PROVIDER=osm` = kalau Google gagal atau jatahnya habis, otomatis coba OpenStreetMap.
`PLACES_FALLBACK_PROVIDER=snapshot` = cadangan dari data offline.

**Saran urutan kerja:** pasang dulu pakai `osm` (data asli, tanpa key) buat memastikan semuanya jalan, baru pindah ke `google`
kalau key-nya sudah jadi.

## Pasang backend

Jalankan di folder repo `driving_buddy` (yang ada `server.py`-nya). Patch dibuat dari versi terbaru di GitHub
(commit `384fec3`), jadi `git pull` dulu.

1. Salin isi paket ke repo (folder `nearby_places/`, `tests_places/`, `requirements-maps.txt`, `README_MAPS.md`):
   ```
   cp -R ~/Downloads/maps_nearby_integration/salin_ke_repo/. .
   ```
2. Pasang patch ke `server.py` dan `.gitignore` (sekitar 12 baris tambahan):
   ```
   git apply ~/Downloads/maps_nearby_integration/patch/integrasi_maps_backend.patch
   ```
   Kalau patch ditolak (misal `server.py` sudah banyak berubah), tambahkan manual di `server.py` setelah fungsi
   `estimate_head_pose`, sebelum bagian `# 3. WEBSOCKET ENDPOINT`:
   ```python
   try:
       from nearby_places import build_router as build_places_router
       app.include_router(build_places_router())
   except Exception as e:
       print(f"[WARN] Modul tempat terdekat tidak dimuat: {e}")
   ```
   dan tambahkan `.places_usage.json` ke `.gitignore`.
3. Pasang dependensi:
   ```
   pip install -r requirements-maps.txt
   ```
4. Buat file `.env` di root repo (sudah ada di `.gitignore`, jangan di-commit). Untuk mulai tanpa key:
   ```
   PLACES_PROVIDER=osm
   ```
5. Jalankan server, lalu cek:
   ```
   python server.py
   ```
   Di terminal harus muncul baris `[PLACES] siap: provider=osm` dan di banner ada baris `Tempat : POST .../places/nearby`.

## Cek cepat

```
curl -s localhost:8000/places/health
curl -s "localhost:8000/places/health?deep=true"
curl -s localhost:8000/places/nearby -H "Content-Type: application/json" -d '{"lat": -6.9904, "lng": 110.4229, "category": "all", "limit": 3}'
```

- `/places/health`: konfigurasi terbaca? provider apa? jatah terpakai berapa? Key tidak pernah ditampilkan.
- `/places/health?deep=true`: sekalian tes koneksi + key ke provider. **Memakai 1 jatah panggilan**, hasilnya di-cache 60 detik.
  Kalau gagal, ada `hint` yang menjelaskan penyebabnya (billing belum aktif, Places API (New) belum di-enable, key dibatasi, dst).
- `http://localhost:8000/docs`: dokumentasi interaktif, bisa coba langsung dari browser.

### Uji untuk wilayah Semarang dan perjalanan ke luar kota

Koordinat pusat kota/kecamatan untuk uji coba (tanpa perlu GPS):

| Titik | `lat` | `lng` |
|---|---|---|
| Simpang Lima, Semarang | -6.9904 | 110.4229 |
| Ungaran (dekat tol Semarang-Solo) | -7.1405 | 110.4020 |
| Kendal (arah Jakarta, tol Batang-Semarang) | -6.9211 | 110.2030 |

Contoh dari Ungaran, rest area saja, dengan arah gerak ke selatan (menuju Solo):

```
curl -s localhost:8000/places/nearby -H "Content-Type: application/json" -d '{"lat": -7.1405, "lng": 110.4020, "category": "rest_area", "heading_deg": 180, "speed_mps": 25, "prefer_ahead": true, "limit": 5}'
```

Pembanding: menurut [Auto2000](https://auto2000.co.id/berita-dan-tips/rest-area-km-429), di tol Semarang-Solo (Ungaran) ada Rest Area
KM 429A dan KM 429B, dan menurut [daftar rest area Semarang-Jakarta](https://auto2000.co.id/berita-dan-tips/rest-area-semarang-jakarta)
di tol Batang-Semarang antara lain KM 360B, KM 379A, dan KM 391A (daftar bisa berubah). Kalau hasil `osm` untuk titik-titik itu kosong
atau jauh dari kenyataan, pindah ke provider `google` (data Google biasanya lebih lengkap untuk rest area tol), dan kalau perlu
sesuaikan `PLACES_GOOGLE_TYPES_REST_AREA`. Hasil untuk `osm` di Semarang belum pernah diperiksa pembuat paket ini.

Radius bawaan sudah disesuaikan untuk perjalanan antar kota: rest area **50 km** (jarak antar rest area di tol bisa puluhan km),
hotel/motel **25 km**, SPBU 10 km, minimarket 3 km. Bisa diubah per permintaan lewat `radius_m` (maksimum 50.000).

## Bikin API key Google (dikerjakan sendiri di browser, sekitar 15 menit)

Key ini **RAHASIA**. Jangan dikirim lewat chat/WhatsApp, jangan di-commit, jangan ditaruh di aplikasi Flutter
(isi APK bisa dibongkar orang). Key hanya dibaca server Python lewat `.env`.

1. Buka [console.cloud.google.com](https://console.cloud.google.com), login, buat project baru (misal `driving-buddy`).
2. **Billing**: hubungkan billing account ke project itu. Wajib walau cuma memakai jatah gratis (Google minta kartu untuk verifikasi).
3. **APIs & Services > Library**, cari **Places API (New)** lalu Enable. Hati-hati, bukan "Places API" yang versi lama.
4. **APIs & Services > Credentials > Create credentials > API key**, salin key-nya.
5. Klik key itu > **API restrictions > Restrict key > Places API (New)**. Untuk "Application restrictions" biarkan *None*
   selama development (jangan pilih Android/iOS/HTTP referrer, karena yang memanggil Google adalah server, bukan HP).
6. **Pasang batas pemakaian di Google.** APIs & Services > Places API (New) > Quotas & System limits > turunkan batas untuk
   Nearby Search (pilih yang per hari kalau ada, misal 300). Budget alert di Billing hanya mengirim email dan
   **tidak menghentikan tagihan** (kata Google sendiri: "Setting a budget does not automatically cap ... usage or spending").
   Kalau pilihan per hari tidak ada di akunmu, pengaman di server (300/hari, 4.500/bulan) jadi lapisan utama.
7. Isi `.env`:
   ```
   PLACES_PROVIDER=google
   GOOGLE_PLACES_API_KEY=isi_key_dari_langkah_4
   PLACES_FALLBACK_PROVIDER=osm
   ```
8. Restart `python server.py`, lalu `curl -s "localhost:8000/places/health?deep=true"` harus menampilkan `"reachable": true`.

Jatah gratis Google (dicek di halaman harga resmi): Nearby Search **Pro** 5.000 panggilan/bulan, lalu $32 per 1.000.
Modul ini hanya meminta field tier Pro, dan membatasi diri **300/hari dan 4.500/bulan** supaya tidak melewati jatah gratis.
Angka resmi bisa berubah, cek di Google Cloud Console > Billing. Hitungan modul ini hanya perkiraan dan disimpan di
`.places_usage.json` (otomatis, ada di `.gitignore`).

## Pasang di aplikasi Flutter

Fitur ini menggantikan dua tombol yang tadinya dummy: **"Cari Rest Area Terdekat (4.2 km)"** di layar pemantauan
(`monitor_screen.dart`) dan **"Cari Rest Area Terdekat"** di beranda (`home_screen.dart`). Aplikasi **tidak** memanggil Google
langsung; aplikasi memanggil `server.py` (jadi key Google tetap aman di server), sehingga **server harus bisa dijangkau dari HP**.

1. Modulnya sudah ikut tersalin di langkah backend (`lib/features/nearby_places/`). Kalau belum, ulangi perintah `cp -R` di atas.
2. Tambah paket (versi dipilih otomatis sesuai SDK kalian):
   ```
   flutter pub add http geolocator url_launcher
   ```
3. Pasang patch (mengubah 2 layar + izin lokasi di AndroidManifest/Info.plist + `http://` lokal untuk build debug):
   ```
   git apply ~/Downloads/maps_nearby_integration/patch/integrasi_maps_flutter.patch
   ```
   Kalau ditolak karena layar sudah diubah teman (misal desain UI baru), pakai **Lampiran: tempel manual** di bawah.
4. Cek:
   ```
   flutter pub get
   flutter analyze
   ```
5. Cari IP laptop (Mac, Wi-Fi), jalankan server di laptop, lalu jalankan aplikasi dengan alamat itu:
   ```
   ipconfig getifaddr en0
   flutter run --dart-define=PLACES_API_BASE_URL=http://192.168.1.10:8000
   ```
   Ganti `192.168.1.10` dengan IP hasil perintah pertama. HP dan laptop harus **satu Wi-Fi**. Saat server pertama kali jalan, macOS
   bisa bertanya apakah Python boleh menerima koneksi masuk: pilih **Allow**. Emulator Android otomatis memakai `10.0.2.2:8000`
   (tanpa `--dart-define`); HP asli yang tidak diberi `--dart-define` ikut memakai alamat emulator itu dan akan gagal terhubung.
   Alamat juga bisa diubah dari dalam aplikasi: ketuk kartu pitstop, lalu ikon server di pojok kanan atas daftar.

   **Wi-Fi kampus sering memblokir koneksi antar perangkat.** Kalau HP Android tidak bisa menjangkau laptop, sambungkan HP lewat
   kabel USB dan pakai `adb reverse` (alamat jadi `127.0.0.1`):
   ```
   adb reverse tcp:8000 tcp:8000
   flutter run --dart-define=PLACES_API_BASE_URL=http://127.0.0.1:8000
   ```

   **Dibawa keluar kota (tes di jalan).** `server.py` jalan di laptop, jadi saat HP dibawa jalan, HP harus tetap bisa menjangkau
   laptop, dan laptop harus punya internet (untuk menghubungi Google/OSM). Cara paling sederhana: bawa laptop di mobil, nyalakan
   hotspot HP, sambungkan laptop ke hotspot itu, lalu pakai IP laptop di jaringan hotspot sebagai alamat server (`ipconfig getifaddr en0`,
   lalu `--dart-define=PLACES_API_BASE_URL=http://IP:8000` atau menu "Atur server" di app). Coba dulu di rumah sebelum berangkat.
   Di iPhone, iOS bisa menanyakan izin "Jaringan Lokal" saat pertama kali menghubungi laptop: pilih Izinkan. Untuk pemakaian
   sungguhan tanpa laptop, server harus di-hosting online (belum termasuk di paket ini).

### Cara kerja di aplikasi

- **Mulai Sesi Monitoring**: kartu **REKOMENDASI PITSTOP** muncul di bawah kamera. Pertama kali kartu meminta izin lokasi (ketuk
  tombolnya). Setelah posisi didapat, kartu menampilkan rest area terdekat yang **di depan** kendaraan, mis. "4,2 km lagi".
  Jaraknya dihitung ulang di HP tiap GPS bergerak, jadi server tidak dipanggil terus-menerus.
- **Tombol navigasi di kartu**: membuka Google Maps (mode mobil) ke tempat itu. **Ketuk bagian lain kartu**: daftar rest area,
  minimarket, hotel/motel, dan SPBU terdekat (chip kategori).
- **Alarm kantuk bunyi**: dialog menampilkan tempat berhenti terdekat **apa pun jenisnya** (mode merah). Tombol
  "ARAHKAN KE REST AREA TERDEKAT" membuka Google Maps ke sana. Kalau server mati atau GPS bermasalah, dialog tetap tampil
  dan alarm tetap bunyi, kartunya cuma menjelaskan masalahnya.
- **Beranda**: tombol "Cari Rest Area Terdekat" membuka daftar yang sama.
- **Demo di meja** (tanpa menyetir): `flutter run --dart-define=PLACES_API_BASE_URL=... --dart-define=PLACES_DEMO_LOCATION=-7.1405,110.4020`
  memakai lokasi tetap (contoh: Ungaran, Semarang). Opsi ini diabaikan di build rilis. Lokasi tetap tidak punya arah gerak, jadi
  label "di depan/di belakang" baru muncul kalau perangkat benar-benar bergerak (GPS asli).

Catatan: berpindah ke Google Maps membuat Driving Buddy ke latar belakang, dan Android tidak mengizinkan kamera dipakai di
latar belakang, jadi pemantauan wajah terhenti selama itu. Setelah kembali, cek apakah pratinjau kamera hidup lagi; kalau tidak,
hentikan lalu mulai sesi lagi. Penanganan khusus untuk ini belum ada di `monitor_screen.dart`.

### Lampiran: tempel manual (kalau patch Flutter ditolak)

`lib/screens/monitor_screen.dart`:

1. Import: `import '../features/nearby_places/nearby_places.dart';`
2. Di `MonitorScreenState`, di bawah `final AlertService _alert = AlertService();`:
   ```dart
   final NearbyPlacesController _nearby = NearbyPlacesController();
   ```
3. Di `dispose()`, sebelum `super.dispose()`: `_nearby.dispose();`
4. Di `_startMonitoring()`, di dalam `try`, setelah `_resumeTimer();` yang terakhir: `unawaited(_nearby.start());`
5. Di `_stopMonitoring()`, setelah `await _alert.stop();`: `_nearby.stop();`
6. Di `_triggerSafetyAlert(...)`:
   - setelah `_isAlertShowing = true;` tambahkan `unawaited(_nearby.requestUrgent());`
   - di `MicrosleepAlertDialog(...)` tambahkan `nearby: _nearby,`
   - di `onRestArea`, tambahkan `final target = _nearby.best;` sebagai baris **pertama** (sebelum `await _alert.stop();`; ini
     mengunci tempat yang sedang tampil di kartu sebelum dialog ditutup), lalu ganti isi
     `if (mounted) { ...SnackBar('Mengarahkan ke rest area terdekat...') }` dengan:
     ```dart
     final opened = target != null
         ? await _nearby.navigateTo(target)
         : await _nearby.navigateToBest();
     if (!opened && mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(
           content: Text('Belum ada tempat berhenti yang ditemukan. Menepi di tempat yang aman ya.'),
           behavior: SnackBarBehavior.floating,
         ),
       );
     }
     ```
   - di `.whenComplete(() { ... })` tambahkan `_nearby.clearUrgent();`
7. Di `_buildActionButtons()`, ganti `OutlinedButton.icon(...)` "Cari Rest Area Terdekat (4.2 km)" dengan `PitstopCard(controller: _nearby)`.
8. Di `MicrosleepAlertDialog`: tambah `final NearbyPlacesController? nearby;` (+ `this.nearby,` di konstruktor), lalu di awal
   `_buildRecommendationCard()`:
   ```dart
   final nearby = widget.nearby;
   if (nearby != null) {
     return PitstopCard(
       controller: nearby,
       urgent: true,
       onNavigate: (_) {
         widget.onRestArea?.call();
         Navigator.of(context).pop();
       },
     );
   }
   ```

`lib/screens/home_screen.dart`: import yang sama, lalu di `_buildRestAreaButton` ganti isi `onPressed` dengan
`() => showNearbyPlacesSheet(context)`.

`android/app/src/main/AndroidManifest.xml`: tambahkan di dalam `<manifest>`
`<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>` dan `ACCESS_COARSE_LOCATION`; di dalam `<queries>` tambahkan
`<intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>`.
`android/app/src/debug/AndroidManifest.xml`: tambahkan `<application android:usesCleartextTraffic="true"/>` (hanya build debug).
`ios/Runner/Info.plist`: tambahkan kunci `NSLocationWhenInUseUsageDescription` beserta teks alasannya.

## Kontrak API (buat FE)

### `POST /places/nearby`

Dipakai POST (bukan GET) supaya koordinat pengemudi tidak masuk URL dan log akses. Nama field mengikuti `Position` dari paket
Flutter `geolocator`, jadi hasil `getCurrentPosition()` bisa diteruskan apa adanya. Nama camelCase juga diterima.

| Field | Wajib | Keterangan |
|---|---|---|
| `lat`, `lng` | ya | Posisi pengemudi (alias: `latitude`, `longitude`, `lon`). Koordinat (0, 0) ditolak (422) karena itu tanda GPS belum dapat sinyal. |
| `category` | tidak | `all` (bawaan: rest area + minimarket + hotel/motel), `rest_area`, `minimarket`, `lodging`, `spbu`. |
| `radius_m` | tidak | 100 - 50.000. Kosong = bawaan per kategori: rest area 50 km, hotel/motel 25 km, SPBU 10 km, minimarket 3 km. |
| `limit` | tidak | 1 - 10 hasil **per kategori** (bawaan 5). |
| `heading_deg` / `speed_mps` | tidak | Arah gerak (derajat dari utara) dan kecepatan (m/s). Arah diabaikan kalau kecepatan di bawah 1,5 m/s karena GPS tidak akurat saat diam. Nilai -1/NaN dianggap "tidak ada". |
| `prefer_ahead` | tidak | `true` = tempat yang ada di depan kendaraan diurutkan lebih dulu (butuh `heading_deg`). |
| `accuracy_m` | tidak | Akurasi GPS. Kalau terlalu kasar, muncul peringatan di `warnings`. |

Respons 200:

```json
{
  "results": [
    {"id": "ChIJ...", "name": "Rest Area KM 57", "category": "rest_area", "category_label": "Rest area",
     "address": "Jl. Tol Jakarta-Cikampek", "lat": -6.3, "lng": 107.1,
     "distance_m": 5500, "distance_text": "5,5 km", "bearing_deg": 95, "ahead": true,
     "open_now": null, "rating": null,
     "maps_url": "https://maps.google.com/?cid=...",
     "navigate_url": "https://www.google.com/maps/dir/?api=1&destination=-6.300000,107.100000&travelmode=driving&destination_place_id=ChIJ...",
     "source": "google", "provider_type": "rest_stop"}
  ],
  "summary": "Rest area terdekat: Rest Area KM 57, sekitar 5,5 kilometer di depan.",
  "category": "rest_area", "provider": "google", "cached": false,
  "degraded": false, "errors": {}, "fallback_used": false, "warnings": [], "latency_ms": 312
}
```

- `distance_m` adalah **jarak garis lurus**, bukan jarak lewat jalan. Jarak dan waktu tempuh asli baru muncul di Google Maps
  setelah navigasi dibuka lewat `navigate_url` (tidak memakai kuota API sama sekali).
- `summary`: kalimat pendek siap dibacakan TTS.
- `degraded: true` = sebagian/seluruh pencarian gagal, penyebab per kategori ada di `errors`:
  `timeout`, `network`, `rate_limited`, `auth`, `bad_request`, `upstream`, `bad_response`, `budget_exhausted`, `internal`.
  HTTP tetap 200 supaya aplikasi tidak crash. `results` bisa kosong, `summary` tetap berisi pesan aman.
- `open_now` dan `rating` hanya terisi kalau `PLACES_GOOGLE_RATING_HOURS=true` (Google menagih tier Enterprise yang lebih mahal,
  jatah gratisnya cuma 1.000/bulan, jadi batas bulanan modul otomatis turun ke 900).

Status lain: `422` input tidak valid, `429` kebanyakan request (lihat header `Retry-After`; batas bawaan 20/menit per klien,
120/menit total), `503` belum dikonfigurasi (isi `detail.message` menjelaskan kurangnya apa), `500` bug tak terduga.

### Lainnya

- `GET /places/categories`: daftar kategori + radius bawaan (buat tombol/tab di aplikasi).
- `GET /places/health[?deep=true]`: lihat bagian "Cek cepat".

## Yang sudah ditangani (bagian yang "teliti")

- **Biaya**: field mask hanya tier Pro, dua lapis pengaman (hitungan harian/bulanan di server + quota cap di Google),
  hasil di-cache 90 detik / 250 meter sehingga posisi yang nyaris sama tidak memanggil Google lagi.
- **Key aman**: hanya di `.env` server, dikirim lewat header (bukan URL), tidak pernah muncul di log, respons, atau `/places/health`.
- **Privasi lokasi**: POST, dan koordinat tidak ditulis ke log aplikasi.
- **Urutan benar**: Google diminta urut jarak, lalu server hitung ulang jarak (haversine) dan sortir sendiri, jadi urutan tidak
  bergantung provider. Arah tempat (utara=0) dan "di depan/di belakang" dihitung dari `heading_deg`.
- **Data kotor dari sensor**: GPS (0,0), heading/speed -1 atau NaN, akurasi buruk tidak membuat error 500.
- **Provider lambat atau mati**: timeout 4 detik, retry 1x untuk error sementara, fallback ke OpenStreetMap, 429 dari provider
  dihormati (tidak dipukul terus).
- **Overpass (OSM)**: User-Agent sendiri, jeda setelah 429, radius otomatis dikecilkan kalau terlalu banyak hasil.
- **Terlalu banyak request**: batas per klien dan global, jawaban 429 + `Retry-After`.

## Konfigurasi lain (opsional, semua di `.env`)

Daftar lengkap dan komentarnya ada di `nearby_places/env.example`. Yang paling berguna:

| Variabel | Bawaan | Fungsi |
|---|---|---|
| `PLACES_GOOGLE_DAILY_BUDGET` / `..._MONTHLY_BUDGET` | 300 / 4500 | Batas panggilan ke Google (0 = tanpa batas, jangan kecuali quota cap sudah dipasang). |
| `PLACES_GOOGLE_RATING_HOURS` | false | Minta rating dan status buka/tutup (lebih mahal). |
| `PLACES_GOOGLE_TYPES_REST_AREA` dst | lihat env.example | Ganti tipe tempat Google kalau hasilnya kurang pas. Kolom `provider_type` di respons menunjukkan tipe asli tiap hasil. |
| `PLACES_TIMEOUT_S` | 4 | Batas waktu per panggilan ke provider. |
| `PLACES_CACHE_TTL_S` | 90 | Lama cache. |
| `PLACES_RATE_PER_CLIENT_PER_MIN` | 20 | Batas request per klien. |
| `PLACES_USAGE_FILE` | `.places_usage.json` | `off` = hitungan hanya di memori. |

## Tes

```
pip install pytest
python -m pytest tests_places -q
```

371 tes, termasuk tes lewat jaringan loopback sungguhan ke server Google dan Overpass palsu (`tests_places/fake_places.py`,
bisa juga dijalankan manual: `python tests_places/fake_places.py 9200`). Lulus di Python 3.9, 3.11, dan 3.13. Semua tes jalan
offline dan tidak memakai API key.

## OSM v2: tahan banting (failover, curl, cache basi)

- **Python bawaan macOS** (`/usr/bin/python3`, Xcode) memakai LibreSSL 2.8.3 dan gagal TLS ke `overpass-api.de`
  (`SSLV3_ALERT_HANDSHAKE_FAILURE`). Dengan `PLACES_OSM_TRANSPORT=auto` (bawaan) server otomatis mengulang lewat
  program `curl` milik macOS. Jangka panjang: pakai Python dari python.org/Homebrew (OpenSSL).
- **Beberapa server Overpass**: isi `PLACES_OSM_URL` dengan beberapa alamat dipisah koma (lihat `env.example`).
  Dicoba satu per satu, tidak paralel, maksimal `PLACES_OSM_DEADLINE_S` (20 dtk). 429/406 -> server itu dijeda
  30 dtk. Server publik sering penuh ("at capacity", 502/504); itu masalah server, bukan kode kita.
- **Cache basi**: kalau semua server gagal, hasil lama (maks 6 jam, pusat dalam 3 km) dipakai dan app menampilkan
  "Data ... tersimpan dari N menit lalu". Hangatkan sebelum demo: buka sheet di lokasi demo saat server longgar.
  `PLACES_STALE_CACHE_FILE` (opsional) menyimpan cache itu ke file supaya tetap ada setelah server restart;
  file itu berisi lokasi pencarian, jadi masukkan ke `.gitignore`.
- **Diagnosa**: `curl -s "http://127.0.0.1:8000/places/health?deep=true"` sekarang juga mengembalikan `detail`
  (penyebab singkat), `hint`, dan `osm.servers` / `osm.transport`.
- **Atribusi**: data dari OpenStreetMap wajib diberi keterangan "© kontributor OpenStreetMap" (lisensi ODbL).

## Data offline (provider `snapshot`)

Server Overpass publik sering penuh (timeout, 502/504). Supaya demo tetap ada datanya, data OSM satu area diambil
**sekali** dengan satu query besar, disimpan ke `places_snapshot.json` di root repo, lalu server menjawab dari file itu
(instan, tanpa internet, tanpa jatah).

1. Ambil data (area Semarang sampai Solo; ubah `bbox` = lat selatan, lng barat, lat utara, lng timur untuk area lain).
   Jalankan dari root repo, cukup sekali; jangan diulang-ulang dalam loop:
   ```
   printf '%s\n' '[out:json][timeout:180][bbox:-7.65,109.70,-6.80,110.95];' '(' 'nwr["highway"~"^(rest_area|services)$"];' 'nwr["shop"="convenience"];' 'nwr["tourism"~"^(hotel|motel|guest_house|hostel)$"];' 'nwr["amenity"="fuel"];' ');' 'out center tags;' > snap_query.ql
   /usr/bin/curl -q -f -sS -m 200 -A "driving-buddy-places/1.0 (student capstone project)" --data-urlencode "data@snap_query.ql" -o places_snapshot.json https://overpass-api.de/api/interpreter
   ```
   Kalau server itu penuh, coba lagi nanti atau ganti alamatnya dengan server lain dari `env.example`.
2. Pilih salah satu di `.env`, lalu restart server:
   - `PLACES_PROVIDER=snapshot` + `PLACES_FALLBACK_PROVIDER=osm`: di dalam area jawabannya instan dari file; di luar
     area baru tanya Overpass live. **Saran untuk demo.**
   - `PLACES_PROVIDER=osm` + `PLACES_FALLBACK_PROVIDER=snapshot`: data live dulu; file dipakai kalau semua server
     Overpass gagal (pengemudi menunggu sampai `PLACES_OSM_DEADLINE_S` dulu).
3. Cek: `curl -s http://127.0.0.1:8000/places/health` menampilkan blok `snapshot` (jumlah tempat per kategori,
   tanggal data, area). Kalau filenya rusak atau belum ada, alasannya ada di `snapshot.problem`.

Yang perlu diketahui:

- App menampilkan keterangan "Data tempat dari salinan OpenStreetMap tanggal ... (offline)". Tempat yang buka atau
  tutup setelah tanggal itu tidak ikut, jadi ambil ulang sesekali (seminggu sekali sudah cukup).
- Di luar area file, provider ini menjawab error (bukan "tidak ada tempat"), supaya pengemudi tidak mengira memang
  tidak ada rest area. Dengan cadangan `osm`, pencarian itu otomatis pindah ke Overpass live.
- Rest area: di OSM Indonesia ada bengkel yang ditandai `highway=services` (mis. "bengkel motor", "Honda Ahass").
  Untuk `osm` dan `snapshot`, elemen yang nama/operatornya mengandung kata bengkel, ahass, servis, tambal ban, dll.,
  atau punya tag `shop=car_repair`/`motorcycle_repair`, tidak dihitung sebagai rest area (`categories.py`).
- File ini hanya berisi data publik OSM (tanpa lokasi pengguna). Ukurannya beberapa MB, jadi sebaiknya tidak di-commit;
  masukkan ke `.gitignore`. Lokasi lain bisa diatur lewat `PLACES_SNAPSHOT_FILE`.
- Atribusi tetap wajib: "© kontributor OpenStreetMap" (ODbL).

## Batasan yang jujur

- **Belum pernah dites dengan API key Google asli**. Semua jalur dites terhadap server palsu yang meniru format jawaban resmi
  Places API (New). Makanya ada `/places/health?deep=true` untuk pertama kali memastikan key dan billing beres.
- Jumlah dan kualitas hasil "rest area" bergantung pada data Google/OSM di lokasi itu. Kalau terlalu sedikit, ubah
  `PLACES_GOOGLE_TYPES_REST_AREA` atau radius.
- Jarak adalah garis lurus. Tempat di seberang tol atau sungai bisa terlihat dekat padahal jauh ditempuh.
- Server mengandalkan koneksi internet laptop. Tanpa internet fitur ini menjawab `degraded` (alarm tetap jalan).
- **Kode Flutter belum pernah dikompilasi atau dijalankan oleh pembuatnya** (SDK Flutter/Dart tidak bisa dipasang di lingkungan
  tempat paket ini dibuat). Sintaksnya sudah diperiksa dengan parser Dart dan seluruh kodenya sudah di-review manual terhadap
  dokumentasi resmi paket `geolocator`, tapi `flutter analyze` di laptop kalian adalah pemeriksaan pertama yang sebenarnya.
  Kalau muncul error di `lib/features/nearby_places/`, itu yang harus dibereskan dulu; backend tidak terpengaruh sama sekali.
- Build **debug** boleh memanggil server lewat `http://` (diizinkan oleh patch). Build **rilis** Android memblokir `http://`
  biasa, jadi untuk APK rilis server perlu di-hosting dengan HTTPS.
