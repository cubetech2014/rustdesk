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

    // support 옵션 설정은 _UpdateGate 의 postFrameCallback 에서 처리
    // (onAppStart 는 initEnv 전이라 mainSetOption 이 silent fail)
  }

  /// 앱 루트 위젯 래핑
  /// - Agent flavor 첫 실행 → 매장 등록 화면
  /// - Agent 등록됨 / Viewer / Support → _UpdateGate 만 (widget tree 안정성 위해 단일 분기)
  ///   _UpdateGate 가 viewer 일 때 추가로 인증 route 처리.
  static Widget wrapApp(Widget child) {
    if (isSupportFlavor) {
      // 1회용 — 인증/등록 없음. _UpdateGate 의 postFrameCallback 이 비번 옵션 설정 (initEnv 후 시점이라 정상 동작)
      return _UpdateGate(child: child);
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (isSupportFlavor) {
        await _initSupport();
      }
      if (isViewerFlavor) {
        await _ensureAuth();
      }
      // 인증 후 (또는 viewer 가 아니면 곧장) 업데이트 모달 체크
      _maybePrompt();
    });
  }

  /// support flavor 1회용 임시 비번 옵션 설정
  /// onAppStart 가 아닌 여기서 호출 — initEnv 완료 후 시점이라 mainSetOption 정상 적용
  Future<void> _initSupport() async {
    try {
      await bind.mainSetOption(key: 'verification-method', value: 'use-temporary-password');
      await bind.mainSetOption(key: 'approve-mode', value: 'password');
      await bind.mainSetOption(key: 'temporary-password-length', value: '8');
      await bind.mainSetOption(key: 'allow-numeric-one-time-password', value: 'Y');
    } catch (_) {}
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
          Get.back();  // login route 닫고 App() initial route 로 복귀
        },
        initialMessage: reason,
      ),
      // initial route (App() 의 home) 는 보존 → 로그인 후 Get.back 으로 복귀 가능
      // 이전엔 (_) => false 라 모든 route 제거 → 로그인 후 갈 곳 없어 멈춤
      predicate: (route) => route.isFirst,
      transition: Transition.fadeIn,
      duration: const Duration(milliseconds: 200),
    );
  }

  Future<void> _maybePrompt() async {
    try {
      final info = await UpdateService.checkNow().timeout(const Duration(seconds: 8));
      if (info == null || !mounted) return;
      // shownKey 검사 제거 — "나중에" 눌러도 매 실행 시 다시 모달 표시
      // (운영 정책: 업데이트는 매장 안전상 빨리 보급되는 게 더 중요)

      final go = await Get.dialog<bool>(
        AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'NEW',
                  style: TextStyle(
                    color: Color(0xFFE53935),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                '업데이트 가능',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 480, maxWidth: 480, maxHeight: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 버전 비교 박스
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('현재 버전',
                                style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                            const SizedBox(height: 4),
                            Text(
                              AGENT_VERSION,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF94A3B8),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(Icons.arrow_forward, size: 20, color: Color(0xFFE53935)),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('새 버전',
                                style: TextStyle(fontSize: 11, color: Color(0xFFE53935), fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                            const SizedBox(height: 4),
                            Text(
                              info.version,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFE53935),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '업데이트 내역',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        info.memo.isNotEmpty ? info.memo : '업데이트 내역이 없습니다.',
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.55,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            // force=false: "나중에" (앱 계속 사용)
            // force=true:  "종료"   (앱 끄고 나중에 수동 설치 — 강제이지만 즉시 못할 수도)
            if (!info.force)
              TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text('나중에'),
              ),
            if (info.force)
              TextButton(
                onPressed: () {
                  Get.back(result: false);
                  exit(0);
                },
                child: const Text('종료', style: TextStyle(color: Color(0xFF64748B))),
              ),
            FilledButton(
              onPressed: () => Get.back(result: true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE53935),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              child: const Text('업데이트', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        barrierDismissible: !info.force,
      );
      if (go == true) {
        await UpdateService.downloadAndInstallGlobal(info);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
