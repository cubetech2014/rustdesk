// CubeRemote headless agent — cube_headless feature 전용 (32비트 Windows POS).
//
// Flutter 빌드에서 Dart 가 하던 일을 Rust 로 옮긴 것이다. 대응 관계:
//   flutter/lib/cuberemote/agent_service.dart  _initOnce()  -> force_settings + ensure_password
//   flutter/lib/cuberemote/registration_page.dart           -> verify_shop_once
//   src/flutter_ffi.rs initialize() 의 설정 강제 주입        -> force_settings
//
// 왜 옮겨야 하나:
//   src/flutter_ffi.rs 는 #[cfg(feature = "flutter")] 라 headless 빌드에서 아예
//   컴파일되지 않는다. 즉 apply.sh [10]/[10c] 가 넣는 conn-type=incoming /
//   access-mode=full 강제가 headless 에서는 하나도 적용되지 않는다. 여기서 같은
//   일을 해야 무인 원격 접속이 성립한다.
//
// heartbeat 는 이미 Rust 라 그대로 재사용한다 (cuberemote_heartbeat.rs).
// 그쪽은 agent.json 을 읽기만 하고, 이 모듈이 그 파일을 채우는 쪽이다.
// 두 모듈이 같은 파일 포맷을 공유하므로 한쪽을 바꾸면 다른 쪽도 확인할 것.
use hbb_common::{
    config::{self, Config},
    log,
    rand::{self, Rng},
    tokio,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;

const VERIFY_SHOP_URL: &str = "https://remote.cube-tech.co.kr/api/cuberemote/verify_shop.php";
const HTTP_TIMEOUT_SECS: u64 = 10;
// 매장 검증 재시도 주기. 부팅 직후엔 네트워크가 아직 안 올라와 있을 수 있다.
const VERIFY_RETRY_SECS: u64 = 60;
// 영구 비밀번호 길이 (Dart _generatePassword(12) 와 동일)
const PASSWORD_LEN: usize = 12;
// 혼동하기 쉬운 문자(l, I, 1, O, 0) 제외 — Dart 쪽 charset 과 동일하게 유지할 것.
const PASSWORD_CHARS: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";

// 빌드 tag. CI 가 CUBE_TAG 를 넘기면 그 값, 아니면 "dev".
// Flutter 빌드는 apply.sh 가 config.dart 의 AGENT_VERSION 을 sed 로 갱신하지만
// headless 에는 Dart 가 없으므로 컴파일 타임 env 로 받는다.
fn agent_version() -> String {
    option_env!("CUBE_TAG").unwrap_or("dev").to_string()
}

// agent.json 의 형태. cuberemote_heartbeat.rs 의 AgentConfig 와 같은 파일을 가리킨다.
// 그쪽은 read-only 라 Deserialize 만 있고, 이쪽은 쓰기도 하므로 Serialize 도 있다.
// 모든 필드가 serde(default) — 인스톨러가 shop_id / device_nm 만 넣고 나머지는
// 비워둔 상태로 시작하는 것이 정상 경로다.
#[derive(Debug, Default, Serialize, Deserialize)]
struct AgentFile {
    #[serde(default)]
    shop_id: String,
    #[serde(default)]
    p_id: String,
    #[serde(default)]
    h_id: String,
    #[serde(default)]
    shop_nm: String,
    #[serde(default)]
    device_nm: String,
    #[serde(default)]
    rustdesk_password: String,
    #[serde(default)]
    agent_version: String,
}

#[derive(Debug, Deserialize)]
struct VerifyShopResponse {
    #[serde(default)]
    valid: bool,
    #[serde(default)]
    p_id: Option<String>,
    #[serde(default)]
    h_id: Option<String>,
    #[serde(default)]
    shop_nm: Option<String>,
}

fn data_dir() -> PathBuf {
    let pd = std::env::var("PROGRAMDATA").unwrap_or_else(|_| "C:\\ProgramData".to_string());
    PathBuf::from(pd).join("CubeRemote")
}

fn agent_json_path() -> PathBuf {
    data_dir().join("agent.json")
}

// 매장 검증 완료 마커.
//
// agent.json 안의 bool 로 두지 않고 별도 파일로 분리한 이유:
// verify_shop.php 는 호출할 때마다 CubeRemoteShops.device_cnt 를 +1 한다 (멱등 아님).
// 무슨 이유로든 agent.json 이 다시 써지면 검증이 재실행되어 대시보드의 장비 대수가
// 부풀어오른다. 마커를 독립 파일로 두면 그 경로가 끊긴다.
fn verified_marker_path() -> PathBuf {
    data_dir().join("verified.flag")
}

fn read_agent_file() -> AgentFile {
    let path = agent_json_path();
    match std::fs::read_to_string(&path) {
        Ok(s) => match serde_json::from_str::<AgentFile>(&s) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("[CubeRemote agent] agent.json parse error: {}", e);
                AgentFile::default()
            }
        },
        Err(_) => AgentFile::default(),
    }
}

