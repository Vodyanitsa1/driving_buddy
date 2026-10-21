import 'dart:collection';
import 'dart:ui' show Offset;

import '../core/thresholds.dart';
import '../models/detection_result.dart';

/// Port dari logika Python (EAR, MAR, head pitch, timer, status bertingkat).
/// Tidak bergantung pada kamera / ML Kit, jadi mudah dites.
class DrowsinessDetector {
  // Indeks landmark MediaPipe Face Mesh (468 titik)
  static const rightEye = [33, 160, 158, 133, 153, 144];
  static const leftEye = [362, 385, 387, 263, 373, 380];

  double? _eyeClosedStart, _yawnStart, _headDropStart;
  double _lastBlink = 0, _yawnDisplayUntil = 0;
  bool _eyeClosed = false, _yawnCounted = false;
  final _yawns = Queue<double>();
  final _blinks = Queue<double>();

  double _d(Offset a, Offset b) => (a - b).distance;

  double _ear(List<Offset> p, List<int> i) {
    final h = _d(p[i[0]], p[i[3]]);
    if (h == 0) return 0;
    return (_d(p[i[1]], p[i[5]]) + _d(p[i[2]], p[i[4]])) / (2 * h);
  }

  double _mar(List<Offset> p) {
    final w = _d(p[61], p[291]);
    return w == 0 ? 0 : _d(p[13], p[14]) / w;
  }

  double _pitch(List<Offset> p) {
    final faceH = _d(p[10], p[199]);
    return faceH > 0 ? _d(p[1], p[199]) / faceH : 0.5;
  }

  /// Panggil tiap frame. Kirim null kalau wajah tidak terdeteksi.
  DetectionResult update(List<Offset>? p) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;

    while (_yawns.isNotEmpty && now - _yawns.first > Thresholds.yawnWindow) {
      _yawns.removeFirst();
    }
    while (_blinks.isNotEmpty && now - _blinks.first > 60) {
      _blinks.removeFirst();
    }

    if (p == null) {
      return DetectionResult(
        status: DriverStatus.noFace,
        subStatus: 'WAJAH TIDAK TERDETEKSI / MENENGOK',
        ear: 0,
        mar: 0,
        blinkCount: _blinks.length,
        yawnCount: _yawns.length,
      );
    }

    final ear = (_ear(p, rightEye) + _ear(p, leftEye)) / 2;
    final mar = _mar(p);
    final pitch = _pitch(p);
    double eyeDur = 0, yawnDur = 0;

    // --- Mata terpejam (abaikan kalau mulut sedang menguap) ---
    if (ear < Thresholds.earClosed && mar < Thresholds.marYawn) {
      if (!_eyeClosed) {
        _eyeClosed = true;
        if (now - _lastBlink >= Thresholds.minBlinkInterval) {
          _blinks.add(now);
          _lastBlink = now;
        }
      }
      _eyeClosedStart ??= now;
      eyeDur = now - _eyeClosedStart!;
    } else {
      _eyeClosed = false;
      _eyeClosedStart = null;
    }

    // --- Menguap (1x per siklus buka-tutup mulut) ---
    if (mar > Thresholds.marYawn) {
      _yawnStart ??= now;
      yawnDur = now - _yawnStart!;
      if (yawnDur >= Thresholds.yawnLimit && !_yawnCounted) {
        _yawns.add(now);
        _yawnDisplayUntil = now + 3.0;
        _yawnCounted = true;
      }
    } else {
      _yawnStart = null;
      _yawnCounted = false;
    }

    // --- Kepala menunduk ---
    if (pitch > Thresholds.headDrop) {
      _headDropStart ??= now;
    } else {
      _headDropStart = null;
    }

    // --- Penentuan status (prioritas bertingkat) ---
    var status = DriverStatus.awake;
    var sub = 'Pengemudi Fokus & Segar';

    if (eyeDur >= Thresholds.eyeClosedLimit) {
      status = DriverStatus.sleep;
      sub = 'BAHAYA: MATA TERPEJAM (${eyeDur.toStringAsFixed(1)}s)!';
    } else if (now < _yawnDisplayUntil || yawnDur >= Thresholds.yawnLimit) {
      status = DriverStatus.yawn;
      sub = 'MENGUAP TERDETEKSI (${_yawns.length}x Total)';
    } else if (_headDropStart != null &&
        now - _headDropStart! >= Thresholds.headDropLimit) {
      status = DriverStatus.drowsy;
      sub = 'PERINGATAN: KEPALA MENUNDUK / TERLELAP';
    } else if (_yawns.length >= Thresholds.yawnAlertFreq) {
      status = DriverStatus.drowsy;
      sub = 'LELAH: ${_yawns.length}x Menguap dalam 5 Mnt';
    } else if (_blinks.length >= Thresholds.highBlinkRate) {
      status = DriverStatus.drowsy;
      sub = 'LELAH: Frekuensi Kedip Tinggi (${_blinks.length}/mnt)';
    }

    return DetectionResult(
      status: status,
      subStatus: sub,
      ear: ear,
      mar: mar,
      blinkCount: _blinks.length,
      yawnCount: _yawns.length,
    );
  }

  /// Reset data akumulasi menguap (misal saat driver konfirmasi sadar / rest area)
  void resetYawns() {
    _yawns.clear();
    _yawnStart = null;
    _yawnCounted = false;
    _yawnDisplayUntil = 0;
  }
}
