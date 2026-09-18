// 실행파일에 아이콘과 매니페스트를 박는다.
//
// 매니페스트가 왜 필수인가:
//   TaskDialogIndirect 는 Common Controls 6.0 에만 있는 함수다. 시스템 기본
//   comctl32.dll(5.82)에는 없다. 매니페스트로 6.0 의존성을 선언하지 않으면
//   import 해석이 실패해서 "진입점을 찾을 수 없습니다" 로 **실행 자체가 안 된다**.
//   res/manifest.xml 에 그 선언이 이미 들어있어 그대로 재사용한다.
//   (DPI 인식 설정도 같이 들어있어 고해상도에서 흐릿하게 나오는 것도 막아준다)
//
// 아이콘은 apply.sh 를 거치지 않으므로 overlay 의 CubeRemote 아이콘을 직접 쓴다.
// apply.sh 는 res/icon.ico 를 덮어쓰지만 런처 job 은 그 스크립트를 돌리지 않는다.
fn main() {
    #[cfg(windows)]
    {
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../overlay/icons/windows/agent.ico")
            .set_manifest_file("../../res/manifest.xml");
        if let Err(e) = res.compile() {
            eprintln!("winres 실패: {}", e);
            std::process::exit(1);
        }
    }
}
