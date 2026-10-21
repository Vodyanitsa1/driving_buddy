import 'package:flutter/material.dart';

import '../data/places_api.dart';
import '../data/places_config.dart';
import 'places_style.dart';

// ============================================================================
// DIALOG "ATUR SERVER" — alamat server FastAPI (server.py) yang menjalankan
// fitur tempat terdekat. Tersimpan di HP (SharedPreferences).
//
// Kenapa perlu: aplikasi ini jalan di HP, sedangkan server.py jalan di laptop.
// "127.0.0.1" di HP = HP itu sendiri, jadi alamatnya harus IP laptop di jaringan
// yang sama, mis. 192.168.1.10:8000. (Emulator Android: 10.0.2.2:8000.)
// KUNCI GOOGLE TIDAK PERNAH ADA DI APLIKASI — hanya di .env server.
// ============================================================================

/// Tampilkan dialog. Mengembalikan `true` kalau alamat berubah (disimpan / di-reset),
/// supaya pemanggil bisa mencari ulang.
Future<bool> showPlacesServerDialog(
  BuildContext context, {
  PlacesConfig? config,
  PlacesApi Function(PlacesConfig config)? apiBuilder,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => PlacesServerDialog(
      config: config ?? PlacesConfig.shared,
      apiBuilder: apiBuilder,
    ),
  );
  return changed ?? false;
}

/// Ringkasan jawaban `GET /places/health` untuk pengguna.
String describeHealth(Map<String, dynamic> info) {
  final provider = info['provider']?.toString() ?? '?';
  if (info['status'] == 'ok') {
    final fallback = info['fallback_provider']?.toString() ?? '';
    final extra = fallback.isEmpty ? '' : ' (cadangan: $fallback)';
    return 'Terhubung. Penyedia peta: $provider$extra.';
  }
  final problem = info['problem']?.toString() ?? '';
  return 'Server terhubung, tapi fitur belum siap: '
      '${problem.isEmpty ? 'buka /places/health di server untuk detailnya.' : problem}';
}

class PlacesServerDialog extends StatefulWidget {
  const PlacesServerDialog({
    super.key,
    required this.config,
    this.apiBuilder,
  });

  final PlacesConfig config;

  /// Pembuat klien untuk "Tes koneksi" (diganti versi palsu di tes).
  final PlacesApi Function(PlacesConfig config)? apiBuilder;

  @override
  State<PlacesServerDialog> createState() => _PlacesServerDialogState();
}

class _PlacesServerDialogState extends State<PlacesServerDialog> {
  static const String _invalidText =
      'Alamat tidak valid. Contoh: 192.168.1.10:8000';

  late final TextEditingController _text;
  bool _testing = false;
  bool? _ok;
  String? _message;
  String? _fieldError;

  static PlacesApi _defaultApi(PlacesConfig config) =>
      HttpPlacesApi(config: config, timeout: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.config.baseUrl);
    _showSavedAddress();
  }

  /// Alamat tersimpan baru terbaca setelah `load()`; tampilkan kalau pengguna belum mengetik.
  Future<void> _showSavedAddress() async {
    final before = widget.config.baseUrl;
    await widget.config.load();
    if (!mounted) return;
    if (_text.text == before && widget.config.baseUrl != before) {
      _text.text = widget.config.baseUrl;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final normalized = PlacesConfig.normalizeBaseUrl(_text.text);
    if (normalized == null) {
      setState(() {
        _fieldError = _invalidText;
        _ok = null;
        _message = null;
      });
      return;
    }
    setState(() {
      _fieldError = null;
      _testing = true;
      _ok = null;
      _message = null;
    });
    final makeApi = widget.apiBuilder ?? _defaultApi;
    final api = makeApi(PlacesConfig(baseUrl: normalized));
    try {
      final info = await api.health();
      if (!mounted) return;
      setState(() {
        _ok = info['status'] == 'ok';
        _message = describeHealth(info);
      });
    } on PlacesApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _message = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _message = 'Tes gagal: $e';
      });
    } finally {
      api.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final saved = await widget.config.save(_text.text);
    if (!mounted) return;
    if (!saved) {
      setState(() => _fieldError = _invalidText);
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _reset() async {
    await widget.config.reset();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    final ok = _ok == true;
    return AlertDialog(
      title: const Text('Server Tempat Terdekat'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Alamat server.py yang menjalankan fitur ini. '
              'HP asli: pakai IP laptop di Wi-Fi yang sama. '
              'Emulator Android: 10.0.2.2:8000.',
              style: PlacesStyle.bodySm.copyWith(color: PlacesStyle.slate600),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('server_url_field'),
              controller: _text,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Alamat server',
                hintText: '192.168.1.10:8000',
                errorText: _fieldError,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _test(),
            ),
            if (_testing) ...<Widget>[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (message != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    ok ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 18,
                    color: ok ? PlacesStyle.emerald : PlacesStyle.vermilion,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      key: const Key('server_test_result'),
                      style: PlacesStyle.bodySm.copyWith(
                        color: PlacesStyle.slate700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('server_reset'),
          onPressed: _testing ? null : _reset,
          child: const Text('Reset'),
        ),
        TextButton(
          key: const Key('server_test'),
          onPressed: _testing ? null : _test,
          child: const Text('Tes koneksi'),
        ),
        TextButton(
          key: const Key('server_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Batal'),
        ),
        FilledButton(
          key: const Key('server_save'),
          onPressed: _testing ? null : _save,
          style: FilledButton.styleFrom(backgroundColor: PlacesStyle.copper),
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
