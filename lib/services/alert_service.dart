import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../core/thresholds.dart';
import '../models/detection_result.dart';
import 'alert_config.dart';

/// Alarm suara + getar saat status Sleep atau Drowsy.
class AlertService {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isPlaying => _playing;

  Future<void> onStatus(DriverStatus status) async {
    final isAlert =
        status == DriverStatus.sleep || status == DriverStatus.drowsy;

    if (isAlert) {
      await playAlert();
    }
  }

  Future<void> playAlert() async {
    final now = DateTime.now();
    if (now.difference(_lastHaptic) >= Thresholds.alertCooldown) {
      _lastHaptic = now;
      HapticFeedback.heavyImpact();
    }

    if (!_playing) {
      _playing = true;
      await _player.setReleaseMode(ReleaseMode.loop);
      final audioType = await AlertConfig.getAudioType();
      if (audioType == AlertAudioType.customFile) {
        final path = await AlertConfig.getCustomAudioPath();
        if (path != null && File(path).existsSync()) {
          await _player.play(DeviceFileSource(path));
          return;
        }
      } else if (audioType == AlertAudioType.loudBeep) {
        await _player.play(AssetSource('sounds/beep.wav'));
        return;
      } else if (audioType == AlertAudioType.buzzer) {
        await _player.play(AssetSource('sounds/buzzer.wav'));
        return;
      }
      try {
        await _player.play(AssetSource('audio/alarm.mp3'));
      } catch (_) {
        await _player.play(AssetSource('sounds/alarm.mp3'));
      }
    }
  }

  Future<void> stop() async {
    if (_playing) {
      _playing = false;
      await _player.stop();
    }
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
