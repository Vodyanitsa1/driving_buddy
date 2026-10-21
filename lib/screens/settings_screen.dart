import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';

import '../core/app_colors.dart';
import '../models/account_config.dart';
import '../services/alert_config.dart';
import '../supabase_service.dart';
import '../routes/app_routes.dart';
import '../widgets/driving_buddy_app_bar.dart';

// ============================================================================
// SETTINGS SCREEN (Akun, Audio Alarm & Pengaturan — Luxury GT)
// ============================================================================

typedef SettingsScreen = AccountSettingsScreen;

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isSaving = false;
  bool _isLoggedIn = false;

  // --- Alert Settings State ---
  AlertAudioType _selectedAudioType = AlertAudioType.defaultSiren;
  String _audioDisplayName = 'Sirene Darurat (Bawaan)';
  String? _customAudioPath;
  final AudioPlayer _previewPlayer = AudioPlayer();
  bool _isPlayingPreview = false;

  AlertImageMode _selectedImageMode = AlertImageMode.none;
  String? _customImagePath;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadAlertSettings();
  }

  Future<void> _loadAlertSettings() async {
    final audioType = await AlertConfig.getAudioType();
    final audioName = await AlertConfig.getAudioDisplayName();
    final customAudio = await AlertConfig.getCustomAudioPath();
    final imageMode = await AlertConfig.getImageMode();
    final customImage = await AlertConfig.getCustomImagePath();
    if (mounted) {
      setState(() {
        _selectedAudioType = audioType;
        _audioDisplayName = audioName;
        _customAudioPath = customAudio;
        _selectedImageMode = imageMode;
        _customImagePath = customImage;
      });
    }
  }

  Future<void> _togglePreviewAudio() async {
    if (_isPlayingPreview) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _isPlayingPreview = false);
      return;
    }

    setState(() => _isPlayingPreview = true);
    try {
      if (_selectedAudioType == AlertAudioType.customFile &&
          _customAudioPath != null &&
          File(_customAudioPath!).existsSync()) {
        await _previewPlayer.play(DeviceFileSource(_customAudioPath!));
      } else if (_selectedAudioType == AlertAudioType.loudBeep) {
        await _previewPlayer.play(AssetSource('sounds/beep.wav'));
      } else if (_selectedAudioType == AlertAudioType.buzzer) {
        await _previewPlayer.play(AssetSource('sounds/buzzer.wav'));
      } else {
        try {
          await _previewPlayer.play(AssetSource('audio/alarm.mp3'));
        } catch (_) {
          await _previewPlayer.play(AssetSource('sounds/alarm.mp3'));
        }
      }

      // Otomatis stop setelah 4 detik
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && _isPlayingPreview) {
          _previewPlayer.stop();
          setState(() => _isPlayingPreview = false);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _isPlayingPreview = false);
    }
  }

  Future<void> _selectAudioPreset(AlertAudioType type) async {
    if (_isPlayingPreview) await _previewPlayer.stop();
    await AlertConfig.setAudioPreset(type);
    await _loadAlertSettings();
  }

  Future<void> _pickCustomAudio() async {
    final controller = TextEditingController(text: _customAudioPath ?? '');
    List<File> foundAudios = [];
    try {
      final dirs = [
        Directory('/storage/emulated/0/Download'),
        Directory('/storage/emulated/0/Music'),
        Directory('/storage/emulated/0/Ringtones'),
        Directory('/sdcard/Download'),
      ];
      for (final dir in dirs) {
        if (dir.existsSync()) {
          final list = dir.listSync();
          for (final item in list) {
            if (item is File) {
              final ext = item.path.split('.').last.toLowerCase();
              if (['mp3', 'wav', 'm4a', 'aac', 'ogg'].contains(ext)) {
                foundAudios.add(item);
              }
            }
          }
        }
      }
    } catch (_) {}

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.audiotrack_rounded, color: Color(0xFFE57A38)),
                SizedBox(width: 10),
                Text(
                  'Pilih Audio Kustom dari HP',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (foundAudios.isNotEmpty) ...[
              const Text(
                'File Audio Terdeteksi di Memori HP:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: foundAudios.length,
                  itemBuilder: (context, i) {
                    final f = foundAudios[i];
                    final fname = f.path.split(Platform.pathSeparator).last;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.music_note_rounded,
                          color: Color(0xFFE57A38), size: 20),
                      title: Text(
                        fname,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.check_circle_outline_rounded,
                          size: 18),
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(ctx);
                        if (_isPlayingPreview) await _previewPlayer.stop();
                        await AlertConfig.setCustomAudio(f.path, fname);
                        await _loadAlertSettings();
                        if (mounted) {
                          messenger.showSnackBar(
                            SnackBar(
                              content:
                                  Text('✅ Suara alarm berhasil diganti: $fname'),
                              backgroundColor: AppColors.success,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              'Atau Masukkan Path File Audio:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: '/storage/emulated/0/Download/alarm.mp3',
                hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () async {
                  final text = controller.text.trim();
                  if (text.isNotEmpty) {
                    final f = File(text);
                    if (f.existsSync()) {
                      Navigator.pop(ctx);
                      if (_isPlayingPreview) await _previewPlayer.stop();
                      final fname = text.split(Platform.pathSeparator).last;
                      await AlertConfig.setCustomAudio(text, fname);
                      await _loadAlertSettings();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('✅ Suara alarm berhasil diganti: $fname'),
                            backgroundColor: AppColors.success,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'File tidak ditemukan di path tersebut. Pastikan path benar.'),
                          backgroundColor: AppColors.danger,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE57A38),
                ),
                child: const Text('Terapkan File Audio'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCustomImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked != null) {
        await AlertConfig.setImageMode(AlertImageMode.custom,
            customPath: picked.path);
        await _loadAlertSettings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Gambar alert berhasil diperbarui'),
              backgroundColor: AppColors.success,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memilih gambar: $e'),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeAlertImage() async {
    await AlertConfig.removeCustomImage();
    await _loadAlertSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gambar kustom dihapus (Kembali ke Ikon Standar)'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadProfile() async {
    if (AuthService.isLoggedIn) {
      final user = AuthService.currentUser;
      final name = AuthService.currentUserName ?? '';
      final email = user?.email ?? '';
      if (mounted) {
        setState(() {
          _nameController.text = name;
          _emailController.text = email;
          _isLoggedIn = true;
        });
      }
    } else {
      final profile = await AccountConfig.getProfile();
      if (mounted) {
        setState(() {
          _nameController.text = profile['name'] ?? '';
          _emailController.text = profile['email'] ?? '';
          _isLoggedIn =
              _nameController.text.isNotEmpty || _emailController.text.isNotEmpty;
        });
      }
    }
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    setState(() => _isSaving = true);
    await AccountConfig.saveProfile(name, email);
    setState(() {
      _isSaving = false;
      _isLoggedIn = name.isNotEmpty || email.isNotEmpty;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Profil tersimpan'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _signOut() async {
    if (AuthService.isLoggedIn) {
      await AuthService.logout();
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.login,
          (route) => false,
        );
      }
    } else {
      await AccountConfig.clearProfile();
      _nameController.clear();
      _emailController.clear();
      setState(() => _isLoggedIn = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Berhasil keluar'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          DrivingBuddyAppBar(
            title: 'Pengaturan',
            showBackButton: true,
            showProfileButton: false,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFE57A38), Color(0xFFC25E21)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFE57A38).withOpacity(0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            _nameController.text.isNotEmpty
                                ? _nameController.text[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isLoggedIn
                            ? (_nameController.text.isNotEmpty
                                ? _nameController.text
                                : 'Pengemudi')
                            : 'Tamu / Offline',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: _isLoggedIn
                              ? const Color(0xFFECFDF5)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isLoggedIn
                                ? const Color(0xFFA7F3D0)
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Text(
                          _isLoggedIn ? '● Supabase Terhubung' : '○ Mode Tamu (Offline)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _isLoggedIn
                                ? const Color(0xFF059669)
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // AI Info Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF14100E), Color(0xFF1F1B18)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF564339)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.psychology_rounded,
                          color: Color(0xFFE57A38), size: 22),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'DrivingBuddy berjalan sepenuhnya On-Device (Google ML Kit Face Mesh). '
                          'Deteksi wajah & kantuk tidak butuh internet.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFEAE0DD),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                const Text(
                  'Nama Pengemudi',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _nameController,
                  hint: 'Masukkan nama kamu',
                  icon: Icons.person_rounded,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Email',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _emailController,
                  hint: 'email@contoh.com',
                  icon: Icons.email_rounded,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : _saveProfile,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(_isSaving ? 'Menyimpan...' : 'Simpan Profil'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE57A38),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Divider(color: Color(0xFFFED7AA)),
                const SizedBox(height: 20),

                // Kustomisasi Alert & Alarm
                _buildAlertSettingsSection(),
                const SizedBox(height: 28),
                const Divider(color: Color(0xFFFED7AA)),
                const SizedBox(height: 20),

                const Text(
                  'Informasi Sistem',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(Icons.security_rounded, 'Privasi',
                    'Kamera diproses lokal 100%, frame video tidak dikirim'),
                const SizedBox(height: 8),
                _buildInfoRow(Icons.info_outline_rounded, 'Versi',
                    'DrivingBuddy v2.0 — Luxury GT Telemetry'),
                const SizedBox(height: 24),
                if (_isLoggedIn) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout_rounded,
                          size: 18, color: Color(0xFFD94126)),
                      label: const Text(
                        'Keluar dari Akun',
                        style: TextStyle(color: Color(0xFFD94126), fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFD94126)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF0F172A),
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.grey.shade400,
            fontWeight: FontWeight.w400,
          ),
          prefixIcon: Icon(icon, color: const Color(0xFFE57A38)),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFEDD5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFFE57A38)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Kustomisasi Peringatan (Alert & Alarm)',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Atur nada suara alarm bawaan dan gambar yang ditampilkan saat bahaya',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 14),

        // ── 1. SUARA ALARM CARD ──
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFFFF), Color(0xFFFFFBF8)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFED7AA)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE57A38).withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: const Icon(Icons.volume_up_rounded,
                        color: Color(0xFFE57A38), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Suara Alarm Keselamatan',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          'Bawaan: Sirene Darurat (bisa diubah sesuai selera)',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildAudioOptionTile(
                title: 'Sirene Darurat (Bawaan)',
                subtitle: 'Suara sirene alarm standar darurat',
                isSelected: _selectedAudioType == AlertAudioType.defaultSiren,
                onTap: () => _selectAudioPreset(AlertAudioType.defaultSiren),
              ),
              const SizedBox(height: 6),
              _buildAudioOptionTile(
                title: 'Beep Peringatan Cepat',
                subtitle: 'Nada beep berulang frekuensi tinggi (1050 Hz)',
                isSelected: _selectedAudioType == AlertAudioType.loudBeep,
                onTap: () => _selectAudioPreset(AlertAudioType.loudBeep),
              ),
              const SizedBox(height: 6),
              _buildAudioOptionTile(
                title: 'Klakson / Buzzer Peringatan',
                subtitle: 'Suara buzzer ganda kendaraan darurat',
                isSelected: _selectedAudioType == AlertAudioType.buzzer,
                onTap: () => _selectAudioPreset(AlertAudioType.buzzer),
              ),
              const SizedBox(height: 6),
              _buildAudioOptionTile(
                title: _selectedAudioType == AlertAudioType.customFile
                    ? 'File Kustom: $_audioDisplayName'
                    : 'Pilih Audio dari File HP...',
                subtitle: _selectedAudioType == AlertAudioType.customFile
                    ? 'Audio kustom tersimpan dari memori HP'
                    : 'Cari atau masukkan path file audio MP3/WAV',
                isSelected: _selectedAudioType == AlertAudioType.customFile,
                onTap: _pickCustomAudio,
                trailingIcon: Icons.folder_open_rounded,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _togglePreviewAudio,
                      icon: Icon(
                        _isPlayingPreview
                            ? Icons.stop_circle_rounded
                            : Icons.play_circle_fill_rounded,
                        size: 18,
                        color: _isPlayingPreview
                            ? const Color(0xFFD94126)
                            : const Color(0xFFE57A38),
                      ),
                      label: Text(
                        _isPlayingPreview ? 'Hentikan Contoh' : 'Tes Bunyi Alarm',
                        style: TextStyle(
                          color: _isPlayingPreview
                              ? const Color(0xFFD94126)
                              : const Color(0xFFE57A38),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: _isPlayingPreview
                              ? const Color(0xFFD94126)
                              : const Color(0xFFE57A38),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  if (_selectedAudioType != AlertAudioType.defaultSiren) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Kembalikan ke sirene bawaan',
                      onPressed: () =>
                          _selectAudioPreset(AlertAudioType.defaultSiren),
                      icon: const Icon(Icons.refresh_rounded,
                          color: Color(0xFFE57A38)),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

       
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFFFF), Color(0xFFFFFBF8)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFED7AA)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE57A38).withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: const Icon(Icons.image_rounded,
                        color: Color(0xFFE57A38), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Gambar Peringatan Visual',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          'Bawaan: Ikon Bahaya Standar',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Image Preview Area
              Center(
                child: Container(
                  height: 130,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFEDD5)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildImagePreviewWidget(),
                ),
              ),

              const SizedBox(height: 14),

              // Action buttons for Image
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _pickCustomImage,
                      icon: const Icon(Icons.photo_library_rounded, size: 16),
                      label: const Text(
                        'Pilih Gambar Kustom',
                        style:
                            TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        backgroundColor: const Color(0xFFE57A38),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  if (_selectedImageMode == AlertImageMode.custom) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _removeAlertImage,
                      icon: const Icon(Icons.delete_outline_rounded,
                          size: 16, color: Color(0xFFD94126)),
                      label: const Text('Hapus',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFFD94126))),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFD94126)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImagePreviewWidget() {
    if (_selectedImageMode == AlertImageMode.custom &&
        _customImagePath != null &&
        File(_customImagePath!).existsSync()) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(_customImagePath!), fit: BoxFit.cover),
          Positioned(
            bottom: 6,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Gambar Kustom Aktif',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      );
    }

    // Default: Clean Safety Icon (No meme)
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.shield_outlined, size: 40, color: Color(0xFFE57A38)),
        SizedBox(height: 6),
        Text(
          'Ikon Peringatan Standar Aktif',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        Text(
          'Menampilkan animasi bahaya darurat',
          style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
        ),
      ],
    );
  }

  Widget _buildAudioOptionTile({
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    IconData? trailingIcon,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF7ED) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFFFED7AA) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 18,
              color: isSelected ? const Color(0xFFE57A38) : const Color(0xFF94A3B8),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w800 : FontWeight.w600,
                      color:
                          isSelected ? const Color(0xFF0F172A) : const Color(0xFF475569),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: isSelected
                          ? const Color(0xFFC25E21)
                          : const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
            if (trailingIcon != null)
              Icon(trailingIcon, size: 18, color: const Color(0xFFE57A38)),
          ],
        ),
      ),
    );
  }
}
