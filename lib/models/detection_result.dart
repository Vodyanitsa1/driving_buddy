enum DriverStatus { awake, sleep, yawn, drowsy, noFace }

class DetectionResult {
  final DriverStatus status;
  final String subStatus;
  final double ear;
  final double mar;
  final int blinkCount; // kedipan dalam 60 detik terakhir
  final int yawnCount; // menguap dalam 5 menit terakhir

  const DetectionResult({
    required this.status,
    required this.subStatus,
    required this.ear,
    required this.mar,
    required this.blinkCount,
    required this.yawnCount,
  });

  static const initial = DetectionResult(
    status: DriverStatus.awake,
    subStatus: 'Menunggu wajah...',
    ear: 0,
    mar: 0,
    blinkCount: 0,
    yawnCount: 0,
  );
}
