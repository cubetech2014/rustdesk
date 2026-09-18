// CubeRemote 런처 — 원격지원을 "받는" 사람에게 주는 단일 실행파일.
//
// 대상은 지식이 없는 사용자다. 우리는 "이거 실행하세요" 한 마디만 하면 되고,
// 나머지는 이 프로그램이 판단한다:
//   1. 1회용 지원인지 상시 설치인지 고른다
//   2. OS 가 32비트인지 64비트인지 알아낸다 (사용자는 모른다)
//   3. 서버에서 맞는 파일을 받아 실행한다
//
// 이 프로그램 자체는 i686 로 빌드한다. 32비트 실행파일은 64비트 Windows 에서도
// WOW64 로 돌기 때문에 이 하나로 모든 Windows 를 커버한다. 자기 자신이 비트를
// 타면 존재 이유가 사라진다.
//
// viewer(관리자용)는 이 런처의 대상이 아니다. 기존대로 x64 MSI 를 직접 설치한다.
//
// UI 에 대하여:
//   선택 화면은 Windows 네이티브 TaskDialog 의 명령 링크를 쓴다. MessageBox 는
//   버튼 라벨이 예/아니오/취소 로 고정이라 무엇이 무엇인지 본문을 읽어야만 알 수
//   있었다. 명령 링크는 버튼 자체에 제목 + 설명이 들어가서 오해의 여지가 없다.
//
//   TaskDialogIndirect 는 Common Controls 6.0 전용 함수다. build.rs 가 박는
//   매니페스트가 없으면 import 가 안 풀려 **실행 자체가 안 된다**. 그 매니페스트는
//   res/manifest.xml 에 이미 있던 것을 재사용한다 (DPI 인식도 같이 딸려온다).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Deserialize;
use std::path::PathBuf;

const LATEST_RELEASE_URL: &str = "https://remote.cube-tech.co.kr/api/cuberemote/latest_release.php";
const HTTP_TIMEOUT_SECS: u64 = 60;
const TITLE: &str = "CubeRemote 원격지원";

#[derive(Debug, Deserialize)]
struct LatestRelease {
    #[serde(default)]
    version: String,
    #[serde(default)]
    files: Vec<ReleaseFile>,
}

#[derive(Debug, Deserialize)]
struct ReleaseFile {
    #[serde(default)]
    file: String,
    #[serde(default)]
    url: String,
}

#[derive(Clone, Copy, PartialEq)]
enum Choice {
    Support,
    Install,
    Quit,
}

// ─── Win32 헬퍼 ────────────────────────────────────────────────────────────

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(windows)]
fn message_box(text: &str, flags: u32) -> i32 {
    use winapi::um::winuser::MessageBoxW;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(text).as_ptr(),
            wide(TITLE).as_ptr(),
            flags,
        )
    }
}

#[cfg(windows)]
fn error(text: &str) {
    use winapi::um::winuser::{MB_ICONERROR, MB_OK};
    message_box(text, MB_OK | MB_ICONERROR);
}

