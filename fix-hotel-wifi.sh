#!/usr/bin/env bash
# Quick diagnostic and fix script for hotel WiFi connection issues

echo "=== Hotel WiFi Connection Diagnostic & Fix ==="
echo ""

# Check if wlan0 exists
if ! ip link show wlan0 >/dev/null 2>&1; then
    echo "❌ ERROR: wlan0 interface not found!"
    echo "   Make sure your onboard WiFi is working."
    exit 1
fi

echo "1️⃣ Checking NetworkManager status..."
NM_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
if [ -z "$NM_STATUS" ]; then
    echo "   ⚠️  wlan0 not found in NetworkManager"
else
    echo "   wlan0 status: $(echo "$NM_STATUS" | awk '{print $3}')"
    STATE=$(echo "$NM_STATUS" | awk '{print $3}')
    
    if [ "$STATE" = "unmanaged" ]; then
        echo "   ❌ wlan0 is UNMANAGED - fixing..."
        sudo nmcli device set wlan0 managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 2
        echo "   ✅ Set wlan0 to managed"
    fi
fi

echo ""
echo "2️⃣ Checking WiFi radio state..."
RADIO_STATE=$(nmcli radio wifi 2>/dev/null | grep "enabled" || echo "disabled")
if echo "$RADIO_STATE" | grep -q "disabled"; then
    echo "   ⚠️  WiFi radio is disabled - enabling..."
    sudo nmcli radio wifi on 2>/dev/null || true
    sleep 2
    echo "   ✅ WiFi radio enabled"
else
    echo "   ✅ WiFi radio is enabled"
fi

echo ""
echo "3️⃣ Checking current connection..."
CURRENT_IP=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
if [ -n "$CURRENT_IP" ]; then
    echo "   ✅ Connected! IP address: $CURRENT_IP"
    echo "   Testing internet connectivity..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "   ✅ Internet is working!"
    else
        echo "   ⚠️  Have IP but no internet - may need captive portal login"
    fi
else
    echo "   ⚠️  Not connected (no IP address)"
    echo ""
    echo "4️⃣ Attempting to connect to saved networks..."
    
    # Rescan for networks
    echo "   Scanning for networks..."
    sudo nmcli device wifi rescan ifname wlan0 2>/dev/null || true
    sleep 3
    
    # Get saved connections
    SAVED=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi$" | cut -d: -f1 || echo "")
    if [ -n "$SAVED" ]; then
        echo "   Found saved networks: $SAVED"
        for conn in $SAVED; do
            echo "   Attempting to connect to: $conn"
            if sudo nmcli connection up "$conn" 2>/dev/null; then
                echo "   ✅ Connected to $conn"
                sleep 3
                NEW_IP=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
                if [ -n "$NEW_IP" ]; then
                    echo "   ✅ Got IP: $NEW_IP"
                fi
                break
            fi
        done
    else
        echo "   ⚠️  No saved WiFi connections found"
        echo ""
        echo "5️⃣ Available WiFi networks:"
        nmcli device wifi list ifname wlan0 2>/dev/null | head -10
        echo ""
        echo "   💡 To connect manually:"
        echo "      sudo nmtui"
        echo "      (Select 'Activate a connection' → choose your hotel WiFi)"
    fi
fi

echo ""
echo "6️⃣ Final status check..."
FINAL_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
if [ -n "$FINAL_STATUS" ]; then
    echo "   wlan0: $(echo "$FINAL_STATUS" | awk '{print $2, $3, $4}')"
fi

FINAL_IP=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
if [ -n "$FINAL_IP" ]; then
    echo "   IP: $FINAL_IP"
    echo ""
    echo "✅ SUCCESS! Hotel WiFi should be working now."
    echo ""
    echo "   Test with: ping -c 3 8.8.8.8"
else
    echo ""
    echo "⚠️  Still not connected. Try these steps:"
    echo ""
    echo "   1. Run: sudo nmtui"
    echo "   2. Select 'Activate a connection'"
    echo "   3. Choose your hotel WiFi network"
    echo "   4. Enter password if needed"
    echo "   5. Complete any captive portal login in a browser"
    echo ""
    echo "   Or connect via command line:"
    echo "   sudo nmcli device wifi connect 'YourHotelSSID' password 'YourPassword' ifname wlan0"
fi
