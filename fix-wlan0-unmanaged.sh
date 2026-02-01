#!/bin/bash
# Emergency fix script to force wlan0 to be managed by NetworkManager
# Run this if wlan0 keeps showing as unmanaged in nmtui

set -e

echo "🔧 Emergency fix for wlan0 unmanaged issue"
echo ""

# Step 1: Ensure config file is correct
echo "1️⃣ Fixing NetworkManager config file..."
ONBOARD_WIFI="${ONBOARD_WIFI:-wlan0}"
USB_WIFI="${USB_WIFI:-wlan1}"

# Remove all unmanaged-devices lines
sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true

# Remove duplicate [keyfile] sections
sudo sed -i '/^\[keyfile\]$/,/^\[/ { /^\[keyfile\]$/d; /^\[/!d; }' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
sudo sed -i '/^\[keyfile\]$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true

# Add clean [keyfile] section with ONLY USB Wi-Fi
if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
fi

# Add unmanaged-devices with ONLY USB Wi-Fi (not wlan0)
if ! grep -q "unmanaged-devices=interface-name:$USB_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "unmanaged-devices=interface-name:$USB_WIFI" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
fi

# Verify wlan0 is NOT in unmanaged-devices
if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "   ⚠️  Found wlan0 in unmanaged-devices! Removing..."
    sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
fi

echo "   ✅ Config file fixed"
echo "   📋 Current config: $(grep 'unmanaged-devices' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo 'none')"
echo ""

# Step 2: Remove any interfering connection profiles
echo "2️⃣ Cleaning up connection profiles..."
sudo nmcli connection delete wlan0 2>/dev/null || true
echo "   ✅ Cleaned up"
echo ""

# Step 3: Reload NetworkManager config
echo "3️⃣ Reloading NetworkManager configuration..."
sudo nmcli general reload 2>/dev/null || true
sleep 2
echo "   ✅ Reloaded"
echo ""

# Step 4: Force wlan0 to be managed (multiple times)
echo "4️⃣ Forcing wlan0 to be managed..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    sudo nmcli device set wlan0 managed yes 2>/dev/null || true
    sudo nmcli radio wifi on 2>/dev/null || true
    sleep 0.3
done
echo "   ✅ Set to managed (10 attempts)"
echo ""

# Step 5: If still unmanaged, restart NetworkManager
sleep 2
NM_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" | awk '{print $3}' || echo "unknown")
echo "5️⃣ Checking status..."
if [ "$NM_STATUS" = "unmanaged" ] || [ "$NM_STATUS" = "unavailable" ]; then
    echo "   ⚠️  Still unmanaged ($NM_STATUS) - restarting NetworkManager..."
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 5
    
    # Set to managed again after restart
    for i in 1 2 3 4 5; do
        sudo nmcli device set wlan0 managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 1
    done
    
    sleep 2
    NM_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" | awk '{print $3}' || echo "unknown")
fi

# Final check
echo ""
echo "📋 Final status:"
nmcli device status | grep wlan0 || echo "wlan0 not found"

if [ "$NM_STATUS" != "unmanaged" ] && [ "$NM_STATUS" != "unavailable" ]; then
    echo ""
    echo "✅ SUCCESS! wlan0 is now: $NM_STATUS"
    echo "✅ nmtui should now show wireless networks!"
else
    echo ""
    echo "❌ FAILED. wlan0 status: $NM_STATUS"
    echo ""
    echo "📋 Manual steps to try:"
    echo "   1. Check config: grep unmanaged-devices /etc/NetworkManager/NetworkManager.conf"
    echo "   2. Verify it only has USB Wi-Fi, NOT wlan0"
    echo "   3. Run: sudo systemctl restart NetworkManager"
    echo "   4. Run: sudo nmcli device set wlan0 managed yes"
    echo "   5. Check: nmcli device status | grep wlan0"
fi