/// 사용자가 무엇을 원하는지 묻는다.
///
/// 명령 링크(TDF_USE_COMMAND_LINKS)는 버튼 하나에 "제목 + 설명" 두 줄을 담는다.
/// 버튼 텍스트의 첫 줄바꿈이 그 경계다.
#[cfg(windows)]
fn ask_choice() -> Choice {
    use winapi::um::commctrl::{
        TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOG_BUTTON, TDCBF_CANCEL_BUTTON,
        TDF_ALLOW_DIALOG_CANCELLATION, TDF_USE_COMMAND_LINKS,
    };

    const ID_SUPPORT: i32 = 101;
    const ID_INSTALL: i32 = 102;

    // 대화상자가 떠 있는 동안 이 문자열들이 살아있어야 한다.
    let title = wide("CubeRemote 원격지원");
    let instruction = wide("무엇을 하시겠습니까?");
    let content = wide("아래에서 선택하시면 나머지는 자동으로 진행됩니다.");
    // 버튼 텍스트의 첫 줄바꿈이 "제목 / 설명" 경계다.
    let b_support = wide("지금 한 번만 원격지원 받기\n설치하지 않습니다. 지원이 끝나면 창을 닫으면 됩니다.");
    let b_install = wide("이 컴퓨터에 설치해서 상시 관리받기\n매장 장비 등록용입니다. 설치 후 매장 정보를 입력합니다.");

    // TASKDIALOGCONFIG 와 TASKDIALOG_BUTTON 은 #[repr(packed)] 이다.
    // 필드에 값을 대입하는 것은 괜찮지만 필드의 참조(&cfg.어떤필드)를 만들면 안 된다.
    // 아이콘(u1)은 union 이라 건드리지 않고 0 으로 둔다 = 아이콘 없음.
    let mut buttons: [TASKDIALOG_BUTTON; 2] = unsafe { std::mem::zeroed() };
    buttons[0].nButtonID = ID_SUPPORT;
    buttons[0].pszButtonText = b_support.as_ptr();
    buttons[1].nButtonID = ID_INSTALL;
    buttons[1].pszButtonText = b_install.as_ptr();

    let mut cfg: TASKDIALOGCONFIG = unsafe { std::mem::zeroed() };
    cfg.cbSize = std::mem::size_of::<TASKDIALOGCONFIG>() as u32;
    cfg.dwFlags = TDF_USE_COMMAND_LINKS | TDF_ALLOW_DIALOG_CANCELLATION;
    cfg.dwCommonButtons = TDCBF_CANCEL_BUTTON;
    cfg.pszWindowTitle = title.as_ptr();
    cfg.pszMainInstruction = instruction.as_ptr();
    cfg.pszContent = content.as_ptr();
    cfg.cButtons = 2;
    cfg.pButtons = buttons.as_ptr();

    let mut pressed: i32 = 0;
    let hr = unsafe {
        TaskDialogIndirect(
            &cfg,
            &mut pressed,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    // S_OK 가 아니면 설정이 잘못됐다는 뜻. 사용자를 막다른 길에 두지 않는다.
    if hr != 0 {
        return ask_choice_fallback();
    }

    match pressed {
        ID_SUPPORT => Choice::Support,
        ID_INSTALL => Choice::Install,
        _ => Choice::Quit,
    }
}

/// TaskDialog 가 실패했을 때의 폴백. 보기 좋진 않지만 어디서나 동작한다.
#[cfg(windows)]
fn ask_choice_fallback() -> Choice {
    use winapi::um::winuser::{IDNO, IDYES, MB_ICONQUESTION, MB_YESNOCANCEL};
    let text = "\
무엇을 하시겠습니까?

[예]      지금 한 번만 원격지원 받기
          설치하지 않습니다. 지원이 끝나면 닫으면 됩니다.

[아니오]  이 컴퓨터에 설치해서 상시 관리받기
          매장 장비 등록용입니다.

[취소]    종료";
    match message_box(text, MB_YESNOCANCEL | MB_ICONQUESTION) {
        x if x == IDYES => Choice::Support,
        x if x == IDNO => Choice::Install,
        _ => Choice::Quit,
    }
}

/// OS 가 64비트인지 32비트인지.
///
/// 이 프로세스는 항상 32비트라 자기 자신을 봐서는 알 수 없다.
/// GetNativeSystemInfo 는 WOW64 아래에서도 "진짜" 시스템 정보를 돌려준다.
#[cfg(windows)]
fn native_arch() -> &'static str {
    use winapi::um::sysinfoapi::GetNativeSystemInfo;
    use winapi::um::winnt::PROCESSOR_ARCHITECTURE_AMD64;
    unsafe {
        let mut si = std::mem::zeroed();
        GetNativeSystemInfo(&mut si);
        if si.u.s().wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 {
            "x64"
        } else {
            "x86"
        }
    }
}

/// 파일을 실행한다. ShellExecuteW 를 쓰는 이유는 MSI 설치에 필요한 UAC 승격을
/// 셸이 알아서 처리해주기 때문이다.
#[cfg(windows)]
fn shell_execute(file: &str, params: &str) -> Result<(), String> {
    use winapi::um::shellapi::ShellExecuteW;
    use winapi::um::winuser::SW_SHOWNORMAL;
    let r = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            wide("open").as_ptr(),
            wide(file).as_ptr(),
            if params.is_empty() {
                std::ptr::null()
            } else {
                wide(params).as_ptr()
            },
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    // ShellExecute 는 성공 시 32보다 큰 값을 돌려준다 (역사적 이유).
    if (r as usize) > 32 {
        Ok(())
    } else {
        Err(format!("실행 실패 (코드 {})", r as usize))
    }
}

// ─── 서버 조회 / 다운로드 ──────────────────────────────────────────────────

fn http_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("네트워크 초기화 실패: {}", e))
}

/// 서버에 "지금 배포 중인 버전의 이 조합 파일" 을 묻는다.
/// 런처는 자기 버전이 없으므로 check_update.php 가 아니라 latest_release.php 를 쓴다.
fn fetch_file(flavor: &str, arch: &str) -> Result<(String, ReleaseFile), String> {
    let resp = http_client()?
        .get(LATEST_RELEASE_URL)
        .query(&[("platform", "Windows"), ("flavor", flavor), ("arch", arch)])
        .send()
        .map_err(|e| format!("서버에 연결할 수 없습니다.\n\n{}", e))?;

    if !resp.status().is_success() {
        return Err(format!("서버 응답 오류 (HTTP {})", resp.status()));
    }

    let rel: LatestRelease = resp
        .json()
        .map_err(|e| format!("서버 응답을 해석할 수 없습니다.\n\n{}", e))?;

    match rel.files.into_iter().next() {
        Some(f) if !f.url.is_empty() => Ok((rel.version, f)),
        // 빌드되지 않는 조합. 32비트 support 가 아직 없을 때 여기로 온다.
        _ => Err(String::new()),
    }
}

