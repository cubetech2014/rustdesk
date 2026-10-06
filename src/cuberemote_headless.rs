// CubeRemote headless 모드 — cube_headless feature 전용.
//
// 현재 이 feature 를 쓰는 것은 **support x86** (32비트 Windows 1회용 원격지원)
// 하나뿐이다. Flutter Windows 데스크톱이 x64 전용이라 32비트에서는 UI 를 통째로
// 들어낸 빌드가 필요하고, 그 빌드에 필요한 설정 강제와 Flutter UI 가 하던
// 일(원격지원 창, 연결 관리자)의 대체를 여기서 한다.
//
// 왜 필요한가:
//   apply.sh [10]/[10c] 는 conn-type / access-mode 강제를 src/flutter_ffi.rs 의
//   initialize() 에 주입한다. 그런데 그 파일은 #[cfg(feature = "flutter")] 라
//   headless 빌드에서는 컴파일조차 되지 않는다. 그대로 두면 무인 원격 접속의
//   전제(수락 팝업 없음, 원격 차단 마스크 해제)가 하나도 성립하지 않는다.
//
// 이전에 여기 있던 것 (2026-09-18 제거):
//   32비트 agent 용 영구 비밀번호 발급 / 매장 검증 / 자동 업데이트가 있었다.
//   32비트 agent 를 만들지 않기로 하면서 전부 걷어냈다. support 에는 오히려
//   해로운 코드였다 - 영구 비밀번호를 만들고 C:\ProgramData 에 agent.json 을
//   남기는데, support 는 "설치하지 않는" 도구라 고객 PC 에 흔적을 남기면 안 된다.
//   되살려야 하면 커밋 dc4e6a90d 참고.
use hbb_common::{config, log};

/// 무인 원격 접속에 필요한 설정 강제.
///
/// core_main() 보다 먼저, main() 맨 앞에서 호출해야 한다. RustDesk 의 여러 분기가
/// 시작 시점에 이 값들을 읽기 때문이다.
///
/// 어느 맵에 넣는지가 핵심이다 (v1.0.37 에서 한 번 틀렸던 부분):
///   conn-type -> HARD_SETTINGS. is_incoming_only() 가 이 맵을 직접 본다.
///   나머지     -> OVERWRITE_SETTINGS. Config::get_option() 이 읽는 순서가
///                OVERWRITE_SETTINGS -> 사용자 설정 -> DEFAULT_SETTINGS 라
///                HARD_SETTINGS 는 아예 보지 않는다.
///
/// 각 값의 근거:
///   conn-type=incoming            제어는 하지 않고 받기만 한다
///   access-mode=full              "원격에서 내 설정 화면 조작 차단" 마스크를 무력화.
///                                 이게 없으면 원격 마우스가 특정 영역에서 씹힌다
///   verification-method=
///     use-temporary-password      support 는 1회용이라 임시 비밀번호를 쓴다.
///                                 영구 비밀번호는 흔적을 남기므로 쓰지 않는다
///                                 (password_security.rs verification_method 참고)
///   approve-mode=password         비밀번호가 맞으면 바로 연결. 고객이 "수락" 을
///                                 누르지 않아도 되게 한다
///   temporary-password-length=8   기본 6자리는 구두 전달 시 충돌 여지가 있다.
///                                 8/10 만 허용되고 그 외 값은 6으로 떨어진다
pub fn force_settings() {
    config::HARD_SETTINGS
        .write()
        .unwrap()
        .insert("conn-type".to_string(), "incoming".to_string());

    {
        let mut ow = config::OVERWRITE_SETTINGS.write().unwrap();
        ow.insert("access-mode".to_string(), "full".to_string());
        ow.insert(
            "verification-method".to_string(),
            "use-temporary-password".to_string(),
        );
        ow.insert("approve-mode".to_string(), "password".to_string());
        ow.insert("temporary-password-length".to_string(), "8".to_string());
    }

    log::info!("[CubeRemote headless] forced settings (incoming / full / temporary-password)");
}

/// core_main() 이 Some 을 돌려준 뒤의 진입점. Flutter 빌드의 ui::start(args) 자리다.
///
/// 같은 EXE 가 두 가지 모습으로 실행된다:
///   인자 없음  고객이 직접 실행 -> 원격지원 창 (ID / 비밀번호)
///   --cm       원격 연결이 들어올 때 서버가 띄움 -> 연결 관리자 (창 없음)
///
/// v1.0.45 는 둘을 가르지 않고 전부 원격지원 창으로 보냈다. 그래서 32비트 첫
/// 실기 테스트에서 접속을 시도할 때마다 창이 하나씩 늘고, viewer 는 계속 끊겼다.
/// run_cm 주석 참고.
pub fn run(args: &[String]) {
    if args.first().map(String::as_str) == Some("--cm") {
        run_cm();
    } else {
        run_support();
    }
}

/// 연결 관리자(CM) 프로세스. 창 없이 IPC 만 받는다.
///
/// 원격 연결이 들어오면 서버는 `<자기 EXE> --cm` 을 띄우고 `_cm` IPC 로 붙는다
/// (server/connection.rs start_ipc). 이 프로세스가 IPC 를 열지 않으면 서버는
/// 몇 초 재시도한 뒤 "connection manager error" 로 그 연결을 끊는다.
/// viewer 가 재접속하면 서버는 다시 --cm 을 띄우고, 같은 일이 반복된다.
///
/// Flutter 는 --cm 에서 CM 창을 띄우지만 여기서는 창이 필요 없다. 비밀번호가
/// 맞으면 바로 연결이고(approve-mode=password) 고객이 누를 "수락" 버튼이 없다.
/// 지원을 끝내고 싶으면 원격지원 창을 닫으면 된다 - 서버가 그 프로세스 안에서
/// 돌기 때문에 연결이 같이 끊긴다. Flutter 의 --cm-no-ui 와 같은 방식이다.
fn run_cm() {
    use crate::ui_cm_interface::{start_ipc, ConnectionManager};

    log::info!("[CubeRemote support] 연결 관리자 시작 (창 없음)");
    // #[tokio::main] 래퍼라 리스너가 살아 있는 동안 여기서 돌아오지 않는다.
    start_ipc(ConnectionManager {
        ui_handler: HeadlessCm,
    });
}

