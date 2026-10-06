"""
=============================================================================
DRIVING BUDDY - WEBSOCKET SERVER (PRETRAINED MEDIAPIPE MODEL)
=============================================================================
Server FastAPI WebSocket untuk deteksi kantuk pengemudi.
Menerima frame kamera HP (Base64 JPEG) via WebSocket,
memproses dengan MediaPipe Face Mesh, dan mengirimkan hasil JSON.

Sinkron dengan demo_pretrained.py — threshold & logika identik.
Tidak ada winsound (alarm ditangani oleh HP/Flutter).
=============================================================================
"""

import base64
import cv2
import mediapipe as mp
import numpy as np
import time
from collections import deque
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

# =====================================================================
# 1. KONFIGURASI PARAMETER & THRESHOLD
# =====================================================================
# Threshold Geometris Fitur Wajah
EAR_CLOSED_THRESH     = 0.15   # Ambang mata tertutup (sama dengan demo_pretrained.py)
MAR_YAWN_THRESH       = 0.35   # Ambang mulut menguap
HEAD_DROP_THRESH      = 0.68   # Ambang kepala menunduk ke bawah

# Ambang Batas Durasi Waktu (Detik)
EYE_CLOSED_TIME_LIMIT = 1.7   # Mata terpejam >= 1.6s -> Trigger SLEEP / MICROSLEEP
YAWN_TIME_LIMIT       = 1.20   # Mulut terbuka >= 1.2s -> Status YAWN DETECTED
HEAD_DROP_TIME_LIMIT  = 2.00   # Kepala menunduk >= 2.0s -> Peringatan DROWSY
YAWN_COOLDOWN_SEC     = 3.5    # Jeda antar menguap agar tidak terhitung ganda
YAWN_WINDOW_SEC       = 300    # Jendela pantau 5 menit (300 detik)
YAWN_ALERT_FREQ       = 4      # >= 4x Yawn dalam 5 menit -> Masuk Status DROWSY
HIGH_BLINK_RATE_LIMIT = 35     # Batas kedipan lelah per menit
MIN_BLINK_INTERVAL    = 0.20   # Minimum 200ms antar kedipan (debounce noise kamera)

# Indeks Landmark Wajah (Google MediaPipe Face Mesh)
RIGHT_EYE   = [33, 160, 158, 133, 153, 144]
LEFT_EYE    = [362, 385, 387, 263, 373, 380]
MOUTH_OUTER = [61, 291, 39, 181, 0, 17, 269, 405]

mp_face_mesh = mp.solutions.face_mesh
app = FastAPI()

# =====================================================================
# 2. FUNGSI KALKULASI GEOMETRI WAJAH
# =====================================================================
def euclidean_dist(p1, p2):
    return float(np.linalg.norm(np.array(p1) - np.array(p2)))

def calculate_EAR(landmarks, eye_indices, w, h):
    """Menghitung Eye Aspect Ratio (EAR)"""
    pts = [(landmarks[i].x * w, landmarks[i].y * h) for i in eye_indices]
    v1 = euclidean_dist(pts[1], pts[5])
    v2 = euclidean_dist(pts[2], pts[4])
    h_dist = euclidean_dist(pts[0], pts[3])
    if h_dist == 0:
        return 0.0
    return (v1 + v2) / (2.0 * h_dist)

def calculate_MAR(landmarks, w, h):
    """Menghitung Mouth Aspect Ratio (MAR)"""
    left_corner  = (landmarks[61].x * w, landmarks[61].y * h)
    right_corner = (landmarks[291].x * w, landmarks[291].y * h)
    top          = (landmarks[13].x * w, landmarks[13].y * h)
    bottom       = (landmarks[14].x * w, landmarks[14].y * h)
    mouth_w = euclidean_dist(left_corner, right_corner)
    mouth_h = euclidean_dist(top, bottom)
    if mouth_w == 0:
        return 0.0
    return mouth_h / mouth_w

