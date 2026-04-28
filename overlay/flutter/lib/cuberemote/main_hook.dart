// RustDesk 포크의 main.dart 에서 CubeRemote 초기화 훅
// 사용법: RustDesk runMobileApp() / runMainApp() 시작 시 호출
//   await CubeRemoteMainHook.onAppStart();
//   runApp(CubeRemoteMainHook.wrapApp(App()));

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_service.dart';
import 'config.dart';
import 'registration_page.dart';
import 'session_service.dart';
import 'update_service.dart';
import 'viewer_login_page.dart';

class CubeRemoteMainHook {
  /// 앱 시작 시 호출.
  /// - 모든 flavor: 백그라운드 업데이트 체크
  /// - Agent flavor + 등록된 기기: heartbeat 시작
  /// - Viewer flavor: 캐시 토큰 복원 (있으면 로그인 게이트 스킵)
  /// - Support flavor: 아무 추가 동작 없음 (RustDesk default)
  static Future<void> onAppStart() async {
    UpdateService.checkInBackground();

    if (isAgentFlavor) {
      final prefs = await SharedPreferences.getInstance();
      final registered = (prefs.getString(PREF_SHOP_ID) ?? '').isNotEmpty;
      if (registered) {
        AgentService.start();
      }
      return;
    }

    if (isViewerFlavor) {
      // 토큰 복원만 (서버 검증은 wrapApp 의 _ViewerAuthGate 가 별도 수행)
      await SessionService.restoreFromCache();
      return;
    }

    // support flavor → no-op (RustDesk default 동작)
  }

  /// 앱 루트 위젯 래핑
  /// - Agent flavor 첫 실행 → 매장 등록 화면
  /// - Agent 등록됨 → _UpdateGate
  /// - Viewer flavor → _ViewerAuthGate (로그인 + 60초 ping)
  /// - Support flavor → child 그대로 (인증/등록 모두 없음)
  static Widget wrapApp(Widget child) {
    if (isSupportFlavor) {
      // 1회용 — 아무 추가 게이트 없이 RustDesk default UI
      return child;
    }

    if (isViewerFlavor) {
      return _ViewerAuthGate(child: child);
    }

    // Agent
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

/// Viewer 인증 게이트
/// - 캐시 토큰 + 서버 검증 통과 시 child (실제 RustDesk UI) 진입
/// - 그 외 ViewerLoginPage 표시
/// - child 진입 시 60초 ping timer 자동 시작
class _ViewerAuthGate extends StatefulWidget {
  final Widget child;
  const _ViewerAuthGate({required this.child});
  @override
  State<_ViewerAuthGate> createState() => _ViewerAuthGateState();
}

class _ViewerAuthGateState extends State<_ViewerAuthGate> {
  bool _checking = true;
  bool _authenticated = false;
  String? _flashMessage;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // restoreFromCache 는 onAppStart 에서 이미 시도됨 — 여기선 서버 검증만
    if (SessionService.isLoggedIn) {
      final ok = await SessionService.validateWithServer();
      if (!mounted) return;
      if (ok) {
        setState(() { _authenticated = true; _checking = false; });
        _startPing();
        return;
      }
    }
    if (!mounted) return;
    setState(() { _authenticated = false; _checking = false; });
  }

  void _onLoginSuccess() {
    setState(() { _authenticated = true; _flashMessage = null; });
    _startPing();
  }

  void _startPing() {
    SessionService.startPingTimer(onForcedLogout: (reason) {
      if (!mounted) return;
      SessionService.stopPingTimer();
      setState(() {
        _authenticated = false;
        _flashMessage = reason;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0B1220),
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }
    if (!_authenticated) {
      return ViewerLoginPage(
        onSuccess: _onLoginSuccess,
        initialMessage: _flashMessage,
      );
    }
    return _UpdateGate(child: widget.child);
  }
}

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
      // RustDesk 의 GetMaterialApp navigator 가 init 되도록 살짝 대기
      await Future.delayed(const Duration(seconds: 2));
      final info = await UpdateService.checkNow().timeout(const Duration(seconds: 8));
      if (info == null || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final shown = prefs.getString(_shownKey) ?? '';
      if (shown == info.version && !info.force) return; // 이미 한 번 안내한 동일 버전 (force 면 재표시)

      // _UpdateGate 자체는 MaterialApp 위에 있어 showDialog 가 동작 안 함 — Get.dialog 사용
      final go = await Get.dialog<bool>(
        AlertDialog(
          title: Text('새 버전 ${info.version}'),
          content: Text(info.memo.isNotEmpty ? info.memo : '업데이트 하시겠습니까?'),
          actions: [
            if (!info.force)
              TextButton(onPressed: () => Get.back(result: false), child: const Text('나중에')),
            FilledButton(onPressed: () => Get.back(result: true), child: const Text('업데이트')),
          ],
        ),
        barrierDismissible: !info.force,
      );
      // 사용자가 명시적으로 답한 경우만 마킹 (Get.dialog 가 silently fail 하면 go=null 이라 마킹 안 함 → 다음 시작 시 재시도)
      if (go != null) {
        await prefs.setString(_shownKey, info.version);
      }
      if (go == true) {
        await UpdateService.downloadAndInstallGlobal(info);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
