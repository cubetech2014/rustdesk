// CubeRemote 서버 설정 (rebrand.sh가 API_BASE / FLAVOR를 주입)
library cuberemote_config;

const API_BASE = "https://remote.cube-tech.co.kr/api/cuberemote";
const HEARTBEAT_INTERVAL_SECONDS = 60;
const AGENT_VERSION = "1.0.0";

// 빌드 flavor: "agent" (POS용) / "viewer" (관리자용)
// rebrand.sh 또는 rebrand_viewer.sh 가 치환
const FLAVOR = String.fromEnvironment("CUBE_FLAVOR", defaultValue: "agent");

bool get isAgentFlavor  => FLAVOR == "agent";
bool get isViewerFlavor => FLAVOR == "viewer";

// SharedPreferences 키
const PREF_SHOP_ID   = "cuberemote_shop_id";
const PREF_P_ID      = "cuberemote_p_id";
const PREF_H_ID      = "cuberemote_h_id";
const PREF_SHOP_NM   = "cuberemote_shop_nm";
const PREF_DEVICE_NM = "cuberemote_device_nm";
