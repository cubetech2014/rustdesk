// CubeRemote 서버 API 클라이언트
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiClient {
  static final _client = http.Client();
  static const _timeout = Duration(seconds: 10);

  static Future<Map<String, dynamic>?> verifyShop(String shopId) async {
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
    } catch (_) {}
    return null;
  }

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

  static Future<Map<String, dynamic>?> checkUpdate(
      String platform, String currentVersion, String flavor) async {
    try {
      final uri = Uri.parse('$API_BASE/check_update.php').replace(
        queryParameters: {
          'platform': platform,
          'version': currentVersion,
          'flavor': flavor,
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
