// CubeRemote 설정 페이지 진입점 (모바일)
//  - 장비 등록 / 재등록
//  - 업데이트 확인 (수동) + 새 버전 발견 시 다운로드/설치
//  - 현재 버전 표시
import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';
import 'config.dart';
import 'registration_page.dart';
import 'update_service.dart';

class CubeRemoteSettingsSection {
  static AbstractSettingsSection build(BuildContext context) {
    return SettingsSection(
      title: const Text('CubeRemote'),
      tiles: [
        // 등록 메뉴는 agent 만 (viewer 는 매장 등록 안 함)
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
        // 업데이트 확인은 agent + viewer 둘 다
        _UpdateTile(),
      ],
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
        title: Text('새 버전 ${info.version}'),
        content: Text(info.memo.isNotEmpty ? info.memo : '업데이트 하시겠습니까?'),
        actions: [
          if (!info.force)
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('나중에')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('업데이트')),
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
