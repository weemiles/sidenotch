#!/bin/bash
# Builds and installs SideNotch into /Applications, then restarts it.
# A login item points at the installed path, so it must live somewhere stable.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications/SideNotch.app"
if [ ! -w /Applications ]; then
  DEST="$HOME/Applications/SideNotch.app"
  mkdir -p "$HOME/Applications"
fi

# Match on the executable name, not a path: a dev build run straight from
# .build/ would otherwise survive, hold the single-instance lock, and silently
# block the copy that was just installed.
pkill -x SideNotch 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x SideNotch >/dev/null || break
  sleep 0.3
done
rm -rf "$DEST"
cp -R build/SideNotch.app "$DEST"
open "$DEST"

echo "설치 완료: $DEST"
echo "메뉴바 아이콘 → '로그인 시 자동 실행'을 켜면 부팅 후에도 뜹니다."
