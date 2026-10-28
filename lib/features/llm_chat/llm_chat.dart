// Integrasi LLM (kartu Trello: [BE] Integration API LLM).
//
// Aplikasi TIDAK memanggil Groq/LLM langsung. Semua lewat server.py (modul
// llm_chat, POST /chat); API key hanya di .env server. Lihat README_LLM.md.
//
// Contoh pakai (UI chat dan suara = kartu Percakapan LLM AI & voice recog):
//
//   final api = LlmChatApi();
//   final r = await api.sendSafe(
//     sessionId: LlmChatApi.sanitizeSessionId(uid),
//     message: 'Aku mulai ngantuk nih',
//     driverState: LlmDriverState.fromDetection(result, tripMinutes: 90),
//   );
//   print(r.reply); // teks polos pendek, siap dibacakan TTS
//
// Alamat server: LlmChatConfig (emulator Android bawaannya http://10.0.2.2:8000;
// HP asli: --dart-define=LLM_API_BASE_URL=http://IP_LAPTOP:8000 atau LlmChatConfig.shared.save()).

export 'llm_chat_api.dart';
export 'llm_chat_config.dart';
export 'llm_chat_models.dart';
