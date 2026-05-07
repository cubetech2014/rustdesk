// CubeRemote 에이전트 등록 화면 (최초 실행 시 1회)
// Skip 시 RustDesk 뷰어 모드로만 동작
import 'dart:convert';
import 'dart:io';
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

      // v1.0.30: Rust service heartbeat 가 즉시 사용할 수 있게 ProgramData 에 mirror.
      //   AgentService._sendOnce 도 mirror 하지만 RustDesk ID 발급 전엔 skip 되어
      //   첫 heartbeat 가 늦어짐 → 등록 직후 보장 위해 여기서 한 번 기록.
      //
      // v1.0.32 fix: 재등록 시 기존 비번 보존. 이전엔 빈값으로 mirror 해서 다음
      //   60초 동안 Rust service heartbeat 가 빈 password 를 송신 → DB password
      //   덮어쓰기 → 원격 접속 실패 race window 발생했음. 이제 PREF_RD_PASSWORD 가
      //   있으면 그대로 mirror, 첫 등록이면 빈값 (정상 — _initOnce 가 곧 채움).
      if (Platform.isWindows) {
        final existingPassword = prefs.getString(PREF_RD_PASSWORD) ?? '';
        await _writeAgentJson(
          shopId: shopId,
          pId: result['p_id']?.toString() ?? '',
          hId: _hId.text.trim(),
          shopNm: result['shop_nm']?.toString() ?? shopNm,
          deviceNm: deviceNm,
          rustdeskPassword: existingPassword,
        );
      }

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

  /// 등록/재등록 직후 ProgramData/CubeRemote/agent.json 에 즉시 mirror.
  /// rustdesk_password: 첫 등록이면 빈값 (_initOnce 가 곧 채움), 재등록이면 기존 비번 보존.
  Future<void> _writeAgentJson({
    required String shopId,
    required String pId,
    required String hId,
    required String shopNm,
    required String deviceNm,
    required String rustdeskPassword,
  }) async {
    try {
      final programData = Platform.environment['PROGRAMDATA'] ?? r'C:\ProgramData';
      final dir = Directory('$programData\\CubeRemote');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}\\agent.json');
      final json = jsonEncode({
        'shop_id': shopId,
        'p_id': pId,
        'h_id': hId,
        'shop_nm': shopNm,
        'device_nm': deviceNm,
        'rustdesk_password': rustdeskPassword,
        'agent_version': AGENT_VERSION,
      });
      await file.writeAsString(json);
    } catch (_) {
      // 실패해도 Flutter heartbeat 는 정상 진행 — service heartbeat 만 1회 늦어짐
    }
  }
}
