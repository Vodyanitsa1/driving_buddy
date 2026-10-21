import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';
import 'screens/main_shell.dart';

// ============================================================================
// AUTH SCREEN (Login & Registrasi — Luxury GT Obsidian Telemetry)
// ============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  late final TabController _tab;

  // Slide animation
  late final AnimationController _slideCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // Login fields
  final _loginEmail = TextEditingController();
  final _loginPassword = TextEditingController();
  bool _loginLoading = false;
  String? _loginError;
  bool _loginObscure = true;

  // Register fields
  final _regName = TextEditingController();
  final _regEmail = TextEditingController();
  final _regPassword = TextEditingController();
  final _regConfirm = TextEditingController();
  bool _regLoading = false;
  String? _regError;
  String? _regSuccess;
  bool _regObscure = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut);
    _slideAnim = Tween(begin: const Offset(0, 0.05), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));
    _slideCtrl.forward();
  }

  @override
  void dispose() {
    _tab.dispose();
    _slideCtrl.dispose();
    _loginEmail.dispose();
    _loginPassword.dispose();
    _regName.dispose();
    _regEmail.dispose();
    _regPassword.dispose();
    _regConfirm.dispose();
    super.dispose();
  }

  // ── login ───────────────────────────────
  Future<void> _doLogin() async {
    setState(() {
      _loginLoading = true;
      _loginError = null;
    });
    try {
      await AuthService.login(
        email: _loginEmail.text.trim(),
        password: _loginPassword.text,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainShell()),
        );
      }
    } on AuthException catch (e) {
      setState(() => _loginError = _xlErr(e.message));
    } catch (_) {
      setState(() => _loginError = 'Terjadi kesalahan saat masuk. Coba lagi.');
    } finally {
      if (mounted) setState(() => _loginLoading = false);
    }
  }

  // ── register ────────────────────────────
  Future<void> _doRegister() async {
    if (_regName.text.trim().isEmpty) {
      return setState(() => _regError = 'Nama tidak boleh kosong.');
    }
    if (_regPassword.text != _regConfirm.text) {
      return setState(() => _regError = 'Konfirmasi password tidak cocok.');
    }
    setState(() {
      _regLoading = true;
      _regError = null;
      _regSuccess = null;
    });
    try {
      await AuthService.register(
        email: _regEmail.text.trim(),
        password: _regPassword.text,
        fullName: _regName.text.trim(),
      );
      setState(() => _regSuccess =
          'Akun berhasil dibuat! Silakan cek email kamu untuk konfirmasi, lalu masuk.');
    } on AuthException catch (e) {
      setState(() => _regError = _xlErr(e.message));
    } catch (_) {
      setState(() => _regError = 'Terjadi kesalahan pendaftaran. Coba lagi.');
    } finally {
      if (mounted) setState(() => _regLoading = false);
    }
  }

  String _xlErr(String m) {
    if (m.contains('Invalid login')) return 'Email atau password salah.';
    if (m.contains('Email not confirmed')) return 'Email belum dikonfirmasi. Cek kotak masuk email kamu.';
    if (m.contains('User not found')) return 'Akun tidak ditemukan.';
    if (m.contains('already registered')) return 'Email sudah terdaftar.';
    if (m.contains('weak password')) return 'Password terlalu lemah (min. 6 karakter).';
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  _buildBrandHeader(),
                  const SizedBox(height: 24),
                  _buildTabSelector(),
                  const SizedBox(height: 20),
                  // Form Card
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFFFFFFF), Color(0xFFFFFBF8)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFE57A38).withOpacity(0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(20),
                    child: AnimatedBuilder(
                      animation: _tab,
                      builder: (context, _) {
                        return _tab.index == 0 ? _buildLoginForm() : _buildRegisterForm();
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandHeader() {
    return Column(
      children: [
        Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFE57A38), Color(0xFFC25E21)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE57A38).withOpacity(0.35),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_car_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'DRIVING',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'BUDDY',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: Color(0xFFE57A38),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFF10B981),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'GT Telemetri Kabin & Monitoring Kelelahan',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF64748B),
          ),
        ),
      ],
    );
  }

  Widget _buildTabSelector() {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: TabBar(
        controller: _tab,
        indicator: BoxDecoration(
          color: const Color(0xFFE57A38),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFE57A38).withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: const Color(0xFF64748B),
        labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        onTap: (index) => setState(() {}),
        tabs: const [
          Tab(text: 'Masuk'),
          Tab(text: 'Daftar Baru'),
        ],
      ),
    );
  }

  Widget _buildLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loginError != null) ...[
          _buildAlertBox(_loginError!, isError: true),
          const SizedBox(height: 16),
        ],

        _buildLabel('Email Pengemudi'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _loginEmail,
          hint: 'nama@email.com',
          icon: Icons.alternate_email_rounded,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 16),

        _buildLabel('Kata Sandi'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _loginPassword,
          hint: '••••••••',
          icon: Icons.lock_outline_rounded,
          obscureText: _loginObscure,
          suffix: IconButton(
            icon: Icon(
              _loginObscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: const Color(0xFF64748B),
              size: 20,
            ),
            onPressed: () => setState(() => _loginObscure = !_loginObscure),
          ),
        ),
        const SizedBox(height: 22),

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _loginLoading ? null : _doLogin,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE57A38),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 4,
              shadowColor: const Color(0xFFE57A38).withOpacity(0.35),
            ),
            child: _loginLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                  )
                : const Text(
                    'Masuk ke Cockpit',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                  ),
          ),
        ),
        const SizedBox(height: 18),

        Center(
          child: GestureDetector(
            onTap: () {
              _tab.animateTo(1);
              setState(() {});
            },
            child: Text.rich(
              TextSpan(
                children: const [
                  TextSpan(
                    text: 'Belum punya akun? ',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  ),
                  TextSpan(
                    text: 'Daftar sekarang',
                    style: TextStyle(
                      color: Color(0xFFE57A38),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRegisterForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_regSuccess != null) ...[
          _buildAlertBox(_regSuccess!, isError: false),
          const SizedBox(height: 16),
        ],
        if (_regError != null) ...[
          _buildAlertBox(_regError!, isError: true),
          const SizedBox(height: 16),
        ],

        _buildLabel('Nama Lengkap'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _regName,
          hint: 'Contoh: Adrian Hartono',
          icon: Icons.person_outline_rounded,
        ),
        const SizedBox(height: 14),

        _buildLabel('Email Pengemudi'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _regEmail,
          hint: 'nama@email.com',
          icon: Icons.alternate_email_rounded,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 14),

        _buildLabel('Kata Sandi'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _regPassword,
          hint: 'Minimal 6 karakter',
          icon: Icons.lock_outline_rounded,
          obscureText: _regObscure,
          suffix: IconButton(
            icon: Icon(
              _regObscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: const Color(0xFF64748B),
              size: 20,
            ),
            onPressed: () => setState(() => _regObscure = !_regObscure),
          ),
        ),
        const SizedBox(height: 14),

        _buildLabel('Konfirmasi Kata Sandi'),
        const SizedBox(height: 6),
        _buildInputField(
          controller: _regConfirm,
          hint: 'Ulangi kata sandi',
          icon: Icons.lock_outline_rounded,
          obscureText: true,
        ),
        const SizedBox(height: 22),

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _regLoading ? null : _doRegister,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE57A38),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 4,
              shadowColor: const Color(0xFFE57A38).withOpacity(0.35),
            ),
            child: _regLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                  )
                : const Text(
                    'Buat Akun Pengemudi',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                  ),
          ),
        ),
        const SizedBox(height: 18),

        Center(
          child: GestureDetector(
            onTap: () {
              _tab.animateTo(0);
              setState(() {});
            },
            child: Text.rich(
              TextSpan(
                children: const [
                  TextSpan(
                    text: 'Sudah punya akun? ',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  ),
                  TextSpan(
                    text: 'Masuk',
                    style: TextStyle(
                      color: Color(0xFFE57A38),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w800,
        color: Color(0xFF0F172A),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffix,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        cursorColor: const Color(0xFFE57A38),
        style: const TextStyle(
          color: Color(0xFF0F172A), // Font hitam pekat jelas
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13.5, fontWeight: FontWeight.normal),
          prefixIcon: Icon(icon, color: const Color(0xFF64748B), size: 19),
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildAlertBox(String msg, {required bool isError}) {
    final color = isError ? const Color(0xFFD94126) : const Color(0xFF059669);
    final bgColor = isError ? const Color(0xFFFEF2F2) : const Color(0xFFECFDF5);
    final borderColor = isError ? const Color(0xFFFECACA) : const Color(0xFFA7F3D0);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

// Keep RegisterScreen alias
class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LoginScreen();
  }
}
