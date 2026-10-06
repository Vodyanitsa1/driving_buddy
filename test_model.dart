import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  final interpreter = Interpreter.fromFile('assets/models/face_landmark.tflite');
  
  print("INPUTS:");
  for (var tensor in interpreter.getInputTensors()) {
    print("Name: ${tensor.name}, Shape: ${tensor.shape}, Type: ${tensor.type}");
  }
  
  print("\nOUTPUTS:");
  for (var tensor in interpreter.getOutputTensors()) {
    print("Name: ${tensor.name}, Shape: ${tensor.shape}, Type: ${tensor.type}");
  }
}
