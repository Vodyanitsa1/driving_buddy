import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

enum AlertImageMode {
  none,
  custom,
}

enum AlertAudioType {
  defaultSiren, // sounds/alarm.mp3
  loudBeep,     // sounds/beep.wav
  buzzer,       // sounds/buzzer.wav
  customFile,   // File dari penyimpanan HP
}

class AlertConfig {
  static const _keyImageMode = 'alert_image_mode';
  static const _keyCustomImagePath = 'alert_custom_image_path';
  static const _keyAudioType = 'alert_audio_type';
  static const _keyCustomAudioPath = 'alert_custom_audio_path';
  static const _keyCustomAudioName = 'alert_custom_audio_name';

  /// Mendapatkan mode gambar alert yang sedang aktif (default: none / tanpa meme)
  static Future<AlertImageMode> getImageMode() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_keyImageMode) ?? 'none';
    switch (mode) {
      case 'custom':
        final path = prefs.getString(_keyCustomImagePath) ?? '';
        if (path.isNotEmpty && File(path).existsSync()) {
          return AlertImageMode.custom;
        }
        return AlertImageMode.none;
      case 'none':
      default:
        return AlertImageMode.none;
    }
  }

  /// Mendapatkan path file gambar kustom (jika ada dan valid)
  static Future<String?> getCustomImagePath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_keyCustomImagePath);
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
    return null;
  }

  /// Menyimpan mode gambar alert
  static Future<void> setImageMode(AlertImageMode mode, {String? customPath}) async {
    final prefs = await SharedPreferences.getInstance();
    switch (mode) {
      case AlertImageMode.custom:
        await prefs.setString(_keyImageMode, 'custom');
        if (customPath != null && customPath.isNotEmpty) {
          await prefs.setString(_keyCustomImagePath, customPath);
        }
        break;
      case AlertImageMode.none:
        await prefs.setString(_keyImageMode, 'none');
        break;
    }
  }

  /// Menghapus gambar alert kustom
  static Future<void> removeCustomImage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyImageMode, 'none');
    await prefs.remove(_keyCustomImagePath);
  }

  /// Mendapatkan tipe audio yang sedang aktif
  static Future<AlertAudioType> getAudioType() async {
    final prefs = await SharedPreferences.getInstance();
    final type = prefs.getString(_keyAudioType) ?? 'default';
    switch (type) {
      case 'beep':
        return AlertAudioType.loudBeep;
      case 'buzzer':
        return AlertAudioType.buzzer;
      case 'custom':
        final path = prefs.getString(_keyCustomAudioPath) ?? '';
        if (path.isNotEmpty && File(path).existsSync()) {
          return AlertAudioType.customFile;
        }
        return AlertAudioType.defaultSiren;
      default:
        return AlertAudioType.defaultSiren;
    }
  }

  /// Mendapatkan path file audio kustom
  static Future<String?> getCustomAudioPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_keyCustomAudioPath);
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
    return null;
  }

  /// Mendapatkan nama audio yang sedang dipilih untuk tampilan UI
  static Future<String> getAudioDisplayName() async {
    final type = await getAudioType();
    switch (type) {
      case AlertAudioType.defaultSiren:
        return 'Sirene Darurat (Bawaan)';
      case AlertAudioType.loudBeep:
        return 'Beep Alarm Peringatan';
      case AlertAudioType.buzzer:
        return 'Klakson / Buzzer Peringatan';
      case AlertAudioType.customFile:
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString(_keyCustomAudioName) ?? 'Audio Kustom';
    }
  }

  /// Mengatur audio ke preset bawaan
  static Future<void> setAudioPreset(AlertAudioType type) async {
    final prefs = await SharedPreferences.getInstance();
    if (type == AlertAudioType.defaultSiren) {
      await prefs.setString(_keyAudioType, 'default');
    } else if (type == AlertAudioType.loudBeep) {
      await prefs.setString(_keyAudioType, 'beep');
    } else if (type == AlertAudioType.buzzer) {
      await prefs.setString(_keyAudioType, 'buzzer');
    }
  }

  /// Mengatur audio kustom dari file
  static Future<void> setCustomAudio(String filePath, String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAudioType, 'custom');
    await prefs.setString(_keyCustomAudioPath, filePath);
    await prefs.setString(_keyCustomAudioName, fileName);
  }

  /// Reset audio ke default
  static Future<void> resetAudio() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAudioType, 'default');
    await prefs.remove(_keyCustomAudioPath);
    await prefs.remove(_keyCustomAudioName);
  }
}
