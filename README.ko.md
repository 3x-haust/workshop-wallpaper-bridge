# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.ko.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

로컬 Wallpaper Engine Workshop 파일을 macOS에서 배경화면처럼 사용합니다.

Workshop Wallpaper Bridge는 복사해 온 Wallpaper Engine Workshop 폴더를 Mac 전용 로컬 라이브러리로 가져오고, 지원되는 월페이퍼를 데스크톱 레이어에서 재생합니다. 이미 로컬에 가지고 있는 파일을 쓰기 위한 앱입니다. Steam에 접속하지 않고, Workshop 항목을 다운로드하지 않고, 복사해 온 Workshop 폴더를 수정하지 않습니다.

[웹사이트](https://3x-haust.github.io/workshop-wallpaper-bridge/) · [English](README.md) · [기여 안내](CONTRIBUTING.md) · [보안 정책](SECURITY.md) · [릴리즈](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) · [후원](https://www.patreon.com/c/3xhaust)

## 빠른 링크

- [다운로드](#다운로드): 최신 DMG를 설치합니다.
- [사용 방법](#사용-방법): 복사한 Workshop 폴더를 가져오거나 로컬 영상을 추가합니다.
- [지원 범위](#지원-범위): 지원되는 월페이퍼 유형을 확인합니다.
- [소스에서 빌드](#소스에서-빌드): 앱을 로컬에서 실행하거나 DMG를 패키징합니다.
- [메인테이너와 기여자](#메인테이너와-기여자): 프로젝트 메인테이너와 기여자 목록입니다.

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

- 스캔 목록은 기본적으로 macOS 폴더 **Date Added** 값을 기준으로 최신순 정렬됩니다(읽을 수 없으면 수정일을 fallback으로 사용).
- 알파벳순으로 보고 싶으면 정렬을 **Name**으로 바꿀 수 있습니다.
- Import 이후 새로 복사되어 다음 Scan에서 발견된 항목에는 **NEW** 배지가 붙습니다.

직접 가진 영상을 쓰려면 Workshop 폴더를 스캔하지 않고 **Add Video File**을 누릅니다.

표시 방식:

- **Fit**: 전체 월페이퍼를 보존합니다.
- **Fill**: 화면을 꽉 채우며 가장자리가 잘릴 수 있습니다.
- **Stretch**: 화면 크기에 정확히 맞추며 이미지가 왜곡될 수 있습니다.

재생 동작:

- Dock과 Space 전환 깜빡임을 줄이기 위해 기본값은 연속 재생입니다.
- **Auto-pause behind apps**는 선택 옵션입니다.
- **Play wallpaper audio**는 기본적으로 꺼져 있습니다(이전 버전과 동일한 무음 재생). 켜고 볼륨 슬라이더를 조절하면 동영상 월페이퍼의 오디오와, scene 월페이퍼의 경우 캐시된 scene 비디오에 함께 구워진 배경음악/환경음을 들을 수 있습니다.
- 두 재생 토글 모두 현재 재생 중인 월페이퍼에 재시작 없이 즉시 적용됩니다. 월페이퍼가 다른 앱에 가려져 자동 일시정지되면 소리도 함께 멈춥니다.
- 설정창을 닫아도 재생은 멈추지 않습니다.
- **Open at Login**을 켜면 로그인 후 마지막 월페이퍼를 복구합니다.
- **Play on Desktop**은 macOS 데스크톱 사진을 바꾸지 않습니다. 그래서 투명 메뉴 바 색은 현재 시스템 배경화면 기준으로 유지됩니다.
- macOS 데스크톱 및 Lock Screen 정적 이미지를 실제로 바꾸고 싶을 때만 **Set Still Wallpaper**를 사용합니다.
- **Remove**는 확인 절차를 거친 뒤 Mac 라이브러리에 복사된 항목만 휴지통으로 이동합니다(복원 가능). 원본 복사 폴더나 원본 영상은 건드리지 않습니다.

설정 창은 **Library** 탭(가져오기, Mac 라이브러리, Display mode, **Play on Desktop** / **Remove**)과 **Settings** 탭(재생 토글, Audio, Scene Engine Assets, Screen Saver, Language)으로 나뉩니다. **Convert Video**와 **Set Still Wallpaper**는 라이브러리 목록의 우클릭 컨텍스트 메뉴와 **Play on Desktop** 옆 **More**("⋯") 메뉴에서 사용할 수 있으며, 항상 보이는 버튼으로 노출되지 않습니다.

Settings 탭의 **Language** 선택기로 앱 UI 텍스트를 **System**, **한국어**, **English** 사이에서 전환할 수 있습니다. 앱을 재시작하지 않아도 즉시 적용되며, 버튼·섹션 제목·안내 문구 등 정적 UI 문구만 번역 대상이므로 앱 실행 중 생성되는 상태 메시지는 영어로 표시될 수 있습니다.

라이브러리 순환(로테이션):

- **Rotate Library**를 켜면 Mac 라이브러리의 재생 가능한 월페이퍼를 타이머에 맞춰 순서대로 자동 전환합니다.
- **Shuffle**은 순서를 무작위로 섞고, **Rotate Every**로 간격(30초·1분·5분·15분·30분·1시간)을 정하며, **Next**로 즉시 다음으로 넘어갑니다.
- 설정창과 메뉴바 양쪽에서 제어할 수 있습니다. 켜짐/꺼짐·셔플·간격 설정은 앱을 다시 켜도 유지되고 로그인 후 자동으로 재개됩니다.
- **Play on Desktop**이나 **Stop**을 누르면 로테이션이 꺼져 수동 선택이 우선합니다. 재생 불가 항목은 자동으로 건너뜁니다.

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
| `scene.pkg` 씬 월페이퍼 | 처음 재생할 때 화면에 보이지 않는 상태로 반복 재생되는 mp4로 렌더링해 캐시한 뒤, 이후에는 일반 동영상 월페이퍼처럼 재생합니다(아래 참고). 비디오 경로를 쓸 수 없으면 네이티브 renderer로 fallback합니다. |

scene 지원은 보수적입니다: 이 앱은 실시간 renderer 창보다 캐시된 비디오 렌더링을 우선하고, 렌더링할 수 없을 때만 근사치를 보여주는 네이티브 renderer로 대체합니다.

### scene 재생 동작 방식

- 처음 재생할 때 (번들되었거나 설정된 외부 GPL scene renderer와 `ffmpeg`를 이용해) scene을 화면에 보이지 않는 상태로(renderer 창은 절대 표시되지 않습니다) 렌더링해 반복 재생되는 mp4로 캐시합니다.
- 번들된 renderer가 지원하는 경우, 중간 PNG 프레임 파일 없이 프레임을 인코더로 동시에 스트리밍하여 첫 렌더링 속도를 눈에 띄게 높이며, 지원하지 않는 이전 renderer 빌드에서는 기존의 record-then-encode 방식으로 자동 대체됩니다.
- 캐시된 클립은 20초 분량이며, 인코딩 시 클립의 마지막 약 1.2초를 처음 약 1.2초와 크로스페이드해 이음매 자체를 자연스럽게 지웁니다(단순히 덜 자주 보이게 하는 데 그치지 않습니다).
- scene 패키지에 저작된 sound layer(배경음악, 환경음 등)가 있으면 해당 오디오를 `scene.pkg`에서 추출해 반복 재생되는 오디오 트랙으로 캐시된 비디오에 믹싱합니다. 오디오는 기본적으로 음소거 상태이며(**Play wallpaper audio**로 켤 수 있음), 비디오와 달리 이음매 크로스페이드가 적용되지 않아 반복 지점에서 미세한 이음매가 들릴 수 있습니다. 추출이 실패해도 무음 비디오가 생성됩니다.
- 첫 렌더링이 진행되는 동안 앱 상태 표시줄에 "Rendering scene to video… N%" 형태로 실시간 진행률이 표시됩니다.
- tradeoff: 비디오로 렌더링하면 scene의 애니메이션 루프가 고정된 클립으로 구워지므로, 재생 중에는 화면의 시계, 오디오 반응, 마우스/키보드 상호작용이 실시간으로 동작하지 않습니다 — renderer 창이 절대 나타나지 않는 대신 감수하는 tradeoff입니다.
- 캐시가 만들어지면 일반 동영상 월페이퍼 경로로 재생됩니다: `AVPlayerLooper` 기반의 끊김 없는 반복, 앱의 fit/fill/stretch 설정과 무관하게 항상 aspect-fill, 그리고 번들된 화면 보호기에서의 재사용(아래 화면 보호기 참고).

`wwbctl attach-scene-video <asset-id> <video-file>`는 여전히 진단이나 비교 workflow용 로컬 reference cache만 저장하며, 자동 렌더-투-비디오 캐시와는 무관합니다.

렌더링에는 번들된 renderer subprocess, `ffmpeg`, 그리고 사용자가 자기 Windows 설치본에서 복사한 Wallpaper Engine runtime `assets` 폴더가 필요합니다(Workshop Wallpaper Bridge는 이 파일들을 다운로드하거나 함께 배포하지 않습니다):

- 앱에서: **Scene Engine Assets** -> **Choose Assets Folder...**에서 복사한 `steamapps/common/wallpaper_engine/assets` 내용 폴더를 선택하세요.
- CLI/개발 실행에서는 `WWB_SCENE_ENGINE_ASSETS_DIR=/path/to/assets`가 앱 설정보다 우선하며, 그 외에는 `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`를 확인합니다.
- renderer binary가 있어도 engine assets 또는 `ffmpeg`가 없거나 불완전하면, 실패할 렌더링을 시도하지 않고 네이티브 fallback을 사용합니다.
- 캐시된 scene 비디오는 asset별로 `~/Library/Application Support/WorkshopWallpaperBridge/SceneVideoCache/`에 저장되며, 원본 `scene.pkg`가 바뀌면 자동으로 다시 만들어집니다.
- 이 프로젝트는 Steam Workshop 항목을 다운로드하지 않고, 제작자 asset을 재배포하지 않고, Steam content를 번들하지 않습니다. renderer binary는 별도 GPL component이며 자체 source notice가 필요합니다.

### 네이티브 fallback renderer

첫 렌더링이 진행 중이거나, renderer subprocess/engine assets/`ffmpeg` 중 하나라도 영구적으로 없을 때 쓰입니다.

지원 항목:

- packed `.tex` texture: LZ4 block과 주요 DXT 형식.
- text layer와 일부 text SceneScript `update(value)` snippet — 제한된 JavaScriptCore context(`Date`, `Math`, `engine.runtime`, `engine.frametime`, `engine.timeOfDay`, 파싱된 `scriptProperties`)에서 실행되며, loop, timer, eval/dynamic function, 지원하지 않는 API, 오류를 던지는 script는 기존 text를 유지하는 fail-closed 방식으로 처리됩니다.
- position/scale/rotation/opacity keyframe, mirror 모드 keyframe 애니메이션은 ping-pong 루프로 재생.
- animated sprite-sheet (`texgif`) texture — RePKG에 문서화된 `TEXS0001`-`TEXS0003` frame container(회전된 sheet packing, frame별 재생 시간 포함)를 해석해 Core Animation frame sequence로 재생.
- puppet-warp 모델(`MDLV0013` skeleton — Wallpaper Engine이 물고기·캐릭터의 몸을 휘게 하는 포맷): mesh/bone/mirror 모드 bone 애니메이션까지 디코드해 CPU skinning으로 재생하므로 puppet 몸체가 뻣뻣하게 미끄러지지 않고 실제로 휘어집니다.
- scene 패키지에 들어있는 GLSL shader를 Core Image로 그대로 포팅한 shader effect: `spin`, `shake`, `waterripple`, `waterwaves`, `waterflow`, `scroll` — flow-map 기반 shake 덕분에 지느러미와 꼬리만 움직이며, scene 전체를 덮는 compose layer의 `waterripple` 같은 full-canvas warp는 아래 layer들로 분배되어 살아있는 keyframe 모션 위에 물결이 적용됩니다.
- 근사 처리되는 particle/glint effect: 단순 sprite/pulse-ring particle system은 Core Animation emitter로, `nitro` 계열 glint effect는 noise 기반 twinkle 근사로 재생.

여전히 생략되거나 근사치인 항목: 복잡한 particle operator, masked effect composition, audio-reactive 또는 object/scene API script, 전체 custom shader pipeline, media integration, 내장 MP4 video texture — 네이티브 scene engine이 해당 runtime 기능을 구현하기 전까지 Wallpaper Engine과 다르게 보일 수 있습니다. package analyzer가 effect file, shader file, shader uniform, SceneScript, particle, sound layer, audio-analysis input, video texture 같은 scene runtime 요구사항을 보존하므로 이 parity 작업을 정확히 겨냥할 수 있습니다.

`preview.jpg`, `thumbnail.jpg`, `cover.png` 같은 Workshop 미리보기 파일은 썸네일로 취급합니다. 프로젝트에 `scene.pkg`가 있으면 낮은 해상도 미리보기를 늘려 쓰지 않고 패키지 내부 scene 데이터를 읽습니다.

## 화면 보호기

**Animate Screen Saver**를 켜면 앱이 번들된 macOS 화면 보호기를 설치하고 현재 Mac host의 화면 보호기로 선택합니다.

화면 보호기에서 움직이는 것:

- Mac 라이브러리의 MP4, MOV, M4V 월페이퍼.
- **Add Video File**로 추가한 로컬 영상.
- 렌더링된 동영상 캐시가 있는 scene 월페이퍼(위 지원 범위 참고): 화면 보호기가 그 캐시된 mp4를 그대로 재사용하며, 백그라운드 렌더링이 끝나는 대로 다시 재생하지 않아도 정적 미리보기에서 자동으로 캐시된 동영상으로 바뀝니다.

정적 fallback을 쓰는 것:

- 변환 전 WebM, MKV, AVI.
- 웹 월페이퍼.
- 아직 동영상 캐시가 렌더링되지 않은 scene 월페이퍼.

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

선택적인 외부 GPL scene renderer를 로컬 패키지에 포함하려면:

- `Scripts/package-app.sh`를 실행하기 전에 `SCENE_RENDERER_BINARY=/path/to/wwb-scene-renderer`를 설정하거나 실행 파일을 `ExternalRenderers/wwb-scene-renderer`에 둡니다.
- 패키지 script는 renderer가 있으면 app resources로 복사하고, [3x-haust/wallpaperengine-mac-renderer](https://github.com/3x-haust/wallpaperengine-mac-renderer)의 기본 pinned source ref `b79ac590ff5ddcfdae2d26f5c3a5d289b3e4b058`와 source link를 담은 `Renderer Notices/GPL Scene Renderer Notice.txt`를 항상 씁니다.
- 다른 renderer build를 배포한다면 해당 공개 source에 맞게 `SCENE_RENDERER_SOURCE_URL`과 `SCENE_RENDERER_SOURCE_REF`를 설정하세요.

패키지는 Wallpaper Engine runtime assets를 절대 포함하지 않습니다:

- 본인의 Windows Wallpaper Engine `steamapps/common/wallpaper_engine/assets` 내용 폴더를 복사한 뒤, 앱의 **Scene Engine Assets** -> **Choose Assets Folder...**에서 선택하세요.
- CLI/개발 실행에서는 `WWB_SCENE_ENGINE_ASSETS_DIR`가 앱 설정보다 우선하며, 기본 fallback은 `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`입니다.
- `swift run wwbctl doctor`로 renderer binary와 필수 engine asset 파일의 사용 가능 여부를 확인할 수 있습니다.

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
- 미리보기에 완전한 검은 화면 대신 무엇이 실패했는지 설명하는 흐릿한 텍스트가 보인다면, 그 메시지가 문제(예: 읽지 못한 이미지)를 알려주는 것입니다; 메시지 없는 순수 검은 화면은 설정 자체가 로드되지 않았다는 뜻이며 위 단계로 해결됩니다.

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

## 메인테이너와 기여자

<!-- profile-roster:start -->
이 영역은 GitHub 사용자 프로필에서 자동 생성됩니다.

### 메인테이너

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`

### 기여자

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`
- <a href="https://github.com/lotgood"><img src="https://avatars.githubusercontent.com/u/31810171?v=4&s=72" width="36" height="36" alt="@lotgood"></a> [@lotgood](https://github.com/lotgood)
- <a href="https://github.com/ohjack83-lab"><img src="https://avatars.githubusercontent.com/u/263676419?v=4&s=72" width="36" height="36" alt="@ohjack83-lab"></a> [ohjack83](https://github.com/ohjack83-lab) `@ohjack83-lab`
<!-- profile-roster:end -->

## 라이선스

MIT
