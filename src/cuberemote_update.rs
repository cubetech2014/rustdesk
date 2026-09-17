// CubeRemote headless 자동 업데이트 — cube_headless feature 전용.
//
// flutter/lib/cuberemote/update_service.dart 를 Rust 로 옮긴 것이다. 차이점:
//   - UI 가 없다. 다이얼로그도 진행률도 없고, 조건이 맞으면 조용히 설치한다.
//   - force_update 는 의미가 없다 (거부할 사용자가 없다). 항상 설치한다.
//   - 대신 원격 세션 중에는 절대 설치하지 않는다. 지원 작업 중에 MSI 가 서비스를
//     재시작하면 연결이 끊긴다.
//
// 재사용한 것 (직접 만들지 않았다):
//   crate::Connection::alive_conns()        활성 연결 확인
//   crate::platform::update_me_msi()        msiexec /i /qn 사일런트 설치
//   crate::updater::get_download_file_from_url()  임시 파일 경로
use hbb_common::{log, tokio};
use serde::Deserialize;
use std::time::Duration;

const CHECK_UPDATE_URL: &str = "https://remote.cube-tech.co.kr/api/cuberemote/check_update.php";
const HTTP_TIMEOUT_SECS: u64 = 30;
// 부팅 직후엔 네트워크와 서비스가 아직 자리를 안 잡았다. 조금 기다렸다 시작한다.
const STARTUP_DELAY_SECS: u64 = 120;
// 평상시 확인 주기.
const CHECK_INTERVAL_SECS: u64 = 6 * 60 * 60;
// 원격 세션 중이거나 확인에 실패했을 때의 재시도 주기.
const RETRY_INTERVAL_SECS: u64 = 30 * 60;

#[derive(Debug, Deserialize)]
struct CheckUpdateResponse {
    #[serde(default)]
    update: bool,
    #[serde(default)]
    version: String,
    #[serde(default)]
    url: String,
}

// 자기 자신이 몇 비트로 빌드됐는지.
//
// 여기서는 cfg! 가 맞다 — 빌드 스크립트가 아니라 일반 코드라 TARGET 을 가리킨다.
// (빌드 스크립트 안의 cfg 는 HOST 를 가리켜서 libsodium-sys 가 그것 때문에 깨졌다.
//  patches/fix_libsodium_sys.py 참고)
fn build_arch() -> &'static str {
    if cfg!(target_pointer_width = "32") {
        "x86"
    } else {
        "x64"
    }
}

// 원격 세션이 하나도 없는가.
//
// updater.rs 의 has_no_active_conns() 는 "제어 중인 세션" 까지 보지만, agent 는
// incoming-only 라 남을 제어하는 일이 없다. 받는 연결만 확인하면 충분하다.
fn is_idle() -> bool {
    crate::Connection::alive_conns().is_empty()
}

async fn fetch_update() -> Result<Option<CheckUpdateResponse>, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("client build: {}", e))?;

    // query 배열은 원소 타입이 모두 같아야 한다. agent_version() 은 String 을
    // 돌려주므로 변수에 담아 &str 로 맞춘다 (&String 을 섞으면 타입이 안 맞는다).
    let version = crate::cuberemote_agent::agent_version();
    let resp = client
        .get(CHECK_UPDATE_URL)
        .query(&[
            ("platform", "Windows"),
            // headless 는 agent 뿐이다. viewer 는 제어 화면이, support 는 ID/비번
            // 표시 화면이 필요해서 UI 없이는 성립하지 않는다.
            ("flavor", "agent"),
            ("arch", build_arch()),
            ("version", version.as_str()),
        ])
        .send()
        .await
        .map_err(|e| format!("get: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let body: CheckUpdateResponse = resp.json().await.map_err(|e| format!("parse: {}", e))?;
    if !body.update || body.url.is_empty() {
        return Ok(None);
    }
    Ok(Some(body))
}

async fn download(url: &str) -> Result<std::path::PathBuf, String> {
    let path = crate::updater::get_download_file_from_url(url)
        .ok_or_else(|| format!("cannot derive filename from url: {}", url))?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS * 10))
        .build()
        .map_err(|e| format!("client build: {}", e))?;
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("download: {}", e))?;
    if !resp.status().is_success() {
        return Err(format!("download HTTP {}", resp.status()));
    }
    let bytes = resp.bytes().await.map_err(|e| format!("body: {}", e))?;
    std::fs::write(&path, &bytes).map_err(|e| format!("write {:?}: {}", path, e))?;
    Ok(path)
}

enum Outcome {
    // 설치를 시작했다. 이 프로세스는 곧 교체된다.
    Installed,
    // 최신이라 할 일이 없다.
    UpToDate,
    // 원격 세션 중이라 미뤘다. 짧은 간격으로 다시 봐야 한다.
    Busy,
}

async fn try_update_once() -> Result<Outcome, String> {
    if !is_idle() {
        return Ok(Outcome::Busy);
    }

    let info = match fetch_update().await? {
        Some(i) => i,
        None => return Ok(Outcome::UpToDate),
    };
    log::info!(
        "[CubeRemote update] new version available: {} ({})",
        info.version,
        info.url
    );

    let path = download(&info.url).await?;

    // 다운로드에 시간이 걸린다. 그 사이에 원격 접속이 들어왔을 수 있으니 다시 본다.
    // (updater.rs 도 같은 이유로 두 번 확인한다)
    if !is_idle() {
        log::info!("[CubeRemote update] session started during download, postponing");
        std::fs::remove_file(&path).ok();
        return Ok(Outcome::Busy);
    }

    let path_str = path.to_str().ok_or_else(|| "non-utf8 path".to_string())?;
    if !path_str.to_lowercase().ends_with(".msi") {
        std::fs::remove_file(&path).ok();
        return Err(format!("unsupported installer type: {}", path_str));
    }

    // quiet=true -> msiexec /i {msi} /qn LAUNCH_TRAY_APP=N
    // 이 호출이 성공하면 서비스가 재시작되며 이 프로세스는 교체된다.
    crate::platform::update_me_msi(path_str, true).map_err(|e| {
        std::fs::remove_file(&path).ok();
        format!("update_me_msi: {}", e)
    })?;

    log::info!("[CubeRemote update] installer launched for {}", info.version);
    Ok(Outcome::Installed)
}

// service process 에서 heartbeat / agent init 과 나란히 돌린다 (src/server.rs).
pub async fn run() {
    tokio::time::sleep(Duration::from_secs(STARTUP_DELAY_SECS)).await;
    log::info!(
        "[CubeRemote update] auto-update task started (arch={}, interval={}h)",
        build_arch(),
        CHECK_INTERVAL_SECS / 3600
    );

    loop {
        let wait = match try_update_once().await {
            // 설치가 시작됐다. 곧 이 프로세스가 내려가므로 더 확인할 이유가 없다.
            // 그래도 무언가 잘못돼 살아남는 경우를 대비해 긴 간격으로 둔다.
            Ok(Outcome::Installed) => CHECK_INTERVAL_SECS,
            Ok(Outcome::UpToDate) => CHECK_INTERVAL_SECS,
            // 원격 지원이 끝나면 곧 설치할 수 있어야 하므로 짧게 잡는다.
            Ok(Outcome::Busy) => RETRY_INTERVAL_SECS,
            Err(e) => {
                log::warn!("[CubeRemote update] failed, will retry: {}", e);
                RETRY_INTERVAL_SECS
            }
        };
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}
