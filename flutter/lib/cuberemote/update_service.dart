// CubeRemote 업데이트 서비스
// - 앱 시작 시 백그라운드 check_update.php 조회
// - 설정 페이지: 수동 "업데이트 확인" 버튼 + 새 버전 다운로드/설치 다이얼로그
// - Android: APK 다운로드 → MethodChannel('com.cube.cuberemote/install') 로 PackageInstaller intent
// - Windows: EXE/MSI 다운로드 → Process.run 또는 launchUrl (Phase D-B 에서 보강)
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api_client.dart';
import 'config.dart';
import 'device_info.dart';

const PREF_UPDATE_URL     = 'cuberemote_update_url';
const PREF_UPDATE_VERSION = 'cuberemote_update_version';
const PREF_UPDATE_MEMO    = 'cuberemote_update_memo';
const PREF_UPDATE_FORCE   = 'cuberemote_update_force';

class UpdateService {
  static const _installChannel = MethodChannel('com.cube.cuberemote/install');
  static bool _backgroundChecked = false;

  /// 백그라운드 1회 체크 (앱 시작 시) — 결과는 SharedPreferences 에만 기록
  static Future<void> checkInBackground() async {
    if (_backgroundChecked) return;
    _backgroundChecked = true;
    await _checkAndStore();
  }

  /// 즉시 체크 (수동 버튼) — 결과 UpdateInfo? 반환 + SharedPreferences 갱신
  static Future<UpdateInfo?> checkNow() async {
    return _checkAndStore();
  }

  static Future<UpdateInfo?> _checkAndStore() async {
    try {
      final platform = DeviceInfoHelper.platform;
      final result = await ApiClient.checkUpdate(platform, AGENT_VERSION, FLAVOR);
      final prefs = await SharedPreferences.getInstance();
      if (result == null || result['update'] != true) {
        await prefs.remove(PREF_UPDATE_URL);
        return null;
      }
      final url = (result['url'] ?? '').toString();
      if (url.isEmpty) return null;
      final info = UpdateInfo(
        url: url,
        version: (result['version'] ?? '').toString(),
        memo: (result['memo'] ?? '').toString(),
        force: result['force'] == true,
      );
      await prefs.setString(PREF_UPDATE_URL, info.url);
      await prefs.setString(PREF_UPDATE_VERSION, info.version);
      await prefs.setString(PREF_UPDATE_MEMO, info.memo);
      await prefs.setBool(PREF_UPDATE_FORCE, info.force);
      return info;
    } catch (_) {
      return null;
    }
  }

  /// SharedPreferences 에 저장된 pending 업데이트 정보
  static Future<UpdateInfo?> getPending() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(PREF_UPDATE_URL) ?? '';
    if (url.isEmpty) return null;
    return UpdateInfo(
      url: url,
      version: prefs.getString(PREF_UPDATE_VERSION) ?? '',
      memo: prefs.getString(PREF_UPDATE_MEMO) ?? '',
      force: prefs.getBool(PREF_UPDATE_FORCE) ?? false,
    );
  }

  /// 다운로드 + (Android) PackageInstaller / (Windows) 실행 / (기타) launchUrl
  /// settings_tile 등 Material context 안에서 호출 — showDialog 사용 OK
  static Future<void> downloadAndInstall(BuildContext context, UpdateInfo info) async {
    if (Platform.isAndroid) {
      await _downloadAndInstallAndroid(context, info);
    } else if (Platform.isWindows) {
      await _downloadAndRunWindows(context, info);
    } else {
      await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication);
    }
  }

  /// Material context 가 없는 곳 (앱 시작 시 _UpdateGate 등) 에서 호출하는 버전
  /// Get.dialog 사용 — RustDesk 의 GetMaterialApp navigator 활용
  static Future<void> downloadAndInstallGlobal(UpdateInfo info) async {
    if (Platform.isAndroid) {
      await _downloadAndInstallAndroidGlobal(info);
    } else if (Platform.isWindows) {
      await _downloadAndRunWindowsGlobal(info);
    } else {
      await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _downloadAndInstallAndroidGlobal(UpdateInfo info) async {
    Get.dialog(
      AlertDialog(
        title: Text('업데이트 v${info.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('다운로드 중...'),
          ],
        ),
      ),
      barrierDismissible: false,
    );
    String? errorMsg;
    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${dir.path}/cuberemote-update.apk');
      final resp = await http.get(Uri.parse(info.url));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      await file.writeAsBytes(resp.bodyBytes);
      await _installChannel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      errorMsg = e.toString();
    }
    if (Get.isDialogOpen ?? false) Get.back();
    if (errorMsg != null) {
      Get.snackbar('업데이트 실패', errorMsg, snackPosition: SnackPosition.BOTTOM);
    }
  }

  static Future<void> _downloadAndRunWindowsGlobal(UpdateInfo info) async {
    Get.dialog(
      AlertDialog(
        title: Text('업데이트 v${info.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('다운로드 중... 완료 후 인스톨러가 실행됩니다.'),
          ],
        ),
      ),
      barrierDismissible: false,
    );
    String? errorMsg;
    try {
      final dir = await getTemporaryDirectory();
      final ext = info.url.toLowerCase().endsWith('.msi') ? 'msi' : 'exe';
      final file = File('${dir.path}/cuberemote-update.$ext');
      final resp = await http.get(Uri.parse(info.url));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      await file.writeAsBytes(resp.bodyBytes);
      if (ext == 'msi') {
        await Process.start('msiexec', ['/i', file.path], mode: ProcessStartMode.detached);
      } else {
        await Process.start(file.path, [], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      errorMsg = e.toString();
    }
    if (Get.isDialogOpen ?? false) Get.back();
    if (errorMsg != null) {
      Get.snackbar('업데이트 실패', errorMsg, snackPosition: SnackPosition.BOTTOM);
    }
  }

  static Future<void> _downloadAndInstallAndroid(BuildContext context, UpdateInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('업데이트 v${info.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('다운로드 중...'),
          ],
        ),
      ),
    );

    String? errorMsg;
    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${dir.path}/cuberemote-update.apk');
      final resp = await http.get(Uri.parse(info.url));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      await file.writeAsBytes(resp.bodyBytes);
      await _installChannel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      errorMsg = e.toString();
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (errorMsg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('업데이트 실패: $errorMsg')),
      );
    }
  }

  static Future<void> _downloadAndRunWindows(BuildContext context, UpdateInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('업데이트 v${info.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('다운로드 중... 완료 후 인스톨러가 실행됩니다.'),
          ],
        ),
      ),
    );

    String? errorMsg;
    try {
      final dir = await getTemporaryDirectory();
      final ext = info.url.toLowerCase().endsWith('.msi') ? 'msi' : 'exe';
      final file = File('${dir.path}/cuberemote-update.$ext');
      final resp = await http.get(Uri.parse(info.url));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      await file.writeAsBytes(resp.bodyBytes);

      // 인스톨러 실행 (현재 앱은 그대로 — 인스톨러가 알아서 종료/대체)
      if (ext == 'msi') {
        await Process.start('msiexec', ['/i', file.path], mode: ProcessStartMode.detached);
      } else {
        await Process.start(file.path, [], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      errorMsg = e.toString();
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (errorMsg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('업데이트 실패: $errorMsg')),
      );
    }
  }
}

class UpdateInfo {
  final String url;
  final String version;
  final String memo;
  final bool force;
  UpdateInfo({required this.url, required this.version, required this.memo, required this.force});
}
