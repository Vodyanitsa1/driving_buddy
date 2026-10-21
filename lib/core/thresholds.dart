/// Semua angka konfigurasi ada di sini supaya mudah dituning di HP.
class Thresholds {
  // Ambang geometris
  static const double earClosed = 0.15; // mata tertutup
  static const double marYawn = 0.35; // mulut menguap
  static const double headDrop = 0.68; // kepala menunduk (pitch ratio)

  // Durasi (detik)
  static const double eyeClosedLimit = 1.7; // -> Sleep
  static const double yawnLimit = 1.2; // -> Yawn
  static const double headDropLimit = 2.0; // -> Drowsy
  static const double yawnWindow = 300; // jendela 5 menit
  static const int yawnAlertFreq = 4; // >=4x menguap / 5 menit -> Drowsy
  static const int highBlinkRate = 35; // kedip / menit -> Drowsy
  static const double minBlinkInterval = 0.2; // debounce kedip

  // Performa & alarm
  static const int processEveryNthFrame = 2; // proses 1 dari tiap N frame
  static const Duration alertCooldown = Duration(seconds: 3);
}
