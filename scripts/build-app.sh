#!/bin/bash
# Tilo.app 번들을 빌드한다. 결과: build/Tilo.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Tilo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Tilo "$APP/Contents/MacOS/Tilo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 언어 리소스 (Bundle.main에서 바로 찾도록 Resources에 직접 복사)
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# Apple Developer 계정 없이 로컬 실행이 가능하도록 ad-hoc 서명
codesign --force --sign - "$APP"

echo "완료: $APP  (실행: open $APP)"
