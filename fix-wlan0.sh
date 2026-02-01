#!/bin/bash
# Quick fix script to ensure wlan0 is managed by NetworkManager

set -e

echo "🔧 Fixing wlan0 to be managed by NetworkManager..."

# Step 1: Check current status
echo ""
echo "Current status:"
nmcli device status | grep wlan0 || echo "wlan0 not found"

# Step 2: Fix config file
echo ""
echo "Step 1: Fixing NetworkManager config file..."
sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true

# Remove duplicate [keyfile] sections
sudo awk '
    BEGIN { in_keyfile=0; keyfile_added=0 }
    /^\[keyfile\]/ { 
        if (!keyfile_added) {
            print ""
            print "[keyfile]"
            print "unmanaged-devices=interface-name:wlan1"
            keyfile_added=1
        }
        in_keyfile=1
        next
    }
    /^\[/ { 
        if (in_keyfile) { in_keyfile=0 }
        print
        next
    }
    in_keyfile { next }
    { print }
    END {
        if (!keyfile_added) {
            print ""
            print "[keyfile]"
            print "unmanaged-devices=interface-name:wlan1"
        }
    }
' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null

if [ -f /tmp/nm_conf_fixed ]; then
    sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
    echo "✅ Config file cleaned up"
else
    # Fallback method
    if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    if ! grep -q "unmanaged-devices=interface-name:wlan1" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "unmanaged-devices=interface-name:wlan1" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    echo "✅ Config file updated (fallback method)"
fi

# Verify wlan0 is NOT in unmanaged-devices
if grep -q "unmanaged-devices.*wlan0" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "⚠️  Found wlan0 in unmanaged-devices! Removing..."
    sudo sed -i 's/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:wlan1/g' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i 's/unmanaged-devices=interface-name:wlan0.*/unmanaged-devices=interface-name:wlan1/g' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
fi

# Step 3: Restart NetworkManager
echo ""
echo "Step 2: Restarting NetworkManager..."
sudo systemctl restart NetworkManager
sleep 8

# Step 4: Set wlan0 to managed multiple times
echo ""
echo "Step 3: Setting wlan0 to managed (multiple attempts)..."
for i in 1 2 3 4 5; do
    echo "   Attempt $i..."
    sudo nmcli device set wlan0 managed yes 2>/dev/null || true
    sleep 2
    sudo nmcli radio wifi on 2>/dev/null || true
    sleep 1
done

# Step 5: Final check
echo ""
echo "Step 4: Final verification..."
sleep 3
FINAL_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
if [ -n "$FINAL_STATUS" ] && ! echo "$FINAL_STATUS" | grep -qE "(unmanaged|unavailable)"; then
    echo "✅ SUCCESS! wlan0 is now managed: $(echo "$FINAL_STATUS" | awk '{print $3}')"
    echo "✅ nmtui should now work!"
else
    echo "❌ FAILED. wlan0 status: $(echo "$FINAL_STATUS" | awk '{print $3}' || echo 'not found')"
    echo ""
    echo "📋 Config file contents:"
    sudo cat /etc/NetworkManager/NetworkManager.conf
    echo ""
    echo "📋 NetworkManager logs (last 20 lines):"
    sudo journalctl -u NetworkManager -n 20 --no-pager | grep -i wlan0 || echo "No wlan0 entries in recent logs"
fi
