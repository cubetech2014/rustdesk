// CubeRemote 업데이트 서비스
// - 앱 시작 시 백그라운드 check_update.php 조회
// - 설정 페이지: 수동 "업데이트 확인" 버튼 + 새 버전 다운로드/설치 다이얼로그
// - Android: APK 다운로드 → MethodChannel('com.cube.cuberemote/install') 로 PackageInstaller intent
// - Windows: MSI 다운로드 → batch script 우회 패턴으로 자동 설치 (viewer.exe 잠금 회피)
//
// v1.0.26 변경:
//   1) Windows: 직접 msiexec 호출 → batch script 호출로 변경.
//      이전: viewer 가 1초 후 exit → msiexec 가 자기 .exe 잠금 못 풀고 즉시 abort
//      이후: viewer → batch (3초 sleep + msiexec) 호출 → exit. batch 가 viewer 종료를 기다리고 설치
//   2) Android: http.get → http.Client().send() streaming + 실제 진행률 + 60초 timeout
//   3) 다이얼로그 제목 'v${info.version}' → '${info.version}' (info.version 이 이미 'v1.0.X' 라 vv 더블 v 발생)
import 'dart:async';
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

  // ─── Android ───────────────────────────────────────────────────────────

  static Future<void> _downloadAndInstallAndroidGlobal(UpdateInfo info) async {
    final progress = ValueNotifier<double>(0);
    final status   = ValueNotifier<String>('연결 중...');

    Get.dialog(
      _DownloadProgressDialog(
        title: '업데이트 ${info.version}',
        progress: progress,
        status: status,
      ),
      barrierDismissible: false,
    );

    String? errorMsg;
    try {
      final dir  = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${dir.path}/cuberemote-update.apk');
      await _downloadStreaming(info.url, file, progress, status);
      status.value = '설치 화면 표시 중...';
      await _installChannel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      errorMsg = e.toString();
    }
    if (Get.isDialogOpen ?? false) Get.back();
    if (errorMsg != null) {
      Get.snackbar(
        '업데이트 실패',
        '직접 다운로드: ${info.url}\n오류: $errorMsg',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 8),
        isDismissible: true,
      );
    }
  }

  static Future<void> _downloadAndInstallAndroid(BuildContext context, UpdateInfo info) async {
    final progress = ValueNotifier<double>(0);
    final status   = ValueNotifier<String>('연결 중...');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadProgressDialog(
        title: '업데이트 ${info.version}',
        progress: progress,
        status: status,
      ),
    );

    String? errorMsg;
    try {
      final dir  = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${dir.path}/cuberemote-update.apk');
      await _downloadStreaming(info.url, file, progress, status);
      status.value = '설치 화면 표시 중...';
      await _installChannel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      errorMsg = e.toString();
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (errorMsg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('업데이트 실패: $errorMsg\n직접 다운로드: ${info.url}'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  // ─── Windows ───────────────────────────────────────────────────────────

  static Future<void> _downloadAndRunWindowsGlobal(UpdateInfo info) async {
    final progress = ValueNotifier<double>(0);
    final status   = ValueNotifier<String>('연결 중...');

    Get.dialog(
      _DownloadProgressDialog(
        title: '업데이트 ${info.version}',
        progress: progress,
        status: status,
        finalNote: '다운로드 완료 후 자동 종료되고 인스톨러가 진행됩니다.',
      ),
      barrierDismissible: false,
    );

    String? errorMsg;
    bool launchedInstaller = false;
    try {
      final dir  = await getTemporaryDirectory();
      final ext  = info.url.toLowerCase().endsWith('.msi') ? 'msi' : 'exe';
      final file = File('${dir.path}/cuberemote-update.$ext');
      await _downloadStreaming(info.url, file, progress, status);
      status.value = '인스톨러 시작 중...';
      await _launchWindowsInstaller(file.path, ext);
      launchedInstaller = true;
    } catch (e) {
      errorMsg = e.toString();
    }
    if (Get.isDialogOpen ?? false) Get.back();
    if (errorMsg != null) {
      Get.snackbar('업데이트 실패', errorMsg, snackPosition: SnackPosition.BOTTOM);
      return;
    }
    if (launchedInstaller) {
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }

  static Future<void> _downloadAndRunWindows(BuildContext context, UpdateInfo info) async {
    final progress = ValueNotifier<double>(0);
    final status   = ValueNotifier<String>('연결 중...');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadProgressDialog(
        title: '업데이트 ${info.version}',
        progress: progress,
        status: status,
        finalNote: '다운로드 완료 후 자동 종료되고 인스톨러가 진행됩니다.',
      ),
    );

    String? errorMsg;
    bool launchedInstaller = false;
    try {
      final dir  = await getTemporaryDirectory();
      final ext  = info.url.toLowerCase().endsWith('.msi') ? 'msi' : 'exe';
      final file = File('${dir.path}/cuberemote-update.$ext');
      await _downloadStreaming(info.url, file, progress, status);
      status.value = '인스톨러 시작 중...';
      await _launchWindowsInstaller(file.path, ext);
      launchedInstaller = true;
    } catch (e) {
      errorMsg = e.toString();
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (errorMsg != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('업데이트 실패: $errorMsg')));
      return;
    }
    if (launchedInstaller) {
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }

  /// Windows: batch script 를 한 단계 끼워서 viewer 종료 후 msiexec 실행.
  /// 직접 msiexec 호출 시 viewer.exe 의 OS file lock 이 안 풀려서 MSI 가 즉시 abort 함.
  /// batch 가 timeout 으로 viewer 가 완전 unload 될 시간을 벌어주고, 그 후 설치 진행.
  static Future<void> _launchWindowsInstaller(String filePath, String ext) async {
    if (ext != 'msi') {
      // exe 직접 실행 (drop-in 인스톨러는 자체적으로 처리)
      await Process.start(filePath, [], mode: ProcessStartMode.detached);
      return;
    }

    final dir     = await getTemporaryDirectory();
    final batPath = '${dir.path}\\cuberemote-update.bat';
    final logPath = '${dir.path}\\cuberemote-update.log';
    // batch 가 자기 자신을 지우는 건 어렵지만, viewer 다음 실행 시 덮어쓰기 되므로 상관없음.
    // /passive: UI 표시 + 사용자 입력 없음
    // /norestart: 자동 재부팅 안 함
    // /L*V "log": verbose log (트러블슈팅용)
    final batContent = [
      '@echo off',
      'rem CubeRemote auto-update batch — generated by viewer',
      'rem viewer 가 종료될 시간을 벌어주고 msiexec 호출.',
      '',
      'timeout /t 3 /nobreak > nul',
      '',
      'msiexec /i "$filePath" /passive /norestart /L*V "$logPath"',
      'rem msiexec exit code: %ERRORLEVEL%',
      '',
      'rem 임시 MSI 정리 (이미 설치 완료됐으면 OK)',
      'del /q "$filePath" 2> nul',
      '',
      'exit /b 0',
    ].join('\r\n');
    await File(batPath).writeAsString(batContent);

    // detached + cmd /c 로 viewer 가 죽어도 batch 가 끝까지 살아남음.
    // 콘솔 창이 잠깐 보일 수 있는데 사용자 경험상 인스톨러가 곧 떠서 묻힘.
    await Process.start(
      'cmd',
      ['/c', 'start', '""', '/min', batPath],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  // ─── 공용: streaming 다운로드 + 진행률 보고 ─────────────────────────────────

  /// http.Client().send() 으로 chunk-by-chunk 다운로드하면서 진행률 갱신.
  /// 60초 connection timeout, chunk 사이 30초 stall timeout.
  static Future<void> _downloadStreaming(
    String url,
    File dest,
    ValueNotifier<double> progress,
    ValueNotifier<String> status,
  ) async {
    final client = http.Client();
    try {
      final req  = http.Request('GET', Uri.parse(url));
      final resp = await client.send(req).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final total    = resp.contentLength ?? 0;
      final sink     = dest.openWrite();
      var received   = 0;
      var lastChunkAt = DateTime.now();

      try {
        await for (final chunk in resp.stream.timeout(
          const Duration(seconds: 30),
          onTimeout: (s) {
            s.addError(TimeoutException('30초간 데이터 없음 (네트워크 점검)'));
            s.close();
          },
        )) {
          sink.add(chunk);
          received += chunk.length;
          lastChunkAt = DateTime.now();
          if (total > 0) {
            progress.value = received / total;
            status.value = '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
          } else {
            status.value = '${(received / 1024 / 1024).toStringAsFixed(1)} MB';
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      // 마지막 chunk 후 progress 1.0 강제
      if (total > 0) progress.value = 1.0;
      // dummy use of lastChunkAt to silence unused warning (실제론 위 timeout 에서 처리됨)
      lastChunkAt.toString();
    } finally {
      client.close();
    }
  }
}

/// 다운로드 진행률 다이얼로그 — Android/Windows 공용
class _DownloadProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<double> progress;
  final ValueNotifier<String> status;
  final String? finalNote;

  const _DownloadProgressDialog({
    required this.title,
    required this.progress,
    required this.status,
    this.finalNote,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v > 0 ? v : null,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, s, __) => Text(s, style: const TextStyle(fontSize: 13)),
          ),
          if (finalNote != null) ...[
            const SizedBox(height: 6),
            Text(finalNote!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ],
      ),
    );
  }
}

class UpdateInfo {
  final String url;
  final String version;
  final String memo;
  final bool force;
  UpdateInfo({required this.url, required this.version, required this.memo, required this.force});
}
