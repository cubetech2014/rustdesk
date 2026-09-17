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
        print("  build.rs: 이미 패치됨, 건너뜀")
        return

    crlf = "\r\n" in s
    old = OLD.replace("\n", "\r\n") if crlf else OLD
    new = NEW.replace("\n", "\r\n") if crlf else NEW
    n = s.count(old)
    if n != 1:
        raise SystemExit(
            "FATAL: build.rs 에서 원본 get_lib_dir() 를 %d 개 찾음 (1개여야 함). "
            "libsodium-sys 버전이 바뀐 듯하다." % n
        )
    io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))

    # 적용 검증.
    # 주의: mingw 분기(mingw/win32, mingw/win64)도 target_pointer_width 를 쓰므로
    # 그 문자열 자체로 판정하면 안 된다. msvc 하드코딩 경로가 사라졌는지를 본다.
    chk = io.open(p, encoding="utf-8", newline="").read()
    if MARKER not in chk:
        raise SystemExit("FATAL: 패치 후에도 새 코드가 없다")
    for lit in BAD_LITERALS:
        if '"%s"' % lit in chk:
            raise SystemExit("FATAL: 버그 있는 하드코딩 경로가 남아있다: %s" % lit)
    print("  build.rs 패치 완료")


def inject_patch_section(cargo_toml, crate_dir):
    s = io.open(cargo_toml, encoding="utf-8", newline="").read()
    if PATCH_LINE_MARKER in s:
        print("  Cargo.toml: 이미 주입됨, 건너뜀")
        return
    nl = "\r\n" if "\r\n" in s else "\n"
    header = "[patch.crates-io]" + nl
    if header not in s:
        raise SystemExit("FATAL: Cargo.toml 에 [patch.crates-io] 섹션이 없다")
    path_val = crate_dir.replace("\\", "/")
    entry = 'libsodium-sys = { path = "%s" }%s' % (path_val, nl)
    io.open(cargo_toml, "w", encoding="utf-8", newline="").write(
        s.replace(header, header + entry, 1)
    )
    print("  Cargo.toml 주입 완료: %s" % path_val)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("사용: fix_libsodium_sys.py <crate_dir> <cargo_toml>")
    crate_dir = os.path.abspath(sys.argv[1])
    cargo_toml = sys.argv[2]
    if not os.path.isfile(os.path.join(crate_dir, "build.rs")):
        raise SystemExit("FATAL: %s 에 build.rs 가 없다" % crate_dir)
    patch_build_rs(crate_dir)
    inject_patch_section(cargo_toml, crate_dir)
    print("완료")


if __name__ == "__main__":
    main()
