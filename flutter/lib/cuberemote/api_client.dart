// CubeRemote 서버 API 클라이언트
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiClient {
  static final _client = http.Client();
  static const _timeout = Duration(seconds: 10);

  /// 실패하면 {valid: false, error: 등록 화면에 그대로 보일 문구} 를 돌려준다.
  /// 예전엔 모든 실패를 null 로 뭉개서 '서버 검증 실패' 만 떴고, 매장 미등록인지
  /// 인증서 문제인지 네트워크 문제인지 현장에서 알 수 없었다 (2026-09-30 BF01).
  static Future<Map<String, dynamic>> verifyShop(String shopId) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$API_BASE/verify_shop.php'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'shop_id': shopId}),
          )
          .timeout(_timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
      if (resp.statusCode == 404) {
        return _verifyFail('등록되지 않은 매장 ID 입니다.\n대시보드 매장 등록 탭에서 먼저 등록해 주세요.');
      }
      if (resp.statusCode == 403) {
        return _verifyFail('차단된 매장입니다. 관리자에게 문의해 주세요.');
      }
      return _verifyFail('서버 오류입니다 (HTTP ${resp.statusCode}). 잠시 후 다시 시도해 주세요.');
    } on TlsException catch (e) {
      // http 패키지는 TLS 오류를 감싸지 않고 그대로 던진다
      return _verifyFail('서버 인증서를 확인하지 못했습니다.\n'
          'PC 의 날짜와 시간이 맞는지 확인해 주세요.\n(${_osDetail(e.osError, e.message)})');
    } on TimeoutException {
      return _verifyFail('서버 응답이 없습니다. 인터넷 연결을 확인해 주세요.');
    } on SocketException catch (e) {
      return _verifyFail('서버에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요.\n'
          '(${_osDetail(e.osError, e.message)})');
    } catch (e) {
      return _verifyFail('서버 검증 실패\n($e)');
    }
  }

  static Map<String, dynamic> _verifyFail(String error) => {'valid': false, 'error': error};

  // OS 가 준 문구는 앞뒤에 줄바꿈/탭이 붙어 온다
  static String _osDetail(OSError? os, String fallback) => (os?.message ?? fallback).trim();

  static Future<bool> sendHeartbeat(Map<String, dynamic> data) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$API_BASE/heartbeat.php'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode(data),
          )
          .timeout(_timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// [arch] 는 빌드 ABI (arm64 / armv7 / x64 / x86). 비우면 파라미터 자체를 생략해서
  /// 서버가 플랫폼 기본값으로 응답 — 구버전 클라이언트와 같은 동작.
  static Future<Map<String, dynamic>?> checkUpdate(
      String platform, String currentVersion, String flavor,
      {String arch = ''}) async {
    try {
      final uri = Uri.parse('$API_BASE/check_update.php').replace(
        queryParameters: {
          'platform': platform,
          'version': currentVersion,
          'flavor': flavor,
          if (arch.isNotEmpty) 'arch': arch,
        },
      );
      final resp = await _client.get(uri).timeout(_timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> sendLog(String deviceId, String level, String message) async {
    try {
      await _client
          .post(
            Uri.parse('$API_BASE/logs.php'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({
              'device_id': deviceId,
              'level': level,
              'message': message,
            }),
          )
          .timeout(_timeout);
    } catch (_) {}
  }

  // ────────── viewer flavor 인증 ──────────

  /// POST /viewer_login.php
  /// 응답:
  ///   { result: "ok",     token, expires_in, user: {...} }     → 성공
  ///   { result: "conflict", existing: {device_label, last_active} } → 다른 기기 활성 (HTTP 409)
  ///   { error: "..." }                                          → 실패 (401/403/500)
  static Future<Map<String, dynamic>?> viewerLogin({
    required String id,
    required String pw,
    required String deviceFingerprint,
    required String deviceLabel,
    bool forceTakeover = false,
  }) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$API_BASE/viewer_login.php'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({
              'id': id,
              'pw': pw,
              'device_fingerprint': deviceFingerprint,
              'device_label': deviceLabel,
              'force_takeover': forceTakeover,
            }),
          )
          .timeout(_timeout);
      // 200 (ok), 409 (conflict), 401/403/500 (error) 모두 body 파싱 시도
      final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      body['_status'] = resp.statusCode;
      return body;
    } catch (_) {
      return null;
    }
  }

  /// GET /viewer_session.php (Bearer 토큰)
  /// 200 → 유효, last_active 갱신됨
  /// 401 → 만료 / 다른 기기 로그인으로 강제 로그아웃됨 / 토큰 invalid
  static Future<Map<String, dynamic>?> viewerSession(String token) async {
    try {
      final resp = await _client
          .get(
            Uri.parse('$API_BASE/viewer_session.php'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (resp.statusCode == 200) {
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
      // 401 → 호출자가 로그아웃 처리해야 함 (null 반환)
    } catch (_) {}
    return null;
  }

  /// POST /viewer_logout.php (Bearer 토큰)
  static Future<void> viewerLogout(String token) async {
    try {
      await _client
          .post(
            Uri.parse('$API_BASE/viewer_logout.php'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
    } catch (_) {}
  }
}
