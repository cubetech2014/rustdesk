// CubeRemote 장비 정보 수집
// 외부 _plus 패키지 의존성 최소화 (RustDesk transitive 의존성 충돌 방지)
// 사용 패키지: device_info_plus, package_info_plus 만 (둘 다 RustDesk가 이미 사용)
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

class DeviceInfoHelper {
  static String? _deviceIdCache;

  /// RustDesk ID를 device_id로 사용 (원격 제어 시 동일 식별자로 통일)
  static Future<String> getDeviceId({String? rustDeskId}) async {
    if (rustDeskId != null && rustDeskId.isNotEmpty) {
      _deviceIdCache = rustDeskId;
      return rustDeskId;
    }
    if (_deviceIdCache != null) return _deviceIdCache!;

    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      _deviceIdCache = 'AND-${a.id}';
    } else if (Platform.isWindows) {
      final w = await info.windowsInfo;
      _deviceIdCache = 'WIN-${w.computerName}';
    } else {
      _deviceIdCache = 'UNK-${DateTime.now().millisecondsSinceEpoch}';
    }
    return _deviceIdCache!;
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
