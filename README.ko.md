# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.ko.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

로컬 Wallpaper Engine Workshop 파일을 macOS에서 배경화면처럼 사용합니다.

Workshop Wallpaper Bridge는 복사해 온 Wallpaper Engine Workshop 폴더를 Mac 전용 로컬 라이브러리로 가져오고, 지원되는 월페이퍼를 데스크톱 레이어에서 재생합니다. 이미 로컬에 가지고 있는 파일을 쓰기 위한 앱입니다. Steam에 접속하지 않고, Workshop 항목을 다운로드하지 않고, 복사해 온 Workshop 폴더를 수정하지 않습니다.

[웹사이트](https://3x-haust.github.io/workshop-wallpaper-bridge/) · [English](README.md) · [기여 안내](CONTRIBUTING.md) · [보안 정책](SECURITY.md) · [릴리즈](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) · [후원](https://www.patreon.com/c/3xhaust)

## 데모

![Workshop Wallpaper Bridge 데모](assets/workshop-wallpaper-bridge-demo.gif)

## 후원

Workshop Wallpaper Bridge가 도움이 되었다면 [Patreon](https://www.patreon.com/c/3xhaust)에서 호환성 개선과 유지보수를 후원할 수 있습니다.

## 다운로드

[Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases)에서 최신 `WorkshopWallpaperBridge-macOS-arm64.dmg`를 받습니다.

1. DMG를 엽니다.
2. **Workshop Wallpaper Bridge.app**을 **Applications**로 드래그합니다.
3. 앱을 엽니다. Dock 앱이 아니라 메뉴바 유틸리티로 실행됩니다.

공개 릴리즈는 Developer ID로 서명하고 공증한 뒤, 다운로드 quarantine이 붙은 상태의 Gatekeeper 검증까지 통과한 DMG만 업로드합니다. 다운로드한 릴리즈가 손상되었다고 표시되면 다음 릴리즈를 받고, macOS 버전과 릴리즈 태그를 이슈에 남겨 주세요.

**Auto-check Updates**가 켜져 있으면 앱이 GitHub Releases에서 업데이트를 자동 확인합니다. 설정 창의 **Check Updates** 또는 메뉴바 메뉴의 **Check for Updates**로 수동 확인할 수 있습니다. 새 릴리즈가 있으면 **Download Update**가 최신 DMG를 다운로드합니다.

## 사용 방법

Wallpaper Engine 프로젝트를 쓰는 경우:

1. Windows에서 Workshop 폴더를 찾습니다.

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. `431960` 폴더를 Mac으로 복사합니다.
3. 메뉴바 아이콘에서 **Workshop Wallpaper Bridge Settings**를 엽니다.
4. **Browse**를 누르고 복사한 `431960` 폴더를 선택한 뒤 **Scan**을 누릅니다.
5. 지원되는 항목을 선택하고 **Import Selected**를 누릅니다.
6. **Play on Desktop**을 누릅니다.

직접 가진 영상을 쓰려면 Workshop 폴더를 스캔하지 않고 **Add Video File**을 누릅니다.

표시 방식:

- **Fit**: 전체 월페이퍼를 보존합니다.
- **Fill**: 화면을 꽉 채우며 가장자리가 잘릴 수 있습니다.
- **Stretch**: 화면 크기에 정확히 맞추며 이미지가 왜곡될 수 있습니다.

재생 동작:

- Dock과 Space 전환 깜빡임을 줄이기 위해 기본값은 연속 재생입니다.
- **Auto-pause behind apps**는 선택 옵션입니다.
- **Play wallpaper audio**는 기본적으로 꺼져 있습니다(이전 버전과 동일한 무음 재생). 켜고 볼륨 슬라이더를 조절하면 동영상 월페이퍼의 오디오와, scene 월페이퍼의 경우 캐시된 scene 비디오에 함께 구워진 배경음악/환경음을 들을 수 있습니다. 두 설정 모두 현재 재생 중인 월페이퍼에 재시작 없이 즉시 적용됩니다. 월페이퍼가 다른 앱에 가려져 자동 일시정지되면 소리도 함께 멈춥니다.
- 설정창을 닫아도 재생은 멈추지 않습니다.
- **Open at Login**을 켜면 로그인 후 마지막 월페이퍼를 복구합니다.
- **Play on Desktop**은 macOS 데스크톱 사진을 바꾸지 않습니다. 그래서 투명 메뉴 바 색은 현재 시스템 배경화면 기준으로 유지됩니다.
- macOS 데스크톱 및 Lock Screen 정적 이미지를 실제로 바꾸고 싶을 때만 **Set Still Wallpaper**를 사용합니다.
- **Remove**는 Mac 라이브러리에 복사된 항목만 삭제합니다. 원본 복사 폴더나 원본 영상은 건드리지 않습니다.

가져온 파일은 아래 위치에 저장됩니다.

```text
~/Library/Application Support/WorkshopWallpaperBridge
```

## 지원 범위

| 프로젝트 유형 | 지원 |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` 동영상 | 바로 재생 |
| `.webm`, `.mkv`, `.avi` 동영상 | 로컬 `ffmpeg`로 변환 후 재생 |
| `index.html` 웹 월페이퍼 | 제한된 로컬 WebView에서 재생 |
| `.jpg`, `.png`, `.gif`, `.heic` 이미지 | 정적 데스크톱 레이어로 표시 |
| `scene.pkg` 씬 월페이퍼 | 처음 재생할 때 (번들되었거나 설정된 외부 GPL scene renderer와 `ffmpeg`를 이용해) scene을 화면에 보이지 않는 상태로 렌더링해 반복 재생되는 mp4로 캐시한 뒤, 이후에는 그 캐시된 비디오를 일반 동영상 월페이퍼와 같은 경로로 재생합니다 — renderer 창은 절대 표시되지 않습니다; renderer, engine assets, `ffmpeg` 중 하나라도 없으면 네이티브 scene renderer로 fallback하며, 이는 패키지 안의 2D image layer, animated sprite-sheet (`texgif`) texture, text-only scene, 일부 text SceneScript `update(value)` snippet, 기본 keyframe 움직임, image-layer와 effect-only layer의 `waterFlow` / `waterWaves` / `waterRipple` / `scroll` shader 움직임, 단순 `shake` / `spin` / `shine` layer effect를 package constant 기반으로 렌더링; 엔진 렌더러 작업에 필요한 shader/effect/script/audio 요구사항 보존 |

scene 지원은 보수적입니다. 데스크톱 scene 재생은 각 scene을 화면에 보이지 않는 상태로 한 번 mp4로 렌더링해 캐시한 뒤(renderer 창은 절대 표시되지 않습니다), 그 캐시된 비디오를 실제 동영상 월페이퍼와 동일한 코드 경로로 재생하므로 `AVPlayerLooper` 기반의 끊김 없는 반복 재생이 되고, 앱의 전체 fit/fill/stretch 설정과 무관하게 항상 화면 전체를 채웁니다(aspect-fill); 첫 렌더링이 진행 중이거나 렌더링을 건너뛴 경우에는 대신 네이티브 scene renderer 화면을 보여줍니다. 번들된 renderer가 지원하는 경우, 이 첫 렌더링은 중간 PNG 프레임 파일 없이 프레임을 인코더로 동시에 스트리밍하여 첫 렌더링 속도를 눈에 띄게 높이며, 이를 지원하지 않는 이전 renderer 빌드에서는 기존의 record-then-encode 방식으로 자동 대체됩니다. 캐시된 클립은 scene을 20초 분량 녹화하므로(더 짧은 루프 대신) 재생이 처음으로 되돌아가는 지점이 덜 자주 나타나며, 인코딩 시 클립의 마지막 약 1.2초를 처음 약 1.2초와 크로스페이드해 이음매 자체를 자연스럽게 지워 단순히 덜 자주 보이게 하는 데 그치지 않습니다. 첫 렌더링이 진행되는 동안 앱 상태 표시줄에 "Rendering scene to video… N%" 형태로 (지금까지 기록된 프레임 수 기준) 실시간 진행률이 표시되므로, 수십 초의 대기 시간을 앱이 멈춘 것으로 오해하지 않습니다. 비디오로 렌더링하면 scene의 애니메이션 루프가 고정된 클립으로 구워지므로, 비디오 재생 중에는 화면의 시계, 오디오 반응, 마우스/키보드 상호작용이 실시간으로 동작하지 않습니다 — renderer 창이 절대 나타나지 않는 대신 감수하는 tradeoff입니다. `wwbctl attach-scene-video <asset-id> <video-file>`는 여전히 진단이나 비교 workflow용 로컬 reference cache만 Mac 전용 라이브러리에 저장하며, 자동 렌더-투-비디오 캐시와는 무관합니다. 비디오가 아직 없을 때 쓰이는 네이티브 scene renderer는 기본 image-layer와 text-only scene을 지원하며, packed `.tex` texture, LZ4 block, 주요 DXT 형식, text layer, 일부 text SceneScript `update(value)` snippet, position/scale/rotation/opacity keyframe을 처리하고, mirror 모드 keyframe 애니메이션은 ping-pong 루프로 재생합니다. animated sprite-sheet texture는 RePKG에 문서화된 `TEXS0001`-`TEXS0003` frame container(회전된 sheet packing, frame별 재생 시간 포함)를 해석해 Core Animation frame sequence로 재생하며, 내장 MP4 video texture는 여전히 지원하지 않습니다. scene 전체를 덮는 compose layer의 `waterripple` 같은 warp는 아래 layer들로 분배되어, effect snapshot에 가려 layer keyframe 움직임이 멈춰 보이는 문제 없이 살아있는 모션 위에 물결이 적용됩니다. workshop `nitro` 계열 glint effect는 noise 기반 twinkle 근사로 재생되고, 단순 sprite/pulse-ring particle system은 Core Animation emitter로 근사합니다. 복잡한 particle operator는 여전히 생략됩니다. puppet-warp 모델(`MDLV0013` skeleton — Wallpaper Engine이 물고기·캐릭터의 몸을 휘게 하는 포맷)은 mesh/bone/mirror 모드 bone 애니메이션까지 디코드해 CPU skinning으로 재생하므로 puppet 몸체가 뻣뻣하게 미끄러지지 않고 실제로 휘어집니다. `spin`, `shake`, `waterripple`, `waterwaves`, `waterflow`, `scroll`은 scene 패키지에 들어있는 GLSL shader를 Core Image로 그대로 포팅해 실행하며, flow-map 기반 shake 덕분에 지느러미와 꼬리만 움직입니다. 지원되는 text script는 제한된 JavaScriptCore context에서 `Date`, `Math`, `engine.runtime`, `engine.frametime`, `engine.timeOfDay`, 파싱된 `scriptProperties`를 사용할 수 있고, loop, timer, eval/dynamic function, 지원하지 않는 API, 오류를 던지는 script는 기존 text를 유지하는 fail-closed 방식으로 처리합니다. 지원되는 image-layer와 effect-only layer의 `waterFlow`, `waterWaves`, `waterRipple`, `scroll` effect는 임의의 layer drift가 아니라 package shader constant의 speed, axis speed, direction, scale, strength, perspective 값을 사용해 움직이고, 단순 `shake`, `spin`, `shine` layer effect는 안전하게 표현할 수 있을 때 Core Animation으로 매핑합니다. 이제 package analyzer가 effect file, shader file, shader uniform, SceneScript, particle, sound layer, audio-analysis input, video texture 같은 scene runtime 요구사항을 보존하므로 renderer-engine parity 작업을 정확히 겨냥할 수 있습니다. masked effect composition, particle, audio-reactive 또는 object/scene API script, 전체 custom shader pipeline, media integration, video texture 재생은 네이티브 scene engine이 해당 runtime 기능을 구현하기 전까지 여전히 생략되거나 Wallpaper Engine과 다르게 보일 수 있습니다.

외부 GPL scene renderer subprocess가 번들되어 있고 `ffmpeg`를 사용할 수 있으면, 데스크톱 `scene.pkg` 재생은 그 scene을 화면에 보이지 않는 상태로(renderer 창을 전혀 열지 않고) mp4로 렌더링해 캐시한 뒤 동영상 월페이퍼 경로로 재생합니다; 캐시가 만들어지는 동안, 또는 subprocess/engine assets/`ffmpeg` 중 하나라도 영구적으로 없으면 네이티브 renderer로 fallback합니다. 번들된 macOS 화면 보호기는 아래에 설명한 네이티브/동영상 지원 경로를 계속 사용합니다. 이 프로젝트는 Steam Workshop 항목을 다운로드하지 않고, 제작자 asset을 재배포하지 않고, Steam content를 번들하지 않습니다. renderer binary는 별도 GPL component이며 자체 source notice가 필요합니다.

외부 scene renderer는 사용자가 자기 Windows Wallpaper Engine 설치본에서 복사한 원본 runtime `assets` 폴더도 필요합니다. Workshop Wallpaper Bridge는 이 파일들을 다운로드하거나 함께 배포하지 않습니다. 앱의 **Scene Engine Assets** -> **Choose Assets Folder...**에서 복사한 `steamapps/common/wallpaper_engine/assets` 내용 폴더를 선택하세요. CLI/개발 실행에서는 `WWB_SCENE_ENGINE_ASSETS_DIR=/path/to/assets`가 앱 설정보다 우선하며, 그 외에는 `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`를 확인합니다. renderer binary가 있어도 engine assets(또는 `ffmpeg`)가 없거나 불완전하면, 실패할 렌더링을 시도하지 않고 네이티브 scene fallback을 계속 사용합니다. 캐시된 scene 비디오는 asset별로 `~/Library/Application Support/WorkshopWallpaperBridge/SceneVideoCache/`에 저장되며, 원본 `scene.pkg`가 바뀌면 자동으로 다시 만들어집니다.

scene 패키지에 저작된 sound layer(배경음악, 환경음 등)가 있으면 해당 오디오 파일을 `scene.pkg`에서 추출해 반복 재생되는 오디오 트랙으로 캐시된 비디오에 함께 인코딩합니다(layer가 여러 개면 scene.json에 지정된 layer별 volume 가중치를 반영해 믹싱). 이렇게 구워진 오디오도 다른 월페이퍼 오디오처럼 기본적으로 음소거 상태이며, 설정의 **Play wallpaper audio**를 켜야 들립니다. 비디오 루프와 달리 이 버전에서는 오디오 트랙에 루프 이음매 크로스페이드가 적용되지 않아 반복 지점에서 미세한 이음매가 들릴 수 있습니다. 오디오 추출이나 믹싱이 실패해도 렌더링 자체는 실패하지 않고 무음 비디오가 생성됩니다.

`preview.jpg`, `thumbnail.jpg`, `cover.png` 같은 Workshop 미리보기 파일은 썸네일로 취급합니다. 프로젝트에 `scene.pkg`가 있으면 낮은 해상도 미리보기를 늘려 쓰지 않고 패키지 내부 scene 데이터를 읽습니다.

## 화면 보호기

**Animate Screen Saver**를 켜면 앱이 번들된 macOS 화면 보호기를 설치하고 현재 Mac host의 화면 보호기로 선택합니다.

화면 보호기에서 움직이는 것:

- Mac 라이브러리의 MP4, MOV, M4V 월페이퍼.
- **Add Video File**로 추가한 로컬 영상.

정적 fallback을 쓰는 것:

- 변환 전 WebM, MKV, AVI.
- 웹 월페이퍼.
- scene 월페이퍼.

화면 보호기가 언제 시작되는지는 macOS가 제어합니다. 시작 시간과 암호 요구 시간은 System Settings > Lock Screen에서 정합니다. macOS가 선택된 화면 보호기를 시작하기 전까지는 일반 정적 잠금화면 배경이 보입니다.

**Set Still Wallpaper**로 정적 데스크톱 배경화면도 명시적으로 설정할 수 있습니다. MP4, MOV, M4V 파일은 작은 Workshop preview 대신 동영상에서 한 프레임을 추출해 사용합니다. **Play on Desktop**은 의도적으로 macOS 데스크톱 사진을 그대로 둡니다. 그래서 애니메이션 재생 중 메뉴 바 색이 갑자기 바뀌는 일을 피합니다.

## 소스에서 빌드

필요한 것:

- macOS 14 이상
- Xcode command line tools
- Swift 6 toolchain
- 선택: WebM, MKV, AVI 변환용 `ffmpeg`

```bash
git clone https://github.com/3x-haust/workshop-wallpaper-bridge.git
cd workshop-wallpaper-bridge
swift run WorkshopWallpaperBridge
```

로컬 앱 번들과 DMG 빌드:

```bash
bash Scripts/package-app.sh
open "dist/Workshop Wallpaper Bridge.app"
```

생성 파일:

```text
dist/WorkshopWallpaperBridge-macOS-arm64.dmg
```

선택적인 외부 GPL scene renderer를 로컬 패키지에 포함하려면 `Scripts/package-app.sh`를 실행하기 전에 `SCENE_RENDERER_BINARY=/path/to/wwb-scene-renderer`를 설정하거나 실행 파일을 `ExternalRenderers/wwb-scene-renderer`에 둡니다. 패키지 script는 renderer가 있으면 app resources로 복사하고, [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)의 기본 pinned source ref `b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d`와 source link를 담은 `Renderer Notices/GPL Scene Renderer Notice.txt`를 항상 씁니다. 다른 renderer build를 배포한다면 해당 공개 source에 맞게 `SCENE_RENDERER_SOURCE_URL`과 `SCENE_RENDERER_SOURCE_REF`를 설정하세요.

패키지는 Wallpaper Engine runtime assets를 절대 포함하지 않습니다. 외부 scene 렌더링을 쓰려면 본인의 Windows Wallpaper Engine `steamapps/common/wallpaper_engine/assets` 내용 폴더를 복사한 뒤, 앱의 **Scene Engine Assets** -> **Choose Assets Folder...**에서 선택하세요. CLI/개발 실행에서는 `WWB_SCENE_ENGINE_ASSETS_DIR`가 앱 설정보다 우선하며, 기본 fallback은 `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`입니다. `swift run wwbctl doctor`로 renderer binary와 필수 engine asset 파일의 사용 가능 여부를 확인할 수 있습니다.

`ffmpeg` 설치:

```bash
brew install ffmpeg
```

## CLI

스캔, 가져오기, 변환, scene 진단에는 `wwbctl`을 쓸 수 있습니다.

```bash
swift run wwbctl scan "/path/to/431960" --out index.json
swift run wwbctl import "/path/to/431960"
swift run wwbctl import-video "/path/to/video.mp4"
swift run wwbctl remove "<asset-id>"
swift run wwbctl convert input.webm --out output.mp4
swift run wwbctl scene-info "/path/to/scene.pkg"
swift run wwbctl scene-render-info "/path/to/scene.pkg"
swift run wwbctl scene-engine-info "/path/to/scene.pkg"
swift run wwbctl scene-parity-check "/path/to/scene.pkg" "/path/to/golden-frames"
swift run wwbctl doctor
```

공개 릴리즈를 서명/공증하려면 `Scripts/package-app.sh` 실행 전에 `SIGN_IDENTITY`, `NOTARY_PROFILE`, `REQUIRE_SIGNING=1`, `REQUIRE_NOTARIZATION=1`을 설정합니다. 릴리즈 workflow에는 `MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`, `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID`, `MACOS_NOTARY_PASSWORD` GitHub Secrets가 필요합니다.

## 문제 해결

바탕화면에 아무것도 보이지 않는 경우:

- 가져온 항목이 `playable`인지 확인합니다.
- **Stop**을 누른 뒤 **Play on Desktop**을 다시 누릅니다.
- 잠시 **Auto-pause behind apps**를 끕니다.
- 전체화면 앱 Space가 아니라 데스크톱을 보고 있는지 확인합니다.

월페이퍼가 흐리거나 잘려 보이는 경우:

- 전체 이미지나 영상을 보려면 **Fit**을 사용합니다.
- 화면을 꽉 채우고 가장자리 잘림을 허용하려면 **Fill**을 사용합니다.
- `scene.pkg` 항목이라면 unsupported particle, advanced script, shader, video texture를 쓰는지 확인합니다.

WebM, MKV, AVI 변환이 실패하는 경우:

```bash
brew install ffmpeg
```

화면 보호기 설정에 **Workshop Wallpaper Bridge**가 보이지 않는 경우:

- `swift run`만 쓰지 말고 패키징된 `.app`을 엽니다.
- **Animate Screen Saver**를 한 번 켭니다.
- `~/Library/Screen Savers/Workshop Wallpaper Bridge.saver`가 있는지 확인합니다.
- 목록이 바로 갱신되지 않으면 System Settings를 종료한 뒤 다시 엽니다.

화면 보호기 미리보기가 검은 화면인 경우:

- 최신 릴리즈를 설치합니다.
- **Animate Screen Saver**를 껐다가 다시 켭니다.
- **Screen Saver Settings**를 한 번 눌러 번들 화면 보호기를 다시 설치하고 선택합니다.

## 프로젝트 경계

Workshop Wallpaper Bridge는 local-only 앱입니다.

- Steam Workshop 항목을 다운로드하지 않습니다.
- Steam 인증을 우회하지 않습니다.
- DRM을 우회하지 않습니다.
- Steam protocol을 흉내 내지 않습니다.
- 완전한 `scene.pkg` 런타임 호환을 주장하지 않습니다.
- 제작자 asset을 업로드, 공유, 재배포하지 않습니다.
- 원본으로 복사해 온 Workshop 폴더를 수정하지 않습니다.

Workshop Wallpaper Bridge는 Valve, Steam, Wallpaper Engine과 관련이 없는 비공식 프로젝트입니다. Wallpaper Engine은 해당 소유자의 상표입니다.

## 라이선스

MIT
