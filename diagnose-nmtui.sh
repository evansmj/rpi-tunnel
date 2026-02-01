#!/usr/bin/env bash
# Diagnostic script to figure out why nmtui isn't showing wireless networks

echo "=== nmtui Wireless Networks Diagnostic ==="
echo ""

echo "1️⃣ Check NetworkManager status:"
echo "   NetworkManager service:"
systemctl status NetworkManager --no-pager | head -5
echo ""
echo "   NetworkManager device status:"
nmcli device status
echo ""

echo "2️⃣ Check if wlan0 is managed by NetworkManager:"
WLAN0_STATUS=$(nmcli device status | grep wlan0 | awk '{print $3}')
echo "   wlan0 status: $WLAN0_STATUS"
if [ "$WLAN0_STATUS" = "unmanaged" ] || [ "$WLAN0_STATUS" = "unavailable" ]; then
    echo "   ❌ PROBLEM: wlan0 is $WLAN0_STATUS (this prevents nmtui from showing networks)"
else
    echo "   ✅ wlan0 is managed by NetworkManager"
fi
echo ""

echo "3️⃣ Check NetworkManager.conf for unmanaged-devices:"
echo "   Current config:"
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
    grep -A 5 -B 2 "unmanaged-devices\|keyfile" /etc/NetworkManager/NetworkManager.conf || echo "   (no unmanaged-devices found)"
else
    echo "   ❌ Config file not found!"
fi
echo ""

echo "4️⃣ Check Wi-Fi radio status:"
WIFI_RADIO=$(nmcli radio wifi)
echo "   Wi-Fi radio: $WIFI_RADIO"
if [ "$WIFI_RADIO" = "disabled" ]; then
    echo "   ❌ PROBLEM: Wi-Fi radio is disabled"
else
    echo "   ✅ Wi-Fi radio is enabled"
fi
echo ""

echo "5️⃣ Check rfkill (software/hardware blocks):"
if command -v rfkill >/dev/null 2>&1; then
    echo "   rfkill status:"
    sudo rfkill list wifi
    echo ""
    SOFT_BLOCKED=$(sudo rfkill list wifi | grep "Soft blocked: yes" || echo "")
    HARD_BLOCKED=$(sudo rfkill list wifi | grep "Hard blocked: yes" || echo "")
    if [ -n "$SOFT_BLOCKED" ]; then
        echo "   ❌ PROBLEM: Wi-Fi is soft blocked"
    fi
    if [ -n "$HARD_BLOCKED" ]; then
        echo "   ❌ PROBLEM: Wi-Fi is hard blocked (hardware switch)"
    fi
    if [ -z "$SOFT_BLOCKED" ] && [ -z "$HARD_BLOCKED" ]; then
        echo "   ✅ Wi-Fi is not blocked"
    fi
else
    echo "   ⚠️  rfkill command not found"
fi
echo ""

echo "6️⃣ Check interface mode (must be 'managed' not 'AP'):"
IFACE_MODE=$(iw dev wlan0 info 2>/dev/null | grep "type" | awk '{print $2}' || echo "unknown")
echo "   wlan0 mode: $IFACE_MODE"
if [ "$IFACE_MODE" = "AP" ] || [ "$IFACE_MODE" = "__ap" ]; then
    echo "   ❌ PROBLEM: Interface is in AP mode (NetworkManager can't scan)"
else
    echo "   ✅ Interface is in correct mode"
fi
echo ""

echo "7️⃣ Check if wpa_supplicant is interfering:"
if systemctl is-active --quiet wpa_supplicant 2>/dev/null || pgrep -x wpa_supplicant >/dev/null 2>&1; then
    echo "   ⚠️  wpa_supplicant is running"
    WPA_INTERFACE=$(sudo wpa_cli -i wlan0 status 2>/dev/null | grep "interface" | cut -d'=' -f2 || echo "")
    if [ -n "$WPA_INTERFACE" ] && [ "$WPA_INTERFACE" = "wlan0" ]; then
        echo "   ❌ PROBLEM: wpa_supplicant is controlling wlan0 (conflicts with NetworkManager)"
    else
        echo "   ⚠️  wpa_supplicant running but may not be directly controlling wlan0"
    fi