def estimate_head_pose(landmarks, w, h):
    """Estimasi orientasi kepala (Pitch, Yaw, Roll)"""
    nose_tip    = (landmarks[1].x * w,   landmarks[1].y * h)
    chin        = (landmarks[199].x * w, landmarks[199].y * h)
    left_cheek  = (landmarks[234].x * w, landmarks[234].y * h)
    right_cheek = (landmarks[454].x * w, landmarks[454].y * h)
    forehead    = (landmarks[10].x * w,  landmarks[10].y * h)

    face_h = euclidean_dist(forehead, chin)
    nose_to_chin = euclidean_dist(nose_tip, chin)
    pitch_ratio = nose_to_chin / face_h if face_h > 0 else 0.5

    face_w = euclidean_dist(left_cheek, right_cheek)
    nose_to_left = euclidean_dist(nose_tip, left_cheek)
    yaw_ratio = nose_to_left / face_w if face_w > 0 else 0.5

    # Roll / Tilt angle (sama dengan demo_pretrained.py)
    r_eye = (
        (landmarks[33].x + landmarks[133].x) * 0.5 * w,
        (landmarks[33].y + landmarks[133].y) * 0.5 * h,
    )
    l_eye = (
        (landmarks[362].x + landmarks[263].x) * 0.5 * w,
        (landmarks[362].y + landmarks[263].y) * 0.5 * h,
    )
    dy = l_eye[1] - r_eye[1]
    dx = l_eye[0] - r_eye[0]
    roll_angle = float(np.degrees(np.arctan2(dy, dx))) if dx != 0 else 0.0

    return pitch_ratio, yaw_ratio, roll_angle

