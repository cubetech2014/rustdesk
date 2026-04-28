// RustDesk 포크의 main.dart 에서 CubeRemote 초기화 훅
// 사용법: RustDesk runMobileApp() / runMainApp() 시작 시 호출
//   await CubeRemoteMainHook.onAppStart();
//   runApp(CubeRemoteMainHook.wrapApp(App()));
//
// v1.0.24 핵심 변경: viewer flavor 도 wrapApp 에서 _UpdateGate(child) 만 반환.
// _ViewerAuthGate (v1.0.21~v1.0.23) 가 build 분기마다 다른 MaterialApp 인스턴스를
// 반환해서 RustDesk windowManager + GetX navigator 초기화와 충돌 → viewer 빈 창.
// 이제 인증 게이트는 _UpdateGate 의 postFrameCallback 에서 Get.offAll(ViewerLoginPage)
// 로 처리 — App() 의 GetMaterialApp 안에 route 로 진입해서 widget tree 변경 없음.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
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
      // 토큰 캐시만 복원 — 서버 검증 + 로그인 게이트는 _UpdateGate 가 mount 후 수행
      await SessionService.restoreFromCache();
      return;
    }

    if (isSupportFlavor) {
      // 1회용 — 매 실행 시 8자리 숫자 임시 비번 + 비번 인증 모드 강제
      try {
        await bind.mainSetOption(key: 'verification-method', value: 'use-temporary-password');
        await bind.mainSetOption(key: 'approve-mode', value: 'password');
        await bind.mainSetOption(key: 'temporary-password-length', value: '8');
        await bind.mainSetOption(key: 'allow-numeric-one-time-password', value: 'Y');
      } catch (_) {}
      return;
    }
  }

  /// 앱 루트 위젯 래핑
  /// - Agent flavor 첫 실행 → 매장 등록 화면
  /// - Agent 등록됨 / Viewer / Support → _UpdateGate 만 (widget tree 안정성 위해 단일 분기)
  ///   _UpdateGate 가 viewer 일 때 추가로 인증 route 처리.
  static Widget wrapApp(Widget child) {
    if (isSupportFlavor) {
      // 1회용 — 인증/등록 모두 없음
      return child;
    }

    if (isViewerFlavor) {
      // viewer: _UpdateGate 가 인증 검사 + 업데이트 모달 모두 담당
      return _UpdateGate(child: child);
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

/// 앱 진입 직후:
/// 1) viewer flavor: 인증 검사 → 미인증/만료 시 ViewerLoginPage 라우트 push (Get.offAll)
/// 2) 새 버전 발견 시 업데이트 다이얼로그
/// 모두 child (App() = GetMaterialApp) mount 이후 postFrameCallback 에서 진행.
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (isViewerFlavor) {
        await _ensureAuth();
      }
      // 인증 후 (또는 viewer 가 아니면 곧장) 업데이트 모달 체크
      _maybePrompt();
    });
  }

  /// viewer 인증 게이트 — 미인증이면 ViewerLoginPage 로 route 전환
  Future<void> _ensureAuth() async {
    // RustDesk 의 GetMaterialApp navigator 가 init 되도록 대기
    await Future.delayed(const Duration(seconds: 2));

    // 토큰 캐시 검증
    bool authenticated = false;
    if (SessionService.isLoggedIn) {
      authenticated = await SessionService.validateWithServer();
    }

    if (!authenticated) {
      await _gotoLogin();
      return;
    }

    // 인증 OK — 60초 ping 시작
    SessionService.startPingTimer(onForcedLogout: (reason) async {
      SessionService.stopPingTimer();
      await _gotoLogin(reason: reason);
    });
  }

  Future<void> _gotoLogin({String? reason}) async {
    if (!mounted) return;
    await Get.offAll(
      () => ViewerLoginPage(
        onSuccess: () {
          // 로그인 성공 → main UI 로 복귀, ping 시작
          SessionService.startPingTimer(onForcedLogout: (r) async {
            SessionService.stopPingTimer();
            await _gotoLogin(reason: r);
          });
          Get.back();  // login route 닫고 _UpdateGate (App) 으로 복귀
        },
        initialMessage: reason,
      ),
      // 다른 어떤 route 도 못 빠져나가게 (predicate false → 모든 이전 route 제거)
      predicate: (_) => false,
      transition: Transition.fadeIn,
      duration: const Duration(milliseconds: 200),
    );
  }

  Future<void> _maybePrompt() async {
    try {
      final info = await UpdateService.checkNow().timeout(const Duration(seconds: 8));
      if (info == null || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final shown = prefs.getString(_shownKey) ?? '';
      if (shown == info.version && !info.force) return;

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
      // 사용자가 명시적으로 답한 경우만 마킹 (silently fail 시 다음 시작 시 재시도)
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