/// 지금 붙어 있는 연결 id. 마지막 하나가 끝나면 CM 프로세스를 끝낸다.
static CM_ACTIVE: std::sync::Mutex<Vec<i32>> = std::sync::Mutex::new(Vec::new());

/// 창 없는 CM 핸들러. 연결 수만 센다.
#[derive(Clone)]
struct HeadlessCm;

impl crate::ui_cm_interface::InvokeUiCM for HeadlessCm {
    // 같은 id 로 여러 번 올 수 있다 (인증 상태가 바뀌면 다시 Login 이 온다).
    fn add_connection(&self, client: &crate::ui_cm_interface::Client) {
        let mut active = CM_ACTIVE.lock().unwrap();
        if !active.contains(&client.id) {
            active.push(client.id);
        }
        log::info!(
            "[CubeRemote support] 연결 #{} peer={} authorized={}",
            client.id,
            client.peer_id,
            client.authorized
        );
    }

    // 마지막 연결이 끝나면 프로세스를 끝낸다. sciter CM(ui/cm.rs) 과 같은 동작이고,
    // 다음 연결이 오면 서버가 --cm 을 다시 띄운다.
    //
    // get_clients_length() 를 쓰지 않는 이유: close=false 로 끝난 연결(답하지 않은
    // 채팅이 있었던 경우 등)은 CLIENTS 에 disconnected 로 남는다. 창이 있으면 사용자가
    // 보고 닫겠지만 여기는 창이 없어서, 그 기준이면 보이지 않는 프로세스가 영원히 남는다.
    fn remove_connection(&self, id: i32, _close: bool) {
        let empty = {
            let mut active = CM_ACTIVE.lock().unwrap();
            active.retain(|x| *x != id);
            active.is_empty()
        };
        log::info!("[CubeRemote support] 연결 #{} 종료 (남은 연결 없음: {})", id, empty);
        if empty {
            crate::platform::quit_gui();
        }
    }

    fn new_message(&self, _id: i32, _text: String) {}

    fn change_theme(&self, _dark: String) {}

    fn change_language(&self) {}

    fn show_elevation(&self, _show: bool) {}

    fn update_voice_call_state(&self, _client: &crate::ui_cm_interface::Client) {}

    fn file_transfer_log(&self, _action: &str, _log: &str) {}
}

/// 9자리 ID 를 "123 456 789" 로. 구두로 불러주기 쉬우라고.
fn format_id(id: &str) -> String {
    if id.len() == 9 && id.chars().all(|c| c.is_ascii_digit()) {
        format!("{} {} {}", &id[0..3], &id[3..6], &id[6..9])
    } else {
        id.to_string()
    }
}

/// 1회용 원격지원 화면.
///
/// 이 시점에 core_main() 이 이미 할 일을 다 했다:
///   - is_quick_support_exe() 로 자신을 인식하고 UAC 승격 / portable service 기동
///   - start_server 를 백그라운드 스레드로 띄움
/// 그래서 여기서는 값이 준비되기를 기다렸다 보여주기만 하면 된다.
fn run_support() {
    // IPC 동기화 스레드를 깨운다. 이 한 줄이 전부다 - SENDER 는 lazy_static 이고
    // 초기화 식이 check_connect_status(true) 라, 처음 건드리는 순간 스레드가 뜬다.
    //
    // 그 스레드가 1초마다 서버 프로세스에 id 와 temporary-password 를 물어
    // UI_STATUS / TEMPORARY_PASSWD 를 채운다. 이 경로 없이는 두 값이 영원히 빈다.
    let _ = crate::ui_interface::SENDER.lock();

    let win = match cube_ui::SupportWindow::new() {
        Some(w) => w,
        None => {
            log::error!("[CubeRemote support] 창을 만들지 못했습니다");
            return;
        }
    };

    // 서버 등록 전에는 ID 도 비밀번호도 없다. 보통 2~3초.
    const WAITING: &str = "연결 중...";

    loop {
        if win.is_closed() {
            break;
        }

        // 둘 다 뮤텍스 복사라 사실상 공짜다. 값이 그대로면 set_info 가 무시한다.
        //
        // ipc::get_id() 를 쓰면 안 된다. 동기 함수처럼 보이지만 실제로는
        // #[tokio::main(flavor = "current_thread")] 래퍼라 IPC 가 늦으면 최대 1초
        // 블로킹이고, 그 사이 메시지 펌프가 멈춰 창이 하얗게 굳는다.
        // (UiStatus::id 는 #[cfg(not(feature = "flutter"))] 필드 - headless 전용)
        let status = crate::ui_interface::get_connect_status();
        let password = crate::ui_interface::temporary_password();

        let id_text = if status.id.is_empty() {
            WAITING.to_string()
        } else {
            format_id(&status.id)
        };
        let pw_text = if password.is_empty() {
            WAITING.to_string()
        } else {
            password
        };
        win.set_info(&id_text, &pw_text);
        win.pump();

        std::thread::sleep(std::time::Duration::from_millis(150));
    }

    log::info!("[CubeRemote support] 사용자가 창을 닫았습니다. 종료합니다.");
}
