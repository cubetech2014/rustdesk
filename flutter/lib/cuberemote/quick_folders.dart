// CubeRemote 파일 전송 - 빠른 접근 폴더(다운로드 / 바탕화면 / 문서) 경로 해석
//
// 왜 필요한가
//   home + "\Downloads" 처럼 이름을 붙여 만드는 방식은 Windows 에서 자주 틀린다.
//     1) 사용자가 폴더 속성 → 위치 탭에서 다운로드/문서를 다른 드라이브로 옮길 수 있다.
//        (예: 다운로드 = H:\download, 문서 = H:\문서)
//     2) OneDrive 백업을 켜면 바탕화면/문서가 한글 이름으로 리디렉션된다.
//        (예: 바탕화면 = C:\Users\xxx\OneDrive\바탕 화면)
//   이 경우 C:\Users\xxx\Downloads 는 남아있는 빈 껍데기이거나 아예 없어서
//   "설정한 경로를 무시하고 C 드라이브로 간다" 로 보인다.
//
// 해결
//   로컬(관리자 PC)  : Windows Known Folder API (SHGetKnownFolderPath) 로 실제 경로를
//                      직접 물어본다. 리디렉션/드라이브 이동을 그대로 따라간다.
//   원격(POS 장비)   : 물어볼 방법이 없다. 파일 전송 프로토콜에 폴더 조회만 있고
//                      Known Folder 질의가 없기 때문. 대신 후보 경로 목록을 만들어
//                      FileController 가 한 번에 조회한 뒤 존재하는 것으로 이동한다.
//
// 외부 패키지 추가 없음 — dart:ffi + 이미 있는 package:ffi 만 사용.
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

enum CubeQuickFolder { pos, downloads, desktop, documents }

extension CubeQuickFolderLabel on CubeQuickFolder {
  String get label {
    switch (this) {
      case CubeQuickFolder.pos:
        return 'POS';
      case CubeQuickFolder.downloads:
        return '다운로드';
      case CubeQuickFolder.desktop:
        return '바탕화면';
      case CubeQuickFolder.documents:
        return '문서';
    }
  }
}

class CubeQuickFolders {
  CubeQuickFolders._();

  // KNOWNFOLDERID (shlguid.h). 값이 바뀌지 않는 상수라 문자열로 두고 런타임에 파싱한다.
  static const _folderIds = <CubeQuickFolder, String>{
    CubeQuickFolder.downloads: '374DE290-123F-4565-9164-39C4925E467B',
    CubeQuickFolder.desktop: 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641',
    CubeQuickFolder.documents: 'FDD39AD0-238F-46AF-ADB4-6C85480369C7',
  };

  // 세션 중에는 바뀌지 않으므로 1회만 조회. 실패도 캐시(null)해서 재시도 비용을 없앤다.
  static final _knownPathCache = <CubeQuickFolder, String?>{};

  /// 로컬(관리자 PC) 쪽 후보. **실제 존재하는 경로만** 우선순위 순으로 돌려준다.
  /// 첫 항목이 Windows 가 알려준 진짜 경로이고, 나머지는 API 실패 시 폴백.
  static List<String> localCandidates(
      CubeQuickFolder folder, String home, bool isWindows) {
    final out = <String>[];
    void add(String? path) {
      if (path == null || path.isEmpty || out.contains(path)) return;
      try {
        if (!Directory(path).existsSync()) return;
      } catch (_) {
        return;
      }
      out.add(path);
    }

    add(_knownFolderPath(folder));
    for (final p in _posInstallDirs(folder, isWindows)) {
      add(p);
    }
    for (final p in _guessUnderHome(folder, home, isWindows)) {
      add(p);
    }
    return out;
  }

  /// 원격(POS) 쪽 후보. 존재 여부를 여기서 확인할 수 없으므로 전부 돌려주고,
  /// FileController.openFirstExisting() 이 동시에 조회해 살아있는 것을 고른다.
  static List<String> remoteCandidates(
      CubeQuickFolder folder, String home, bool isWindows) {
    final out = <String>[];
    void add(String path) {
      if (path.isEmpty || out.contains(path)) return;
      out.add(path);
    }

    for (final p in _posInstallDirs(folder, isWindows)) {
      add(p);
    }
    for (final p in _guessUnderHome(folder, home, isWindows)) {
      add(p);
    }
    if (!isWindows) {
      // Android POS. home 이 앱 전용 디렉터리라 사용자 폴더가 그 아래에 없다.
      for (final p in _androidPublicDirs(folder)) {
        add(p);
      }
    }
    return out;
  }

  /// 홈 경로가 있어야 후보를 만들 수 있는 항목인지. POS 는 절대 경로라 불필요하므로
  /// 원격에서도 홈 확정(왕복 1회) 없이 바로 이동할 수 있다.
  static bool needsHome(CubeQuickFolder folder) =>
      folder != CubeQuickFolder.pos;

