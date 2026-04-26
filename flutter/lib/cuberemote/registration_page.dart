// CubeRemote 에이전트 등록 화면 (최초 실행 시 1회)
// Skip 시 RustDesk 뷰어 모드로만 동작
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_service.dart';
import 'api_client.dart';
import 'config.dart';

class CubeRemoteRegistrationPage extends StatefulWidget {
  final VoidCallback onDone;
  const CubeRemoteRegistrationPage({super.key, required this.onDone});

  @override
  State<CubeRemoteRegistrationPage> createState() => _CubeRemoteRegistrationPageState();
}

class _CubeRemoteRegistrationPageState extends State<CubeRemoteRegistrationPage> {
  final _shopId   = TextEditingController();
  final _shopNm   = TextEditingController();
  final _hId      = TextEditingController();
  final _deviceNm = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _skip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cuberemote_skipped', true);
    widget.onDone();
  }

  Future<void> _register() async {
    final shopId   = _shopId.text.trim();
    final shopNm   = _shopNm.text.trim();
    final deviceNm = _deviceNm.text.trim();

    if (shopId.isEmpty || shopNm.isEmpty || deviceNm.isEmpty) {
      setState(() => _error = '매장 ID, 매장명, 장비 닉네임은 필수입니다.');
      return;
    }

    setState(() { _loading = true; _error = null; });
    try {
      final result = await ApiClient.verifyShop(shopId);
      if (result == null || result['valid'] != true) {
        setState(() => _error = result?['error']?.toString() ?? '서버 검증 실패');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PREF_SHOP_ID, shopId);
      await prefs.setString(PREF_P_ID,   result['p_id']?.toString() ?? '');
      await prefs.setString(PREF_H_ID,   _hId.text.trim());
      await prefs.setString(PREF_SHOP_NM, result['shop_nm']?.toString() ?? shopNm);
      await prefs.setString(PREF_DEVICE_NM, deviceNm);
      await prefs.setBool('cuberemote_skipped', false);

      await AgentService.start();
      widget.onDone();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _dec(String label, String hint) => InputDecoration(
    labelText: label, hintText: hint,
    border: const OutlineInputBorder(),
    filled: true, fillColor: const Color(0xFFF8FAFC),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CubeRemote 장비 등록')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const Text(
              '이 기기를 POS 에이전트로 등록하시겠습니까?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '등록하면 60초마다 서버로 상태를 보고합니다.\n관리자용으로만 쓰려면 건너뛰세요.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            TextField(controller: _shopId,   decoration: _dec('매장 ID *',   '예: SHOP001')),
            const SizedBox(height: 12),
            TextField(controller: _shopNm,   decoration: _dec('매장명 *',    '예: 강남점')),
            const SizedBox(height: 12),
            TextField(controller: _hId,      decoration: _dec('본사 ID',     '선택')),
            const SizedBox(height: 12),
            TextField(controller: _deviceNm, decoration: _dec('장비 닉네임 *', '예: 카운터1')),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading ? null : _register,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('에이전트로 등록', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loading ? null : _skip,
              child: const Text('건너뛰기 (뷰어 모드로만 사용)'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shopId.dispose(); _shopNm.dispose(); _hId.dispose(); _deviceNm.dispose();
    super.dispose();
  }
}
