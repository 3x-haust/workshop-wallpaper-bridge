# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.ko.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

내가 가진 Wallpaper Engine Workshop 프로젝트를 macOS에서 배경화면처럼 사용합니다.

Workshop Wallpaper Bridge는 Windows에서 Wallpaper Engine을 구매해 사용하던 사람이, 본인의 로컬 Workshop 폴더를 Mac으로 복사한 뒤 쓰기 위한 앱입니다. 복사한 폴더를 스캔하고, 지원 가능한 월페이퍼를 Mac 전용 로컬 라이브러리에 가져오고, video/web/image/scene 월페이퍼를 데스크톱 레이어에서 재생합니다.

[English README](README.md) · [기여 안내](CONTRIBUTING.md) · [보안 정책](SECURITY.md)

## 데모

![Workshop Wallpaper Bridge 데모](assets/workshop-wallpaper-bridge-demo.gif)

## 주요 기능

- 로컬로 복사한 Wallpaper Engine Workshop 프로젝트를 Mac 전용 라이브러리로 가져옵니다.
- MP4, MOV, M4V, 제한된 로컬 웹 월페이퍼, 이미지, 지원 가능한 `scene.pkg` 프로젝트를 데스크톱 레이어에서 재생합니다.
- WebM, MKV, AVI 파일은 로컬 `ffmpeg`로 변환할 수 있습니다.
- Mac이 잠겨 있는 동안 애니메이션을 재생하는 macOS 화면 보호기를 번들로 설치할 수 있습니다.
- 원본으로 복사해 온 Workshop 폴더는 수정하지 않습니다.
- 스캔, 가져오기, 변환, scene 진단을 위한 CLI `wwbctl`을 제공합니다.

## 프로젝트 상태

아직 초기 호환성 프로젝트입니다. 동영상과 이미지는 가장 안정적인 경로입니다. scene 지원은 보수적으로 동작하며, 현재는 패키지 안의 2D image layer, 주요 texture 형식, 기본 keyframe 움직임에 집중합니다.

Workshop Wallpaper Bridge는 Valve, Steam, Wallpaper Engine과 관련이 없는 비공식 프로젝트입니다. Steam Workshop 다운로드, Steam 인증 우회, DRM 우회, 제작자 asset 재배포 기능을 제공하지 않습니다.

## 빠른 시작

1. Windows에서 Wallpaper Engine Workshop 폴더를 찾습니다.

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. `431960` 폴더를 Mac으로 복사합니다.
3. GitHub 최신 release에서 `WorkshopWallpaperBridge-macOS-arm64.dmg`를 받습니다.
4. DMG를 열고 **Workshop Wallpaper Bridge.app**을 **Applications**로 드래그한 뒤 앱을 엽니다.
5. 메뉴바 아이콘을 누르고 **Open Settings**를 선택합니다.
6. Wallpaper Engine 프로젝트는 **Browse**를 누르고 복사한 `431960` 폴더를 선택한 뒤 **Scan**을 누릅니다.
7. 지원 가능한 프로젝트를 선택하고 **Import Selected**를 누릅니다.
8. 직접 가진 영상을 쓰려면 대신 **Add Video File**을 누릅니다.
9. 가져온 프로젝트나 영상을 선택하고 **Play on Desktop**을 누릅니다.
10. **Display**를 선택합니다.
    - **Fit**: 전체 월페이퍼를 다 보여줍니다. 화면 비율이 다르면 검은 여백이 생길 수 있습니다.
    - **Fill**: Wallpaper Engine의 cover 방식처럼 화면을 꽉 채웁니다. 가장자리가 잘릴 수 있습니다.
    - **Stretch**: 화면에 정확히 맞게 늘립니다. 이미지가 왜곡될 수 있습니다.
11. 더 이상 필요 없는 항목은 **Remove**로 Mac 로컬 라이브러리에서 지울 수 있습니다. 원본 복사 폴더나 원본 영상은 건드리지 않습니다.

앱은 메뉴바 유틸리티로 실행됩니다. Dock이나 앱 전환기에 계속 뜨지 않고, 설정창을 닫아도 데스크톱 레이어의 움직이는 배경화면은 계속 재생됩니다.