/// 청크 단위로 받으면서 진행률을 갱신한다.
///
/// 한 번에 다 받아서 쓰면(resp.bytes()) 24MB 동안 화면이 멈춘 것처럼 보인다.
/// 사용자는 지식이 없는 사람이라 "멈췄나?" 하고 꺼버리기 쉽다.
#[cfg(windows)]
fn download(
    url: &str,
    filename: &str,
    win: Option<&cube_ui::ProgressWindow>,
) -> Result<PathBuf, String> {
    use std::io::{Read, Write};

    let path = std::env::temp_dir().join(filename);
    let mut resp = http_client()?
        .get(url)
        .send()
        .map_err(|e| format!("다운로드 실패: {}", e))?;
    if !resp.status().is_success() {
        return Err(format!("다운로드 실패 (HTTP {})", resp.status()));
    }

    let total = resp.content_length();
    let mut file = std::fs::File::create(&path).map_err(|e| format!("파일 저장 실패: {}", e))?;
    let mut buf = vec![0u8; 64 * 1024];
    let mut done: u64 = 0;
    // 화면에 보이는 값이 실제로 바뀔 때만 다시 그린다.
    // 청크마다 갱신하면 24MB 에 380번을 그리게 되고, STATIC 컨트롤은 이중
    // 버퍼링이 없어서 그게 깜빡임으로 보인다.
    // 전체 크기를 아는 경우는 퍼센트(최대 101회), 모르면 1MB 단위로 센다.
    let mut last_tick = u64::MAX;

    loop {
        let n = resp
            .read(&mut buf)
            .map_err(|e| format!("다운로드 중 끊겼습니다: {}", e))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|e| format!("파일 저장 실패: {}", e))?;
        done += n as u64;

        if let Some(w) = win {
            let tick = match total {
                Some(t) if t > 0 => (done * 100) / t,
                _ => done / 1048576,
            };
            if tick != last_tick {
                last_tick = tick;
                match total {
                    Some(t) if t > 0 => {
                        w.set_progress(tick as u32);
                        w.set_text(&format!(
                            "내려받는 중...  {:.1} / {:.1} MB",
                            done as f64 / 1048576.0,
                            t as f64 / 1048576.0
                        ));
                    }
                    // Content-Length 가 없는 경우. 받은 양만 보여준다.
                    _ => w.set_text(&format!("내려받는 중...  {:.1} MB", done as f64 / 1048576.0)),
                }
            }
            // 갱신을 건너뛴 때도 불러야 한다. 이걸 빼먹으면 창이 "응답 없음" 으로
            // 하얗게 변한다.
            w.pump();
        }
    }
    Ok(path)
}

// ─── 흐름 ──────────────────────────────────────────────────────────────────

#[cfg(windows)]
fn run() -> Result<(), String> {
    let choice = ask_choice();
    if choice == Choice::Quit {
        return Ok(());
    }

    let arch = native_arch();
    let flavor = if choice == Choice::Support {
        "support"
    } else {
        "agent"
    };

    let (version, file) = match fetch_file(flavor, arch) {
        Ok(v) => v,
        // 빈 에러 = 그 조합이 없다는 뜻. 사용자에게는 기술 용어 대신 상황을 설명한다.
        Err(e) if e.is_empty() => {
            if choice == Choice::Support {
                error(
                    "이 컴퓨터(32비트 Windows)에서는 1회용 원격지원을 아직 \
                     사용할 수 없습니다.\n\n담당자에게 문의해 주세요.",
                );
            } else {
                error("이 컴퓨터에 맞는 설치 파일이 없습니다.\n\n담당자에게 문의해 주세요.");
            }
            return Ok(());
        }
        Err(e) => return Err(e),
    };

    // 진행률 창을 띄우고 다운로드한다. 창 생성이 실패해도(None) 작업은 계속한다 -
    // 표시가 없을 뿐 기능은 같다.
    let win = cube_ui::ProgressWindow::new(
        "CubeRemote 원격지원",
        &format!("프로그램을 준비하고 있습니다. ({})", version),
    );

    let path = download(&file.url, &file.file, win.as_ref())?;
    let path_str = path.to_string_lossy().to_string();

    if let Some(w) = win.as_ref() {
        w.set_progress(100);
        w.set_text("준비가 끝났습니다. 다음 화면이 곧 나타납니다.");
        w.pump();
    }
    // 설치 화면과 겹치지 않게 먼저 닫는다.
    drop(win);

    if choice == Choice::Support {
        // portable 실행파일. 그냥 실행하면 된다.
        shell_execute(&path_str, "")?;
    } else {
        // MSI 는 msiexec 에 넘긴다. UAC 승격은 셸이 처리한다.
        // /passive: 진행률만 보이고 사용자 입력을 묻지 않는다. /norestart: 재부팅 안 함.
        shell_execute("msiexec.exe", &format!("/i \"{}\" /passive /norestart", path_str))?;
    }
    Ok(())
}

#[cfg(windows)]
fn main() {
    if let Err(e) = run() {
        if !e.is_empty() {
            error(&e);
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("CubeRemote 런처는 Windows 전용입니다.");
    std::process::exit(1);
}
