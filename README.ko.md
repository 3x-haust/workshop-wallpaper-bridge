# Workshop Wallpaper Bridge

내가 가진 Wallpaper Engine Workshop 프로젝트를 macOS에서 배경화면처럼 사용합니다.

Workshop Wallpaper Bridge는 Windows에서 Wallpaper Engine을 구매해 사용하던 사람이, 본인의 로컬 Workshop 폴더를 Mac으로 복사한 뒤 쓰기 위한 앱입니다. 복사한 폴더를 스캔하고, 지원 가능한 월페이퍼를 Mac 전용 로컬 라이브러리에 가져오고, video/web/image 월페이퍼를 데스크톱 레이어에서 재생합니다.

[English README](README.md)

## 빠른 시작

1. Windows에서 Wallpaper Engine Workshop 폴더를 찾습니다.

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. `431960` 폴더를 Mac으로 복사합니다.
3. GitHub 최신 release에서 `WorkshopWallpaperBridge-macOS-arm64.zip`을 받습니다.
4. 압축을 풀고 **Workshop Wallpaper Bridge.app**을 엽니다.
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

## 재생 방식

- **Auto-pause behind apps**가 기본으로 켜져 있습니다.
- Workshop Wallpaper Bridge 컨트롤 창을 최소화하거나 숨겨도 재생은 멈추지 않습니다.
- 설정창을 닫아도 앱은 종료되지 않습니다. 완전히 끄려면 메뉴바 아이콘에서 **Quit**을 누릅니다.
- 다른 앱이 데스크톱을 가리면 월페이퍼 레이어는 그대로 두고 동영상 재생만 멈춥니다.
- 다시 바탕화면으로 돌아오면 자동으로 재생을 이어갑니다.
- 노트북이 잠자기에서 깨어나거나 모니터 구성이 바뀌면 월페이퍼 창을 다시 만들고 선택한 월페이퍼를 복구합니다.
- 계속 재생하고 싶으면 메뉴바 아이콘이나 설정창에서 **Auto-pause behind apps**를 끄면 됩니다.
- 가져온 항목이 필요 없어지면 imported library 목록에서 **Remove**를 눌러 Mac 라이브러리 복사본을 삭제합니다.

## 잠금화면과 정적 배경화면

macOS는 서드파티 앱이 안정적으로 사용할 수 있는 공개 animated Lock Screen wallpaper API를 제공하지 않습니다. 이 앱은 private API나 시스템 wallpaper database 패치를 사용하지 않습니다.

대신 안전하게 할 수 있는 것:

- Workshop 프로젝트의 미리보기 이미지를 macOS 데스크톱 배경화면으로 설정합니다.
- macOS 설정이 데스크톱 배경을 잠금화면과 연동하는 경우, 잠금화면에도 같은 정적 이미지가 표시될 수 있습니다.

가져온 프로젝트에서 **Set Still Wallpaper**를 누르면 됩니다. 동영상 프로젝트는 `preview.jpg`, `preview.png` 같은 썸네일 파일이 있어야 합니다.

## 지원 범위

| 프로젝트 유형 | 지원 |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` 동영상 | 바로 재생 |
| `.webm`, `.mkv`, `.avi` 동영상 | 로컬 `ffmpeg`로 변환 후 재생 |
| `index.html` 웹 월페이퍼 | 제한된 WebView에서 로컬 재생 |
| `.jpg`, `.png`, `.gif`, `.heic` 이미지 | 정적 데스크톱 레이어로 표시 |
| `scene.pkg` 씬 월페이퍼 | 감지만 함. 해체/변환하지 않음 |

직접 가진 로컬 영상도 **Add Video File**로 추가할 수 있습니다. MP4, MOV, M4V는 바로 재생하고, WebM, MKV, AVI는 먼저 가져온 뒤 로컬 `ffmpeg`로 변환해서 재생합니다.

`preview.jpg`, `thumbnail.jpg`, `cover.png` 같은 Workshop 미리보기 파일은 실제 월페이퍼가 아니라 썸네일로 취급합니다. 어떤 Workshop 프로젝트가 `scene.pkg`와 미리보기 이미지만 가지고 있으면, 앱은 저해상도 preview를 화면에 늘려 쓰지 않고 지원 불가 항목으로 표시합니다.

## 하지 않는 것

Workshop Wallpaper Bridge는 local-only 앱입니다.

- Steam Workshop 자료를 다운로드하지 않습니다.
- Steam 인증을 우회하지 않습니다.
- DRM을 우회하지 않습니다.
- Steam protocol을 흉내 내지 않습니다.
- `scene.pkg`를 풀거나 역공학하지 않습니다.
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
dist/WorkshopWallpaperBridge-macOS-arm64.zip
```

## CLI

고급 사용자와 검증을 위해 `wwbctl`도 제공합니다.

```bash
swift run wwbctl scan "/path/to/431960" --out index.json
swift run wwbctl import "/path/to/431960"
swift run wwbctl import-video "/path/to/video.mp4"
swift run wwbctl remove "<asset-id>"
swift run wwbctl convert input.webm --out output.mp4
swift run wwbctl doctor
```

## 문제 해결

바탕화면에 아무것도 안 보이면:

- 가져온 프로젝트가 `playable`인지 확인합니다.
- **Stop**을 누른 뒤 **Play on Desktop**을 다시 누릅니다.
- 잠시 **Auto-pause behind apps**를 꺼봅니다.
- 전체화면 앱 Space가 아니라 실제 바탕화면을 보고 있는지 확인합니다.

화질이 흐리거나 화면이 잘려 보이면:

- 전체 이미지/영상을 다 보고 싶으면 **Fit**을 선택합니다.
- 화면을 꽉 채우고 가장자리 잘림을 허용하려면 **Fill**을 선택합니다.
- Workshop 항목이 `scene.pkg` 프로젝트인지 확인합니다. scene-only 프로젝트는 감지만 하고 렌더링하지 않으므로 preview 썸네일을 가짜 배경화면으로 쓰지 않습니다.

WebM/MKV/AVI 변환이 실패하면:

```bash
brew install ffmpeg
```

macOS가 확인되지 않은 개발자 경고를 띄우면 아직 공증되지 않은 배포본이라는 뜻입니다. 원하면 Swift로 직접 빌드해서 실행할 수 있습니다.

## Wallpaper Engine과의 관계

이 프로젝트는 Valve, Steam, Wallpaper Engine과 관련이 없는 비공식 프로젝트입니다. Wallpaper Engine은 해당 소유자의 상표입니다. Workshop Wallpaper Bridge는 사용자가 합법적으로 접근할 수 있는 로컬 파일을 개인적으로 활용하기 위한 호환 도구입니다.

## 라이선스

MIT