  /// CUBE POS 프로그램 설치 폴더. 홈 아래가 아니라 고정 절대 경로다.
  /// Windows POS 는 관례상 C:\cube, 드라이브를 나눠 쓴 매장은 D:\cube 를 쓴다.
  static List<String> _posInstallDirs(CubeQuickFolder folder, bool isWindows) {
    if (folder != CubeQuickFolder.pos || !isWindows) return const [];
    return const ['C:\\cube', 'D:\\cube'];
  }

  static List<String> _guessUnderHome(
      CubeQuickFolder folder, String home, bool isWindows) {
    if (home.isEmpty) return const [];
    final sep = isWindows ? '\\' : '/';
    final base =
        (home.endsWith('/') || home.endsWith('\\')) ? home : '$home$sep';
    final names = isWindows
        ? _windowsNames(folder)
        : _posixNames(folder).map((e) => e.replaceAll('\\', '/')).toList();
    return names.map((n) => '$base$n').toList();
  }

  static List<String> _windowsNames(CubeQuickFolder folder) {
    switch (folder) {
      case CubeQuickFolder.pos:
        // 홈 아래가 아니라 _posInstallDirs() 가 절대 경로로 처리한다.
        return const [];
      case CubeQuickFolder.downloads:
        return ['Downloads', 'OneDrive\\Downloads', 'OneDrive\\다운로드'];
      case CubeQuickFolder.desktop:
        // OneDrive 백업을 켠 한글 Windows 는 실제 폴더 이름이 "바탕 화면"(공백 포함).
        return [
          'Desktop',
          'OneDrive\\Desktop',
          'OneDrive\\바탕 화면',
          'OneDrive\\바탕화면'
        ];
      case CubeQuickFolder.documents:
        return ['Documents', 'OneDrive\\Documents', 'OneDrive\\문서'];
    }
  }

  static List<String> _posixNames(CubeQuickFolder folder) {
    switch (folder) {
      case CubeQuickFolder.pos:
        // Android POS 는 CUBE POS 설치 폴더 개념이 없다.
        return const [];
      case CubeQuickFolder.downloads:
        return ['Downloads', 'Download'];
      case CubeQuickFolder.desktop:
        return ['Desktop', '바탕화면'];
      case CubeQuickFolder.documents:
        return ['Documents', '문서'];
    }
  }

  static List<String> _androidPublicDirs(CubeQuickFolder folder) {
    switch (folder) {
      case CubeQuickFolder.pos:
        return const [];
      case CubeQuickFolder.downloads:
        return ['/storage/emulated/0/Download', '/sdcard/Download'];
      case CubeQuickFolder.desktop:
        return const [];
      case CubeQuickFolder.documents:
        return ['/storage/emulated/0/Documents', '/sdcard/Documents'];
    }
  }

  static String? _knownFolderPath(CubeQuickFolder folder) {
    if (!Platform.isWindows) return null;
    if (_knownPathCache.containsKey(folder)) return _knownPathCache[folder];
    final path = _queryKnownFolder(folder);
    _knownPathCache[folder] = path;
    return path;
  }

  static String? _queryKnownFolder(CubeQuickFolder folder) {
    final guid = _folderIds[folder];
    if (guid == null) return null;
    Pointer<Uint8> pGuid = nullptr;
    Pointer<Pointer<Utf16>> pOut = nullptr;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final ole32 = DynamicLibrary.open('ole32.dll');
      final shGetKnownFolderPath = shell32.lookupFunction<
          Int32 Function(
              Pointer<Uint8>, Uint32, IntPtr, Pointer<Pointer<Utf16>>),
          int Function(Pointer<Uint8>, int, int,
              Pointer<Pointer<Utf16>>)>('SHGetKnownFolderPath');
      final coTaskMemFree = ole32.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('CoTaskMemFree');

      pGuid = _allocGuid(guid);
      pOut = calloc<Pointer<Utf16>>();
      // dwFlags=0 (KF_FLAG_DEFAULT), hToken=0 (현재 사용자)
      final hr = shGetKnownFolderPath(pGuid, 0, 0, pOut);
      if (hr != 0) return null;
      final path = pOut.value.toDartString();
      coTaskMemFree(pOut.value.cast<Void>());
      return path.isEmpty ? null : path;
    } catch (e) {
      debugPrint('CubeQuickFolders: SHGetKnownFolderPath($folder) 실패: $e');
      return null;
    } finally {
      if (pGuid != nullptr) calloc.free(pGuid);
      if (pOut != nullptr) calloc.free(pOut);
    }
  }

  /// "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" → 16바이트 GUID 구조체 메모리.
  /// Data1(4) / Data2(2) / Data3(2) 는 리틀엔디언, Data4(8) 는 기록된 순서 그대로.
  static Pointer<Uint8> _allocGuid(String guid) {
    final hex = guid.replaceAll('-', '');
    final b = List<int>.generate(
        16, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
    final p = calloc<Uint8>(16);
    p[0] = b[3];
    p[1] = b[2];
    p[2] = b[1];
    p[3] = b[0];
    p[4] = b[5];
    p[5] = b[4];
    p[6] = b[7];
    p[7] = b[6];
    for (var i = 8; i < 16; i++) {
      p[i] = b[i];
    }
    return p;
  }
}
