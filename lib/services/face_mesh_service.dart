import 'dart:ui' show Offset;

import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

/// Pembungkus model face mesh on-device (pengganti mp_face_mesh.FaceMesh).
class FaceMeshService {
  // Model dimuat sekali di sini
  final FaceMeshDetector _detector =
      FaceMeshDetector(option: FaceMeshDetectorOptions.faceMesh);

  /// Mengembalikan 468 titik wajah, atau null kalau tidak ada wajah.
  Future<List<Offset>?> detect(InputImage image) async {
    final meshes = await _detector.processImage(image);
    if (meshes.isEmpty) return null;

    final pts = List<Offset>.filled(468, Offset.zero);
    for (final p in meshes.first.points) {
      if (p.index >= 0 && p.index < 468) {
        pts[p.index] = Offset(p.x, p.y);
      }
    }
    return pts;
  }

  Future<void> dispose() => _detector.close();
}
