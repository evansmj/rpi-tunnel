#!/usr/bin/env bash
# Fix script to make nmtui show wireless networks

echo "=== Fixing nmtui to show wireless networks ==="
echo ""

# Problem 1: unmanaged-devices in config file
echo "1️⃣ Removing unmanaged-devices from NetworkManager.conf..."
if grep -q "unmanaged-devices" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "   Found unmanaged-devices line - removing..."
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf
    echo "   ✅ Removed"
else
    echo "   ✅ No unmanaged-devices found"
fi

# Problem 2: Multiple [keyfile] sections (clean them up)
echo ""
echo "2️⃣ Cleaning up duplicate [keyfile] sections..."
# Remove duplicate [keyfile] lines, keep only the first one
sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
if [ -f /tmp/nm_conf_fixed ]; then
    sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
    echo "   ✅ Cleaned up duplicate sections"
else
    echo "   ⚠️  Could not clean up (may not be necessary)"
fi

# Problem 3: Stop wpa_supplicant
echo ""
echo "3️⃣ Stopping wpa_supplicant to avoid conflicts..."
sudo systemctl stop wpa_supplicant 2>/dev/null
sudo pkill -x wpa_supplicant 2>/dev/null
sleep 1
if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
    echo "   ✅ wpa_supplicant stopped"
else
    echo "   ⚠️  wpa_supplicant may still be running"
fi

# Problem 4: Set wlan0 to managed
echo ""
echo "4️⃣ Setting wlan0 to managed..."
sudo nmcli device set wlan0 managed yes 2>/dev/null
echo "   ✅ Set to managed"

# Problem 5: Restart NetworkManager
echo ""
echo "5️⃣ Restarting NetworkManager..."
sudo systemctl stop NetworkManager 2>/dev/null
sleep 2
sudo systemctl start NetworkManager 2>/dev/null
sleep 5
echo "   ✅ NetworkManager restarted"

# Verify it worked
echo ""
echo "6️⃣ Verifying fix..."
sleep 2
WLAN0_STATUS=$(nmcli device status 2>/dev/null | grep wlan0 | awk '{print $3}' || echo "unknown")
echo "   wlan0 status: $WLAN0_STATUS"

if [ "$WLAN0_STATUS" != "unmanaged" ] && [ "$WLAN0_STATUS" != "unavailable" ]; then
    echo ""
    echo "   ✅ SUCCESS! wlan0 is now $WLAN0_STATUS"
    echo "   ✅ nmtui should now show wireless networks!"
    echo ""
    echo "   To use nmtui:"
    echo "     1. Run: sudo nmtui"
    echo "     2. Select 'Activate a connection'"
    echo "     3. You should see wireless networks listed"
else
    echo ""
    echo "   ❌ Still showing as $WLAN0_STATUS"
    echo ""
    echo "   Try these manual commands:"
    echo "     sudo nano /etc/NetworkManager/NetworkManager.conf"
    echo "     (Remove any line with 'unmanaged-devices')"
    echo "     sudo nmcli device set wlan0 managed yes"
    echo "     sudo systemctl restart NetworkManager"
fi

echo ""
echo "=== Fix Complete ==="
