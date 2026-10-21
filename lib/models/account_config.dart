import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// ACCOUNT CONFIG — Simpan profil user secara lokal
// ============================================================================

class AccountConfig {
  static const _keyName = 'account_name';
  static const _keyEmail = 'account_email';

  static Future<Map<String, String>> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString(_keyName) ?? '',
      'email': prefs.getString(_keyEmail) ?? '',
    };
  }

  static Future<void> saveProfile(String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyName, name);
    await prefs.setString(_keyEmail, email);
  }

  static Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyName);
    await prefs.remove(_keyEmail);
  }
}