Mac이 잠겨 있는 동안 움직이게 하려면 **Animate Lock Screen**을 켜고 **Screen Saver Settings**를 누른 뒤 macOS 화면 보호기에서 **Workshop Wallpaper Bridge**를 선택합니다. 이 버튼은 System Settings를 열기 전에 번들된 화면 보호기를 먼저 설치합니다. macOS는 로그인/잠금화면 배경화면 자체를 라이브 영상으로 교체하는 공개 경로를 제공하지 않으므로, 이 앱은 화면 보호기 경로를 사용합니다. MP4, MOV, M4V 월페이퍼는 선택한 화면 보호기가 시작된 뒤 재생됩니다. 다른 형식은 정적 이미지 fallback을 사용합니다.

## 재생 방식

- **Auto-pause behind apps**가 기본으로 켜져 있습니다.
- Workshop Wallpaper Bridge 컨트롤 창을 최소화하거나 숨겨도 재생은 멈추지 않습니다.
- 설정창을 닫아도 앱은 종료되지 않습니다. 완전히 끄려면 메뉴바 아이콘에서 **Quit**을 누릅니다.
- 다른 앱이 데스크톱을 가리면 월페이퍼 레이어는 그대로 두고 동영상 재생만 멈춥니다.
- 다시 바탕화면으로 돌아오면 자동으로 재생을 이어갑니다.
- 노트북이 잠자기에서 깨어나거나 모니터 구성이 바뀌면 월페이퍼 창을 다시 만들고 선택한 월페이퍼를 복구합니다.
- 계속 재생하고 싶으면 메뉴바 아이콘이나 설정창에서 **Auto-pause behind apps**를 끄면 됩니다.
- 로그인 후 자동으로 켜지게 하려면 **Open at Login**을 켭니다. **Stop Playback**을 누르지 않았다면 앱 실행 시 마지막으로 재생한 월페이퍼를 다시 복구합니다.
- 가져온 항목이 필요 없어지면 imported library 목록에서 **Remove**를 눌러 Mac 라이브러리 복사본을 삭제합니다.

## 성능 스냅샷

Apple M2 Mac, macOS 26.2, 로컬 MP4 월페이퍼 기준으로 측정했습니다.

- Launch-to-process 평균: 5회 cold open 기준 69.8 ms.
- 재생 샘플: 20초 동안 평균 CPU 2.35%, 평균 RSS 107.1 MB.
- 동영상 still frame 추출: 5회 평균 231.7 ms.
- 현재 로컬 라이브러리 스캔: 466 ms.

## 잠금화면과 정적 배경화면

Workshop Wallpaper Bridge는 번들된 macOS screen saver로 잠금 상태 애니메이션을 지원합니다. Apple은 커스텀 screen saver를 만들 수 있는 공개 `ScreenSaverView` framework를 제공하고, macOS Lock Screen 설정은 선택한 screen saver를 비활성 상태나 잠금 상태에서 시작할 수 있습니다.

중요: macOS 설정에서 **Workshop Wallpaper Bridge**를 화면 보호기로 직접 선택해야 합니다. 앱은 번들된 화면 보호기를 설치하고 현재 선택한 월페이퍼 설정을 기록할 수 있지만, macOS가 선택한 화면 보호기를 강제로 바꾸지는 않습니다.

잠금화면에 기존 정적 배경화면이 계속 보이면 System Settings의 Lock Screen 시간 설정을 확인합니다. macOS는 선택한 화면 보호기가 시작되기 전까지 일반 로그인/잠금화면 배경을 보여줍니다. Mac을 닫았다가 다시 열면 보통 이 정적 시스템 잠금화면이 먼저 보이고, 움직임은 macOS가 선택한 화면 보호기를 시작한 뒤에만 나타납니다.

움직이는 잠금화면으로 지원하는 것:

- Mac 라이브러리에서 선택한 MP4, MOV, M4V 동영상 월페이퍼.
- **Add Video File**로 추가한 직접 가진 영상.

정적 이미지 fallback을 쓰는 것:

- MP4로 변환하기 전의 WebM, MKV, AVI.
- 웹 월페이퍼.
- scene 월페이퍼. 데스크톱에서는 지원 가능한 2D image layer를 렌더링하지만, 잠금화면 screen saver는 scene 프로젝트에 대해 정적 fallback 이미지를 사용합니다.

켜는 방법:

1. **Workshop Wallpaper Bridge Settings**를 엽니다.
2. **Animate Lock Screen**을 켭니다.
3. **Screen Saver Settings**를 누릅니다. 이 동작은 번들된 `.saver`를 `~/Library/Screen Savers`에 설치하거나 갱신합니다.
4. macOS 화면 보호기에서 **Workshop Wallpaper Bridge**를 선택합니다.
5. macOS Lock Screen 설정에서 화면 보호기 시작 시간과 암호 요구 시간을 정합니다.

