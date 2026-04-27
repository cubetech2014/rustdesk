// CubeRemote 업데이트 체크 서비스
// 시작 시 백그라운드로 check_update.php 조회 → 결과 SharedPreferences 저장
// 설정 페이지에서 "업데이트 가능" 표시 + 클릭 시 URL 열기 (사용자 설치)
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
  static bool _checked = false;

  /// 백그라운드 체크 — 호출 즉시 반환, 결과는 SharedPreferences에 저장
  static Future<void> checkInBackground() async {
    if (_checked) return;
    _checked = true;
    try {
      final platform = DeviceInfoHelper.platform;
      final result = await ApiClient.checkUpdate(platform, AGENT_VERSION);
      final prefs = await SharedPreferences.getInstance();
      if (result == null || result['update'] != true) {
        await prefs.remove(PREF_UPDATE_URL);
        return;
      }
      final url = (result['url'] ?? '').toString();
      if (url.isEmpty) return;
      await prefs.setString(PREF_UPDATE_URL, url);
      await prefs.setString(PREF_UPDATE_VERSION, (result['version'] ?? '').toString());
      await prefs.setString(PREF_UPDATE_MEMO, (result['memo'] ?? '').toString());
      await prefs.setBool(PREF_UPDATE_FORCE, result['force'] == true);
    } catch (_) {}
  }

  /// 저장된 업데이트 정보 (없으면 null)
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

  /// 사용자가 업데이트 클릭 시: 브라우저로 URL 열기 → 다운로드/설치
  static Future<void> openDownload(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class UpdateInfo {
  final String url;
  final String version;
  final String memo;
  final bool force;
  UpdateInfo({required this.url, required this.version, required this.memo, required this.force});
}
