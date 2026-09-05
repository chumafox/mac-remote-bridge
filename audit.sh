#!/usr/bin/env bash
echo "=== 1. OS & USER ==="
sw_vers 2>/dev/null || uname -a
echo "User: $(whoami) (id: $(id -u))"
dseditgroup -o checkmember -m "$(whoami)" admin 2>/dev/null || true
echo ""

echo "=== 2. SSH PORT 22 ==="
lsof -nP -iTCP:22 -sTCP:LISTEN 2>/dev/null || echo "Port 22: NOT LISTENING"
echo ""

echo "=== 3. SSHD SYNTAX & TEST ==="
sudo -n /usr/sbin/sshd -t 2>&1 || /usr/sbin/sshd -t 2>&1 || echo "sshd test done"
echo ""

echo "=== 4. HOST KEYS IN /etc/ssh ==="
ls -la /etc/ssh/ssh_host_*_key 2>/dev/null || echo "NO HOST KEYS FOUND"
echo ""

echo "=== 5. LAUNCHD SSH STATUS ==="
launchctl print system/com.openssh.sshd 2>&1 | grep -E "state =|Disabled|last exit|active count|runs =" || true
echo ""

echo "=== 6. SSH ACL GROUP ==="
dseditgroup -o read com.apple.access_ssh 2>/dev/null || echo "Group com.apple.access_ssh: NOT FOUND"
echo ""

echo "=== 7. MACOS FIREWALL ==="
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true
echo ""

echo "=== 8. PINGGY REACHABILITY (PORT 443) ==="
nc -z -G 2 free.pinggy.io 443 2>&1 && echo "Pinggy: REACHABLE" || echo "Pinggy: BLOCKED"
echo ""
echo "=== AUDIT COMPLETE ==="
