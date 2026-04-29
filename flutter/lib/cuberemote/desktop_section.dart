// Windows desktop 좌측 사이드바 CubeRemote 섹션
//   - 현재 버전 표시
//   - 로그인 사용자 정보 (viewer 한정)
//   - 업데이트 확인 버튼 (pending 있으면 빨간 배지 + 클릭 시 모달)
//   - 로그아웃 버튼 (viewer 한정)
//
// 모바일의 settings_tile.dart 와 동일 기능 + desktop 디자인.
// apply.sh 가 desktop_home_page.dart 의 buildLeftPane children 에 widget 주입.
import 'dart:io';
import 'package:flutter/material.dart';
import 'config.dart';
import 'session_service.dart';
import 'update_service.dart';

class CubeRemoteDesktopSection extends StatefulWidget {
  const CubeRemoteDesktopSection({super.key});

  @override
  State<CubeRemoteDesktopSection> createState() => _CubeRemoteDesktopSectionState();
}

class _CubeRemoteDesktopSectionState extends State<CubeRemoteDesktopSection> {
  bool _checking = false;
  UpdateInfo? _pending;

  @override
  void initState() {
    super.initState();
    // v1.0.29: support flavor 는 1회용 portable — 업데이트 의미 없음. pending 조회 skip.
    if (!isSupportFlavor) {
      UpdateService.getPending().then((info) {
        if (mounted) setState(() => _pending = info);
      });
    }
  }

  Future<void> _onCheckUpdate() async {
    if (_pending != null) {
      await UpdateService.downloadAndInstall(context, _pending!);
      return;
    }
    setState(() => _checking = true);
    final info = await UpdateService.checkNow();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _pending = info;
    });
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('최신 버전입니다'), duration: Duration(seconds: 2)),
      );
    } else {
      await UpdateService.downloadAndInstall(context, info);
    }
  }

  Future<void> _onLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('정말 로그아웃하시겠습니까?\n로그아웃 후 viewer 가 종료됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SessionService.logout();
    // viewer 종료 — 다음 실행 시 _UpdateGate 가 미인증 상태 감지 → 로그인 화면
    await Future.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final user = isViewerFlavor ? SessionService.user : null;
    final hasUpdate = _pending != null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 버전 헤더
          Row(
            children: [
              const Icon(Icons.verified_outlined, size: 14, color: Color(0xFFE53935)),
              const SizedBox(width: 6),
              const Text(
                'CubeRemote',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              const SizedBox(width: 6),
              Text(
                AGENT_VERSION,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (user != null) ...[
            const SizedBox(height: 8),
            _miniRow(
              icon: Icons.account_circle_outlined,
              text: user.id,
              subtitle: '${user.name} / ${user.pNm}',
            ),
          ],
          const SizedBox(height: 10),
          // 업데이트 버튼 — support flavor 는 1회용 portable 이라 노출 X
          if (!isSupportFlavor)
            _SidebarButton(
              icon: hasUpdate ? Icons.system_update : Icons.refresh,
              label: hasUpdate ? '업데이트 가능 (${_pending!.version})' : '업데이트 확인',
              color: hasUpdate ? const Color(0xFFE53935) : null,
              badge: hasUpdate,
              loading: _checking,
              onTap: _checking ? null : _onCheckUpdate,
            ),
          if (isViewerFlavor) ...[
            const SizedBox(height: 6),
            _SidebarButton(
              icon: Icons.logout,
              label: '로그아웃',
              onTap: _onLogout,
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniRow({required IconData icon, required String text, String? subtitle}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade400),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final bool badge;
  final bool loading;
  final VoidCallback? onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    this.color,
    this.badge = false,
    this.loading = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.grey.shade400;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          children: [
            if (loading)
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: c),
              )
            else
              Icon(icon, size: 14, color: c),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color != null ? color : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (badge)
              Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFE53935),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
