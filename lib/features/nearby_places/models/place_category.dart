import 'package:flutter/material.dart';

// ============================================================================
// KATEGORI TEMPAT
// ============================================================================

/// Jenis tempat yang bisa dicari. [apiValue] HARUS sama dengan `category` di
/// backend (nearby_places/categories.py). "Semua" tidak ada di enum ini:
/// di seluruh modul, `null` berarti semua kategori.
enum PlaceCategory {
  restArea('rest_area', 'Rest Area', Icons.local_cafe_rounded),
  minimarket('minimarket', 'Minimarket', Icons.storefront_rounded),
  lodging('lodging', 'Hotel/Motel', Icons.hotel_rounded),
  spbu('spbu', 'SPBU', Icons.local_gas_station_rounded);

  const PlaceCategory(this.apiValue, this.label, this.icon);

  /// Nilai yang dikirim ke / diterima dari server.
  final String apiValue;

  /// Teks untuk chip/tombol di aplikasi.
  final String label;

  final IconData icon;

  /// `null` kalau [value] tidak dikenal (misalnya server menambah kategori baru).
  static PlaceCategory? fromApi(String? value) {
    for (final c in PlaceCategory.values) {
      if (c.apiValue == value) return c;
    }
    return null;
  }
}
