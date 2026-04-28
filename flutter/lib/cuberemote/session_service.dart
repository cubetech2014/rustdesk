// CubeRemote viewer 세션 (토큰 기반, 60초 ping, 30분 무활동 만료)
// - 첫 로그인 후 SharedPreferences 에 토큰 + user 저장
// - Timer 가 60초마다 viewer_session.php 호출 → last_active 갱신
// - 401 응답 시 onForcedLogout 콜백 호출 (UI 가 로그인 페이지로 복귀)

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'config.dart';
import 'device_info.dart';

class SessionUser {
  final String id;
  final String name;
  final String role;
  final String pId;
  final String pNm;

  const SessionUser({
    required this.id,
    required this.name,
    required this.role,
    required this.pId,
    required this.pNm,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'p_id': pId,
        'p_nm': pNm,
      };

  factory SessionUser.fromJson(Map<String, dynamic> j) => SessionUser(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        role: j['role']?.toString() ?? 'partner',
        pId: j['p_id']?.toString() ?? '',
        pNm: j['p_nm']?.toString() ?? '',
      );
}

typedef ForcedLogoutCallback = void Function(String reason);

class SessionService {
  static Timer? _pingTimer;
  static String? _token;
  static SessionUser? _user;
  static ForcedLogoutCallback? _onForcedLogout;

  static String? get token => _token;
  static SessionUser? get user => _user;
  static bool get isLoggedIn => _token != null;

  /// 앱 시작 시 1회 호출 — SharedPreferences 에서 토큰 + user 복원
  static Future<bool> restoreFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(PREF_SESSION_TOKEN);
    final u = prefs.getString(PREF_SESSION_USER);
    if (t == null || t.isEmpty || u == null || u.isEmpty) return false;
    try {
      _token = t;
      _user = SessionUser.fromJson(jsonDecode(u) as Map<String, dynamic>);
      return true;
    } catch (_) {
      _token = null;
      _user = null;
      return false;
    }
  }

  /// 서버에 토큰 유효성 검증 — 200 이면 true, 401 이면 캐시 정리 후 false
  static Future<bool> validateWithServer() async {
    if (_token == null) return false;
    final resp = await ApiClient.viewerSession(_token!);
    if (resp == null) {
      // 401 또는 네트워크 실패 — 안전하게 invalidate
      await _clearCache();
      return false;
    }
    // 응답에 user 정보 갱신 (이름/역할 변경 반영)
    final u = resp['user'];
    if (u is Map<String, dynamic>) {
      _user = SessionUser.fromJson(u);
      await _persistUser();
    }
    return true;
  }

  /// 로그인 시도 — 결과 응답을 그대로 반환 (호출자가 ok / conflict / error 처리)
  /// 응답 형태:
  ///   { result: "ok",       token, user, _status: 200 }
  ///   { result: "conflict", existing: {...}, _status: 409 }
  ///   { error: "...",                          _status: 401|403|500 }
  ///   null  → 네트워크 실패
  static Future<Map<String, dynamic>?> login({
    required String id,
    required String pw,
    bool forceTakeover = false,
  }) async {
    final fp = await _getOrCreateDeviceFingerprint();
    final label = await _buildDeviceLabel();
    final resp = await ApiClient.viewerLogin(
      id: id,
      pw: pw,
      deviceFingerprint: fp,
      deviceLabel: label,
      forceTakeover: forceTakeover,
    );
    if (resp == null) return null;
    if (resp['result'] == 'ok') {
      _token = resp['token']?.toString();
      final u = resp['user'];
      if (u is Map<String, dynamic>) {
        _user = SessionUser.fromJson(u);
      }
      await _persistAll();
    }
    return resp;
  }

  /// 사용자 명시적 로그아웃 — 서버 토큰 invalidate + 캐시 정리
  static Future<void> logout() async {
    final t = _token;
    stopPingTimer();
    await _clearCache();
    if (t != null) {
      // 백그라운드, 실패해도 무방
      ApiClient.viewerLogout(t);
    }
  }

  /// 60초 ping 시작 (viewer 진입 직후 호출)
  static void startPingTimer({required ForcedLogoutCallback onForcedLogout}) {
    _onForcedLogout = onForcedLogout;
    stopPingTimer();
    _pingTimer = Timer.periodic(
      const Duration(seconds: SESSION_PING_INTERVAL_SECONDS),
      (_) => _ping(),
    );
  }

  static void stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  static Future<void> _ping() async {
    if (_token == null) return;
    final resp = await ApiClient.viewerSession(_token!);
    if (resp == null) {
      // 401 또는 네트워크 실패 — 강제 로그아웃 처리
      // (네트워크 일시적 실패는 다음 ping 에서 회복 가능하지만, 보수적으로 로그아웃 처리)
      stopPingTimer();
      await _clearCache();
      _onForcedLogout?.call('세션이 만료되었거나 다른 기기에서 로그인되었습니다. 다시 로그인해주세요.');
    } else {
      // 사용자 정보 갱신
      final u = resp['user'];
      if (u is Map<String, dynamic>) {
        _user = SessionUser.fromJson(u);
        await _persistUser();
      }
    }
  }

  // ── 내부 helpers ──

  static Future<void> _persistAll() async {
    final prefs = await SharedPreferences.getInstance();
    if (_token != null) await prefs.setString(PREF_SESSION_TOKEN, _token!);
    if (_user != null) {
      await prefs.setString(PREF_SESSION_USER, jsonEncode(_user!.toJson()));
    }
  }

  static Future<void> _persistUser() async {
    if (_user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PREF_SESSION_USER, jsonEncode(_user!.toJson()));
  }

  static Future<void> _clearCache() async {
    _token = null;
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PREF_SESSION_TOKEN);
    await prefs.remove(PREF_SESSION_USER);
  }

  /// 기기 고유 식별자 (UUID-like, 1회 생성 후 SharedPreferences 보관).
  /// 단일 기기 강제 정책의 키 — 같은 기기 재로그인은 충돌 안 남.
  static Future<String> _getOrCreateDeviceFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    var fp = prefs.getString(PREF_DEVICE_FP) ?? '';
    if (fp.isNotEmpty) return fp;
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    fp = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(PREF_DEVICE_FP, fp);
    return fp;
  }

  /// 사용자에게 보여줄 기기 라벨 ("DESKTOP-ABC123 (Windows)")
  static Future<String> _buildDeviceLabel() async {
    final name = await DeviceInfoHelper.getDeviceName();
    final platform = DeviceInfoHelper.platform;
    return '$name ($platform)';
  }
}
