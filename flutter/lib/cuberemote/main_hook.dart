// RustDesk 포크의 main.dart 에서 CubeRemote 초기화 훅
// 사용법: RustDesk main() / runMobileApp() 시작 시 호출
//   await CubeRemoteMainHook.onAppStart();
//   runApp(CubeRemoteMainHook.wrapApp(App()));

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_service.dart';
import 'config.dart';
import 'registration_page.dart';
import 'update_service.dart';

class CubeRemoteMainHook {
  /// 앱 시작 시 호출.
  /// - 모든 flavor: 백그라운드 업데이트 체크
  /// - Agent flavor + 등록된 기기: heartbeat 시작
  static Future<void> onAppStart() async {
    // viewer 도 새 버전 체크
    UpdateService.checkInBackground();

    if (!isAgentFlavor) return;
    final prefs = await SharedPreferences.getInstance();
    final registered = (prefs.getString(PREF_SHOP_ID) ?? '').isNotEmpty;
    if (registered) {
      AgentService.start();
    }
  }

  /// 앱 루트 위젯 래핑
  /// - Agent flavor 첫 실행 → 등록 화면
  /// - 등록된 Agent → _UpdateGate 가 새 버전 발견 시 다이얼로그 표시 후 child 진입
  /// - Viewer flavor → child 그대로
  static Widget wrapApp(Widget child) {
    // Viewer: 등록 화면 없음, 업데이트 게이트만
    if (isViewerFlavor) return _UpdateGate(child: child);

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
            return _UpdateGate(child: child);
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

/// 앱 진입 직후 1회 — 새 버전 있으면 다이얼로그.
/// 다이얼로그 표시는 Material context 안에서 한 번만 (이전 표시 버전을 SharedPreferences 에 기록).
class _UpdateGate extends StatefulWidget {
  final Widget child;
  const _UpdateGate({required this.child});

  @override
  State<_UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<_UpdateGate> {
  static const _shownKey = 'cuberemote_update_shown_version';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  Future<void> _maybePrompt() async {
    try {
      final info = await UpdateService.checkNow().timeout(const Duration(seconds: 8));
      if (info == null || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final shown = prefs.getString(_shownKey) ?? '';
      if (shown == info.version && !info.force) return; // 이미 한 번 안내한 동일 버전 (force 면 재표시)

      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        barrierDismissible: !info.force,
        builder: (d) => AlertDialog(
          title: Text('새 버전 ${info.version}'),
          content: Text(info.memo.isNotEmpty ? info.memo : '업데이트 하시겠습니까?'),
          actions: [
            if (!info.force)
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('나중에')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('업데이트')),
          ],
        ),
      );
      await prefs.setString(_shownKey, info.version);
      if (go == true && mounted) {
        await UpdateService.downloadAndInstall(context, info);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
