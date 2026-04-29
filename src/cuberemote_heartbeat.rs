// CubeRemote agent heartbeat — runs in service process (start_server is_server=true).
//
// 왜 service 에서 도는가:
//   기존 v1.0.29 까지의 heartbeat 는 Flutter 의 main window process 안에서 Timer.periodic 로
//   동작. window 가 닫히면 (사용자가 X 클릭, 작업관리자 종료, 로그아웃 등) Timer 같이 죽어서
//   heartbeat 끊김 → 대시보드 오프라인 표시. service 는 SYSTEM 권한 + Windows 자동 재시작
//   정책 적용 가능 + 일반 사용자가 종료 못 함 → heartbeat 안정성 ↑.
//
// 데이터 출처:
//   - shop_id / p_id / h_id / shop_nm / device_nm / rustdesk_password / agent_version
//     → C:\ProgramData\CubeRemote\agent.json (Flutter 가 등록 / _initOnce 시 기록)
//   - device_id (RustDesk ID) → 매번 fresh (hbb_common::config::Config::get_id)
//   - hostname / IP / OS / remote_version → 매번 fresh (system / crate::VERSION)
//
// 시작점:
//   src/server.rs::start_server() 에서 is_server=true 일 때 tokio::spawn 으로 fire.
use hbb_common::{config::Config, log};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;

const HEARTBEAT_INTERVAL_SECS: u64 = 60;
const HEARTBEAT_URL: &str = "https://remote.cube-tech.co.kr/api/cuberemote/heartbeat.php";
const HTTP_TIMEOUT_SECS: u64 = 10;

/// Flutter 가 ProgramData 에 쓰는 agent 설정 (등록 데이터 + 비번)
#[derive(Debug, Deserialize)]
struct AgentConfig {
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

#[derive(Debug, Serialize)]
struct HeartbeatPayload {
    device_id: String,
    p_id: String,
    h_id: String,
    shop_id: String,
    shop_nm: String,
    device_nm: String,
    device_name: String,
    ip: String,
    battery: i32,
    network: String,
    platform: String,
    agent_version: String,
    remote_version: String,
    app_version: String,
    os_version: String,
    rustdesk_password: String,
}

fn agent_json_path() -> PathBuf {
    #[cfg(windows)]
    {
        let pd = std::env::var("PROGRAMDATA").unwrap_or_else(|_| "C:\\ProgramData".to_string());
        PathBuf::from(pd).join("CubeRemote").join("agent.json")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/var/lib/cuberemote/agent.json")
    }
}

fn read_agent_config() -> Option<AgentConfig> {
    let path = agent_json_path();
    let data = std::fs::read_to_string(&path).ok()?;
    match serde_json::from_str::<AgentConfig>(&data) {
        Ok(cfg) => Some(cfg),
        Err(e) => {
            log::warn!("[CubeRemote heartbeat] agent.json parse error: {}", e);
            None
        }
    }
}

fn hostname() -> String {
    #[cfg(windows)]
    {
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Unknown".to_string())
    }
    #[cfg(not(windows))]
    {
        std::env::var("HOSTNAME").unwrap_or_else(|_| "Unknown".to_string())
    }
}

/// 비-루프백 IPv4 첫 번째 (UDP socket 트릭으로 outgoing route 의 local addr 획득).
/// 실제 패킷 송신 안 함 — connect() 가 라우팅 결정만.
fn local_ip() -> String {
    use std::net::{IpAddr, UdpSocket};
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return "0.0.0.0".to_string(),
    };
    if socket.connect("8.8.8.8:80").is_err() {
        return "0.0.0.0".to_string();
    }
    match socket.local_addr() {
        Ok(addr) => match addr.ip() {
            IpAddr::V4(v4) => v4.to_string(),
            _ => "0.0.0.0".to_string(),
        },
        Err(_) => "0.0.0.0".to_string(),
    }
}

fn os_version_string() -> String {
    #[cfg(windows)]
    {
        // 간단히 Windows 표시. 정확한 버전 파싱은 Flutter 측에서 함.
        // service 에서 정확한 productName 읽으려면 reg query 필요한데 service 가 한 번
        // heartbeat 보내면 그 값이 DB 에 남아 displayed UI 갱신에 충분.
        "Windows".to_string()
    }
    #[cfg(not(windows))]
    {
        std::env::consts::OS.to_string()
    }
}

fn build_payload(cfg: &AgentConfig, device_id: String, remote_version: String) -> HeartbeatPayload {
    HeartbeatPayload {
        device_id,
        p_id: cfg.p_id.clone(),
        h_id: cfg.h_id.clone(),
        shop_id: cfg.shop_id.clone(),
        shop_nm: cfg.shop_nm.clone(),
        device_nm: cfg.device_nm.clone(),
        device_name: hostname(),
        ip: local_ip(),
        battery: -1,
        network: "Unknown".to_string(),
        platform: if cfg!(windows) { "Windows".to_string() } else { "Other".to_string() },
        agent_version: cfg.agent_version.clone(),
        remote_version: remote_version.clone(),
        app_version: cfg.agent_version.clone(),
        os_version: os_version_string(),
        rustdesk_password: cfg.rustdesk_password.clone(),
    }
}

async fn send_one() -> Result<(), String> {
    let cfg = match read_agent_config() {
        Some(c) => c,
        None => {
            // agent.json 없음 = 매장 등록 미완료 또는 viewer/support flavor — 조용히 skip
            return Ok(());
        }
    };
    if cfg.shop_id.is_empty() {
        // 등록 미완료
        return Ok(());
    }

    let device_id = Config::get_id();
    if device_id.is_empty() {
        return Err("RustDesk ID not yet issued".to_string());
    }
    let remote_version = crate::VERSION.to_string();
    let payload = build_payload(&cfg, device_id, remote_version);

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {}", e))?;
    let resp = client
        .post(HEARTBEAT_URL)
        .json(&payload)
        .send()
        .await
        .map_err(|e| format!("post: {}", e))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }
    Ok(())
}

/// 60초 주기로 heartbeat 송신. 실패는 log 만 찍고 다음 tick 으로 재시도.
/// agent.json 없으면 조용히 skip (viewer/support flavor 또는 미등록 agent).
pub async fn run() {
    log::info!("[CubeRemote heartbeat] task started (interval={}s)", HEARTBEAT_INTERVAL_SECS);
    let mut interval = tokio::time::interval(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        interval.tick().await;
        match send_one().await {
            Ok(_) => log::debug!("[CubeRemote heartbeat] tick ok"),
            Err(e) => log::warn!("[CubeRemote heartbeat] failed: {}", e),
        }
    }
}
