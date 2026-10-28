# Integrasi LLM - Driving Buddy

Kartu Trello: **[BE] Integration API LLM**.
Menambah endpoint `POST /chat` ke `server.py`: pengemudi ngomong, Buddy (LLM) bales singkat dan siap dibacakan TTS.
Satu kode buat semua provider berformat OpenAI (Groq, Gemini, OpenAI, OpenRouter, Ollama), ganti lewat `.env`.

Prinsip: **alarm kantuk tidak boleh bergantung ke LLM.** Kalau LLM mati, lambat, atau key salah, `/chat` tetap jawab
HTTP 200 dengan balasan darurat (`fallback: true`) yang tetap bawa pesan keselamatan. Kalau modul ini gagal dimuat,
`server.py` tetap nyala dan `/ws` jalan normal.

## Pasang

Modul sudah terpasang di repo: folder `llm_chat/`, 7 baris di `server.py` (setelah `app = FastAPI()`),
dan contoh variabel di `.env.example`. Yang perlu dilakukan di laptop yang menjalankan server:

1. `pip install -r requirements-llm.txt`
2. Bikin `.env` di root repo (sudah di `.gitignore`) lalu isi:
   ```
   LLM_PROVIDER=groq
   LLM_API_KEY=gsk_xxxxxxxx
   ```
   API key Groq dibuat sendiri di console.groq.com. Jangan dikirim lewat chat dan jangan di-commit.
3. `python server.py`, lalu buka `http://localhost:8000/docs` buat nyoba lewat browser.

Kalau modul gagal dimuat (misal paket belum di-install), server cuma mencetak `[WARN] Modul LLM tidak dimuat`
dan `/ws` tetap jalan.

Tanpa `.env` modul jalan di **mode mock** (balasan palsu): enak buat anak frontend ngerjain UI tanpa API key.

## Cek cepat

```bash
curl -s localhost:8000/chat/health                 # config kebaca? provider/model apa?
curl -s "localhost:8000/chat/health?deep=true"     # sekalian tes koneksi + key + nama model ke provider (tanpa makan token)

curl -s localhost:8000/chat -H "Content-Type: application/json" -d '{
  "session_id": "demo-1",
  "message": "Aku mulai ngantuk nih",
  "driver_state": {"status": "Drowsy", "yawnCount": 3, "blinkCount": 28}
}'
```

## Kontrak API (buat FE)

`POST /chat`

| Field request | Wajib | Keterangan |
|---|---|---|
| `session_id` | ya | ID percakapan (user id / UUID per perjalanan). Huruf, angka, `_ . : -`, maks 64. Riwayat disimpan per ID. |
| `message` | ya | Ucapan pengemudi, 1-500 karakter. |
| `driver_state` | tidak | Kondisi dari detektor kantuk di aplikasi (`DetectionResult`): `status` (`Awake`/`Yawn`/`Drowsy`/`Sleep`/`No Face`, nama enum Dart seperti `noFace` juga boleh), `yawnCount`, `blinkCount`. Opsional `tripMinutes`. Field lain diabaikan. snake_case juga boleh. |
| `reset` | tidak | `true` = lupakan riwayat sebelum membalas. |

Respons 200:
```json
{"reply": "Wah, kedengarannya kamu mulai capek. Menepi dulu ya, aku tungguin.",
 "session_id": "demo-1", "provider": "groq", "model": "openai/gpt-oss-120b",
 "latency_ms": 412, "fallback": false, "error": null}
```
- `reply`: teks polos, maks 2 kalimat, tanpa emoji/markdown, aman langsung dibacakan TTS.
- `fallback: true` = LLM gagal, `reply` adalah balasan darurat bawaan, `error` isinya penyebab (`timeout`, `network`, `rate_limited`, `auth`, `upstream`, `empty`, ...).

Status lain: `422` request salah format, `429` kebanyakan request (lihat header `Retry-After`), `503` LLM belum dikonfigurasi (isi `detail.message` jelasin kurangnya apa).
`DELETE /chat/{session_id}` hapus riwayat satu sesi.

## Dipanggil dari Flutter

Klien siap pakai ada di `lib/features/llm_chat/` (pakai paket `http` yang sudah ada di `pubspec.yaml`).
UI chat dan input suara/TTS bukan bagian modul ini (kartu Percakapan LLM AI dan voice recog).

```dart
import 'package:driving_buddy/features/llm_chat/llm_chat.dart';

final api = LlmChatApi();
final r = await api.sendSafe(
  sessionId: LlmChatApi.sanitizeSessionId(uid),          // uid Firebase / id perjalanan
  message: 'Aku mulai ngantuk nih',
  driverState: LlmDriverState.fromDetection(result, tripMinutes: 90),
);
print(r.reply);   // teks polos pendek, siap dibacakan TTS
```

- `sendSafe` tidak pernah melempar error: kalau server.py mati atau beda Wi-Fi, hasilnya balasan darurat
  (`fallback: true`, `provider: "offline"`) yang tetap membawa pesan keselamatan.
  `send` melempar `LlmChatException` (`unreachable`, `timeout`, `notConfigured`, `rateLimited`, ...) kalau UI butuh
  membedakannya.
- `health(deep: true)` buat tes koneksi + API key, `clear(sessionId)` buat hapus riwayat saat perjalanan selesai.
- Alamat server (`LlmChatConfig`): emulator Android otomatis `http://10.0.2.2:8000`. HP asli:
  `flutter run --dart-define=LLM_API_BASE_URL=http://IP_LAPTOP:8000` atau `LlmChatConfig.shared.save('IP_LAPTOP:8000')`.
  HP dan laptop harus satu Wi-Fi.
