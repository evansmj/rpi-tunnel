#!/usr/bin/env bash
# Debug script for Pi tunnel connectivity issues

echo "=== Pi Tunnel Debug Script ==="
echo ""

# 1. Check DNS configuration
echo "1️⃣ DNS Configuration Check:"
echo "   Current /etc/resolv.conf:"
cat /etc/resolv.conf
echo ""
if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
    echo "   ⚠️  /etc/resolv.conf is IMMUTABLE (this causes DNS fight!)"
else
    echo "   ✅ /etc/resolv.conf is not immutable"
fi
echo ""

# 2. Check systemd-resolved status
echo "2️⃣ systemd-resolved Status:"
if systemctl is-active --quiet systemd-resolved; then
    echo "   ⚠️  systemd-resolved is RUNNING (may conflict with Tailscale)"
    systemctl status systemd-resolved --no-pager | head -5
else
    echo "   ✅ systemd-resolved is not running"
fi
echo ""

# 3. Check Tailscale status
echo "3️⃣ Tailscale Status:"
if command -v tailscale >/dev/null 2>&1; then
    echo "   Tailscale status:"
    sudo tailscale status
    echo ""
    echo "   Tailscale DNS:"
    sudo tailscale status --json | grep -i dns || echo "   No DNS info"
else
    echo "   ❌ Tailscale not installed"
fi
echo ""

# 4. Check network interfaces
echo "4️⃣ Network Interfaces:"
ip addr show | grep -E "^[0-9]+:|inet " | head -20
echo ""

# 5. Check WiFi access point
echo "5️⃣ WiFi Access Point Status:"
if systemctl is-active --quiet hostapd; then
    echo "   ✅ hostapd is running"
    echo "   Interface status:"
    for iface in wlan0 wlan1; do
        if iw dev $iface info 2>/dev/null | grep -q "type AP"; then
            echo "   ✅ $iface is in AP mode"
            ip addr show $iface | grep "inet " || echo "   ⚠️  $iface has no IP address"
        fi
    done
else
    echo "   ❌ hostapd is not running"
    systemctl status hostapd --no-pager | head -5
fi
echo ""

# 6. Check routing
echo "6️⃣ Routing Table:"
ip route show | head -10
echo ""

# 7. Test connectivity
echo "7️⃣ Connectivity Tests:"
echo "   Testing DNS resolution..."
if nslookup google.com >/dev/null 2>&1; then
    echo "   ✅ DNS resolution working"
else
    echo "   ❌ DNS resolution failing"
    echo "   Testing with 8.8.8.8..."
    if nslookup google.com 8.8.8.8 >/dev/null 2>&1; then
        echo "   ⚠️  DNS works with 8.8.8.8 but not with system DNS"
    else
        echo "   ❌ DNS completely broken"
    fi
fi

echo "   Testing internet connectivity..."
if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "   ✅ Can reach internet (8.8.8.8)"
else
    echo "   ❌ Cannot reach internet"
fi

if ping -c 2 google.com >/dev/null 2>&1; then
    echo "   ✅ Can resolve and reach google.com"
else
    echo "   ❌ Cannot reach google.com"
fi
echo ""

# 8. Check dnsmasq
echo "8️⃣ dnsmasq Status:"
if systemctl is-active --quiet dnsmasq; then
    echo "   ✅ dnsmasq is running"
else
    echo "   ❌ dnsmasq is not running"
    systemctl status dnsmasq --no-pager | head -5
fi
echo ""

# 9. Check firewall
echo "9️⃣ Firewall Status:"
if systemctl is-active --quiet nftables; then
    echo "   ✅ nftables is running"
    echo "   Current rules:"
    sudo nft list ruleset | head -20
else
    echo "   ⚠️  nftables is not running"
fi
echo ""

echo "=== Debug Complete ==="
echo ""
echo "🔧 Quick Fixes to Try:"
echo "1. Fix DNS fight: sudo chattr -i /etc/resolv.conf && sudo systemctl stop systemd-resolved"
echo "2. Restart Tailscale: sudo systemctl restart tailscaled"
echo "3. Restart access point: sudo systemctl restart hostapd dnsmasq"
echo "4. Check logs: sudo journalctl -u tailscaled -n 50"
echo "5. Check hostapd logs: sudo journalctl -u hostapd -n 50"

