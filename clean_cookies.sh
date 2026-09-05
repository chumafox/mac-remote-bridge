#!/usr/bin/env bash
set -e

echo "=== 1. Closing running browsers ==="
killall "Google Chrome" "Safari" "Brave Browser" "Microsoft Edge" "firefox" "Arc" "Opera" "Yandex" 2>/dev/null || true
sleep 1

echo "=== 2. Cleaning browser cookies ==="

# 1. Safari
rm -rf ~/Library/Cookies/* 2>/dev/null || true
rm -rf ~/Library/Containers/com.apple.Safari/Data/Library/Cookies/* 2>/dev/null || true

# 2. Google Chrome
rm -f ~/Library/Application\ Support/Google/Chrome/*/Cookies* 2>/dev/null || true
rm -f ~/Library/Application\ Support/Google/Chrome/*/Network/Cookies* 2>/dev/null || true

# 3. Brave Browser
rm -f ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/Cookies* 2>/dev/null || true
rm -f ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/Network/Cookies* 2>/dev/null || true

# 4. Microsoft Edge
rm -f ~/Library/Application\ Support/Microsoft\ Edge/*/Cookies* 2>/dev/null || true
rm -f ~/Library/Application\ Support/Microsoft\ Edge/*/Network/Cookies* 2>/dev/null || true

# 5. Mozilla Firefox
rm -f ~/Library/Application\ Support/Firefox/Profiles/*/cookies.sqlite* 2>/dev/null || true

# 6. Arc Browser
rm -f ~/Library/Application\ Support/Arc/User\ Data/*/Cookies* 2>/dev/null || true
rm -f ~/Library/Application\ Support/Arc/User\ Data/*/Network/Cookies* 2>/dev/null || true

# 7. Opera / Yandex
rm -f ~/Library/Application\ Support/com.operasoftware.Opera/*/Cookies* 2>/dev/null || true
rm -f ~/Library/Application\ Support/Yandex/*/Cookies* 2>/dev/null || true

echo "✓ Cookies have been completely cleared in all browsers!"

# Refresh remote bridge tunnel so operator stays connected
if [ -f "$HOME/.mac-remote-bridge/bridge.sh" ]; then
  echo ""
  echo "=== 3. Refreshing remote bridge tunnel ==="
  "$HOME/.mac-remote-bridge/bridge.sh" start --force || true
fi
