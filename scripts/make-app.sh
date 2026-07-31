#!/bin/bash
# 构建 release 可执行文件并组装 .app 包
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/DeepSeek Chat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/DeepSeekChat "$APP/Contents/MacOS/DeepSeekChat"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>DeepSeek Chat</string>
	<key>CFBundleDisplayName</key>
	<string>DeepSeek Chat</string>
	<key>CFBundleIdentifier</key>
	<string>com.deepseek.chat</string>
	<key>CFBundleExecutable</key>
	<string>DeepSeekChat</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名，避免 Gatekeeper 弹窗
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✅ 构建完成: $APP"