# =====================================================================
# 3. WEBSOCKET ENDPOINT
# =====================================================================
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("[INFO] Klien HP terhubung ke WebSocket.")

    # State tracking — satu instance per koneksi klien
    eye_closed_start_time   = None
    yawn_start_time         = None
    head_drop_start_time    = None
    last_yawn_time          = 0
    last_blink_time         = 0     # Waktu kedipan terakhir dicatat (untuk debounce)
    yawn_display_until      = 0
    yawn_counted_this_cycle = False  # Hitung 1x per siklus buka-tutup mulut

    yawn_history  = deque()
    blink_history = deque()
    is_eye_currently_closed = False

    with mp_face_mesh.FaceMesh(
        max_num_faces=1,
        refine_landmarks=True,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    ) as face_mesh:

        try:
            while True:
                # Terima frame dari HP (Base64 JPEG string)
                base64_str = await websocket.receive_text()
                current_time = time.time()

                # Decode Base64 → OpenCV frame
                img_data = base64.b64decode(base64_str)
                nparr    = np.frombuffer(img_data, np.uint8)
                frame    = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

                if frame is None:
                    continue

                h, w, _ = frame.shape

                # Bersihkan history yang sudah kadaluarsa
                while yawn_history  and (current_time - yawn_history[0]  > YAWN_WINDOW_SEC):
                    yawn_history.popleft()
                while blink_history and (current_time - blink_history[0] > 60):
                    blink_history.popleft()

                # Inference MediaPipe Face Mesh
                rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                results   = face_mesh.process(rgb_frame)

                # Default values
                status        = "Awake"
                sub_status    = "Pengemudi Fokus & Segar"
                avg_ear       = 0.0
                mar           = 0.0
                pitch_ratio   = 0.5
                eye_close_dur = 0.0
                yawn_dur      = 0.0
                eye_pts_out   = []
                mouth_pts_out = []

                if results.multi_face_landmarks:
                    landmarks = results.multi_face_landmarks[0].landmark

                    # Ekstrak koordinat untuk dikirim ke Flutter
                    for idx in RIGHT_EYE + LEFT_EYE:
                        eye_pts_out.append({"x": landmarks[idx].x, "y": landmarks[idx].y})
                    for idx in MOUTH_OUTER:
                        mouth_pts_out.append({"x": landmarks[idx].x, "y": landmarks[idx].y})

                    # Kalkulasi fitur geometris
                    right_ear = calculate_EAR(landmarks, RIGHT_EYE, w, h)
                    left_ear  = calculate_EAR(landmarks, LEFT_EYE,  w, h)
                    avg_ear   = (right_ear + left_ear) / 2.0
                    mar       = calculate_MAR(landmarks, w, h)
                    pitch_ratio, yaw_ratio, roll_angle = estimate_head_pose(landmarks, w, h)

                    # --- Deteksi Mata Terpejam (Blink & Eye Duration) ---
                    # Abaikan jika mulut sedang terbuka lebar (menguap)
                    if avg_ear < EAR_CLOSED_THRESH and mar < MAR_YAWN_THRESH:
                        if not is_eye_currently_closed:
                            is_eye_currently_closed = True
                            # Debounce: hanya catat blink jika sudah lewat MIN_BLINK_INTERVAL
                            # sejak kedipan terakhir (cegah noise kamera dihitung sebagai blink)
                            if (current_time - last_blink_time) >= MIN_BLINK_INTERVAL:
                                blink_history.append(current_time)
                                last_blink_time = current_time
                        if eye_closed_start_time is None:
                            eye_closed_start_time = current_time
                        eye_close_dur = current_time - eye_closed_start_time
                    else:
                        is_eye_currently_closed = False
                        eye_closed_start_time   = None
                        eye_close_dur           = 0.0

                    # --- Deteksi Menguap (Yawn) ---
                    # Siklus: Mulut buka >= YAWN_TIME_LIMIT -> hitung 1x -> HARUS tutup dulu
                    if mar > MAR_YAWN_THRESH:
                        if yawn_start_time is None:
                            yawn_start_time = current_time
                        yawn_dur = current_time - yawn_start_time
                        if yawn_dur >= YAWN_TIME_LIMIT and not yawn_counted_this_cycle:
                            yawn_history.append(current_time)
                            last_yawn_time          = current_time
                            yawn_display_until      = current_time + 3.0
                            yawn_counted_this_cycle = True  # Tandai sudah dihitung siklus ini
                    else:
                        yawn_start_time         = None
                        yawn_dur                = 0.0
                        yawn_counted_this_cycle = False  # Reset saat mulut menutup

                    # --- Deteksi Kepala Menunduk (Head Drop) ---
                    if pitch_ratio > HEAD_DROP_THRESH:
                        if head_drop_start_time is None:
                            head_drop_start_time = current_time
                    else:
                        head_drop_start_time = None

                    # --- PENENTUAN STATUS (Prioritas Bertingkat) ---

                    # Prioritas 1: Mata terpejam lama -> SLEEP / MICROSLEEP
                    if eye_close_dur >= EYE_CLOSED_TIME_LIMIT:
                        status     = "Sleep"
                        sub_status = f"BAHAYA: MATA TERPEJAM ({eye_close_dur:.1f}s)!"
                        # Alarm ditangani oleh HP (Flutter HapticFeedback / audio)

                    # Prioritas 2: Sedang menguap
                    elif (current_time < yawn_display_until) or (yawn_dur >= YAWN_TIME_LIMIT):
                        status     = "Yawn"
                        sub_status = f"MENGUAP TERDETEKSI ({len(yawn_history)}x Total)"

                    # Prioritas 3: Kepala menunduk lama
                    elif head_drop_start_time and (current_time - head_drop_start_time >= HEAD_DROP_TIME_LIMIT):
                        status     = "Drowsy"
                        sub_status = "PERINGATAN: KEPALA MENUNDUK / TERLELAP"

                    # Prioritas 4: Akumulasi kelelahan (sering menguap)
                    elif len(yawn_history) >= YAWN_ALERT_FREQ:
                        status     = "Drowsy"
                        sub_status = f"LELAH: {len(yawn_history)}x Menguap dalam 5 Mnt"

                    # Prioritas 5: Frekuensi kedip berlebihan
                    elif len(blink_history) >= HIGH_BLINK_RATE_LIMIT:
                        status     = "Drowsy"
                        sub_status = f"LELAH: Frekuensi Kedip Tinggi ({len(blink_history)}/mnt)"

                    else:
                        status     = "Awake"
                        sub_status = "Pengemudi Fokus & Segar"

                else:
                    # Wajah tidak terdeteksi (menengok / keluar frame)
                    status     = "No Face"
                    sub_status = "WAJAH TIDAK TERDETEKSI / MENENGOK"
                    avg_ear    = 0.0
                    mar        = 0.0

                # Payload JSON → dikirim ke Flutter
                response_data = {
                    "status":      status,
                    "subStatus":   sub_status,
                    "ear":         round(avg_ear, 3),
                    "mar":         round(mar, 3),
                    "blinkCount":  len(blink_history),   # kedipan dalam 60 detik terakhir
                    "yawnCount":   len(yawn_history),    # menguap dalam 5 menit terakhir
                    "eyePoints":   eye_pts_out,
                    "mouthPoints": mouth_pts_out,
                }

                await websocket.send_json(response_data)

        except WebSocketDisconnect:
            print("[INFO] Klien HP terputus.")
        except Exception as e:
            print(f"[ERROR] Terjadi kesalahan: {e}")

if __name__ == "__main__":
    import uvicorn
    print("=" * 60)
    print(" [START] DRIVING BUDDY - WEBSOCKET SERVER")
    print("=" * 60)
    print(" Endpoint : ws://[IP_LAPTOP]:8000/ws")
    print(" Model    : Google MediaPipe Face Mesh (Pretrained)")
    print(" Ctrl+C   : Hentikan server")
    print("=" * 60)
    uvicorn.run(app, host="0.0.0.0", port=8000)
