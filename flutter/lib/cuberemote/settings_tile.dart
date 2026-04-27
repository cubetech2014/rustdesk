// CubeRemote 설정 페이지 진입점
// RustDesk 모바일 설정 페이지에 끼워넣어 등록/재등록을 다시 할 수 있게 함.
import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';
import 'config.dart';
import 'registration_page.dart';

class CubeRemoteSettingsSection {
  /// 모바일 설정 페이지에 끼워넣을 섹션 반환.
  /// Viewer flavor 면 빈 섹션 (보이지 않음).
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
      ],
    );
  }
}
