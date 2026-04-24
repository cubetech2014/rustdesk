// CubeRemote 장비 정보 수집 (Flutter + RustDesk 런타임 활용)
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

class DeviceInfoHelper {
  static String? _deviceIdCache;

  /// RustDesk ID를 device_id로 사용 (원격 제어 시 동일 식별자로 통일)
  /// RustDesk 초기화 후에만 호출 가능
  static Future<String> getDeviceId({String? rustDeskId}) async {
    if (rustDeskId != null && rustDeskId.isNotEmpty) {
      _deviceIdCache = rustDeskId;
      return rustDeskId;
    }
    if (_deviceIdCache != null) return _deviceIdCache!;

    // Fallback: ANDROID_ID / MAC 조합
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

  static Future<int> getBatteryLevel() async {
    if (Platform.isWindows) return -1;
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return -1;
    }
  }

  static Future<String> getNetworkType() async {
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.wifi)) return 'WiFi';
    if (conn.contains(ConnectivityResult.mobile)) return 'LTE';
    if (conn.contains(ConnectivityResult.ethernet)) return 'Ethernet';
    return 'None';
  }

  static Future<String> getIpAddress() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final info = NetworkInfo();
        final wifi = await info.getWifiIP();
        if (wifi != null && wifi.isNotEmpty) return wifi;
      }
      for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
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

  static String get platform => Platform.isAndroid ? 'Android' : (Platform.isWindows ? 'Windows' : 'Other');
}
