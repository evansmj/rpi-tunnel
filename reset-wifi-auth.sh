#!/usr/bin/env bash
# Reset WiFi authentication blockers caused by tunnel.sh

echo "=== Resetting WiFi Authentication Blockers ==="
echo ""

# 1. Make resolv.conf writable (remove immutable flag)
echo "1️⃣ Making /etc/resolv.conf writable..."
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
echo "   ✅ Removed immutable flag"

# 2. Restore resolv.conf to let NetworkManager manage it
echo ""
echo "2️⃣ Resetting DNS to let NetworkManager manage it..."
sudo rm -f /etc/resolv.conf
echo "   ✅ Removed hardcoded DNS"

# 3. Restart systemd-resolved if it exists (helps with DNS)
echo ""
echo "3️⃣ Restarting systemd-resolved (if available)..."
sudo systemctl restart systemd-resolved 2>/dev/null || true
echo "   ✅ systemd-resolved restarted"

# 4. Restart NetworkManager to pick up DNS changes
echo ""
echo "4️⃣ Restarting NetworkManager..."
sudo systemctl restart NetworkManager 2>/dev/null || true
sleep 3
echo "   ✅ NetworkManager restarted"

# 5. Ensure wlan0 is managed and WiFi is on
echo ""
echo "5️⃣ Ensuring wlan0 is ready..."
sudo nmcli device set wlan0 managed yes 2>/dev/null || true
sudo nmcli radio wifi on 2>/dev/null || true
sleep 2
echo "   ✅ wlan0 configured"

# 6. Check current status
echo ""
echo "6️⃣ Current status:"
echo "   NetworkManager: $(systemctl is-active NetworkManager 2>/dev/null || echo 'unknown')"
echo "   wlan0 status: $(nmcli device status 2>/dev/null | grep '^wlan0' | awk '{print $3}' || echo 'unknown')"
echo "   DNS servers: $(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -3 || echo 'none configured')"

echo ""
echo "✅ WiFi authentication blockers reset!"
echo ""
echo "💡 Now try connecting to your hotel WiFi:"
echo "   sudo nmtui"
echo "   (Select 'Activate a connection' → choose your hotel WiFi)"
echo ""
echo "   Or via command line:"
echo "   sudo nmcli device wifi connect 'YourHotelSSID' password 'YourPassword' ifname wlan0"