이 앱은 Apple Aerial wallpaper database를 패치하거나 비공개 Lock Screen wallpaper database를 수정하지 않습니다.

대신 안전하게 할 수 있는 것:

- 정적 이미지를 macOS 데스크톱 배경화면으로 설정합니다.
- MP4, MOV, M4V 동영상 월페이퍼는 작은 Workshop preview GIF 대신 동영상 파일에서 still frame을 뽑아 사용합니다.
- 현재 사용자용 macOS Lock Screen cache가 사용 가능한 경우, 같은 정적 이미지를 그 cache에도 기록합니다.

가져온 프로젝트에서 **Set Still Wallpaper**를 누르면 됩니다. 바로 재생 가능한 동영상 프로젝트는 동영상 파일에서 생성한 frame을 사용하고, WebM/MKV/AVI 프로젝트는 먼저 변환해야 합니다. 이미지/scene 프로젝트는 사용 가능한 still preview를 사용합니다. macOS가 이미 잠금화면 이미지를 캐시한 상태라면 실제 화면 반영은 잠금, 로그아웃, 다음 wallpaper refresh 이후에 보일 수 있습니다.

## 지원 범위

| 프로젝트 유형 | 지원 |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` 동영상 | 바로 재생 |
| `.webm`, `.mkv`, `.avi` 동영상 | 로컬 `ffmpeg`로 변환 후 재생 |
| `index.html` 웹 월페이퍼 | 제한된 WebView에서 로컬 재생 |
| `.jpg`, `.png`, `.gif`, `.heic` 이미지 | 정적 데스크톱 레이어로 표시 |
| `scene.pkg` 씬 월페이퍼 | 패키지 안의 2D image layer와 기본 keyframe 움직임을 렌더링 |

직접 가진 로컬 영상도 **Add Video File**로 추가할 수 있습니다. MP4, MOV, M4V는 바로 재생하고, WebM, MKV, AVI는 먼저 가져온 뒤 로컬 `ffmpeg`로 변환해서 재생합니다.

`preview.jpg`, `thumbnail.jpg`, `cover.png` 같은 Workshop 미리보기 파일은 실제 월페이퍼가 아니라 썸네일로 취급합니다. Workshop 프로젝트가 `scene.pkg`를 가지고 있으면, 앱은 패키지 내부 scene 데이터를 읽고 지원 가능한 2D image layer를 렌더링합니다. 저해상도 preview를 화면에 늘려 가짜 배경화면으로 쓰지 않습니다.

scene 지원은 보수적으로 동작합니다. 기본 image-layer scene은 로컬에서 재생되며, packed `.tex` texture, LZ4 block, 주요 DXT texture 형식, position/scale/rotation/opacity keyframe을 처리합니다. 하지만 particle, audio-reactive script, custom shader, text layer, media integration, video/GIF texture animation 같은 Wallpaper Engine 런타임 기능은 생략되거나 원본과 다르게 보일 수 있습니다.

## 하지 않는 것

Workshop Wallpaper Bridge는 local-only 앱입니다.

- Steam Workshop 자료를 다운로드하지 않습니다.
- Steam 인증을 우회하지 않습니다.
- DRM을 우회하지 않습니다.
- Steam protocol을 흉내 내지 않습니다.
- 완전한 `scene.pkg` 런타임 호환을 지원한다고 주장하지 않습니다.
- 제작자 asset을 업로드, 공유, 재배포하지 않습니다.
- 원본으로 복사해 온 Workshop 폴더를 수정하지 않습니다.

가져온 파일은 아래 위치에 복사됩니다.

```text
~/Library/Application Support/WorkshopWallpaperBridge
```

## 소스에서 실행

필요한 것:

- macOS 14 이상
- Xcode command line tools
- Swift 6 toolchain
- 선택: WebM/MKV/AVI 변환용 `ffmpeg`

```bash
git clone https://github.com/3x-haust/workshop-wallpaper-bridge.git
cd workshop-wallpaper-bridge
swift run WorkshopWallpaperBridge
```

`ffmpeg` 설치:

```bash
brew install ffmpeg
```

## 로컬 앱 번들 만들기

```bash
bash Scripts/package-app.sh
open "dist/Workshop Wallpaper Bridge.app"
```

생성되는 파일:

```text
dist/WorkshopWallpaperBridge-macOS-arm64.dmg
```

## Developer ID 서명과 공증

로컬 개발 빌드는 unsigned여도 괜찮지만, 공개 GitHub release는 Apple Developer ID 서명과 notarization을 해야 사용자가 확인되지 않은 개발자 경고를 덜 보게 됩니다.

필요한 것:

- Apple Developer Program 가입
- Keychain에 설치된 `Developer ID Application` 인증서
- 저장된 notary profile. 예:

```bash
xcrun notarytool store-credentials "wwb-notary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

