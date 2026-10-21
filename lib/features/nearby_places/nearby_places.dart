// ============================================================================
// FITUR "TEMPAT TERDEKAT" (Maps API) — satu pintu masuk untuk layar lain:
//
//   import '../features/nearby_places/nearby_places.dart';
//
// Isi:
//   NearbyPlacesController  otak fitur (izin lokasi, ambil data, mode darurat kantuk)
//   PitstopCard             kartu "REKOMENDASI PITSTOP" (desain Stitch)
//   showNearbyPlacesSheet   daftar rest area / minimarket / hotel-motel / SPBU
//   showPlacesServerDialog  atur alamat server (server.py)
//   PlaceLauncher           buka Google Maps untuk navigasi
//
// Server: modul `nearby_places` di server.py (lihat README_MAPS.md).
// KUNCI Google hanya ada di .env server, TIDAK PERNAH di aplikasi ini.
// ============================================================================

export 'data/location_provider.dart';
export 'data/places_api.dart';
export 'data/places_config.dart';
export 'logic/geo_math.dart' show GeoPoint, formatDistance;
export 'logic/nearby_controller.dart';
export 'logic/place_launcher.dart';
export 'models/nearby_place.dart';
export 'models/place_category.dart';
export 'ui/nearby_sheet.dart';
export 'ui/pitstop_card.dart';
export 'ui/places_server_dialog.dart';
export 'ui/places_style.dart';
export 'data/direct_osm_places_api.dart';