else
    echo "   ✅ wpa_supplicant is not running (no conflict)"
fi
echo ""

echo "8️⃣ Test if NetworkManager can scan for networks:"
echo "   Attempting to scan..."
SCAN_RESULT=$(timeout 10 sudo nmcli device wifi list 2>&1)
if echo "$SCAN_RESULT" | grep -qi "error\|unavailable\|failed\|permission"; then
    echo "   ❌ PROBLEM: NetworkManager scan failed"
    echo "   Error: $(echo "$SCAN_RESULT" | head -3)"
elif echo "$SCAN_RESULT" | grep -qi "SSID\|BSSID"; then
    NETWORK_COUNT=$(echo "$SCAN_RESULT" | grep -c "SSID:" || echo "0")
    echo "   ✅ NetworkManager CAN scan - found $NETWORK_COUNT networks"
    echo "   First few networks:"
    echo "$SCAN_RESULT" | head -10
else
    echo "   ⚠️  Scan result unclear"
    echo "   Output: $(echo "$SCAN_RESULT" | head -5)"
fi
echo ""

echo "9️⃣ Check interface state:"
echo "   wlan0 link state:"
ip link show wlan0 | grep -E "state|UP|DOWN"
echo ""
echo "   wlan0 IP address:"
ip addr show wlan0 | grep "inet " || echo "   (no IP address)"
echo ""

echo "🔟 Check NetworkManager logs for errors:"
echo "   Recent NetworkManager errors:"
sudo journalctl -u NetworkManager --since "5 minutes ago" | grep -i "error\|fail\|wlan0\|unmanaged" | tail -10 || echo "   (no recent errors)"
echo ""

echo "=== SUMMARY ==="
echo ""
echo "For nmtui to show wireless networks, ALL must be true:"
echo "  1. NetworkManager running: $(systemctl is-active NetworkManager 2>/dev/null && echo '✅' || echo '❌')"
echo "  2. Wi-Fi radio enabled: $(nmcli radio wifi 2>/dev/null | grep -q 'enabled' && echo '✅' || echo '❌')"
echo "  3. wlan0 is managed: $([ "$WLAN0_STATUS" != "unmanaged" ] && [ "$WLAN0_STATUS" != "unavailable" ] && echo '✅' || echo '❌')"
echo "  4. Interface in managed mode: $([ "$IFACE_MODE" = "managed" ] && echo '✅' || echo '❌')"
echo "  5. Not blocked by rfkill: $([ -z "$SOFT_BLOCKED" ] && [ -z "$HARD_BLOCKED" ] && echo '✅' || echo '❌')"
echo "  6. wpa_supplicant not interfering: $(! pgrep -x wpa_supplicant >/dev/null 2>&1 && echo '✅' || echo '❌')"
echo ""

echo "=== QUICK FIX COMMANDS ==="
echo ""
echo "If wlan0 is 'unmanaged', run these:"
echo "  sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
echo "  sudo nmcli device set wlan0 managed yes"
echo "  sudo systemctl stop NetworkManager"
echo "  sudo systemctl start NetworkManager"
echo ""
echo "If Wi-Fi radio is disabled:"
echo "  sudo nmcli radio wifi on"
echo ""
echo "If wpa_supplicant is interfering:"
echo "  sudo systemctl stop wpa_supplicant"
echo "  sudo pkill -x wpa_supplicant"
echo ""
echo "If interface is in AP mode:"
echo "  sudo iw dev wlan0 set type managed"
echo ""
echo "If soft blocked:"
echo "  sudo rfkill unblock wifi"
echo ""