DMG 빌드, 서명, 공증, staple:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" \
NOTARY_PROFILE="wwb-notary" \
REQUIRE_SIGNING=1 \
bash Scripts/package-app.sh
```

스크립트는 번들 내부 실행 파일, 앱 번들, DMG를 서명하고, `notarytool`로 제출한 뒤 통과한 ticket을 staple하고 `spctl`로 최종 DMG를 검증합니다.

## CLI

고급 사용자와 검증을 위해 `wwbctl`도 제공합니다.

```bash
swift run wwbctl scan "/path/to/431960" --out index.json
swift run wwbctl import "/path/to/431960"
swift run wwbctl import-video "/path/to/video.mp4"
swift run wwbctl remove "<asset-id>"
swift run wwbctl convert input.webm --out output.mp4
swift run wwbctl scene-info "/path/to/scene.pkg"
swift run wwbctl scene-render-info "/path/to/scene.pkg"
swift run wwbctl doctor
```

scene이 정적으로 보이면 먼저 `scene-info`를 실행해 보세요. 큰 texture를 디코딩하지 않고 animation, particle, effect, shader 개수를 보여줍니다. `scene-render-info`는 지원 가능한 texture를 실제로 디코딩하므로 고해상도 scene에서는 시간이 더 걸릴 수 있습니다.

## 문제 해결

바탕화면에 아무것도 안 보이면:

- 가져온 프로젝트가 `playable`인지 확인합니다.
- **Stop**을 누른 뒤 **Play on Desktop**을 다시 누릅니다.
- 잠시 **Auto-pause behind apps**를 꺼봅니다.
- 전체화면 앱 Space가 아니라 실제 바탕화면을 보고 있는지 확인합니다.

화질이 흐리거나 화면이 잘려 보이면:

- 전체 이미지/영상을 다 보고 싶으면 **Fit**을 선택합니다.
- 화면을 꽉 채우고 가장자리 잘림을 허용하려면 **Fill**을 선택합니다.
- Workshop 항목이 unsupported 효과를 많이 쓰는 `scene.pkg` 프로젝트인지 확인합니다. scene 프로젝트는 지원 가능한 image layer와 기본 keyframe layer motion을 렌더링하지만 particle, script, custom shader, animated texture 기능은 Wallpaper Engine과 다르게 보일 수 있습니다.

WebM/MKV/AVI 변환이 실패하면:

```bash
brew install ffmpeg
```

macOS가 확인되지 않은 개발자 경고를 띄우면 아직 공증되지 않은 배포본이라는 뜻입니다. 원하면 Swift로 직접 빌드해서 실행할 수 있습니다.

화면 보호기 설정에 **Workshop Wallpaper Bridge**가 보이지 않으면:

- `swift run`만 쓰지 말고 패키징된 `.app`에서 실행합니다.
- **Animate Lock Screen**을 한 번 켠 뒤 **Screen Saver Settings**를 누릅니다.
- `~/Library/Screen Savers/Workshop Wallpaper Bridge.saver`가 생겼는지 확인합니다.
- macOS가 목록을 바로 갱신하지 않으면 System Settings를 종료한 뒤 다시 엽니다.

미리보기가 검은 화면이면 최신 앱을 설치한 뒤 System Settings를 다시 시작합니다. 앱은 이제 화면 보호기용 still fallback 이미지를 기록하고, 화면 보호기가 미디어를 읽기 전에 가져온 파일의 macOS quarantine metadata를 제거합니다.

## Wallpaper Engine과의 관계

이 프로젝트는 Valve, Steam, Wallpaper Engine과 관련이 없는 비공식 프로젝트입니다. Wallpaper Engine은 해당 소유자의 상표입니다. Workshop Wallpaper Bridge는 사용자가 합법적으로 접근할 수 있는 로컬 파일을 개인적으로 활용하기 위한 호환 도구입니다.

## 라이선스

MIT
