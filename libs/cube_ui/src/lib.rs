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
use winapi::shared::minwindef::{HINSTANCE, LPARAM, LRESULT, UINT, WPARAM};
use winapi::shared::windef::{HBRUSH, HFONT, HMENU, HWND};
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
// 장비 등록 입력 폼
//
// headless agent(32비트 Windows)에는 Flutter 등록 화면이 없다. 그 자리를 메운다.
//
// 서비스(SYSTEM)는 세션 0 격리 때문에 사용자에게 창을 못 띄운다. 그래서 이 창은
// 서비스가 아니라 사용자 세션에서 `rustdesk.exe --cube-register` 로 따로 띄운다.
// 런처가 MSI 설치 직후 그 명령을 실행하는 구조다.
//
// 입력은 두 개뿐이다. 매장명 / 대리점 / 본사는 verify_shop.php 응답에서 서버가
// 채워주므로 현장에서 칠 이유가 없다. 오타 여지를 줄이는 쪽이 낫다.
// ─────────────────────────────────────────────────────────────────────────

/// 등록 폼이 돌려주는 값.
pub struct RegisterInput {
    pub shop_id: String,
    pub device_nm: String,
}

const ID_SHOP: i32 = 201;
const ID_NAME: i32 = 202;
const ID_OK: i32 = 203;
const ID_CANCEL: i32 = 204;

struct FormState {
    edit_shop: HWND,
    edit_name: HWND,
    result: Option<RegisterInput>,
}

// 이 폼은 프로세스당 한 번, 메인 스레드에서만 뜬다. 그래서 창 핸들에 포인터를
// 매달지 않고 thread_local 로 상태를 들고 있어도 안전하고, 그 편이 훨씬 단순하다.
thread_local! {
    static FORM: std::cell::RefCell<Option<FormState>> = std::cell::RefCell::new(None);
}

unsafe fn read_text(hwnd: HWND) -> String {
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return String::new();
    }
    let mut buf: Vec<u16> = vec![0; (len + 1) as usize];
    let n = GetWindowTextW(hwnd, buf.as_mut_ptr(), len + 1);
    if n <= 0 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..n as usize]).trim().to_string()
}

unsafe extern "system" fn form_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_COMMAND => {
            let id = winapi::shared::minwindef::LOWORD(wparam as u32) as i32;
            if id == ID_OK {
                let mut ok = false;
                FORM.with(|f| {
                    if let Some(st) = f.borrow_mut().as_mut() {
                        let shop = read_text(st.edit_shop);
                        if shop.is_empty() {
                            // 매장 ID 가 비면 등록 자체가 성립하지 않는다.
                            MessageBoxW(
                                hwnd,
                                wide("매장 ID 를 입력해 주세요.").as_ptr(),
                                wide("CubeRemote 장비 등록").as_ptr(),
                                MB_OK | MB_ICONWARNING,
                            );
                            SetFocus(st.edit_shop);
                            return;
                        }
                        st.result = Some(RegisterInput {
                            shop_id: shop,
                            device_nm: read_text(st.edit_name),
                        });
                        ok = true;
                    }
                });
                if ok {
                    DestroyWindow(hwnd);
                }
                return 0;
            }
            if id == ID_CANCEL {
                DestroyWindow(hwnd);
                return 0;
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_CLOSE => {
            // 여기서는 닫기를 허용한다. 진행률 창과 달리 취소가 정상 경로다.
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

unsafe fn label(parent: HWND, hinst: HINSTANCE, text: &str, x: i32, y: i32, w: i32) -> HWND {
    let h = CreateWindowExW(
        0,
        wide("STATIC").as_ptr(),
        wide(text).as_ptr(),
        WS_CHILD | WS_VISIBLE,
        x,
        y,
        w,
        20,
        parent,
        null_mut(),
        hinst,
        null_mut(),
    );
    apply_default_font(h);
    h
}

unsafe fn edit(parent: HWND, hinst: HINSTANCE, id: i32, text: &str, x: i32, y: i32, w: i32) -> HWND {
    let h = CreateWindowExW(
        0,
        wide("EDIT").as_ptr(),
        wide(text).as_ptr(),
        WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL,
        x,
        y,
        w,
        24,
        parent,
        id as usize as HMENU,
        hinst,
        null_mut(),
    );
    apply_default_font(h);
    h
}

unsafe fn button(
    parent: HWND,
    hinst: HINSTANCE,
    id: i32,
    text: &str,
    x: i32,
    y: i32,
    default: bool,
) -> HWND {
    let mut style = WS_CHILD | WS_VISIBLE | WS_TABSTOP;
    if default {
        style |= BS_DEFPUSHBUTTON;
    }
    let h = CreateWindowExW(
        0,
        wide("BUTTON").as_ptr(),
        wide(text).as_ptr(),
        style,
        x,
        y,
        92,
        30,
        parent,
        id as usize as HMENU,
        hinst,
        null_mut(),
    );
    apply_default_font(h);
    h
}

/// 매장 ID / 장비 이름을 입력받는다. 취소하면 None.
///
/// `default_device_nm` 는 보통 컴퓨터 이름을 넘긴다. 현장에서 그대로 두는 경우가
/// 많아서 비워두는 것보다 낫다.
pub fn prompt_registration(default_device_nm: &str) -> Option<RegisterInput> {
    unsafe {
        let hinst = GetModuleHandleW(null_mut());
        let class_name = wide("CubeRemoteRegister");

        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(form_proc);
        wc.hInstance = hinst;
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.hbrBackground = (COLOR_BTNFACE + 1) as HBRUSH;
        wc.lpszClassName = class_name.as_ptr();
        RegisterClassW(&wc);

        let hwnd = CreateWindowExW(
            0,
            class_name.as_ptr(),
            wide("CubeRemote 장비 등록").as_ptr(),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            440,
            250,
            null_mut(),
            null_mut(),
            hinst,
            null_mut(),
        );
        if hwnd.is_null() {
            return None;
        }

        label(
            hwnd,
            hinst,
            "이 컴퓨터를 원격관리 대상으로 등록합니다.",
            18,
            16,
            400,
        );
        label(hwnd, hinst, "매장 ID", 18, 56, 80);
        let edit_shop = edit(hwnd, hinst, ID_SHOP, "", 104, 54, 300);
        label(hwnd, hinst, "장비 이름", 18, 94, 80);
        let edit_name = edit(hwnd, hinst, ID_NAME, default_device_nm, 104, 92, 300);
        label(
            hwnd,
            hinst,
            "매장 ID 는 관리자에게 받은 값을 입력하세요.",
            18,
            126,
            400,
        );

        button(hwnd, hinst, ID_OK, "등록", 210, 164, true);
        button(hwnd, hinst, ID_CANCEL, "취소", 312, 164, false);

        FORM.with(|f| {
            *f.borrow_mut() = Some(FormState {
                edit_shop,
                edit_name,
                result: None,
            });
        });

        ShowWindow(hwnd, SW_SHOWNORMAL);
        UpdateWindow(hwnd);
        SetFocus(edit_shop);

        // 진행률 창과 달리 여기서는 블로킹 루프를 돈다. 사용자가 결정할 때까지
        // 기다리는 것이 이 창의 목적이다.
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            // IsDialogMessage 를 쓰면 Tab 이동과 Enter 가 동작하지만, 이 창은
            // 대화상자 클래스가 아니라 일반 창이라 그냥 표준 처리를 한다.
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        FORM.with(|f| f.borrow_mut().take().and_then(|st| st.result))
    }
}
