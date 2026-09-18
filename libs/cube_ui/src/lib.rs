// CubeRemote 최소 Win32 UI.
//
// Flutter 를 못 쓰는 자리를 메운다. headless 빌드에는 UI 가 통째로 없고,
// 런처는 1MB 대를 유지해야 해서 UI 프레임워크를 넣을 수 없다.
//
// 여기 있는 것은 "동작에 꼭 필요한 최소한" 이다. 보기 좋게 만드는 것보다
// 어떤 Windows 에서도 똑같이 뜨는 것을 우선했다.
//
// 지금은 진행률 창만 있다. 입력 폼(agent 매장 등록)과 표시 창(support ID/비번)이
// 뒤따를 예정이고, 그때 이 파일의 창 생성 / 메시지 루프를 공유한다.
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
            let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
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
