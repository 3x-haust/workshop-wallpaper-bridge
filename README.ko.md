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

스캔 목록은 기본적으로 macOS 폴더 **Date Added** 값을 기준으로 최신순 정렬됩니다.
Date Added를 읽을 수 없으면 수정일을 fallback으로 사용합니다. 알파벳순으로 보고 싶으면
정렬을 **Name**으로 바꿀 수 있습니다. Import 이후 새로 복사되어 다음 Scan에서 발견된
항목에는 **NEW** 배지가 붙습니다.

직접 가진 영상을 쓰려면 Workshop 폴더를 스캔하지 않고 **Add Video File**을 누릅니다.

표시 방식:

- **Fit**: 전체 월페이퍼를 보존합니다.
- **Fill**: 화면을 꽉 채우며 가장자리가 잘릴 수 있습니다.
- **Stretch**: 화면 크기에 정확히 맞추며 이미지가 왜곡될 수 있습니다.

재생 동작:

- Dock과 Space 전환 깜빡임을 줄이기 위해 기본값은 연속 재생입니다.
- **Auto-pause behind apps**는 선택 옵션입니다.
- 설정창을 닫아도 재생은 멈추지 않습니다.
- **Open at Login**을 켜면 로그인 후 마지막 월페이퍼를 복구합니다.
- **Play on Desktop**은 macOS 데스크톱 사진을 바꾸지 않습니다. 그래서 투명 메뉴 바 색은 현재 시스템 배경화면 기준으로 유지됩니다.
- macOS 데스크톱 및 Lock Screen 정적 이미지를 실제로 바꾸고 싶을 때만 **Set Still Wallpaper**를 사용합니다.
- **Remove**는 Mac 라이브러리에 복사된 항목만 삭제합니다. 원본 복사 폴더나 원본 영상은 건드리지 않습니다.

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
| `scene.pkg` 씬 월페이퍼 | 네이티브 scene renderer를 먼저 사용합니다. packed 2D image layer, animated sprite-sheet texture, text-only scene, 일부 SceneScript snippet, keyframe 움직임, 일부 water/scroll shader, 단순 layer effect를 지원합니다. |

scene 지원은 보수적입니다. 이 앱은 지원되는 scene 기능을 직접 렌더링하지만, Wallpaper Engine 런타임 전체 호환을 주장하지 않습니다.

지원되는 scene 기능:

- Packed `.tex` texture, LZ4 block, 주요 DXT 형식.
- Text layer와 일부 text SceneScript `update(value)` snippet.
- Position, scale, rotation, opacity keyframe.
- Mirror 모드 keyframe animation의 ping-pong loop 재생.
- `TEXS0001`-`TEXS0003` frame container 기반 animated sprite-sheet(`texgif`) texture.
- Package constant 기반 일부 `waterFlow`, `waterWaves`, `waterRipple`, `scroll` shader 움직임.
- 안전하게 표현 가능한 단순 `shake`, `spin`, `shine` layer effect.
- Mesh, bone, mirror-mode bone animation, CPU skinning을 포함한 puppet-warp 모델(`MDLV0013`).
- `nitro` 계열 glint effect 근사와 단순 sprite 또는 pulse-ring particle system 근사.

아직 제한되거나 지원하지 않는 것:

- 내장 MP4 video texture.
- 복잡한 particle operator.
- Masked effect composition.
- Audio-reactive script.
- Object 또는 scene API script.
- 전체 custom shader pipeline.
- Media integration.

`wwbctl attach-scene-video <asset-id> <video-file>`는 진단이나 비교 workflow용 로컬 reference cache만 Mac 전용 라이브러리에 저장합니다. scene renderer를 대체하지 않습니다.

Package analyzer는 effect file, shader file, shader uniform, SceneScript, particle, sound layer, audio-analysis input, video texture 같은 scene runtime 요구사항을 보존하므로 renderer-engine parity 작업을 정확히 겨냥할 수 있습니다.

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

## 메인테이너와 기여자

<!-- profile-roster:start -->
이 영역은 GitHub 사용자 프로필에서 자동 생성됩니다.

### 메인테이너

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`

### 기여자

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`
- <a href="https://github.com/ohjack83-lab"><img src="https://avatars.githubusercontent.com/u/263676419?v=4&s=72" width="36" height="36" alt="@ohjack83-lab"></a> [ohjack83](https://github.com/ohjack83-lab) `@ohjack83-lab`
<!-- profile-roster:end -->

## 라이선스

MIT
