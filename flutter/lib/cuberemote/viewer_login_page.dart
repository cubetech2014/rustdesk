// CubeRemote viewer 로그인 페이지 (Windows/Android 양쪽)
// dashboard 의 Login.jsx 디자인 참고 — navy 배경 + white card + 빨강 액센트
// 단일 기기 정책: 다른 기기 활성 세션 발견 시 confirm 다이얼로그
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'session_service.dart';

class ViewerLoginPage extends StatefulWidget {
  /// 로그인 성공 후 호출 — 호출자가 main UI 로 전환
  final VoidCallback onSuccess;

  /// 강제 로그아웃 후 진입 시 표시할 안내 메시지 (선택)
  final String? initialMessage;

  const ViewerLoginPage({super.key, required this.onSuccess, this.initialMessage});

  @override
  State<ViewerLoginPage> createState() => _ViewerLoginPageState();
}

class _ViewerLoginPageState extends State<ViewerLoginPage> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialMessage != null) _error = widget.initialMessage;
  }

  Future<void> _submit({bool forceTakeover = false}) async {
    final id = _id.text.trim();
    final pw = _pw.text.trim();
    if (id.isEmpty || pw.isEmpty) {
      setState(() => _error = '아이디와 비밀번호를 입력하세요.');
      return;
    }
    setState(() { _loading = true; _error = null; });

    try {
      final resp = await SessionService.login(
        id: id, pw: pw, forceTakeover: forceTakeover,
      );

      if (resp == null) {
        setState(() => _error = '서버 연결 실패. 네트워크를 확인하세요.');
        return;
      }

      // result == "ok" → onSuccess
      if (resp['result'] == 'ok') {
        widget.onSuccess();
        return;
      }

      // result == "conflict" → 다른 기기 활성, 사용자에게 confirm
      if (resp['result'] == 'conflict') {
        final ex = resp['existing'] as Map<String, dynamic>? ?? {};
        final label = ex['device_label']?.toString() ?? '알 수 없는 기기';
        final lastActive = ex['last_active']?.toString() ?? '';
        if (!mounted) return;
        final go = await _showConflictDialog(label, lastActive);
        if (go == true) {
          await _submit(forceTakeover: true);
        }
        return;
      }

      // 그 외 — error 메시지 표시
      setState(() => _error = resp['error']?.toString() ?? '로그인 실패');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _showConflictDialog(String existingDevice, String lastActive) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('이미 다른 기기에서 사용 중'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('이 계정은 다음 기기에서 사용 중입니다:'),
            const SizedBox(height: 8),
            Text(existingDevice, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (lastActive.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('최근 활동: $lastActive', style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
            const SizedBox(height: 12),
            const Text('계속하시면 해당 기기의 접속이 종료됩니다.\n계속하시겠습니까?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            child: const Text('계속'),
          ),
        ],
      ),
    );
  }

  Future<void> _onClose() async {
    // Desktop: window 종료 (앱 종료). Mobile: 그냥 SystemNavigator.pop 같은 효과
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        await windowManager.destroy();
      } catch (_) {}
      exit(0);
    } else {
      // Android: 그냥 finish (RustDesk 종료는 어차피 OS 가 메모리 회수)
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CubeRemote',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE53935)),
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        body: Stack(
          children: [
            // 메인 카드
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 30,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 로고 + 타이틀 (컴팩트)
                        Center(
                          child: Container(
                            width: 64, height: 64,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFE53935).withOpacity(0.25),
                                  blurRadius: 18, offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.desktop_windows_outlined,
                              size: 36, color: Color(0xFFE53935),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Center(
                          child: Text(
                            'CubeRemote',
                            style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A), letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Center(
                          child: Text(
                            'POS 원격 모니터링 뷰어',
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ),
                        const SizedBox(height: 20),

                        if (_error != null) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFFECACA)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline, size: 16, color: Color(0xFFB91C1C)),
                                const SizedBox(width: 6),
                                Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12))),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],

                        _label('아이디'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _id,
                          autofocus: true,
                          decoration: _decoration(Icons.person_outline, '아이디를 입력하세요'),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 12),
                        _label('비밀번호'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _pw,
                          obscureText: _obscure,
                          decoration: _decoration(Icons.lock_outline, '비밀번호를 입력하세요').copyWith(
                            suffixIcon: IconButton(
                              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18),
                              onPressed: () => setState(() => _obscure = !_obscure),
                              padding: EdgeInsets.zero,
                            ),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 18),

                        SizedBox(
                          height: 44,
                          child: FilledButton(
                            onPressed: _loading ? null : () => _submit(),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFE53935),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              elevation: 4,
                            ),
                            child: _loading
                                ? const SizedBox(
                                    width: 18, height: 18,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                  )
                                : const Text('로그인', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.3)),
                          ),
                        ),

                        const SizedBox(height: 14),
                        Center(
                          child: Text(
                            'CUBE TECHNOLOGY',
                            style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade400,
                              letterSpacing: 1.2, fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 우상단 닫기 버튼 (RustDesk 의 hidden-titlebar 라 OS 닫기 X 없음 → 자체 X)
            Positioned(
              top: 12,
              right: 12,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _onClose,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(
        t.toUpperCase(),
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF64748B), letterSpacing: 0.8),
      );

  InputDecoration _decoration(IconData icon, String hint) => InputDecoration(
        prefixIcon: Icon(icon, size: 20, color: const Color(0xFF94A3B8)),
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.8),
        ),
      );

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }
}
