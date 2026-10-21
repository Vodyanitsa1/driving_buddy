import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Imports
code = code.replace("import 'package:tflite_flutter/tflite_flutter.dart';", "import 'package:web_socket_channel/web_socket_channel.dart';\nimport 'dart:convert';")
code = code.replace("import 'package:image/image.dart' as imglib;", "")

# 2. State fields
code = code.replace("Interpreter? _interpreter;", "WebSocketChannel? _channel;")

# 3. Dispose
code = code.replace("_interpreter?.close();", "_channel?.sink.close();")
code = code.replace("_interpreter = null;", "_channel = null;")

# 4. Init
init_tflite_pattern = r"// 2\. Init TFLite.*?_interpreter!\.allocateTensors\(\); // WAJIB: inisialisasi tensor sebelum inferensi"
init_ws = """// 2. Konek WebSocket ke Laptop
      _channel = WebSocketChannel.connect(Uri.parse('ws://192.168.10.19:8000/ws'));
      _channel?.stream.listen((message) {
        if (!mounted) return;
        try {
          final data = jsonDecode(message);
          setState(() {
            _driverCondition = data['status']?.toString().toUpperCase() ?? 'AWAKE';
            _conditionDescription = data['subStatus']?.toString() ?? 'Pengemudi Fokus';
            
            final e = data['ear'] as num?;
            if (e != null) {
              _eyeOpenness = (e / 0.30).clamp(0.0, 1.0);
            }
            
            final b = data['blinkCount'] as int?;
            if (b != null) _blinkCount = b;
            
            final y = data['yawnCount'] as int?;
            if (y != null) _yawnCount = y;

            if (_driverCondition == 'SLEEP' || _driverCondition == 'MICROSLEEP') {
              _triggerMicrosleepAlert();
            }
          });
        } catch (e) {
          debugPrint('JSON parse error: $e');
        }
      }, onError: (e) {
        debugPrint('WebSocket error: $e');
      }, onDone: () {
        debugPrint('WebSocket ditutup.');
      });"""
code = re.sub(init_tflite_pattern, init_ws, code, flags=re.DOTALL)

# 5. Process loop
loop_pattern = r"final eyeOpenness = await _runTFLiteLandmark\(tempPath\);\s+if \(mounted\) _updateDrowsinessState\(eyeOpenness\);"
loop_ws = """final bytes = await File(tempPath).readAsBytes();
          _channel?.sink.add(base64Encode(bytes));"""
code = re.sub(loop_pattern, loop_ws, code)

# 6. Delete _runTFLiteLandmark, _computeEARList, _updateDrowsinessState completely
code = re.sub(r"// ---------- TFLite Inference — MediaPipe Face Landmark ----------.*?\s+void _stopMonitoring", "  void _stopMonitoring", code, flags=re.DOTALL)


with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(code)
print("Patched!")