// temp 파일에 쓰고 rename — heartbeat 가 반쯤 쓰인 파일을 읽는 race 를 막는다.
// Windows 의 rename 은 destination 이 있으면 실패하므로 delete 후 rename.
// (Dart _mirrorAgentJson 과 같은 패턴)
fn write_agent_file(cfg: &AgentFile) -> Result<(), String> {
    let dir = data_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("create_dir_all: {}", e))?;
    let final_path = agent_json_path();
    let temp_path = dir.join("agent.json.tmp");
    let json = serde_json::to_string(cfg).map_err(|e| format!("serialize: {}", e))?;
    std::fs::write(&temp_path, json).map_err(|e| format!("write temp: {}", e))?;
    if final_path.exists() {
        std::fs::remove_file(&final_path).map_err(|e| format!("remove old: {}", e))?;
    }
    std::fs::rename(&temp_path, &final_path).map_err(|e| format!("rename: {}", e))?;
    Ok(())
}

fn generate_password(len: usize) -> String {
    let mut rng = rand::thread_rng();
    (0..len)
        .map(|_| PASSWORD_CHARS[rng.gen_range(0..PASSWORD_CHARS.len())] as char)
        .collect()
}

// 무인 원격 접속에 필요한 설정 강제.
//
// core_main() 보다 먼저, main() 맨 앞에서 호출해야 한다. RustDesk 의 여러 분기가
// 시작 시점에 이 값들을 읽기 때문이다.
//
// 어느 맵에 넣는지가 핵심이다 (v1.0.37 에서 한 번 틀렸던 부분):
//   conn-type -> HARD_SETTINGS. is_incoming_only() 가 이 맵을 직접 본다.
//   나머지     -> OVERWRITE_SETTINGS. Config::get_option() 이 읽는 순서가
//                OVERWRITE_SETTINGS -> 사용자 설정 -> DEFAULT_SETTINGS 라
//                HARD_SETTINGS 는 아예 안 본다.
// access-mode=full 은 "원격에서 내 설정 화면 조작 차단" 마스크를 무력화한다.
// verification-method / approve-mode 는 password_security.rs 가 Config::get_option 으로
// 읽는다 (각각 43, 78행).
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
            "use-permanent-password".to_string(),
        );
        ow.insert("approve-mode".to_string(), "password".to_string());
    }

    log::info!("[CubeRemote agent] forced settings (incoming / full / permanent-password)");
}

