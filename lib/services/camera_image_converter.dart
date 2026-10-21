import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

const _orientations = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Mengubah CameraImage menjadi InputImage (termasuk rotasi sensor).
/// Mendukung NV21 1-plane maupun YUV420 3-plane (umum di HP Vivo/Xiaomi/Samsung).
InputImage? cameraImageToInputImage(
  CameraImage image,
  CameraDescription camera,
  DeviceOrientation deviceOrientation,
) {
  final sensorOrientation = camera.sensorOrientation;
  InputImageRotation? rotation;

  if (Platform.isIOS) {
    rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
  } else if (Platform.isAndroid) {
    var compensation = _orientations[deviceOrientation];
    if (compensation == null) return null;
    if (camera.lensDirection == CameraLensDirection.front) {
      compensation = (sensorOrientation + compensation) % 360;
    } else {
      compensation = (sensorOrientation - compensation + 360) % 360;
    }
    rotation = InputImageRotationValue.fromRawValue(compensation);
  }
  if (rotation == null) return null;

  Uint8List bytes;
  int bytesPerRow;
  InputImageFormat format;

  if (Platform.isAndroid) {
    if (image.planes.length == 1) {
      // Perangkat yang langsung menghasilkan 1 bidang NV21
      bytes = image.planes.first.bytes;
      bytesPerRow = image.planes.first.bytesPerRow;
      format = InputImageFormat.nv21;
    } else if (image.planes.length == 3) {
      // Perangkat dengan 3 bidang YUV420 (Vivo, iQOO, Xiaomi, dll)
      bytes = _yuv420ToNv21(image);
      bytesPerRow = image.width;
      format = InputImageFormat.nv21;
    } else {
      return null;
    }
  } else if (Platform.isIOS) {
    if (image.planes.isEmpty) return null;
    bytes = image.planes.first.bytes;
    bytesPerRow = image.planes.first.bytesPerRow;
    format = InputImageFormat.bgra8888;
  } else {
    return null;
  }

  return InputImage.fromBytes(
    bytes: bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: bytesPerRow,
    ),
  );
}

/// Menggabungkan 3 plane YUV_420_888 menjadi 1 buffer NV21
Uint8List _yuv420ToNv21(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final yBuffer = yPlane.bytes;
  final uBuffer = uPlane.bytes;
  final vBuffer = vPlane.bytes;

  final numPixels = width * height;
  final nv21 = Uint8List(numPixels + (numPixels ~/ 2));

  // 1. Salin bidang Y
  final yRowStride = yPlane.bytesPerRow;
  if (yRowStride == width) {
    nv21.setRange(0, numPixels, yBuffer);
  } else {
    for (int row = 0; row < height; row++) {
      nv21.setRange(
        row * width,
        (row + 1) * width,
        yBuffer,
        row * yRowStride,
      );
    }
  }

  // 2. Interleave V dan U (format NV21 adalah V, U, V, U...)
  final uvHeight = height ~/ 2;
  final uvWidth = width ~/ 2;
  final uRowStride = uPlane.bytesPerRow;
  final uPixelStride = uPlane.bytesPerPixel ?? 1;
  final vRowStride = vPlane.bytesPerRow;
  final vPixelStride = vPlane.bytesPerPixel ?? 1;

  int uvIndex = numPixels;
  for (int row = 0; row < uvHeight; row++) {
    for (int col = 0; col < uvWidth; col++) {
      final vIndex = row * vRowStride + col * vPixelStride;
      final uIndex = row * uRowStride + col * uPixelStride;
      if (vIndex < vBuffer.length) {
        nv21[uvIndex++] = vBuffer[vIndex];
      } else {
        uvIndex++;
      }
      if (uIndex < uBuffer.length) {
        nv21[uvIndex++] = uBuffer[uIndex];
      } else {
        uvIndex++;
      }
    }
  }

  return nv21;
}
