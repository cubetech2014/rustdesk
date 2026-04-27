// CubeRemote 설정 페이지 진입점
// RustDesk 모바일 설정 페이지에 끼워넣어:
//  1) 등록/재등록
//  2) 업데이트 가능 알림 + 클릭 시 다운로드 페이지로 이동
import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'registration_page.dart';
import 'update_service.dart';

class CubeRemoteSettingsSection {
  static AbstractSettingsSection build(BuildContext context) {
    if (isViewerFlavor) {
      return CustomSettingsSection(child: const SizedBox.shrink());
    }
    return SettingsSection(
      title: const Text('CubeRemote'),
      tiles: [
        SettingsTile(
          title: const Text('장비 등록 / 재등록'),
          description: const Text('매장 ID, 매장명, 장비 닉네임 변경'),
          leading: const Icon(Icons.app_registration),
          onPressed: (ctx) {
            Navigator.of(ctx).push(MaterialPageRoute(
              builder: (_) => CubeRemoteRegistrationPage(
                onDone: () => Navigator.of(ctx).pop(),
              ),
            ));
          },
        ),
        _UpdateTile(),
      ],
    );
  }
}

class _UpdateTile extends AbstractSettingsTile {
  const _UpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UpdateInfo?>(
      future: UpdateService.getPending(),
      builder: (ctx, snap) {
        final info = snap.data;
        final hasUpdate = info != null;
        return ListTile(
          leading: Icon(
            hasUpdate ? Icons.system_update : Icons.check_circle_outline,
            color: hasUpdate ? Colors.orange : Colors.grey,
          ),
          title: Text(hasUpdate ? '업데이트 가능 (v${info.version})' : '최신 버전 사용 중'),
          subtitle: hasUpdate && info.memo.isNotEmpty ? Text(info.memo) : null,
          trailing: hasUpdate ? const Icon(Icons.chevron_right) : null,
          onTap: hasUpdate
              ? () async {
                  await UpdateService.openDownload(info.url);
                }
              : null,
        );
      },
    );
  }
}
