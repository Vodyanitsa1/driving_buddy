import 'package:flutter/material.dart';

// ============================================================================
// GAYA — token desain dari rancangan Stitch "Driving Buddy" (layar Berkendara):
// tembaga (copper) #E57A38 di atas gading hangat, teks tinta #0F172A,
// kapital kecil berjarak untuk label, sudut membulat 8/12 px.
//
// Semua warna & ukuran modul "tempat terdekat" ada di file ini. Kalau desain
// berubah (atau tema aplikasi diganti), cukup ubah di sini.
// Font mengikuti tema aplikasi (tidak memaksa font tertentu).
// ============================================================================

class PlacesStyle {
  const PlacesStyle._();

  // ------------------------------------------------------------------ warna

  /// Warna utama desain (tembaga).
  static const Color copper = Color(0xFFE57A38);
  static const Color copperDark = Color(0xFFC25E21);

  /// Teks utama.
  static const Color ink = Color(0xFF0F172A);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate600 = Color(0xFF475569);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate100 = Color(0xFFF1F5F9);

  /// Latar halaman / sheet.
  static const Color pageBg = Color(0xFFF8F9FA);
  static const Color ivory = Color(0xFFFFFBF8);
  static const Color orange50 = Color(0xFFFFF7ED);
  static const Color orange100 = Color(0xFFFFEDD5);
  static const Color orange200 = Color(0xFFFED7AA);
  static const Color orange300 = Color(0xFFFDBA74);

  static const Color emerald = Color(0xFF059669);
  static const Color emerald50 = Color(0xFFECFDF5);
  static const Color emerald200 = Color(0xFFA7F3D0);

  /// Mode darurat (alarm kantuk) dan pesan kesalahan.
  static const Color vermilion = Color(0xFFD94126);
  static const Color vermilionDark = Color(0xFFB3301B);
  static const Color vermilion50 = Color(0xFFFFF1EE);
  static const Color vermilion100 = Color(0xFFFFE0D9);
  static const Color vermilion300 = Color(0xFFF4A593);

  // ---------------------------------------------------------------- ukuran

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 16;
  static const double spaceLg = 24;

  static const double radiusLg = 8;
  static const double radiusXl = 12;

  /// Tombol aksi bulat-persegi (navigasi) & kotak ikon: 48 px.
  static const double actionSize = 48;

  // ------------------------------------------------------------------ teks

  /// 11 px, kapital berjarak, tebal — label kecil di atas judul.
  static const TextStyle labelCaps = TextStyle(
    fontSize: 11,
    height: 14 / 11,
    letterSpacing: 0.88,
    fontWeight: FontWeight.w700,
  );

  /// 20 px — nama tempat di kartu.
  static const TextStyle headlineSm = TextStyle(
    fontSize: 20,
    height: 26 / 20,
    letterSpacing: -0.3,
    fontWeight: FontWeight.w700,
  );

  /// 14 px — teks isi.
  static const TextStyle bodyMd = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: 0.07,
    fontWeight: FontWeight.w400,
  );

  /// 12 px — keterangan.
  static const TextStyle bodySm = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.12,
    fontWeight: FontWeight.w500,
  );

  /// Teks tombol kategori.
  static const TextStyle chip = TextStyle(
    fontSize: 12.5,
    height: 1.2,
    fontWeight: FontWeight.w700,
  );

  // -------------------------------------------------------------- dekorasi

  /// Latar kartu Pitstop normal.
  static const LinearGradient pitstopGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[orange50, orange100, ivory],
    stops: <double>[0.0, 0.6, 1.0],
  );

  /// Latar kartu Pitstop saat alarm kantuk (darurat).
  static const LinearGradient urgentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[vermilion50, vermilion100, ivory],
    stops: <double>[0.0, 0.6, 1.0],
  );

  /// Bayangan halus (shadow-sm di desain).
  static const List<BoxShadow> softShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A0F172A),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
  ];

  /// Bayangan sangat tipis (shadow-xs).
  static const List<BoxShadow> hairShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x0D0F172A),
      blurRadius: 2,
      offset: Offset(0, 1),
    ),
  ];
}
