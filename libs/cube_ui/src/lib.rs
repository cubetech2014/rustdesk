// CubeRemote 최소 Win32 UI.
//
// Flutter 를 못 쓰는 자리를 메운다. headless 빌드에는 UI 가 통째로 없고,
// 런처는 1MB 대를 유지해야 해서 UI 프레임워크를 넣을 수 없다.
//
// 여기 있는 것은 "동작에 꼭 필요한 최소한" 이다. 보기 좋게 만드는 것보다
// 어떤 Windows 에서도 똑같이 뜨는 것을 우선했다.
//
// 두 가지가 있다:
//   ProgressWindow  런처의 다운로드 진행률
//   SupportWindow   support x86 의 ID / 임시 비밀번호 표시
// 창 생성과 메시지 루프를 공유한다.
//
// 장비 등록 입력 폼도 한 번 만들었다가 지웠다 (커밋 fa0d7cf30). 32비트 agent 를
// 만들지 않기로 하면서 쓸 곳이 없어졌다. 필요해지면 그 커밋에서 되살리면 된다.
#![cfg(windows)]

use std::ptr::null_mut;
use winapi::shared::minwindef::{LPARAM, LRESULT, UINT, WPARAM};
use winapi::shared::windef::{HBRUSH, HFONT, HWND};
use winapi::um::libloaderapi::GetModuleHandleW;
use winapi::um::wingdi::{GetStockObject, DEFAULT_GUI_FONT};
use winapi::um::winuser::*;

