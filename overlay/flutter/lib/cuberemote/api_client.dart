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

  static Future<Map<String, dynamic>?> checkUpdate(String platform, String currentVersion) async {
    try {
      final uri = Uri.parse('$API_BASE/check_update.php').replace(
        queryParameters: {'platform': platform, 'version': currentVersion},
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
}
