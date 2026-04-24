// RustDesk 포크의 main.dart에서 CubeRemote 초기화 훅
// 사용법: RustDesk flutter/lib/main.dart 의 main() 안에서 아래를 호출
//
//   await CubeRemoteMainHook.onAppStart();
//
// RustDesk 서비스 초기화 직후에 두면 됨

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_service.dart';
import 'config.dart';
import 'registration_page.dart';

class CubeRemoteMainHook {
  /// RustDesk main() 시작 직후 호출.
  /// - Agent flavor + 에이전트 등록된 기기면 heartbeat 시작
  /// - Viewer flavor 는 heartbeat 미실행
  static Future<void> onAppStart() async {
    if (!isAgentFlavor) return;
    final prefs = await SharedPreferences.getInstance();
    final registered = (prefs.getString(PREF_SHOP_ID) ?? '').isNotEmpty;
    if (registered) {
      AgentService.start();
    }
  }

  /// 앱 루트 위젯 래핑
  /// - Agent flavor: 최초 실행 시 등록 화면 → 이후 RustDesk UI
  /// - Viewer flavor: 등록 화면 건너뜀, 바로 RustDesk UI (관리자용)
  static Widget wrapApp(Widget child) {
    if (isViewerFlavor) return child;

    return FutureBuilder<_LaunchState>(
      future: _resolveLaunch(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
        }
        switch (snap.data!) {
          case _LaunchState.firstRun:
            return MaterialApp(
              home: CubeRemoteRegistrationPage(
                onDone: () => runApp(child),
              ),
            );
          case _LaunchState.normal:
            return child;
        }
      },
    );
  }

  static Future<_LaunchState> _resolveLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final shopId  = prefs.getString(PREF_SHOP_ID) ?? '';
    final skipped = prefs.getBool('cuberemote_skipped') ?? false;
    if (shopId.isEmpty && !skipped) return _LaunchState.firstRun;
    return _LaunchState.normal;
  }
}

enum _LaunchState { firstRun, normal }
