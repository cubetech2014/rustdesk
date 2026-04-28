// CubeRemote 설정 페이지 진입점 (모바일)
//  - 장비 등록 / 재등록 (agent)
//  - 로그인 정보 + 로그아웃 (viewer)
//  - 업데이트 확인 (수동) + 새 버전 발견 시 다운로드/설치
//  - 현재 버전 표시
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';
import 'config.dart';
import 'registration_page.dart';
import 'session_service.dart';
import 'update_service.dart';

class CubeRemoteSettingsSection {
  static AbstractSettingsSection build(BuildContext context) {
    return SettingsSection(
      title: const Text('CubeRemote'),
      tiles: [
        // agent: 매장 등록 / 재등록
        if (isAgentFlavor)
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
        // viewer: 로그인 사용자 정보 (탭 안 됨, 정보 표시만)
        if (isViewerFlavor && SessionService.user != null)
          SettingsTile(
            title: Text('로그인: ${SessionService.user!.id}'),
            description: Text('${SessionService.user!.name} / ${SessionService.user!.pNm}'),
            leading: const Icon(Icons.account_circle_outlined),
          ),
        // 업데이트 확인은 agent + viewer 둘 다
        _UpdateTile(),
        // viewer: 로그아웃
        if (isViewerFlavor)
          _LogoutTile(),
      ],
    );
  }
}

class _LogoutTile extends AbstractSettingsTile {
  const _LogoutTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.logout, color: Color(0xFFE53935)),
      title: const Text('로그아웃', style: TextStyle(color: Color(0xFFE53935))),
      subtitle: const Text('서버 세션 종료 후 로그인 화면으로'),
      onTap: () async {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('로그아웃'),
            content: const Text('정말 로그아웃하시겠습니까?'),
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
        if (confirm != true) return;
        await SessionService.logout();
        // _ViewerAuthGate 는 widget tree 의 root 라 안에서 setState 트리거 어려움
        // → 앱 자체 종료, 사용자가 다시 실행하면 깨끗하게 로그인 화면
        await Future.delayed(const Duration(milliseconds: 200));
        exit(0);
      },
    );
  }
}

class _UpdateTile extends AbstractSettingsTile {
  const _UpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    return _UpdateTileWidget();
  }
}

class _UpdateTileWidget extends StatefulWidget {
  @override
  State<_UpdateTileWidget> createState() => _UpdateTileWidgetState();
}

class _UpdateTileWidgetState extends State<_UpdateTileWidget> {
  bool _checking = false;
  UpdateInfo? _pending;

  @override
  void initState() {
    super.initState();
    UpdateService.getPending().then((info) {
      if (mounted) setState(() => _pending = info);
    });
  }

  Future<void> _onTap() async {
    final ctx = context;
    if (_pending != null) {
      // 이미 발견된 업데이트 → 바로 다운로드 다이얼로그
      await _confirmAndInstall(_pending!);
      return;
    }
    // 즉시 체크
    setState(() => _checking = true);
    final info = await UpdateService.checkNow();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _pending = info;
    });
    if (info == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('최신 버전입니다')),
      );
    } else {
      await _confirmAndInstall(info);
    }
  }

  Future<void> _confirmAndInstall(UpdateInfo info) async {
    final ctx = context;
    final go = await showDialog<bool>(
      context: ctx,
      barrierDismissible: !info.force,
      builder: (d) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                'NEW',
                style: TextStyle(color: Color(0xFFE53935), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5),
              ),
            ),
            const SizedBox(width: 10),
            Text(info.version, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 320, maxWidth: 360, maxHeight: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '새 버전이 출시되었습니다.',
                style: TextStyle(fontSize: 13, color: Color(0xFF334155)),
              ),
              const SizedBox(height: 14),
              Container(height: 1, color: const Color(0xFFE5E7EB)),
              const SizedBox(height: 12),
              const Text(
                '업데이트 내역',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF64748B), letterSpacing: 0.8),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      info.memo.isNotEmpty ? info.memo : '업데이트 내역이 없습니다.',
                      style: const TextStyle(fontSize: 12, height: 1.55, color: Color(0xFF1F2937)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!info.force)
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('나중에')),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            child: const Text('업데이트', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      await UpdateService.downloadAndInstall(ctx, info);
      // 설치 후 정보 재조회
      final fresh = await UpdateService.getPending();
      if (mounted) setState(() => _pending = fresh);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final hasUpdate = pending != null;
    return ListTile(
      leading: Icon(
        hasUpdate ? Icons.system_update : Icons.cloud_done_outlined,
        color: hasUpdate ? Colors.orange : Colors.grey,
      ),
      title: Text(
        hasUpdate ? '업데이트 가능 (${pending.version})' : '업데이트 확인',
      ),
      subtitle: Text(
        hasUpdate
            ? (pending.memo.isNotEmpty ? pending.memo : '탭하여 다운로드')
            : '현재 버전: $AGENT_VERSION',
      ),
      trailing: _checking
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right),
      onTap: _checking ? null : _onTap,
    );
  }
}
