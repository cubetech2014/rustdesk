#!/usr/bin/env python3
"""libsodium-sys 0.2.7 의 크로스컴파일 버그를 고쳐서 [patch.crates-io] 로 물린다.

버그:
  build.rs 의 get_lib_dir() 가 아래처럼 분기한다.
      #[cfg(all(target_env = "msvc", target_pointer_width = "32"))]  -> msvc/Win32/...
      #[cfg(all(target_env = "msvc", target_pointer_width = "64"))]  -> msvc/x64/...
  그런데 빌드 스크립트 안의 cfg 는 TARGET 이 아니라 HOST 를 가리킨다.
  x64 러너에서 i686 을 크로스컴파일하면 x64 lib 을 집어와서
  LNK4272 (machine type 'x64' conflicts with 'x86') + LNK1120 이 난다.

왜 SODIUM_LIB_DIR 로는 부족한가:
  그 환경변수는 호스트/타겟 구분 없이 모든 빌드에 적용된다. rustdesk 의 build.rs 가
  hbb_common 을 build-dependency 로 쓰기 때문에 libsodium-sys 는 호스트용으로도
  빌드되는데, 거기에 x86 lib 이 들어가면 이번엔 반대 방향으로 깨진다.
  (PoC run #4 에서 실제로 그렇게 깨졌다)

해법:
  CARGO_CFG_TARGET_POINTER_WIDTH 를 쓴다. cargo 가 빌드 대상에 맞춰 넣어주는 값이라
  build-dependencies 를 빌드할 때는 host 값(64), 일반 dependencies 를 i686 으로
  빌드할 때는 target 값(32)이 들어온다. 양쪽이 자동으로 맞는다.

사용: python fix_libsodium_sys.py <추출된_크레이트_경로> <레포_Cargo.toml_경로>
멱등 - 두 번 돌려도 안전하다.
"""
import io
import os
import sys

OLD = '''#[cfg(all(target_env = "msvc", target_pointer_width = "32"))]
fn get_lib_dir() -> PathBuf {
    if is_release_profile() {
        get_crate_dir().join("msvc/Win32/Release/v142/")
    } else {
        get_crate_dir().join("msvc/Win32/Debug/v142/")
    }
}

#[cfg(all(target_env = "msvc", target_pointer_width = "64"))]
fn get_lib_dir() -> PathBuf {
    if is_release_profile() {
        get_crate_dir().join("msvc/x64/Release/v142/")
    } else {
        get_crate_dir().join("msvc/x64/Debug/v142/")
    }
}'''

NEW = '''// CubeRemote patch: 원본은 target_pointer_width cfg 로 분기했으나, 빌드 스크립트의
// cfg 는 TARGET 이 아니라 HOST 를 가리킨다. CARGO_CFG_TARGET_POINTER_WIDTH 는 cargo 가
// 빌드 대상에 맞춰 넣어주므로 host 빌드와 target 빌드 양쪽 다 올바른 lib 을 집는다.
#[cfg(target_env = "msvc")]
fn get_lib_dir() -> PathBuf {
    let width = env::var("CARGO_CFG_TARGET_POINTER_WIDTH").unwrap_or_default();
    let arch = if width == "32" { "Win32" } else { "x64" };
    let profile = if is_release_profile() { "Release" } else { "Debug" };
    get_crate_dir().join(format!("msvc/{}/{}/v142/", arch, profile))
}'''

MARKER = "CARGO_CFG_TARGET_POINTER_WIDTH"
PATCH_LINE_MARKER = "libsodium-sys = { path ="
BAD_LITERALS = (
    "msvc/Win32/Release/v142/",
    "msvc/x64/Release/v142/",
    "msvc/Win32/Debug/v142/",
    "msvc/x64/Debug/v142/",
)


def patch_build_rs(crate_dir):
    p = os.path.join(crate_dir, "build.rs")
    s = io.open(p, encoding="utf-8", newline="").read()

    if MARKER in s:
        print("  build.rs: already patched, skipping")
        return

    crlf = "\r\n" in s
    old = OLD.replace("\n", "\r\n") if crlf else OLD
    new = NEW.replace("\n", "\r\n") if crlf else NEW
    n = s.count(old)
    if n != 1:
        raise SystemExit(
            "FATAL: found %d matches of the original get_lib_dir() in build.rs "
            "(expected exactly 1). libsodium-sys version may have changed." % n
        )
    io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))

    # 적용 검증.
    # 주의: mingw 분기(mingw/win32, mingw/win64)도 target_pointer_width 를 쓰므로
    # 그 문자열 자체로 판정하면 안 된다. msvc 하드코딩 경로가 사라졌는지를 본다.
    chk = io.open(p, encoding="utf-8", newline="").read()
    if MARKER not in chk:
        raise SystemExit("FATAL: patched marker missing after write")
    for lit in BAD_LITERALS:
        if '"%s"' % lit in chk:
            raise SystemExit("FATAL: buggy hardcoded path still present: %s" % lit)
    print("  build.rs patched")


def inject_patch_section(cargo_toml, crate_dir):
    s = io.open(cargo_toml, encoding="utf-8", newline="").read()
    if PATCH_LINE_MARKER in s:
        print("  Cargo.toml: patch entry already present, skipping")
        return
    nl = "\r\n" if "\r\n" in s else "\n"
    header = "[patch.crates-io]" + nl
    if header not in s:
        raise SystemExit("FATAL: no [patch.crates-io] section in Cargo.toml")
    path_val = crate_dir.replace("\\", "/")
    entry = 'libsodium-sys = { path = "%s" }%s' % (path_val, nl)
    io.open(cargo_toml, "w", encoding="utf-8", newline="").write(
        s.replace(header, header + entry, 1)
    )
    print("  Cargo.toml patched -> %s" % path_val)


def _force_utf8_output():
    """CI 러너의 콘솔 인코딩이 cp1252 라서 비ASCII 출력이 죽는다.
    아래 메시지는 전부 ASCII 로 쓰지만, 이후 수정으로 비ASCII 가 섞여도
    죽지 않도록 스트림 인코딩도 같이 바꿔둔다."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def main():
    _force_utf8_output()
    if len(sys.argv) != 3:
        raise SystemExit("usage: fix_libsodium_sys.py <crate_dir> <cargo_toml>")
    crate_dir = os.path.abspath(sys.argv[1])
    cargo_toml = sys.argv[2]
    if not os.path.isfile(os.path.join(crate_dir, "build.rs")):
        raise SystemExit("FATAL: no build.rs in %s" % crate_dir)
    patch_build_rs(crate_dir)
    inject_patch_section(cargo_toml, crate_dir)
    print("done")


if __name__ == "__main__":
    main()
