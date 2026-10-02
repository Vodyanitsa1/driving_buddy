import base64
import cv2
import mediapipe as mp
import numpy as np
import time
from collections import deque
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

# =====================================================================
# 1. KONFIGURASI THRESHOLD
# =====================================================================
EAR_CLOSED_THRESH     = 0.19   # EAR di bawah ini = mata dianggap tertutup
MAR_YAWN_THRESH       = 0.55   # MAR di atas ini = menguap
HEAD_DROP_THRESH      = 0.68   # pitch ratio > ini = kepala nunduk
EYE_CLOSED_TIME_LIMIT = 5.00   # detik mata terpejam sebelum trigger SLEEP (diubah ke 5 dtk)
YAWN_TIME_LIMIT       = 1.5    # detik menguap sebelum dicatat
HEAD_DROP_TIME_LIMIT  = 2.00   # detik kepala nunduk sebelum trigger Drowsy
YAWN_COOLDOWN_SEC     = 5.00   # jeda minimum antar-yawn yang dicatat
YAWN_WINDOW_SEC       = 300    # jendela waktu 5 menit untuk hitung akumulasi yawn
YAWN_ALERT_FREQ       = 3.00   # jumlah yawn dalam 5 mnt sebelum trigger Drowsy
HIGH_BLINK_RATE_LIMIT = 35     # kedipan/mnt sebelum trigger Drowsy

# Indeks Landmark
RIGHT_EYE   = [33, 160, 158, 133, 153, 144]
LEFT_EYE    = [362, 385, 387, 263, 373, 380]
MOUTH_OUTER = [61, 291, 39, 181, 0, 17, 269, 405]

mp_face_mesh = mp.solutions.face_mesh
app = FastAPI()

def euclidean_dist(p1, p2):
    return float(np.linalg.norm(np.array(p1) - np.array(p2)))

def calculate_EAR(landmarks, eye_indices, w, h):
    pts = [(landmarks[i].x * w, landmarks[i].y * h) for i in eye_indices]
    v1 = euclidean_dist(pts[1], pts[5])
    v2 = euclidean_dist(pts[2], pts[4])
    h_dist = euclidean_dist(pts[0], pts[3])
    if h_dist == 0: return 0.0
    return (v1 + v2) / (2.0 * h_dist)

def calculate_MAR(landmarks, w, h):
    left_corner  = (landmarks[61].x * w, landmarks[61].y * h)
    right_corner = (landmarks[291].x * w, landmarks[291].y * h)
    top          = (landmarks[13].x * w, landmarks[13].y * h)
    bottom       = (landmarks[14].x * w, landmarks[14].y * h)
    
    mouth_w = euclidean_dist(left_corner, right_corner)
    mouth_h = euclidean_dist(top, bottom)
    if mouth_w == 0: return 0.0
    return mouth_h / mouth_w