- Kalau nanti dites lewat Flutter **web**, server perlu CORS:
  `from fastapi.middleware.cors import CORSMiddleware; app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])`.

## Ganti provider (`.env`)

```
# Groq (default; ada free tier, cek limit akun di console.groq.com)
LLM_PROVIDER=groq      LLM_API_KEY=gsk_...

# Gemini (free tier ada, tapi data free tier dipakai Google buat ningkatin produknya)
LLM_PROVIDER=gemini    LLM_API_KEY=AIza...

# OpenAI (berbayar per token, nama model wajib diisi)
LLM_PROVIDER=openai    LLM_API_KEY=sk-...   LLM_MODEL=<nama model dari platform.openai.com>

# Server lain yang kompatibel OpenAI (Ollama lokal, OpenRouter, LM Studio)
LLM_PROVIDER=custom    LLM_BASE_URL=http://localhost:11434/v1   LLM_MODEL=llama3.2
```

Pengaturan opsional (semua punya default):

| Variabel | Default | Fungsi |
|---|---|---|
| `LLM_MODEL` | per provider | Nama model. Default Groq `openai/gpt-oss-120b` (Llama 3.3 70B sudah dipensiunkan Groq 16 Agu 2026; alternatif lebih ringan `openai/gpt-oss-20b`), Gemini `gemini-3.1-flash-lite`. Nama model bisa dipensiunkan provider, cek `/chat/health?deep=true`. |
| `LLM_TIMEOUT_S` | 8 | Batas tunggu jawaban. Lewat batas = langsung fallback (tidak diulang). Error jaringan, 5xx, dan 429 pendek dicoba ulang maksimal `LLM_MAX_RETRIES` (1) kali. |
| `LLM_MAX_TOKENS` | Groq 512, Gemini/OpenAI 1024, lainnya 256 | Batas panjang jawaban. Model "thinking" ikut menghitung token berpikirnya. |
| `LLM_REASONING_EFFORT` | Groq & Gemini `low`, lainnya kosong | Hanya dikirim kalau diisi; ditolak provider = otomatis dibuang. |
| `LLM_TEMPERATURE` | 0.7 | Kreativitas. |
| `LLM_HISTORY_TURNS` | 6 | Berapa tanya-jawab terakhir yang diingat Buddy. Makin banyak makin boros token. |
| `LLM_RATE_PER_SESSION_PER_MIN` / `LLM_RATE_GLOBAL_PER_MIN` | 12 / 120 | Pembatas request (0 = mati). |
| `LLM_MAX_REPLY_CHARS` | 280 | Balasan dipotong di akhir kalimat kalau lebih panjang. |
| `LLM_SESSION_TTL_S` / `LLM_MAX_SESSIONS` | 1800 / 500 | Riwayat dibuang kalau 30 menit tidak dipakai. |

Provider yang menolak parameter (misal nama batas token atau `temperature`) ditangani otomatis: client mengulang tanpa
parameter itu dan mengingatnya.

## Kalau ada masalah

| Gejala | Penyebab / solusi |
|---|---|
| `503 llm_not_configured` | Lihat `detail.message` atau `GET /chat/health`: biasanya API key belum diisi / nama model kosong. |
| `fallback: true`, `error: "auth"` | API key salah. Cek `?deep=true`. |
| `error: "not_found"` | Nama model salah/sudah dipensiunkan. |
| `error: "empty"` | Model "thinking" menghabiskan token. Naikkan `LLM_MAX_TOKENS=1024`, pastikan `LLM_REASONING_EFFORT=low`. |
| `error: "rate_limited"` | Kena limit free tier. Tunggu, kurangi `LLM_HISTORY_TURNS`, atau ganti model/provider. |
| `error: "timeout"` | Provider lambat. Naikkan `LLM_TIMEOUT_S` atau pilih model lebih kecil. |

Log `[LLM] ...` di terminal server mencatat provider, latensi, dan jumlah token. Isi percakapan tidak dicatat, API key disamarkan.

## Tes

```bash
pip install pytest
python -m pytest tests_llm -q          # 100+ tes, tanpa internet dan tanpa API key
python tests_llm/fake_openai.py 9100   # provider palsu buat coba manual (lihat komentar di file)
flutter test test/llm_chat_api_test.dart   # klien Flutter (server palsu, tanpa jaringan)
```
Tes mencakup: parsing config, pembersih balasan, riwayat sesi, rate limit, retry/timeout/429/401, adaptasi parameter,
dan end-to-end lewat jaringan localhost ke fake provider.
Belum dites ke Groq/Gemini asli karena butuh API key tim, jadi tes pertama dengan key asli = `?deep=true` lalu satu `curl /chat`.

## Sebelum rilis ke Play Store

- **Belum ada autentikasi.** Siapa pun yang bisa menjangkau server bisa memakai kuota API key. Tambah verifikasi Firebase ID token di `/chat` (dan `/ws`) sebelum server dibuka ke internet.
- API key hanya di `.env` server. Jangan pernah masuk ke aplikasi Flutter (APK bisa dibongkar).
- Riwayat percakapan hanya di memori server dan hilang saat restart. Kalau perlu bertahan, simpan ke Firestore (kartu Percakapan LLM AI).
- Buddy baru menjawab saat diajak bicara. Memulai obrolan sendiri saat status `Drowsy` (proaktif) dan input suara itu kerjaan kartu voice recognition / Percakapan.
