// CubeRemote Heartbeat 서비스 (60초 주기)
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'config.dart';
import 'device_info.dart';

class AgentService {
  static Timer? _timer;
  static bool _running = false;

  static Future<bool> isAgentMode() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(PREF_SHOP_ID) ?? '').isNotEmpty;
  }

  static Future<void> start() async {
    if (_running) return;
    if (!await isAgentMode()) return;
    _running = true;

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
        'remote_version': '', // RustDesk 본체 버전 (차후 주입)
        'app_version':   await DeviceInfoHelper.getAppVersion(),
        'os_version':    await DeviceInfoHelper.getOsVersion(),
      });
    } catch (_) {}
  }
}