/// UTF-16 + NUL. Win32 의 W 계열 함수는 전부 이 형태를 받는다.
pub fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// 창과 자식 컨트롤이 같은 폰트를 쓰게 한다.
/// 이걸 안 하면 Windows 가 1990년대 시스템 폰트를 써서 유독 낡아 보인다.
unsafe fn apply_default_font(hwnd: HWND) {
    let font = GetStockObject(DEFAULT_GUI_FONT as i32) as HFONT;
    SendMessageW(hwnd, WM_SETFONT, font as WPARAM, 1 as LPARAM);
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        // 사용자가 X 를 눌러도 프로세스를 끝내지 않는다.
        // 다운로드 중 창만 닫히고 작업은 계속되게 둔다 - 중간에 죽이면
        // 반쯤 받은 파일이 남는다.
        WM_CLOSE => 0,
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// 진행률 창. 다운로드처럼 몇십 초 걸리는 작업에 붙인다.
///
/// 스레드를 쓰지 않는다. 호출자가 작업 중간중간 `set_progress` 와 `pump` 를
/// 불러주는 방식이다. 스레드를 쓰면 동기화 코드가 늘고, 이 정도 용도에는
/// 과하다.
pub struct ProgressWindow {
    hwnd: HWND,
    label: HWND,
    bar: HWND,
}

impl ProgressWindow {
    /// 창을 띄운다. 실패하면 None - 호출자는 UI 없이 작업을 계속하면 된다.
    pub fn new(title: &str, text: &str) -> Option<Self> {
        unsafe {
            // 진행률 바는 공용 컨트롤이라 초기화가 필요하다.
            let mut icc: winapi::um::commctrl::INITCOMMONCONTROLSEX = std::mem::zeroed();
            icc.dwSize = std::mem::size_of::<winapi::um::commctrl::INITCOMMONCONTROLSEX>() as u32;
            icc.dwICC = winapi::um::commctrl::ICC_PROGRESS_CLASS;
            winapi::um::commctrl::InitCommonControlsEx(&icc);

            let hinst = GetModuleHandleW(null_mut());
            let class_name = wide("CubeRemoteProgress");

            let mut wc: WNDCLASSW = std::mem::zeroed();
            wc.lpfnWndProc = Some(wnd_proc);
            wc.hInstance = hinst;
            wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
            wc.hbrBackground = (COLOR_BTNFACE + 1) as HBRUSH;
            wc.lpszClassName = class_name.as_ptr();
            // 이미 등록돼 있으면 0 을 돌려주는데 그것도 정상이다.
            RegisterClassW(&wc);

            // 크기 조절도 최대화도 필요 없다. 제목줄 + 닫기만.
            //
            // WS_CLIPCHILDREN 이 중요하다. 이게 없으면 부모 창이 자식 컨트롤이
            // 덮고 있는 영역까지 배경을 칠한 뒤 자식이 그 위에 다시 그린다.
            // 갱신이 잦을수록 그 순간이 깜빡임으로 보인다.
            let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN;
            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                wide(title).as_ptr(),
                style,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                420,
                150,
                null_mut(),
                null_mut(),
                hinst,
                null_mut(),
            );
            if hwnd.is_null() {
                return None;
            }

            let static_class = wide("STATIC");
            let label = CreateWindowExW(
                0,
                static_class.as_ptr(),
                wide(text).as_ptr(),
                WS_CHILD | WS_VISIBLE,
                16,
                18,
                380,
                40,
                hwnd,
                null_mut(),
                hinst,
                null_mut(),
            );

            let bar_class = wide(winapi::um::commctrl::PROGRESS_CLASS);
            let bar = CreateWindowExW(
                0,
                bar_class.as_ptr(),
                null_mut(),
                WS_CHILD | WS_VISIBLE,
                16,
                66,
                380,
                22,
                hwnd,
                null_mut(),
                hinst,
                null_mut(),
            );
            if !bar.is_null() {
                SendMessageW(
                    bar,
                    winapi::um::commctrl::PBM_SETRANGE32,
                    0,
                    100 as LPARAM,
                );
            }

            apply_default_font(label);

            ShowWindow(hwnd, SW_SHOWNORMAL);
            UpdateWindow(hwnd);

            let w = ProgressWindow { hwnd, label, bar };
            w.pump();
            Some(w)
        }
    }

    /// 0 ~ 100.
    pub fn set_progress(&self, percent: u32) {
        if self.bar.is_null() {
            return;
        }
        let p = percent.min(100);
        unsafe {
            SendMessageW(
                self.bar,
                winapi::um::commctrl::PBM_SETPOS,
                p as WPARAM,
                0,
            );
        }
    }

    pub fn set_text(&self, text: &str) {
        if self.label.is_null() {
            return;
        }
        unsafe {
            SetWindowTextW(self.label, wide(text).as_ptr());
        }
    }

    /// 대기 중인 창 메시지를 처리한다.
    ///
    /// 이걸 주기적으로 안 부르면 창이 "응답 없음" 으로 하얗게 변한다.
    /// 다운로드 루프 안에서 청크마다 부르는 것을 전제로 만들었다.
    pub fn pump(&self) {
        unsafe {
            let mut msg: MSG = std::mem::zeroed();
            while PeekMessageW(&mut msg, null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}

impl Drop for ProgressWindow {
    fn drop(&mut self) {
        unsafe {
            if !self.hwnd.is_null() {
                DestroyWindow(self.hwnd);
            }
            // DestroyWindow 가 남긴 메시지를 비운다. 안 비우면 다음에 뜨는
            // 대화상자가 그 메시지를 받아 이상하게 동작할 수 있다.
            let mut msg: MSG = std::mem::zeroed();
            while PeekMessageW(&mut msg, null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────
// 1회용 원격지원 표시 창 (support x86)
//
// 고객이 화면의 ID 와 비밀번호를 읽어 상담원에게 불러주는 것이 이 창의 전부다.
// 그래서 support 는 UI 를 버릴 수 없었고, headless 코어 위에 이 창만 얹는다.
//
// ID 는 서버에 접속해야 발급되므로 창이 뜬 직후에는 비어 있다. 호출자가
// 주기적으로 set_info 와 pump 를 부르며 채워 넣는 구조다 (ProgressWindow 와 동일).
//
// 창을 닫으면 지원이 끝난다. is_closed() 가 true 가 되면 호출자가 프로세스를
// 종료하면 된다.
// ─────────────────────────────────────────────────────────────────────────

// 창이 닫혔는지. 이 창도 프로세스당 하나, 메인 스레드 전용이라 thread_local 로 충분하다.
thread_local! {
    static SUPPORT_CLOSED: std::cell::Cell<bool> = std::cell::Cell::new(false);
}

/// STATIC 라벨 하나를 만든다.
///
/// 클로저로 쓰지 않는 이유: unsafe 블록이 클로저 본문까지 덮는지가 한눈에
/// 분명하지 않다. 로컬에서 컴파일해볼 수 없는 상황이라 모호한 쪽을 피했다.
unsafe fn static_label(
    parent: HWND,
    hinst: winapi::shared::minwindef::HINSTANCE,
    text: &str,
    x: i32,
    y: i32,
    w: i32,
) -> HWND {
    let h = CreateWindowExW(
        0,
        wide("STATIC").as_ptr(),
        wide(text).as_ptr(),
        WS_CHILD | WS_VISIBLE,
        x,
        y,
        w,
        24,
        parent,
        null_mut(),
        hinst,
        null_mut(),
    );
    apply_default_font(h);
    h
}

unsafe extern "system" fn support_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CLOSE => {
            // 진행률 창과 반대로 닫기가 정상 경로다. 닫으면 지원 종료다.
            SUPPORT_CLOSED.with(|c| c.set(true));
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            SUPPORT_CLOSED.with(|c| c.set(true));
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// ID / 비밀번호를 보여주는 창.
pub struct SupportWindow {
    hwnd: HWND,
    id_value: HWND,
    pw_value: HWND,
}

impl SupportWindow {
    pub fn new() -> Option<Self> {
        unsafe {
            SUPPORT_CLOSED.with(|c| c.set(false));

            let hinst = GetModuleHandleW(null_mut());
            let class_name = wide("CubeRemoteSupport");

            let mut wc: WNDCLASSW = std::mem::zeroed();
            wc.lpfnWndProc = Some(support_proc);
            wc.hInstance = hinst;
            wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
            wc.hbrBackground = (COLOR_BTNFACE + 1) as HBRUSH;
            wc.lpszClassName = class_name.as_ptr();
            RegisterClassW(&wc);

            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                wide("CubeRemote 원격지원").as_ptr(),
                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                420,
                250,
                null_mut(),
                null_mut(),
                hinst,
                null_mut(),
            );
            if hwnd.is_null() {
                return None;
            }

            static_label(hwnd, hinst, "아래 두 가지를 상담원에게 알려주세요.", 18, 16, 380);
            static_label(hwnd, hinst, "ID", 18, 62, 80);
            let id_value = static_label(hwnd, hinst, "발급 중...", 110, 62, 280);
            static_label(hwnd, hinst, "비밀번호", 18, 96, 80);
            let pw_value = static_label(hwnd, hinst, "", 110, 96, 280);
            static_label(hwnd, hinst, "이 창을 닫으면 원격지원이 종료됩니다.", 18, 150, 380);

            ShowWindow(hwnd, SW_SHOWNORMAL);
            UpdateWindow(hwnd);

            let w = SupportWindow {
                hwnd,
                id_value,
                pw_value,
            };
            w.pump();
            Some(w)
        }
    }

    /// 화면의 값을 갱신한다. 같은 값이면 아무것도 하지 않는다 -
    /// 불필요한 다시 그리기가 깜빡임이 된다 (진행률 창에서 겪었다).
    pub fn set_info(&self, id: &str, password: &str) {
        unsafe {
            set_text_if_changed(self.id_value, id);
            set_text_if_changed(self.pw_value, password);
        }
    }

    pub fn pump(&self) {
        unsafe {
            let mut msg: MSG = std::mem::zeroed();
            while PeekMessageW(&mut msg, null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }

    /// 사용자가 창을 닫았는가. true 면 호출자가 프로세스를 끝내면 된다.
    pub fn is_closed(&self) -> bool {
        SUPPORT_CLOSED.with(|c| c.get())
    }
}

impl Drop for SupportWindow {
    fn drop(&mut self) {
        unsafe {
            if !self.hwnd.is_null() && !self.is_closed() {
                DestroyWindow(self.hwnd);
            }
        }
    }
}

/// 값이 실제로 바뀔 때만 SetWindowTextW 를 부른다.
unsafe fn set_text_if_changed(hwnd: HWND, text: &str) {
    if hwnd.is_null() {
        return;
    }
    let len = GetWindowTextLengthW(hwnd);
    if len >= 0 {
        let mut buf: Vec<u16> = vec![0; (len + 1) as usize];
        let n = GetWindowTextW(hwnd, buf.as_mut_ptr(), len + 1);
        let cur = if n > 0 {
            String::from_utf16_lossy(&buf[..n as usize])
        } else {
            String::new()
        };
        if cur == text {
            return;
        }
    }
    SetWindowTextW(hwnd, wide(text).as_ptr());
}
