#!/usr/bin/env bash
# 构建 → 安装 → 启动 → 截图，一步到位。
#
# 存在的理由：DerivedData 下可能同时存在多个 Conn-* 目录（project 构建与
# workspace 构建各一个），用 `find | head -1` 猜路径会装到旧包上，且症状是
# "改了代码没生效"，极难察觉。这里改用 xcodebuild -showBuildSettings 取
# 权威的 TARGET_BUILD_DIR。
#
# 用法：
#   Tooling/run_sim.sh                      # 构建并截图到 /tmp
#   Tooling/run_sim.sh out.png              # 指定截图路径
#   DEVICE=<udid> Tooling/run_sim.sh        # 指定模拟器

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/Conn.xcworkspace"
SCHEME="Conn"
BUNDLE_ID="com.crazyball.Conn"
# 默认 iPhone 15 Pro / iOS 17.2 —— 与部署基线 iOS 17.0 最接近的可用模拟器
DEVICE="${DEVICE:-3E72DF80-B012-4A74-9217-F079D5FA00B1}"
SHOT="${1:-/tmp/conn-sim.png}"

echo "▸ 构建…"
xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug build \
  2>&1 | grep -E "error:|warning: .*(deprecated|unused)|BUILD" | tail -5

echo "▸ 解析产物路径…"
BUILD_DIR=$(xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR =/ {print $2; exit}')
APP="$BUILD_DIR/$SCHEME.app"

if [[ ! -d "$APP" ]]; then
  echo "✗ 找不到构建产物：$APP" >&2
  exit 1
fi
echo "  $APP"
echo "  产物时间: $(stat -f '%Sm' "$APP/$SCHEME")"

echo "▸ 启动模拟器…"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true

echo "▸ 安装并启动…"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

sleep 4
xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null
echo "▸ 截图: $SHOT"