def estimate_head_pose(landmarks, w, h):
    nose_tip    = (landmarks[1].x * w, landmarks[1].y * h)
    chin        = (landmarks[199].x * w, landmarks[199].y * h)
    left_cheek  = (landmarks[234].x * w, landmarks[234].y * h)
    right_cheek = (landmarks[454].x * w, landmarks[454].y * h)
    forehead    = (landmarks[10].x * w, landmarks[10].y * h)
    
    face_h = euclidean_dist(forehead, chin)
    nose_to_chin = euclidean_dist(nose_tip, chin)
    pitch_ratio = nose_to_chin / face_h if face_h > 0 else 0.5
    
    face_w = euclidean_dist(left_cheek, right_cheek)
    nose_to_left = euclidean_dist(nose_tip, left_cheek)
    yaw_ratio = nose_to_left / face_w if face_w > 0 else 0.5
    return pitch_ratio, yaw_ratio, 0.0

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    print("[INFO] Klien terhubung ke WebSocket.")

    eye_closed_start_time = None
    yawn_start_time       = None
    head_drop_start_time  = None
    last_yawn_time        = 0
    yawn_display_until    = 0
    
    yawn_history  = deque()
    blink_history = deque()
    is_eye_currently_closed = False

    with mp_face_mesh.FaceMesh(
        max_num_faces=1, refine_landmarks=True,
        min_detection_confidence=0.5, min_tracking_confidence=0.5
    ) as face_mesh:

        try:
            while True:
                base64_str = await websocket.receive_text()
                current_time = time.time()
                
                img_data = base64.b64decode(base64_str)
                nparr = np.frombuffer(img_data, np.uint8)
                frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

                if frame is None:
                    continue

                h, w, _ = frame.shape
                
                while yawn_history and (current_time - yawn_history[0] > YAWN_WINDOW_SEC):
                    yawn_history.popleft()
                while blink_history and (current_time - blink_history[0] > 60):
                    blink_history.popleft()

                rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                results = face_mesh.process(rgb_frame)

                status = "Awake"
                sub_status = "Pengemudi Fokus & Segar"
                avg_ear, mar, pitch_ratio, eye_close_dur = 0.0, 0.0, 0.5, 0.0
                
                # Variabel penampung koordinat untuk digambar di Flutter
                eye_pts_out = []
                mouth_pts_out = []

                if results.multi_face_landmarks:
                    landmarks = results.multi_face_landmarks[0].landmark

                    # Ekstrak titik koordinat mata
                    for idx in RIGHT_EYE + LEFT_EYE:
                        eye_pts_out.append({"x": landmarks[idx].x, "y": landmarks[idx].y})
                    # Ekstrak titik koordinat mulut
                    for idx in MOUTH_OUTER:
                        mouth_pts_out.append({"x": landmarks[idx].x, "y": landmarks[idx].y})

                    # Kalkulasi
                    right_ear = calculate_EAR(landmarks, RIGHT_EYE, w, h)
                    left_ear  = calculate_EAR(landmarks, LEFT_EYE, w, h)
                    avg_ear   = (right_ear + left_ear) / 2.0
                    mar       = calculate_MAR(landmarks, w, h)
                    pitch_ratio, _, _ = estimate_head_pose(landmarks, w, h)

                    # Logika Mata Terpejam
                    if avg_ear < EAR_CLOSED_THRESH and mar < MAR_YAWN_THRESH:
                        if not is_eye_currently_closed:
                            is_eye_currently_closed = True
                            blink_history.append(current_time)
                        if eye_closed_start_time is None:
                            eye_closed_start_time = current_time
                        eye_close_dur = current_time - eye_closed_start_time
                    else:
                        is_eye_currently_closed = False
                        eye_closed_start_time = None
                        eye_close_dur = 0.0

                    # Logika Menguap
                    if mar > MAR_YAWN_THRESH:
                        if yawn_start_time is None:
                            yawn_start_time = current_time
                        yawn_dur = current_time - yawn_start_time
                        if yawn_dur >= YAWN_TIME_LIMIT:
                            if (current_time - last_yawn_time) > YAWN_COOLDOWN_SEC:
                                yawn_history.append(current_time)
                                last_yawn_time = current_time
                                yawn_display_until = current_time + 3.0
                    else:
                        yawn_start_time = None
                        yawn_dur = 0.0

                    # Logika Kepala (Head Drop) - Pemicu "Drowsy"
                    if pitch_ratio > HEAD_DROP_THRESH:
                        if head_drop_start_time is None:
                            head_drop_start_time = current_time
                    else:
                        head_drop_start_time = None

                    # --- PENENTUAN STATUS ---
                    if eye_close_dur >= EYE_CLOSED_TIME_LIMIT:
                        status = "Sleep"
                        sub_status = f"BAHAYA: MATA TERPEJAM ({eye_close_dur:.1f}s)!"
                        # Bunyi alarm ditangani oleh HP (Flutter) — tidak dari laptop
                    elif (current_time < yawn_display_until) or (yawn_dur >= YAWN_TIME_LIMIT):
                        status = "Yawn"
                        sub_status = f"MENGUAP TERDETEKSI ({len(yawn_history)}x Total)"
                    
                    # INI PEMICU DROWSY 1: Kepala Nunduk
                    elif head_drop_start_time and (current_time - head_drop_start_time >= HEAD_DROP_TIME_LIMIT):
                        status = "Drowsy"
                        sub_status = "PERINGATAN: KEPALA MENUNDUK"
                        
                    # INI PEMICU DROWSY 2: Akumulasi Kelelahan (Sering Menguap)
                    elif len(yawn_history) >= YAWN_ALERT_FREQ:
                        status = "Drowsy"
                        sub_status = f"LELAH: {len(yawn_history)}x Menguap dalam 5 Mnt"
                        
                    # INI PEMICU DROWSY 3: Kedipan Berlebihan
                    elif len(blink_history) >= HIGH_BLINK_RATE_LIMIT:
                        status = "Drowsy"
                        sub_status = f"LELAH: Frekuensi Kedip Tinggi ({len(blink_history)}/mnt)"

                else:
                    status = "No Face"
                    sub_status = "WAJAH TIDAK TERDETEKSI"

                # Payload Response
                response_data = {
                    "status": status,
                    "subStatus": sub_status,
                    "ear": round(avg_ear, 3),
                    "mar": round(mar, 3),
                    "blinkCount": len(blink_history),  # jumlah kedipan dalam 60 detik terakhir
                    "eyePoints": eye_pts_out,
                    "mouthPoints": mouth_pts_out
                }
                
                await websocket.send_json(response_data)

        except WebSocketDisconnect:
            print("[INFO] Klien terputus.")
        except Exception as e:
            print(f"[ERROR] Terjadi kesalahan: {e}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
