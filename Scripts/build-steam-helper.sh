#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/steam-helper.env"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'Steam helper builds require macOS arm64.' >&2
  exit 1
fi
CACHE="${APP_SCRATCH_DIR:-${TMPDIR:-/tmp}/wwb-steam-helper-build}"
mkdir -p "$CACHE"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$CACHE/dotnet-home}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$CACHE/nuget}"
DOTNET="${DOTNET_ROOT:+$DOTNET_ROOT/dotnet}"
if [[ -z "$DOTNET" || ! -x "$DOTNET" ]]; then DOTNET="$(command -v dotnet || true)"; fi
if [[ -z "$DOTNET" || "$("$DOTNET" --version)" != "$STEAM_HELPER_SDK_VERSION" ]]; then
  export DOTNET_ROOT="$CACHE/dotnet-$STEAM_HELPER_SDK_VERSION"
  DOTNET="$DOTNET_ROOT/dotnet"
  if [[ ! -x "$DOTNET" ]]; then
    ARCHIVE="$CACHE/dotnet-$STEAM_HELPER_SDK_VERSION-osx-arm64.tar.gz"
    curl --fail --location --proto '=https' --tlsv1.2 "$STEAM_HELPER_SDK_URL" -o "$ARCHIVE"
    printf '%s  %s\n' "$STEAM_HELPER_SDK_SHA512" "$ARCHIVE" | shasum -a 512 -c -
    mkdir -p "$DOTNET_ROOT"
    tar -xzf "$ARCHIVE" -C "$DOTNET_ROOT"
  fi
fi
DOTNET="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$DOTNET")"
python3 "$ROOT/SteamHelper/verify-source.py"
cd "$ROOT/SteamHelper"
"$DOTNET" restore SteamHelper.csproj --locked-mode --runtime osx-arm64
"$DOTNET" publish SteamHelper.csproj --no-restore --configuration Release --runtime osx-arm64 \
  --self-contained true -p:DebugType=None -p:DebugSymbols=false -p:TreatWarningsAsErrors=true \
  --output "$ROOT/.build/steam-helper"
DESTINATION="$ROOT/.build/steam-helper"
mkdir -p "$DESTINATION/Licenses"
cp "$ROOT/SteamHelper/LICENSE" "$DESTINATION/Licenses/DepotDownloader-GPL-2.0.txt"
cp "$ROOT/SteamHelper/NOTICE.md" "$DESTINATION/NOTICE.md"
cp "$(dirname "$DOTNET")/LICENSE.txt" "$DESTINATION/Licenses/dotnet-LICENSE.txt"
cp "$(dirname "$DOTNET")/ThirdPartyNotices.txt" "$DESTINATION/Licenses/dotnet-ThirdPartyNotices.txt"
python3 "$ROOT/SteamHelper/package-source.py" "$DESTINATION"
printf '%s\n' "Built self-contained helper folder: $DESTINATION" "Executable: $DESTINATION/wwb-steam-helper"
