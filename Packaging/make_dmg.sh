#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# make_dmg.sh  —  24DOST DMG 패키져 (ffmpeg 임베드 포함)
# ─────────────────────────────────────────────────────────
set -e

APP_NAME="24DOST"
VERSION="0.1.1"
# 마운트되는 볼륨 이름. 예전엔 상수라 릴리스마다 옛 버전이 그대로 박혀 나갔다.
VOL_NAME="${APP_NAME} ${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"   # xcodebuild은 프로젝트 디렉터리에서 실행해야 함
OUTPUT_BASENAME="${1:-${APP_NAME}-${VERSION}}"
OUTPUT_BASENAME="${OUTPUT_BASENAME%.dmg}"
OUTPUT="${SCRIPT_DIR}/../Releases/${VERSION}/${OUTPUT_BASENAME}.dmg"
BG_IMG="${SCRIPT_DIR}/24DOST_wallpaper.png"

# dylib 소스 경로 목록 (cp가 심링크를 자동으로 역참조함)
DYLIB_SOURCES=(
  "/opt/homebrew/opt/ffmpeg/lib/libavdevice.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavfilter.11.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavformat.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libswresample.6.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libswscale.9.dylib"
  "/opt/homebrew/opt/ffmpeg/lib/libavutil.60.dylib"
  "/opt/homebrew/opt/libvmaf/lib/libvmaf.3.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
  "/opt/homebrew/opt/libvpx/lib/libvpx.12.dylib"
  "/opt/homebrew/opt/dav1d/lib/libdav1d.7.dylib"
  "/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib"
  "/opt/homebrew/opt/opus/lib/libopus.0.dylib"
  "/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib"
  "/opt/homebrew/opt/x264/lib/libx264.165.dylib"
  "/opt/homebrew/opt/x265/lib/libx265.216.dylib"
)

# Homebrew 경로를 번들 내부 경로로 교체
# $1: 파일 경로  $2: rpath 접두사 (@executable_path/../Frameworks 또는 @loader_path)
fix_homebrew_refs() {
  local file="$1"
  local rpath_prefix="$2"

  while IFS= read -r old_path; do
    [ -z "$old_path" ] && continue
    local base
    base=$(basename "$old_path")
    install_name_tool -change "$old_path" "${rpath_prefix}/${base}" "$file" 2>/dev/null || true
  done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep '/opt/homebrew')
}

# ──────────────────────────────────────────────────────────

# 배경 이미지 확인
if [ ! -f "$BG_IMG" ]; then
  echo "Error: 배경 이미지가 없습니다: $BG_IMG"; exit 1
fi

# ffmpeg 존재 확인
if [ ! -x "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" ]; then
  echo "Error: ffmpeg를 찾을 수 없습니다. brew install ffmpeg 를 먼저 실행하세요."; exit 1
fi

echo "▶ 1/5  Release 빌드 중…"
TEMP_DIR=$(mktemp -d)
DERIVED_DATA_DIR="${TEMP_DIR}/DerivedData"
xcodebuild \
  -scheme Dost \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build \
  -quiet

# 빌드 결과 경로를 동적으로 확인
BUILT_DIR="$(xcodebuild \
  -scheme Dost \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  -showBuildSettings 2>/dev/null \
  | awk '/^ +BUILT_PRODUCTS_DIR =/{for(i=3;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":""); print ""}')"
APP_SRC="${BUILT_DIR}/${APP_NAME}.app"

echo "    ✓ ${APP_SRC}"

echo "▶ 2/5  스테이징 구성 중…"
DMG_TEMP="${TEMP_DIR}/dmg_temp"
mkdir -p "${DMG_TEMP}/.background"

cp -R "${APP_SRC}"  "${DMG_TEMP}/${APP_NAME}.app"
ln -s /Applications  "${DMG_TEMP}/Applications"
cp "${BG_IMG}"       "${DMG_TEMP}/.background/background.png"

echo "▶ 3/5  ffmpeg 임베드 중…"
APP_BUNDLE="${DMG_TEMP}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
FW_DIR="${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "$FW_DIR"

# ffmpeg 바이너리 복사 (심링크 역참조)
cp /opt/homebrew/opt/ffmpeg/bin/ffmpeg "$MACOS_DIR/ffmpeg"
chmod +x "$MACOS_DIR/ffmpeg"

# ffprobe도 포함 (코덱 감지에 사용 — 공유 dylib 추가 없음)
if [ -x "/opt/homebrew/opt/ffmpeg/bin/ffprobe" ]; then
  cp /opt/homebrew/opt/ffmpeg/bin/ffprobe "$MACOS_DIR/ffprobe"
  chmod +x "$MACOS_DIR/ffprobe"
fi

# dylib 복사
for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  cp "$src" "$FW_DIR/$base"
  chmod 644 "$FW_DIR/$base"
done

# ffmpeg / ffprobe 바이너리: Homebrew 경로 → @executable_path/../Frameworks/
fix_homebrew_refs "$MACOS_DIR/ffmpeg" "@executable_path/../Frameworks"
[ -f "$MACOS_DIR/ffprobe" ] && \
  fix_homebrew_refs "$MACOS_DIR/ffprobe" "@executable_path/../Frameworks"

# 각 dylib: 자체 ID 설정 + 내부 상호 참조 수정
for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  target="$FW_DIR/$base"
  install_name_tool -id "@loader_path/$base" "$target" 2>/dev/null || true
  fix_homebrew_refs "$target" "@loader_path"
done

# 애드혹 코드 서명 (dylib → helper → 앱 번들 순)
for src in "${DYLIB_SOURCES[@]}"; do
  base=$(basename "$src")
  codesign --force --sign - --timestamp=none "$FW_DIR/$base"
done
codesign --force --sign - --timestamp=none "$MACOS_DIR/ffmpeg"
[ -f "$MACOS_DIR/ffprobe" ] && \
  codesign --force --sign - --timestamp=none "$MACOS_DIR/ffprobe"

# 앱 번들 전체 재서명 (수정된 번들 포함)
codesign --force --sign - --deep --timestamp=none "$APP_BUNDLE"

echo "    ✓ ffmpeg 임베드 완료 (Frameworks: $(du -sh "$FW_DIR" | cut -f1))"

echo "▶ 4/5  DMG 생성 및 Finder 창 설정 중…"

# 이전 마운트 정리
if [ -d "/Volumes/${VOL_NAME}" ]; then
  hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true
fi

# 쓰기 가능한 HFS+ DMG
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${DMG_TEMP}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${TEMP_DIR}/temp.dmg" >/dev/null

hdiutil attach "${TEMP_DIR}/temp.dmg" -readwrite -noverify -noautoopen >/dev/null
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 740, 580}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 80
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {195, 240}
    set position of item "Applications"    of container window to {445, 240}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync; sleep 2

for attempt in 1 2 3; do
  hdiutil detach "/Volumes/${VOL_NAME}" >/dev/null 2>&1 && break || sleep 1
done
hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true

for i in 1 2 3 4 5; do
  [ ! -d "/Volumes/${VOL_NAME}" ] && break; sleep 1
done

echo "▶ 5/5  압축 DMG 변환 중…"
mkdir -p "$(dirname "${OUTPUT}")"
rm -f "${OUTPUT}"
hdiutil convert "${TEMP_DIR}/temp.dmg" -format UDZO -o "${OUTPUT}" >/dev/null
rm -rf "${TEMP_DIR}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ ${OUTPUT}"
echo "  크기: $(du -sh "${OUTPUT}" | cut -f1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