// 영구 비밀번호 보장. 없으면 만들고, 있으면 RustDesk 에 다시 적용한다.
// 매 부팅마다 호출해도 안전하다 (set_permanent_password 는 같은 값이면 no-op).
fn ensure_password() -> Result<(), String> {
    let mut cfg = read_agent_file();
    let mut dirty = false;

    if cfg.rustdesk_password.is_empty() {
        cfg.rustdesk_password = generate_password(PASSWORD_LEN);
        dirty = true;
        log::info!("[CubeRemote agent] generated new permanent password");
    }

    // device_nm 이 비어 있으면 hostname 으로 채운다. 인스톨러가 안 넣어준 경우 대비.
    if cfg.device_nm.is_empty() {
        cfg.device_nm = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "POS".to_string());
        dirty = true;
    }

    // heartbeat 가 agent.json 의 agent_version 을 그대로 보내므로 여기서 갱신한다.
    let ver = agent_version();
    if cfg.agent_version != ver {
        cfg.agent_version = ver;
        dirty = true;
    }

    // RustDesk 쪽에는 항상 적용한다. config 가 초기화됐거나 사용자가 바꿨을 수 있다.
    Config::set_permanent_password(&cfg.rustdesk_password);

    if dirty {
        write_agent_file(&cfg)?;
    }
    Ok(())
}

// 매장 검증. Ok(true) = 이번에 검증함, Ok(false) = 할 일 없음, Err = 재시도 필요.
//
// verify_shop.php 는 멱등이 아니다 (device_cnt +1). 성공 직후 마커를 남겨
// 두 번 호출되지 않게 한다.
async fn verify_shop_once() -> Result<bool, String> {
    if verified_marker_path().exists() {
        return Ok(false);
    }

    let cfg = read_agent_file();
    if cfg.shop_id.is_empty() {
        // 인스톨러가 매장 정보를 안 넣었다. 검증할 게 없으니 조용히 넘어간다.
        return Ok(false);
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {}", e))?;

    let resp = client
        .post(VERIFY_SHOP_URL)
        .json(&serde_json::json!({ "shop_id": cfg.shop_id }))
        .send()
        .await
        .map_err(|e| format!("post: {}", e))?;

    let status = resp.status();
    if !status.is_success() {
        // 404(없는 매장) / 403(차단) 은 재시도해도 소용없지만, 대시보드에서 매장을
        // 나중에 등록하는 운영 흐름이 있으므로 계속 재시도한다.
        return Err(format!("HTTP {}", status));
    }

    let body: VerifyShopResponse = resp
        .json()
        .await
        .map_err(|e| format!("parse response: {}", e))?;
    if !body.valid {
        return Err("server returned valid=false".to_string());
    }

    // 서버가 돌려준 매장 정보를 agent.json 에 채운다.
    // 인스톨러는 shop_id 만 넣으면 되고 p_id / h_id / shop_nm 은 여기서 확정된다.
    let mut cfg = read_agent_file();
    if let Some(v) = body.p_id {
        cfg.p_id = v;
    }
    if let Some(v) = body.h_id {
        cfg.h_id = v;
    }
    if let Some(v) = body.shop_nm {
        cfg.shop_nm = v;
    }
    write_agent_file(&cfg)?;

    // 마커는 반드시 agent.json 을 쓴 뒤에 남긴다. 순서가 바뀌면 중간에 죽었을 때
    // 매장 정보 없이 "검증됨" 상태가 되어 heartbeat 가 빈 값을 보낸다.
    std::fs::write(verified_marker_path(), b"1").map_err(|e| format!("write marker: {}", e))?;
    log::info!("[CubeRemote agent] shop verified: {}", cfg.shop_id);
    Ok(true)
}

// service process 에서 heartbeat 와 나란히 돌린다 (src/server.rs).
// 비밀번호는 네트워크가 필요 없으니 즉시, 매장 검증은 성공할 때까지 재시도한다.
pub async fn run() {
    log::info!("[CubeRemote agent] init task started");

    if let Err(e) = ensure_password() {
        log::error!("[CubeRemote agent] ensure_password failed: {}", e);
    }

    let mut interval = tokio::time::interval(Duration::from_secs(VERIFY_RETRY_SECS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        // tokio interval 의 첫 tick 은 즉시 발생한다.
        interval.tick().await;
        match verify_shop_once().await {
            Ok(true) => {
                log::info!("[CubeRemote agent] registration complete");
                break;
            }
            Ok(false) => break,
            Err(e) => log::warn!("[CubeRemote agent] verify_shop failed, will retry: {}", e),
        }
    }
}
