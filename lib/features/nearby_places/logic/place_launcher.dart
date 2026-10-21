import 'package:url_launcher/url_launcher.dart';

import '../models/nearby_place.dart';

// ============================================================================
// PELUNCUR — membuka Google Maps ke tempat yang dipilih. Tidak memakai API key
// dan tidak ada biaya: cukup membuka link `google.com/maps/dir/?api=1&...`.
// ============================================================================

/// Pembuka URL (diganti versi palsu di tes).
typedef UrlOpener = Future<bool> Function(Uri uri);

class PlaceLauncher {
  const PlaceLauncher._();

  /// Hanya link ke layanan peta ini yang boleh dibuka dari data jaringan.
  static const Set<String> _allowedHosts = <String>{
    'www.google.com',
    'google.com',
    'maps.google.com',
    'www.openstreetmap.org',
    'openstreetmap.org',
  };

  static Future<bool> _defaultOpener(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static bool _isAllowed(Uri? uri) {
    return uri != null && uri.scheme == 'https' && _allowedHosts.contains(uri.host);
  }

  /// Link navigasi mobil ke [place]. Memakai `navigate_url` dari server kalau
  /// aman, kalau tidak dibuat sendiri dari koordinat.
  static Uri navigationUri(NearbyPlace place) {
    final given = Uri.tryParse(place.navigateUrl);
    if (_isAllowed(given)) return given!;
    return Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination':
          '${place.lat.toStringAsFixed(6)},${place.lng.toStringAsFixed(6)}',
      'travelmode': 'driving',
    });
  }

  /// Link halaman tempat (bukan navigasi). Cadangan: pencarian koordinat di Google Maps.
  static Uri placePageUri(NearbyPlace place) {
    final given = Uri.tryParse(place.mapsUrl);
    if (_isAllowed(given)) return given!;
    return Uri.https('www.google.com', '/maps/search/', <String, String>{
      'api': '1',
      'query': '${place.lat.toStringAsFixed(6)},${place.lng.toStringAsFixed(6)}',
    });
  }

  /// Buka navigasi. `false` kalau tidak ada aplikasi/browser yang bisa membukanya.
  static Future<bool> navigate(NearbyPlace place, {UrlOpener? opener}) async {
    return _open(navigationUri(place), opener);
  }

  static Future<bool> openPlacePage(NearbyPlace place, {UrlOpener? opener}) async {
    return _open(placePageUri(place), opener);
  }

  static Future<bool> _open(Uri uri, UrlOpener? opener) async {
    try {
      return await (opener ?? _defaultOpener)(uri);
    } catch (_) {
      return false;
    }
  }
}
