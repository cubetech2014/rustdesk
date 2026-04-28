// CubeRemote 장비 정보 수집
// 외부 _plus 패키지 의존성 최소화 (RustDesk transitive 의존성 충돌 방지)
// 사용 패키지: device_info_plus, package_info_plus 만 (둘 다 RustDesk가 이미 사용)
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class DeviceInfoHelper {
  /// RustDesk가 발급한 9자리 ID. rustdesk:// 딥링크 / 원격 제어 식별자.
  /// RustDesk 초기화 후에만 받을 수 있음. 못 받으면 null.
  static Future<String?> getRustDeskId() async {
    try {
      final id = await bind.mainGetMyId();
      if (id.isNotEmpty) return id;
    } catch (_) {}
    return null;
  }

  /// 폴백 device id (디버그/표시용).
  /// heartbeat 의 device_id 로는 사용 금지 — getRustDeskId() 만 사용.
  static Future<String> getFallbackId() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return 'AND-${a.id}';
    } else if (Platform.isWindows) {
      final w = await info.windowsInfo;
      return 'WIN-${w.computerName}';
    }
    return 'UNK-${DateTime.now().millisecondsSinceEpoch}';
  }

  static Future<String> getDeviceName() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return '${a.manufacturer} ${a.model}';
    }
    if (Platform.isWindows) {
      final w = await info.windowsInfo;
      return w.computerName;
    }
    return Platform.operatingSystem;
  }

  static Future<String> getOsVersion() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return 'Android ${a.version.release} (API ${a.version.sdkInt})';
    }
    if (Platform.isWindows) {
      final w = await info.windowsInfo;
      return 'Windows ${w.productName}';
    }
    return Platform.operatingSystemVersion;
  }

  /// 배터리 잔량 — 일단 -1 (추후 native channel 보강)
  static Future<int> getBatteryLevel() async => -1;

  /// 네트워크 타입 — 인터페이스 이름으로 추정
  static Future<String> getNetworkType() async {
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in list) {
        final n = iface.name.toLowerCase();
        if (n.contains('wlan') || n.contains('wifi') || n.startsWith('wl')) return 'WiFi';
        if (n.contains('rmnet') || n.contains('ccmni') || n.contains('lte')) return 'LTE';
        if (n.contains('eth')) return 'Ethernet';
      }
    } catch (_) {}
    return 'Unknown';
  }

  /// 첫 번째 비-루프백 IPv4
  static Future<String> getIpAddress() async {
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in list) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '0.0.0.0';
  }

  static Future<String> getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  static String get platform =>
      Platform.isAndroid ? 'Android' : (Platform.isWindows ? 'Windows' : 'Other');
}
