#!/usr/bin/env bash
# Debug script for Pi tunnel connectivity issues with auto-fix capability

# Check if auto-fix is enabled (default: yes, use --no-fix to disable)
AUTO_FIX=true
if [[ "$1" == "--no-fix" ]] || [[ "$1" == "-n" ]]; then
    AUTO_FIX=false
    echo "⚠️  Auto-fix disabled (manual mode)"
fi

# Track fixes applied
FIXES_APPLIED=()

echo "=== Pi Tunnel Debug Script ==="
if [ "$AUTO_FIX" = true ]; then
    echo "🔧 Auto-fix mode: ENABLED (use --no-fix to disable)"
else
    echo "🔧 Auto-fix mode: DISABLED"
fi
echo ""

# Check if tunnel.sh has been run (tunnel is configured)
TUNNEL_CONFIGURED=false
if [ -f /etc/hostapd/hostapd.conf ] && [ -f /etc/systemd/system/tunnel-watchdog.service ]; then
    TUNNEL_CONFIGURED=true
    echo "✅ TUNNEL CONFIGURATION DETECTED"
    echo "   tunnel.sh has been run - tunnel is configured."
    echo "   NetworkManager should be managing hotel Wi-Fi (wlan0) for nmtui."
    echo "   Only USB Wi-Fi (wlan1) should be unmanaged (AP mode)."
    echo ""
fi

echo "📖 Quick Explanation:"
echo "   - wpa_supplicant: Low-level Wi-Fi daemon (handles WPA/WPA2 authentication)"
echo "   - NetworkManager: High-level network manager (uses wpa_supplicant internally)"
echo "   - Conflict: Both controlling same interface = neither works properly"
echo "   - Solution: Let NetworkManager manage Wi-Fi (it uses wpa_supplicant as backend)"
echo ""

# 0. Check NetworkManager Wi-Fi visibility (for nmtui)
echo "0️⃣ NetworkManager Wi-Fi Visibility Check (nmtui):"
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    # Find hotel Wi-Fi interface (should be wlan0 - onboard Wi-Fi)
    # wlan0 = onboard Wi-Fi (connects to hotel Wi-Fi)
    # wlan1 = USB Wi-Fi (should be in AP mode, NOT managed by NetworkManager)
    HOTEL_WIFI_CHECK=""
    
    # First, check which interface is which by looking at their mode
    WLAN0_MODE=$(iw dev wlan0 info 2>/dev/null | grep "type" | awk '{print $2}' || echo "unknown")
    WLAN1_MODE=$(iw dev wlan1 info 2>/dev/null | grep "type" | awk '{print $2}' || echo "unknown")
    
    echo "   🔍 wlan0 (onboard) mode: $WLAN0_MODE"
    echo "   🔍 wlan1 (USB wifi) mode: $WLAN1_MODE"
    
    # wlan0 should be in managed mode (for connecting to hotel Wi-Fi)
    # wlan1 should be in AP mode (for access point)
    if [ "$WLAN0_MODE" = "managed" ] || [ "$WLAN0_MODE" = "unknown" ]; then
        HOTEL_WIFI_CHECK="wlan0"
        echo "   ✅ Using wlan0 (onboard) as hotel Wi-Fi interface"
    elif [ "$WLAN1_MODE" = "managed" ] && [ "$WLAN0_MODE" != "managed" ]; then
        # wlan1 is managed but wlan0 is not - this is wrong, fix it
        echo "   ⚠️  WARNING: wlan1 (USB wifi) is in managed mode, but wlan0 (onboard) is not!"
        echo "   💡 This is why nmtui shows 'USB wifi' instead of normal wireless networks"
        echo "   💡 wlan0 should be managed (for hotel Wi-Fi), wlan1 should be in AP mode"
        HOTEL_WIFI_CHECK="wlan0"  # Force wlan0 as the correct interface
        echo "   🔧 Will fix wlan0 to be managed and ensure wlan1 is NOT managed"
    else
        HOTEL_WIFI_CHECK="wlan0"  # Default to wlan0 (onboard)
        echo "   ✅ Defaulting to wlan0 (onboard) as hotel Wi-Fi interface"
    fi
    
    # Check if NetworkManager is managing the Wi-Fi interface
    # Get the full status line to handle cases where status might be split
    NM_STATUS_LINE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI_CHECK" || echo "")
    if [ -z "$NM_STATUS_LINE" ]; then
        # Device not found in nmcli output - try without the ^ anchor
        NM_STATUS_LINE=$(nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | head -1 || echo "")
    fi
    NM_MANAGED=$(echo "$NM_STATUS_LINE" | awk '{print $3}' || echo "unknown")
    echo "   🔍 Current NetworkManager state for $HOTEL_WIFI_CHECK: $NM_MANAGED"
    echo "   🔍 Full status line: $NM_STATUS_LINE"
    
    # Check if device is unmanaged or unavailable (handle both single and combined states)
    if [ "$NM_MANAGED" = "unmanaged" ] || [ "$NM_MANAGED" = "unavailable" ] || echo "$NM_STATUS_LINE" | grep -qE "(unmanaged|unavailable)"; then
        echo "   ❌ NetworkManager is NOT managing $HOTEL_WIFI_CHECK ($NM_MANAGED)"
        echo "   💡 This is why nmtui shows no networks!"
        echo "   💡 NetworkManager was disabled to prevent interference with tunnel setup"
        
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 FIXING: Applying comprehensive nmtui fix..."
            
            # Show what's currently in the config
            if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
                echo "   🔍 BEFORE - Current config file contents:"
                grep -A 2 -B 2 "unmanaged-devices\|keyfile" /etc/NetworkManager/NetworkManager.conf 2>/dev/null | head -10 || echo "      (no unmanaged-devices found)"
            fi
            
            # Fix 1: Remove ALL unmanaged-devices lines
            echo "   🔧 Fix 1: Removing ALL unmanaged-devices entries..."
            sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
            
            # CRITICAL: Ensure wlan1 (USB wifi) is NOT managed by NetworkManager
            # It should be in AP mode, not managed mode
            echo "   🔧 Fix 1b: Ensuring wlan1 (USB wifi) is NOT managed by NetworkManager..."
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            # Make sure wlan1 is in AP mode, not managed mode
            if iw dev wlan1 info 2>/dev/null | grep -q "type AP\|type __ap"; then
                echo "   ✅ wlan1 is correctly in AP mode"
            else
                echo "   ⚠️  wlan1 is not in AP mode - this is expected if it's not configured yet"
            fi
            
            # Fix 2: Clean up duplicate [keyfile] sections (critical fix from fix-nmtui.sh)
            echo "   🔧 Fix 2: Cleaning up duplicate [keyfile] sections..."
            sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
            if [ -f /tmp/nm_conf_fixed ]; then
                sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
                echo "   ✅ Cleaned up duplicate sections"
            fi

            # Fix 2b: Add wlan1 ONLY to unmanaged-devices (CRITICAL for AP mode)
            echo "   🔧 Fix 2b: Adding wlan1 to unmanaged-devices (for AP mode)..."
            if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            fi
            if ! grep -q "unmanaged-devices=interface-name:wlan1" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "unmanaged-devices=interface-name:wlan1" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                echo "   ✅ Added wlan1 to unmanaged-devices"
            else
                echo "   ✅ wlan1 already in unmanaged-devices"
            fi
            
            # Fix 3: Stop wpa_supplicant to avoid conflicts (critical fix from fix-nmtui.sh)
            echo "   🔧 Fix 3: Stopping wpa_supplicant to avoid conflicts..."
            # More aggressive stopping - kill all wpa_supplicant processes
            sudo systemctl stop wpa_supplicant 2>/dev/null || true
            sudo systemctl disable wpa_supplicant 2>/dev/null || true
            sudo pkill -9 -x wpa_supplicant 2>/dev/null || true
            sudo killall -9 wpa_supplicant 2>/dev/null || true
            sleep 2
            # Verify it's actually stopped
            WPA_PIDS=$(pgrep -x wpa_supplicant || echo "")
            if [ -z "$WPA_PIDS" ] && ! systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
                echo "   ✅ wpa_supplicant stopped"
            else
                echo "   ⚠️  wpa_supplicant may still be running (PIDs: $WPA_PIDS)"
                echo "   🔧 Trying one more aggressive kill..."
                sudo killall -9 wpa_supplicant 2>/dev/null || true
                sleep 1
            fi
            
            # Fix 4: Ensure interface is up and in managed mode
            echo "   🔧 Fix 4: Ensuring $HOTEL_WIFI_CHECK (onboard) is up and in managed mode..."
            sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null || true
            sudo iw dev $HOTEL_WIFI_CHECK set type managed 2>/dev/null || true
            sleep 1
            
            # CRITICAL: Make sure wlan1 (USB wifi) is NOT managed and is in AP mode
            echo "   🔧 Fix 4b: Ensuring wlan1 (USB wifi) is NOT managed (should be AP mode)..."
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            # Don't change wlan1's mode if it's already in AP mode (hostapd needs it)
            if ! iw dev wlan1 info 2>/dev/null | grep -q "type AP\|type __ap"; then
                echo "   ⚠️  Note: wlan1 is not in AP mode - this is OK if hostapd will configure it"
            fi
            
            # Fix 5: Force set to managed via nmcli (multiple times to be sure)
            echo "   🔧 Fix 5: Setting $HOTEL_WIFI_CHECK to managed..."
            sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
            sleep 1
            sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
            
            # Fix 6: Full stop/start NetworkManager (not restart - more reliable)
            echo "   🔧 Fix 6: Restarting NetworkManager properly..."
            # Stop NetworkManager completely and wait for it to fully stop
            sudo systemctl stop NetworkManager 2>/dev/null || true
            sleep 3
            # Kill any remaining NetworkManager processes
            sudo pkill -9 NetworkManager 2>/dev/null || true
            sleep 2
            # Start fresh
            sudo systemctl start NetworkManager 2>/dev/null || true
            sleep 8  # Give it more time to fully initialize and recognize interfaces
            
            # Show what's left
            echo "   🔍 AFTER - Config file now:"
            grep -A 2 -B 2 "keyfile\|unmanaged" /etc/NetworkManager/NetworkManager.conf 2>/dev/null | head -10 || echo "      (clean - no unmanaged-devices)"
            
            # Verify it actually worked
            echo "   🔍 Verifying fix worked..."
            sleep 2  # Give NetworkManager time to update
            NM_STATUS_AFTER=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI_CHECK" || nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | head -1 || echo "")
            NM_MANAGED_AFTER=$(echo "$NM_STATUS_AFTER" | awk '{print $3}' || echo "unknown")
            echo "   🔍 NetworkManager status for $HOTEL_WIFI_CHECK: $NM_MANAGED_AFTER"
            echo "   🔍 Full status line: $NM_STATUS_AFTER"
            
            # Check if it's now managed (not unmanaged or unavailable)
            if [ "$NM_MANAGED_AFTER" != "unmanaged" ] && [ "$NM_MANAGED_AFTER" != "unavailable" ] && ! echo "$NM_STATUS_AFTER" | grep -qE "(unmanaged|unavailable)"; then
                FIXES_APPLIED+=("Fixed NetworkManager - wlan0 is now $NM_MANAGED_AFTER") && echo "   ✅ SUCCESS! Status is now: $NM_MANAGED_AFTER"
                echo "   ✅ nmtui SHOULD NOW show wireless networks!"
                echo ""
                echo "   💡 To use nmtui:"
                echo "      1. Run: sudo nmtui"
                echo "      2. Select 'Activate a connection'"
                echo "      3. You should see wireless networks listed"
            else
                echo "   ❌ Fix did NOT work - still showing as: $NM_MANAGED_AFTER"
                echo ""
                echo "   🔧 Trying one more time with different approach..."
                # More aggressive: Remove entire [keyfile] section if it only has unmanaged-devices
                sudo sed -i '/^\[keyfile\]$/,/^\[/ { /unmanaged-devices/d; }' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
                # Ensure interface is up
                sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null || true
                sudo iw dev $HOTEL_WIFI_CHECK set type managed 2>/dev/null || true
                # Set to managed multiple times
                sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
                sleep 1
                sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
                # Full restart
                sudo systemctl stop NetworkManager 2>/dev/null || true
                sleep 3
                sudo pkill -9 NetworkManager 2>/dev/null || true
                sleep 2
                sudo systemctl start NetworkManager 2>/dev/null || true
                sleep 8
                # Check final status
                NM_STATUS_FINAL=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI_CHECK" || nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | head -1 || echo "")
                NM_FINAL=$(echo "$NM_STATUS_FINAL" | awk '{print $3}' || echo "unknown")
                if [ "$NM_FINAL" != "unmanaged" ] && [ "$NM_FINAL" != "unavailable" ] && ! echo "$NM_STATUS_FINAL" | grep -qE "(unmanaged|unavailable)"; then
                    FIXES_APPLIED+=("Fixed NetworkManager on second attempt") && echo "   ✅ Second attempt worked! Status: $NM_FINAL"
                else
                    echo "   ❌ Still not working. Manual intervention needed."
                    echo "   💡 Run these commands manually:"
                    echo "      sudo nano /etc/NetworkManager/NetworkManager.conf"
                    echo "      (Remove any line with 'unmanaged-devices')"
                    echo "      sudo nmcli device set wlan0 managed yes"
                    echo "      sudo systemctl restart NetworkManager"
                fi
            fi
        else
            echo "   💡 To fix manually:"
            echo "      1. Edit /etc/NetworkManager/NetworkManager.conf"
            echo "      2. Remove $HOTEL_WIFI_CHECK from unmanaged-devices line"
            echo "      3. Run: sudo nmcli device set $HOTEL_WIFI_CHECK managed yes"
            echo "      4. Run: sudo systemctl restart NetworkManager"
        fi
    elif [ "$NM_MANAGED" = "connected" ] || [ "$NM_MANAGED" = "disconnected" ]; then
        echo "   ✅ NetworkManager is managing $HOTEL_WIFI_CHECK ($NM_MANAGED)"
        echo "   ✅ nmtui should show wireless networks for this interface"
    else
        echo "   ✅ NetworkManager status: $NM_MANAGED"
    fi
    
    # Check if Wi-Fi radio is on (critical for nmtui to show networks)
    echo "   🔍 Checking Wi-Fi radio status..."
    WIFI_RADIO=$(nmcli radio wifi 2>/dev/null || echo "unknown")
    if [ "$WIFI_RADIO" = "disabled" ]; then
        echo "   ❌ Wi-Fi radio is DISABLED in NetworkManager"
        echo "   💡 This is why nmtui shows no wireless networks!"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Enabling Wi-Fi radio..."
            sudo nmcli radio wifi on 2>/dev/null && FIXES_APPLIED+=("Enabled Wi-Fi radio in NetworkManager") && echo "   ✅ Fixed! nmtui should now show wireless networks"
        else
            echo "   💡 To fix: sudo nmcli radio wifi on"
        fi
    else
        echo "   ✅ Wi-Fi radio is enabled in NetworkManager"
    fi
    
    # Check rfkill (software/hardware blocks)
    echo "   🔍 Checking rfkill (software/hardware Wi-Fi blocks)..."
    if command -v rfkill >/dev/null 2>&1; then
        RFKILL_WIFI=$(sudo rfkill list wifi 2>/dev/null | grep -A 2 "wifi" | head -3 || echo "")
        if echo "$RFKILL_WIFI" | grep -q "Soft blocked: yes"; then
            echo "   ❌ Wi-Fi is SOFT BLOCKED (software block)"
            echo "   💡 This prevents nmtui from showing wireless networks!"
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Unblocking Wi-Fi..."
                sudo rfkill unblock wifi 2>/dev/null && FIXES_APPLIED+=("Unblocked Wi-Fi via rfkill") && echo "   ✅ Fixed!"
            else
                echo "   💡 To fix: sudo rfkill unblock wifi"
            fi
        elif echo "$RFKILL_WIFI" | grep -q "Hard blocked: yes"; then
            echo "   ❌ Wi-Fi is HARD BLOCKED (hardware switch/button)"
            echo "   💡 Check for a physical Wi-Fi switch or button on your device"
            echo "   💡 Cannot be fixed via software"
        else
            echo "   ✅ Wi-Fi is not blocked by rfkill"
        fi
    else
        echo "   ⚠️  rfkill command not found (cannot check for blocks)"
    fi
    
    # Check if NetworkManager can see Wi-Fi devices
    echo "   🔍 Checking if NetworkManager sees Wi-Fi devices..."
    NM_WIFI_DEVICES=$(nmcli device status 2>/dev/null | grep -i "wifi\|802-11" | wc -l || echo "0")
    if [ "$NM_WIFI_DEVICES" -eq "0" ]; then
        echo "   ⚠️  NetworkManager sees 0 Wi-Fi devices"
        echo "   💡 This could be why nmtui shows no wireless networks"
        echo "   💡 Check: sudo nmcli device status"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Restarting NetworkManager to refresh device list..."
            sudo systemctl stop NetworkManager 2>/dev/null || true
            sleep 2
            sudo systemctl start NetworkManager 2>/dev/null || true
            sleep 5
            FIXES_APPLIED+=("Restarted NetworkManager to refresh Wi-Fi devices")
        fi
    else
        echo "   ✅ NetworkManager sees $NM_WIFI_DEVICES Wi-Fi device(s)"
        # Show what NetworkManager sees
        nmcli device status 2>/dev/null | grep -i "wifi\|802-11" | head -3 || true
        # Check if our target interface is in the list
        if ! nmcli device status 2>/dev/null | grep -q "^$HOTEL_WIFI_CHECK"; then
            echo "   ⚠️  WARNING: $HOTEL_WIFI_CHECK is not in NetworkManager's device list!"
            echo "   💡 This is why nmtui doesn't show it - NetworkManager doesn't see the interface"
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Bringing interface up and restarting NetworkManager..."
                sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null || true
                sudo iw dev $HOTEL_WIFI_CHECK set type managed 2>/dev/null || true
                sudo systemctl restart NetworkManager 2>/dev/null || true
                sleep 5
                FIXES_APPLIED+=("Attempted to make $HOTEL_WIFI_CHECK visible to NetworkManager")
            fi
        fi
    fi
    
    # Check for wpa_supplicant conflict (if wpa_supplicant is controlling the interface, NetworkManager can't)
    echo "   🔍 Checking for wpa_supplicant conflicts..."
    if systemctl is-active --quiet wpa_supplicant 2>/dev/null || pgrep -x wpa_supplicant >/dev/null 2>&1; then
        echo "   ⚠️  wpa_supplicant is running"
        # Check if it's controlling our interface
        WPA_INTERFACE=$(sudo wpa_cli -i $HOTEL_WIFI_CHECK status 2>/dev/null | grep "interface" | cut -d'=' -f2 || echo "")
        WPA_PIDS=$(pgrep -x wpa_supplicant || echo "")
        if [ -n "$WPA_INTERFACE" ] && [ "$WPA_INTERFACE" = "$HOTEL_WIFI_CHECK" ]; then
            echo "   ❌ wpa_supplicant is actively controlling $HOTEL_WIFI_CHECK"
            echo "   💡 This PREVENTS NetworkManager from managing Wi-Fi and showing networks in nmtui!"
        elif [ -n "$WPA_PIDS" ]; then
            echo "   ⚠️  wpa_supplicant process is running (PID: $WPA_PIDS)"
            echo "   💡 Even if not directly controlling $HOTEL_WIFI_CHECK, it may interfere"
        fi
        
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Stopping wpa_supplicant completely to let NetworkManager take over..."
            # More aggressive stopping
            sudo systemctl stop wpa_supplicant 2>/dev/null || true
            sudo systemctl disable wpa_supplicant 2>/dev/null || true
            sudo pkill -9 -x wpa_supplicant 2>/dev/null || true
            sudo killall -9 wpa_supplicant 2>/dev/null || true
            sleep 2
            # Verify it's stopped
            WPA_PIDS_AFTER=$(pgrep -x wpa_supplicant || echo "")
            if [ -z "$WPA_PIDS_AFTER" ] && ! systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
                FIXES_APPLIED+=("Stopped wpa_supplicant to allow NetworkManager control") && echo "   ✅ Fixed! wpa_supplicant stopped"
            else
                echo "   ⚠️  wpa_supplicant may still be running (PIDs: $WPA_PIDS_AFTER) - trying one more kill..."
                sudo killall -9 wpa_supplicant 2>/dev/null || true
                sleep 1
            fi
        else
            echo "   💡 To fix: sudo systemctl stop wpa_supplicant && sudo pkill -9 -x wpa_supplicant"
        fi
    else
        echo "   ✅ wpa_supplicant is not running (no conflict)"
    fi
    
    # Check interface mode (must be "managed" not "AP" for NetworkManager to scan)
    echo "   🔍 Checking interface mode..."
    IFACE_MODE=$(iw dev $HOTEL_WIFI_CHECK info 2>/dev/null | grep "type" | awk '{print $2}' || echo "unknown")
    if [ "$IFACE_MODE" = "AP" ] || [ "$IFACE_MODE" = "__ap" ]; then
        echo "   ❌ Interface $HOTEL_WIFI_CHECK is in AP mode (not managed mode)"
        echo "   💡 NetworkManager cannot scan for networks when interface is in AP mode!"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Setting interface to managed mode..."
            sudo ip link set $HOTEL_WIFI_CHECK down 2>/dev/null
            sudo iw dev $HOTEL_WIFI_CHECK set type managed 2>/dev/null
            sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null
            sleep 2
            FIXES_APPLIED+=("Set $HOTEL_WIFI_CHECK to managed mode") && echo "   ✅ Fixed! Interface is now in managed mode"
        else
            echo "   💡 To fix: sudo iw dev $HOTEL_WIFI_CHECK set type managed"
        fi
    elif [ "$IFACE_MODE" = "managed" ]; then
        echo "   ✅ Interface is in managed mode (correct for NetworkManager)"
    else
        echo "   ⚠️  Interface mode: $IFACE_MODE"
    fi
    
    # Final verification: Can NetworkManager actually scan?
    echo "   🔍 Final verification: Testing if NetworkManager can scan for networks..."
    sleep 2  # Give NetworkManager time to recognize the interface
    
    # Check current state one more time
    NM_FINAL_STATE=$(nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | awk '{print $2, $3}' || echo "unknown unknown")
    echo "   🔍 Final NetworkManager state: $NM_FINAL_STATE"
    
    # Try to scan
    NM_SCAN_TEST=$(timeout 15 sudo nmcli device wifi list 2>&1)
    if echo "$NM_SCAN_TEST" | grep -qi "error\|unavailable\|failed\|permission denied"; then
        echo "   ❌ NetworkManager scan FAILED with errors:"
        echo "   💡 $(echo "$NM_SCAN_TEST" | head -3)"
        echo ""
        echo "   🔧 Troubleshooting steps:"
        echo "   1. Check if interface is actually managed: sudo nmcli device status"
        echo "   2. Check NetworkManager logs: sudo journalctl -u NetworkManager -n 20"
        echo "   3. Try manual scan: sudo nmcli device wifi rescan"
        echo "   4. Check if wpa_supplicant is interfering: sudo systemctl status wpa_supplicant"
    elif echo "$NM_SCAN_TEST" | grep -qi "SSID\|BSSID"; then
        NETWORK_COUNT=$(echo "$NM_SCAN_TEST" | grep -c "SSID:" || echo "0")
        NETWORK_COUNT=$(echo "$NETWORK_COUNT" | tr -d '\n\r ' | head -1)
        if [ -n "$NETWORK_COUNT" ] && [ "$NETWORK_COUNT" -gt "0" ]; then
            echo "   ✅ NetworkManager CAN scan - found $NETWORK_COUNT networks!"
            echo "   ✅ nmtui SHOULD show wireless networks now!"
            echo ""
            echo "   💡 If nmtui still doesn't show networks, try:"
            echo "      1. Close and reopen nmtui"
            echo "      2. In nmtui, go to 'Activate a connection' (not 'Edit a connection')"
            echo "      3. You should see wireless networks listed there"
        else
            echo "   ⚠️  NetworkManager can scan but found 0 networks"
            echo "   💡 This might be normal if no networks are in range"
        fi
    else
        echo "   ⚠️  Could not verify NetworkManager scanning capability"
        echo "   💡 Raw output: $(echo "$NM_SCAN_TEST" | head -3)"
    fi
    
    # Additional nmtui-specific check
    echo ""
    echo "   🔍 nmtui-specific diagnostics:"
    echo "   💡 For nmtui to show wireless networks, ALL of these must be true:"
    echo "      1. NetworkManager is running: $(systemctl is-active NetworkManager 2>/dev/null && echo '✅' || echo '❌')"
    echo "      2. Wi-Fi radio is on: $(nmcli radio wifi 2>/dev/null | grep -q 'enabled' && echo '✅' || echo '❌')"
    echo "      3. Interface is managed: $(nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | grep -qE 'connected|disconnected' && echo '✅' || echo '❌')"
    echo "      4. Interface is in managed mode: $(iw dev $HOTEL_WIFI_CHECK info 2>/dev/null | grep -q 'type managed' && echo '✅' || echo '❌')"
    echo "      5. wpa_supplicant not interfering: $(! pgrep -x wpa_supplicant >/dev/null 2>&1 && echo '✅' || echo '❌')"
    
    # If still not working, try one more aggressive fix (comprehensive fix from fix-nmtui.sh)
    if [ "$AUTO_FIX" = true ]; then
        # Get current status more reliably
        NM_STATUS_CURRENT=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI_CHECK" || nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | head -1 || echo "")
        NM_CURRENT=$(echo "$NM_STATUS_CURRENT" | awk '{print $3}' || echo "")
        # Check if still unmanaged or unavailable
        if [ "$NM_CURRENT" = "unmanaged" ] || [ "$NM_CURRENT" = "unavailable" ] || echo "$NM_STATUS_CURRENT" | grep -qE "(unmanaged|unavailable)"; then
            echo ""
            echo "   🔧 Attempting comprehensive aggressive fix for nmtui (all fixes from fix-nmtui.sh)..."
            echo "   This is a full reset of NetworkManager configuration for $HOTEL_WIFI_CHECK (wlan0 - onboard)"
            echo "   CRITICAL: wlan1 (USB wifi) should NOT be managed - it's for the access point!"
            
            # Fix 1: Completely remove ALL unmanaged-devices from config
            echo "   Step 1: Removing all unmanaged-devices entries..."
            sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
            
            # CRITICAL: Ensure wlan1 (USB wifi) is NOT managed
            echo "   Step 1b: Ensuring wlan1 (USB wifi) is NOT managed by NetworkManager..."
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            
            # Fix 2: Clean up duplicate [keyfile] sections
            echo "   Step 2: Cleaning up duplicate [keyfile] sections..."
            sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
            if [ -f /tmp/nm_conf_fixed ]; then
                sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
            fi

            # Fix 2b: Add wlan1 ONLY to unmanaged-devices (CRITICAL for AP mode)
            echo "   Step 2b: Adding wlan1 to unmanaged-devices (for AP mode)..."
            if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            fi
            if ! grep -q "unmanaged-devices=interface-name:wlan1" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "unmanaged-devices=interface-name:wlan1" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                echo "   ✅ Added wlan1 to unmanaged-devices"
            fi

            # Fix 3: Aggressively stop wpa_supplicant
            echo "   Step 3: Aggressively stopping wpa_supplicant..."
            sudo systemctl stop wpa_supplicant 2>/dev/null || true
            sudo systemctl disable wpa_supplicant 2>/dev/null || true
            sudo pkill -9 -x wpa_supplicant 2>/dev/null || true
            sudo killall -9 wpa_supplicant 2>/dev/null || true
            sleep 2
            
            # Fix 4: Ensure interface is up and in managed mode
            echo "   Step 4: Ensuring $HOTEL_WIFI_CHECK (onboard) is up and in managed mode..."
            sudo ip link set $HOTEL_WIFI_CHECK down 2>/dev/null || true
            sleep 1
            sudo iw dev $HOTEL_WIFI_CHECK set type managed 2>/dev/null || true
            sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null || true
            sleep 2
            
            # CRITICAL: Make sure wlan1 (USB wifi) is NOT managed
            echo "   Step 4b: Ensuring wlan1 (USB wifi) is NOT managed (should be AP mode)..."
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            
            # Fix 5: Force set to managed multiple times
            echo "   Step 5: Setting interface to managed..."
            sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
            sleep 1
            sudo nmcli device set $HOTEL_WIFI_CHECK managed yes 2>/dev/null || true
            
            # Fix 6: Full NetworkManager restart with kill
            echo "   Step 6: Fully restarting NetworkManager..."
            sudo systemctl stop NetworkManager 2>/dev/null || true
            sleep 3
            sudo pkill -9 NetworkManager 2>/dev/null || true
            sleep 2
            sudo systemctl start NetworkManager 2>/dev/null || true
            sleep 10  # Give it plenty of time to initialize
            
            # Verify
            echo "   Step 7: Verifying fix..."
            sleep 2
            NM_STATUS_AGGRESSIVE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI_CHECK" || nmcli device status 2>/dev/null | grep "$HOTEL_WIFI_CHECK" | head -1 || echo "")
            NM_AFTER_AGGRESSIVE=$(echo "$NM_STATUS_AGGRESSIVE" | awk '{print $3}' || echo "unknown")
            echo "   🔍 Final status: $NM_AFTER_AGGRESSIVE"
            echo "   🔍 Full status line: $NM_STATUS_AGGRESSIVE"
            
            if [ "$NM_AFTER_AGGRESSIVE" != "unmanaged" ] && [ "$NM_AFTER_AGGRESSIVE" != "unavailable" ] && ! echo "$NM_STATUS_AGGRESSIVE" | grep -qE "(unmanaged|unavailable)"; then
                FIXES_APPLIED+=("Aggressively fixed NetworkManager for nmtui") && echo "   ✅ Aggressive fix applied! Status: $NM_AFTER_AGGRESSIVE"
                echo "   ✅ nmtui should now show wireless networks!"
            else
                echo "   ⚠️  Aggressive fix did not resolve the issue - status still: $NM_AFTER_AGGRESSIVE"
                echo "   🔧 Trying emergency recovery - complete reset..."
                
                # Emergency recovery: Complete reset
                echo "   Step 8: Emergency recovery - complete NetworkManager reset for wlan0..."
                # Remove all unmanaged-devices
                sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
                # Clean up config
                sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
                if [ -f /tmp/nm_conf_fixed ]; then
                    sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
                fi
                # CRITICAL: Add wlan1 ONLY to unmanaged-devices (for AP mode)
                # This ensures wlan0 stays managed while wlan1 is free for hostapd
                if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                    echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                    echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                fi
                if ! grep -q "unmanaged-devices=interface-name:wlan1" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                    echo "unmanaged-devices=interface-name:wlan1" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                fi
                echo "   ✅ Added wlan1 to unmanaged-devices (for AP mode)"
                # Ensure wlan0 is up and managed
                sudo ip link set wlan0 up 2>/dev/null || true
                sudo iw dev wlan0 set type managed 2>/dev/null || true
                # Ensure wlan1 is NOT managed
                sudo nmcli device set wlan1 managed no 2>/dev/null || true
                # Set wlan0 to managed
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                # Enable Wi-Fi radio
                sudo nmcli radio wifi on 2>/dev/null || true
                # Full restart
                sudo systemctl stop NetworkManager 2>/dev/null || true
                sleep 3
                sudo pkill -9 NetworkManager 2>/dev/null || true
                sleep 2
                sudo systemctl start NetworkManager 2>/dev/null || true
                sleep 8
                
                # Final check
                NM_EMERGENCY=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
                if [ -n "$NM_EMERGENCY" ] && ! echo "$NM_EMERGENCY" | grep -qE "(unmanaged|unavailable)"; then
                    FIXES_APPLIED+=("Emergency recovery successful") && echo "   ✅ Emergency recovery worked! wlan0 is now visible"
                else
                    echo "   ❌ Emergency recovery failed"
                    echo "   💡 Manual steps needed:"
                    echo "      1. sudo nano /etc/NetworkManager/NetworkManager.conf"
                    echo "      2. Remove ALL 'unmanaged-devices' lines"
                    echo "      3. sudo nmcli device set wlan0 managed yes"
                    echo "      4. sudo nmcli radio wifi on"
                    echo "      5. sudo systemctl restart NetworkManager"
                fi
            fi
        fi
    fi
    
    # Check if interface is up
    if ip link show $HOTEL_WIFI_CHECK 2>/dev/null | grep -q "state UP"; then
        echo "   ✅ Interface $HOTEL_WIFI_CHECK is UP"
    else
        echo "   ⚠️  Interface $HOTEL_WIFI_CHECK is DOWN"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Bringing interface up..."
            sudo ip link set $HOTEL_WIFI_CHECK up 2>/dev/null && FIXES_APPLIED+=("Brought $HOTEL_WIFI_CHECK interface up") && echo "   ✅ Fixed!"
        fi
    fi
    
    # CRITICAL FINAL CHECK: Ensure NetworkManager can actually see wlan0 and it's managed
    echo ""
    echo "   🔍 FINAL VERIFICATION: Checking if NetworkManager sees wlan0..."
    NM_WLAN0_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
    if [ -z "$NM_WLAN0_STATUS" ]; then
        echo "   ❌ CRITICAL: NetworkManager does NOT see wlan0 at all!"
        echo "   💡 This is why nmtui shows no wireless networks"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 EMERGENCY FIX: Making wlan0 visible to NetworkManager..."
            # Bring interface up
            sudo ip link set wlan0 up 2>/dev/null || true
            # Set to managed mode
            sudo iw dev wlan0 set type managed 2>/dev/null || true
            # Ensure it's managed by NetworkManager
            sudo nmcli device set wlan0 managed yes 2>/dev/null || true
            # Ensure wlan1 is NOT managed
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            # Restart NetworkManager to refresh
            sudo systemctl restart NetworkManager 2>/dev/null || true
            sleep 5
            # Check again
            NM_WLAN0_AFTER=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
            if [ -n "$NM_WLAN0_AFTER" ]; then
                FIXES_APPLIED+=("Made wlan0 visible to NetworkManager") && echo "   ✅ SUCCESS! NetworkManager now sees wlan0"
            else
                echo "   ⚠️  Still not visible - may need manual intervention"
            fi
        fi
    else
        echo "   ✅ NetworkManager sees wlan0: $NM_WLAN0_STATUS"
        # Check if it's managed
        if echo "$NM_WLAN0_STATUS" | grep -qE "(unmanaged|unavailable)"; then
            echo "   ⚠️  But wlan0 is $(echo "$NM_WLAN0_STATUS" | awk '{print $3}') - fixing..."
            if [ "$AUTO_FIX" = true ]; then
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo systemctl restart NetworkManager 2>/dev/null || true
                sleep 3
                FIXES_APPLIED+=("Set wlan0 to managed mode")
            fi
        fi
    fi
    
    # Check Wi-Fi radio one more time (critical for nmtui)
    echo ""
    echo "   🔍 FINAL CHECK: Wi-Fi radio status..."
    WIFI_RADIO_FINAL=$(nmcli radio wifi 2>/dev/null || echo "unknown")
    if [ "$WIFI_RADIO_FINAL" != "enabled" ]; then
        echo "   ❌ Wi-Fi radio is NOT enabled: $WIFI_RADIO_FINAL"
        echo "   💡 This will prevent nmtui from showing wireless networks!"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Enabling Wi-Fi radio..."
            sudo nmcli radio wifi on 2>/dev/null && FIXES_APPLIED+=("Enabled Wi-Fi radio") && echo "   ✅ Fixed!"
        fi
    else
        echo "   ✅ Wi-Fi radio is enabled"
    fi
    
    # Show what NetworkManager currently sees
    echo ""
    echo "   🔍 NetworkManager device list (what nmtui will show):"
    nmcli device status 2>/dev/null | head -10 || echo "   (no devices found)"
    
else
    echo "   ⚠️  NetworkManager is not running"
    echo "   💡 nmtui requires NetworkManager to be running"
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fixing: Starting NetworkManager..."
        sudo systemctl start NetworkManager 2>/dev/null && sleep 2 && FIXES_APPLIED+=("Started NetworkManager") && echo "   ✅ Fixed!"
    fi
fi
echo ""

# 1. Check DNS configuration
echo "1️⃣ DNS Configuration Check:"
echo "   Current /etc/resolv.conf:"
cat /etc/resolv.conf
echo ""
if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
    echo "   ⚠️  /etc/resolv.conf is IMMUTABLE (this causes DNS fight!)"
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fixing: Removing immutable flag..."
        sudo chattr -i /etc/resolv.conf 2>/dev/null && FIXES_APPLIED+=("Removed immutable flag from /etc/resolv.conf") && echo "   ✅ Fixed!"
    fi
else
    echo "   ✅ /etc/resolv.conf is not immutable"
fi
echo ""

# 2. Check systemd-resolved status
echo "2️⃣ systemd-resolved Status:"
if systemctl is-active --quiet systemd-resolved; then
    echo "   ⚠️  systemd-resolved is RUNNING (may conflict with Tailscale)"
    systemctl status systemd-resolved --no-pager | head -5
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fixing: Stopping systemd-resolved..."
        sudo systemctl stop systemd-resolved 2>/dev/null && sudo systemctl disable systemd-resolved 2>/dev/null && FIXES_APPLIED+=("Stopped and disabled systemd-resolved") && echo "   ✅ Fixed!"
    fi
else
    echo "   ✅ systemd-resolved is not running"
fi
echo ""

# 3. Check Tailscale status
echo "3️⃣ Tailscale Status:"
if command -v tailscale >/dev/null 2>&1; then
    echo "   Tailscale status:"
    TAILSCALE_STATUS_OUTPUT=$(sudo tailscale status 2>/dev/null || echo "")
    echo "$TAILSCALE_STATUS_OUTPUT"
    echo ""
    
    # Check if Tailscale is authenticated (better detection)
    # If tailscale status shows devices/IPs, it's authenticated
    # If it says "logged out" or is empty, it's not authenticated
    TAILSCALE_IS_AUTHENTICATED=false
    if [ -z "$TAILSCALE_STATUS_OUTPUT" ]; then
        echo "   ❌ Tailscale status is empty (may not be running)"
    elif echo "$TAILSCALE_STATUS_OUTPUT" | grep -qi "logged out\|not logged in\|not logged"; then
        echo "   ❌ Tailscale is LOGGED OUT (not authenticated)"
        echo "   💡 This breaks Tailscale DNS (100.100.100.100) and DNS leak protection"
        echo "   💡 To fix: sudo tailscale up (requires internet connection)"
    elif echo "$TAILSCALE_STATUS_OUTPUT" | grep -qE "^100\.[0-9]+\.[0-9]+\.[0-9]+"; then
        # If status shows IP addresses (100.x.x.x), it's authenticated
        echo "   ✅ Tailscale is authenticated (shows devices/IPs)"
        TAILSCALE_IS_AUTHENTICATED=true
    elif ip link show tailscale0 >/dev/null 2>&1; then
        # If tailscale0 exists, it's likely authenticated
        echo "   ✅ Tailscale appears to be authenticated (tailscale0 interface exists)"
        TAILSCALE_IS_AUTHENTICATED=true
    else
        echo "   ⚠️  Cannot determine Tailscale authentication status"
    fi
    
    # Check if tailscale0 interface exists
    if ip link show tailscale0 >/dev/null 2>&1; then
        TAILSCALE_IP=$(ip addr show tailscale0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
        if [ -n "$TAILSCALE_IP" ]; then
            echo "   ✅ tailscale0 interface active with IP: $TAILSCALE_IP"
        else
            echo "   ⚠️  tailscale0 interface exists but has no IP"
        fi
    else
        echo "   ❌ tailscale0 interface does not exist (Tailscale not connected)"
    fi
    
    echo ""
    echo "   Tailscale DNS Configuration:"
    TAILSCALE_DNS_JSON=$(sudo tailscale status --json 2>/dev/null | grep -i dns || echo "")
    if [ -n "$TAILSCALE_DNS_JSON" ]; then
        echo "   $TAILSCALE_DNS_JSON"
    else
        echo "   ⚠️  No DNS info in Tailscale status"
    fi
    
    # Check if /etc/resolv.conf is using Tailscale DNS
    if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
        echo "   ✅ /etc/resolv.conf is configured to use Tailscale DNS (100.100.100.100)"
        
        # Check if Tailscale DNS is actually reachable
        if ping -c 1 -W 2 100.100.100.100 >/dev/null 2>&1; then
            echo "   ✅ Tailscale DNS server (100.100.100.100) is reachable"
        else
            echo "   ❌ Tailscale DNS server (100.100.100.100) is NOT reachable!"
            echo "   💡 This is why DNS is failing"
            
            # Check if route to Tailscale DNS goes through tailscale0
            ROUTE_TO_TS_DNS=$(ip route get 100.100.100.100 2>/dev/null | grep -o "dev [^ ]*" || echo "")
            if echo "$ROUTE_TO_TS_DNS" | grep -q "tailscale0"; then
                echo "   ✅ Route to Tailscale DNS goes through tailscale0 (correct)"
            else
                echo "   ⚠️  Route to Tailscale DNS: $ROUTE_TO_TS_DNS"
                echo "   💡 Route may not go through tailscale0 - this could be the issue"
            fi
        fi
        
        # Check if --accept-dns was used
        echo "   🔍 Checking if Tailscale DNS is enabled (--accept-dns flag)..."
        TAILSCALE_UP_CMD=$(systemctl cat tailscale-exit.service 2>/dev/null | grep "ExecStart" || echo "")
        if echo "$TAILSCALE_UP_CMD" | grep -q "accept-dns"; then
            echo "   ✅ Tailscale service uses --accept-dns flag"
        else
            echo "   ⚠️  Tailscale service may not have --accept-dns flag"
            echo "   💡 To enable: sudo tailscale up --accept-dns"
        fi
    else
        echo "   ⚠️  /etc/resolv.conf is NOT using Tailscale DNS"
        echo "   💡 DNS leak protection may not be active"
    fi
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
AP_INTERFACE=""
if systemctl is-active --quiet hostapd; then
    echo "   ✅ hostapd is running"
    echo "   Interface status:"
    for iface in wlan0 wlan1; do
        if iw dev $iface info 2>/dev/null | grep -q "type AP"; then
            AP_INTERFACE="$iface"
            echo "   ✅ $iface is in AP mode"
            AP_IP=$(ip addr show $iface | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
            if [ -n "$AP_IP" ]; then
                echo "   ✅ $iface has IP address: $AP_IP"
            else
                echo "   ⚠️  $iface has no IP address"
            fi
        fi
    done
else
    echo "   ❌ hostapd is not running"
    systemctl status hostapd --no-pager | head -5
fi
echo ""

# 5b. Check Access Point Internet Connectivity (for connected devices)
echo "5️⃣b️⃣ Access Point Internet Connectivity (Devices Connected to AP):"
if [ -n "$AP_INTERFACE" ] && systemctl is-active --quiet hostapd; then
    # Load config to get AP network details
    if [ -f "tunnel.conf" ]; then
        source tunnel.conf 2>/dev/null
    fi
    
    # Detect AP network from interface IP if config not available
    if [ -z "$AP_GATEWAY" ] && [ -n "$AP_IP" ]; then
        AP_GATEWAY="$AP_IP"
        AP_IP_RANGE=$(echo "$AP_IP" | cut -d'.' -f1-3)
    fi
    
    # Default values if still not set
    AP_GATEWAY=${AP_GATEWAY:-"10.0.50.1"}
    AP_IP_RANGE=${AP_IP_RANGE:-"10.0.50"}
    
    echo "   🔍 AP Interface: $AP_INTERFACE"
    echo "   🔍 AP Gateway: $AP_GATEWAY"
    echo "   🔍 AP Network: ${AP_IP_RANGE}.0/24"
    
    # Check if dnsmasq is running (provides DHCP/DNS for AP clients)
    if systemctl is-active --quiet dnsmasq; then
        echo "   ✅ dnsmasq is running (provides DHCP/DNS for AP clients)"
    else
        echo "   ❌ dnsmasq is NOT running (AP clients won't get IP addresses or DNS!)"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Starting dnsmasq..."
            sudo systemctl start dnsmasq 2>/dev/null && sleep 2 && FIXES_APPLIED+=("Started dnsmasq for AP") && echo "   ✅ Fixed!"
        fi
    fi
    
    # Check for connected clients (via dnsmasq leases or iw dev)
    CONNECTED_CLIENTS=0
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        CONNECTED_CLIENTS=$(wc -l < /var/lib/misc/dnsmasq.leases 2>/dev/null || echo "0")
        if [ "$CONNECTED_CLIENTS" -gt "0" ]; then
            echo "   ✅ Found $CONNECTED_CLIENTS device(s) connected to AP (from DHCP leases)"
        fi
    fi
    
    # Check IP forwarding (CRITICAL for AP internet access)
    IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [ "$IP_FORWARD" = "1" ]; then
        echo "   ✅ IP forwarding is enabled"
    else
        echo "   ❌ IP forwarding is DISABLED (AP clients cannot access internet!)"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Enabling IP forwarding..."
            echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl -w net.ipv4.ip_forward=1 2>/dev/null && FIXES_APPLIED+=("Enabled IP forwarding") && echo "   ✅ Fixed!"
        else
            echo "   💡 To fix: sudo sysctl -w net.ipv4.ip_forward=1"
        fi
    fi
    
    # Check Tailscale connection (CRITICAL - all AP traffic goes through Tailscale)
    echo "   🔍 Checking Tailscale connection (required for AP internet)..."
    if command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_STATUS=$(sudo tailscale status 2>/dev/null || echo "")
        if echo "$TAILSCALE_STATUS" | grep -qi "logged out\|not logged in"; then
            echo "   ❌ Tailscale is NOT authenticated (AP clients have no internet!)"
            if [ "$AUTO_FIX" = true ]; then
                if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    echo "   🔧 Internet available - but Tailscale needs manual authentication"
                    echo "   💡 Run: sudo tailscale up"
                else
                    echo "   ⚠️  Cannot authenticate Tailscale without internet"
                fi
            fi
        elif echo "$TAILSCALE_STATUS" | grep -q "active.*exit node"; then
            echo "   ✅ Tailscale exit node is active"
        else
            echo "   ⚠️  Tailscale is authenticated but exit node may not be active"
            if [ "$AUTO_FIX" = true ] && [ -f "tunnel.conf" ]; then
                source tunnel.conf 2>/dev/null
                if [ -n "$TAILSCALE_EXIT_NODE_IP" ]; then
                    echo "   🔧 Auto-fixing: Reconnecting to Tailscale exit node..."
                    timeout 10 sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns 2>/dev/null && FIXES_APPLIED+=("Reconnected Tailscale exit node") && echo "   ✅ Attempted fix"
                fi
            fi
        fi
        
        # Check if tailscale0 interface exists and has IP
        if ip link show tailscale0 >/dev/null 2>&1; then
            TAILSCALE_IP=$(ip addr show tailscale0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
            if [ -n "$TAILSCALE_IP" ]; then
                echo "   ✅ tailscale0 interface has IP: $TAILSCALE_IP"
            else
                echo "   ❌ tailscale0 interface exists but has no IP"
            fi
        else
            echo "   ❌ tailscale0 interface does not exist (Tailscale not connected!)"
        fi
    else
        echo "   ❌ Tailscale not installed"
    fi
    
    # Check NAT rules (CRITICAL - masquerades AP traffic through Tailscale)
    echo "   🔍 Checking NAT rules (masquerades AP traffic through Tailscale)..."
    if command -v nft >/dev/null 2>&1; then
        NAT_RULE=$(sudo nft list table ip nat 2>/dev/null | grep -A 2 "chain postrouting" | grep "tailscale0.*masquerade" || echo "")
        if [ -n "$NAT_RULE" ]; then
            echo "   ✅ NAT rule exists: masquerade traffic through tailscale0"
        else
            echo "   ❌ NAT rule MISSING (AP clients cannot access internet!)"
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Adding NAT masquerade rule..."
                # Check if nftables config exists
                if [ -f /etc/nftables.conf ]; then
                    # Add NAT rule if missing
                    if ! sudo nft list table ip nat 2>/dev/null | grep -q "tailscale0.*masquerade"; then
                        sudo nft add rule ip nat postrouting oifname "tailscale0" masquerade 2>/dev/null && FIXES_APPLIED+=("Added NAT masquerade rule") && echo "   ✅ Fixed!"
                    fi
                else
                    echo "   ⚠️  /etc/nftables.conf not found - may need to run tunnel.sh"
                fi
            else
                echo "   💡 To fix: sudo nft add rule ip nat postrouting oifname \"tailscale0\" masquerade"
            fi
        fi
    else
        echo "   ⚠️  nftables not installed (cannot check NAT rules)"
    fi
    
    # Check forwarding rules (allows traffic from AP to Tailscale)
    echo "   🔍 Checking forwarding rules (allows AP -> Tailscale traffic)..."
    if command -v nft >/dev/null 2>&1; then
        FORWARD_RULE=$(sudo nft list chain inet filter forward 2>/dev/null | grep -E "$AP_INTERFACE.*tailscale0|tailscale0.*$AP_INTERFACE" || echo "")
        if [ -n "$FORWARD_RULE" ]; then
            echo "   ✅ Forwarding rule exists: $AP_INTERFACE <-> tailscale0"
        else
            echo "   ⚠️  Forwarding rule may be missing or using default policy"
            # Check if forward chain has accept policy
            FORWARD_POLICY=$(sudo nft list chain inet filter forward 2>/dev/null | grep "policy" | awk '{print $2}' || echo "")
            if [ "$FORWARD_POLICY" = "accept" ]; then
                echo "   ✅ Forward chain policy is 'accept' (should work)"
            else
                echo "   ❌ Forward chain policy is not 'accept' (may block AP traffic!)"
                if [ "$AUTO_FIX" = true ]; then
                    echo "   🔧 Auto-fixing: Setting forward policy to accept..."
                    sudo nft chain inet filter forward { policy accept \; } 2>/dev/null && FIXES_APPLIED+=("Set forward policy to accept") && echo "   ✅ Fixed!"
                fi
            fi
        fi
    fi
    
    # Test internet connectivity from Pi itself (prerequisite for AP clients)
    echo "   🔍 Testing internet connectivity from Pi (required for AP clients)..."
    if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "   ✅ Pi can reach internet (8.8.8.8)"
        
        # Test DNS resolution
        if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
            echo "   ✅ Pi DNS resolution working"
        else
            echo "   ⚠️  Pi DNS resolution failing (AP clients will also fail DNS)"
        fi
        
        # Test if traffic is going through Tailscale
        if [ -f "tunnel.conf" ]; then
            source tunnel.conf 2>/dev/null
            if [ -n "$TAILSCALE_EXPECTED_IP" ]; then
                ACTUAL_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo "")
                if [ -n "$ACTUAL_IP" ]; then
                    if [ "$ACTUAL_IP" = "$TAILSCALE_EXPECTED_IP" ]; then
                        echo "   ✅ Pi traffic is going through Tailscale exit node ($ACTUAL_IP)"
                    else
                        echo "   ⚠️  Pi traffic is NOT going through exit node (got $ACTUAL_IP, expected $TAILSCALE_EXPECTED_IP)"
                    fi
                fi
            fi
        fi
    else
        echo "   ❌ Pi CANNOT reach internet (AP clients will also fail!)"
        echo "   💡 This is the root cause - fix Pi internet connection first"
    fi
    
    # Test routing from AP network perspective
    echo "   🔍 Testing routing from AP network perspective..."
    # Check if there's a route for AP network traffic
    AP_ROUTE=$(ip route show | grep "${AP_IP_RANGE}.0/24" || echo "")
    if [ -n "$AP_ROUTE" ]; then
        echo "   ✅ Route exists for AP network: $AP_ROUTE"
    else
        echo "   ⚠️  No explicit route for AP network (may use default routing)"
    fi
    
    # Check if default route goes through Tailscale
    DEFAULT_ROUTE=$(ip route show default | head -1 || echo "")
    # Detect hotel WiFi interface (the one NOT in AP mode)
    HOTEL_WIFI_IFACE=""
    for iface in wlan0 wlan1; do
        if [ "$iface" != "$AP_INTERFACE" ] && iw dev $iface info 2>/dev/null | grep -q "type managed"; then
            HOTEL_WIFI_IFACE="$iface"
            break
        fi
    done
    if [ -z "$HOTEL_WIFI_IFACE" ]; then
        HOTEL_WIFI_IFACE="wlan0"  # Default fallback
    fi
    
    if echo "$DEFAULT_ROUTE" | grep -q "tailscale0"; then
        echo "   ✅ Default route goes through tailscale0"
    elif echo "$DEFAULT_ROUTE" | grep -q "$HOTEL_WIFI_IFACE"; then
        echo "   ⚠️  Default route goes through $HOTEL_WIFI_IFACE (not Tailscale)"
        echo "   💡 AP traffic should go through Tailscale, not directly to hotel Wi-Fi"
    else
        echo "   ⚠️  Default route: $DEFAULT_ROUTE"
    fi
    
    # Summary and diagnosis
    echo ""
    echo "   📊 AP Internet Connectivity Diagnosis:"
    ISSUES=0
    
    if [ "$IP_FORWARD" != "1" ]; then
        echo "      ❌ IP forwarding disabled"
        ISSUES=$((ISSUES + 1))
    fi
    
    if ! systemctl is-active --quiet dnsmasq; then
        echo "      ❌ dnsmasq not running"
        ISSUES=$((ISSUES + 1))
    fi
    
    if ! ip link show tailscale0 >/dev/null 2>&1 || [ -z "$TAILSCALE_IP" ]; then
        echo "      ❌ Tailscale not connected"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ -z "$NAT_RULE" ] && command -v nft >/dev/null 2>&1; then
        echo "      ❌ NAT masquerade rule missing"
        ISSUES=$((ISSUES + 1))
    fi
    
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "      ❌ Pi cannot reach internet"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ "$ISSUES" -eq "0" ]; then
        echo "      ✅ All checks passed - AP internet should work!"
        echo "      💡 If devices still can't access internet:"
        echo "         1. Check device DNS settings (should use $AP_GATEWAY)"
        echo "         2. Try disconnecting and reconnecting device to AP"
        echo "         3. Check device firewall/antivirus blocking connections"
    else
        echo "      ❌ Found $ISSUES issue(s) preventing AP internet access"
        if [ "$AUTO_FIX" = true ]; then
            echo "      🔧 Auto-fixes have been applied above - re-run script to verify"
        else
            echo "      💡 Run with auto-fix enabled to apply fixes automatically"
        fi
    fi
else
    echo "   ⚠️  Access Point not running or interface not detected"
    echo "   💡 AP must be running for devices to connect"
fi
echo ""

# 6. Check routing
echo "6️⃣ Routing Table:"
ip route show | head -10
echo ""

# 7. Test connectivity
echo "7️⃣ Connectivity Tests:"
echo "   Testing DNS resolution..."

# Initialize variables
DNS_WORKING=false
INTERNET_WORKING=false
DNS_FAILURE_REASON=""

# First, show what DNS servers are configured
echo "   🔍 Current DNS servers in /etc/resolv.conf:"
DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "")
TAILSCALE_DNS_DETECTED=false
if [ -z "$DNS_SERVERS" ]; then
    echo "   ❌ NO DNS SERVERS CONFIGURED! This is why DNS is failing!"
    DNS_FAILURE_REASON="No DNS servers configured"
    
    # Auto-fix: Add DNS servers if resolv.conf is empty
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fixing: Adding public DNS servers to /etc/resolv.conf..."
        sudo chattr -i /etc/resolv.conf 2>/dev/null || true
        if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
            echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf > /dev/null
            echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
            sleep 1
            DNS_SERVERS="8.8.8.8 1.1.1.1"
            FIXES_APPLIED+=("Added DNS servers to empty resolv.conf") && echo "   ✅ Fixed! Added 8.8.8.8 and 1.1.1.1"
        fi
    fi
else
    echo "   Configured DNS servers:"
    echo "$DNS_SERVERS" | while read dns; do
        echo "      - $dns"
        if [ "$dns" = "100.100.100.100" ]; then
            TAILSCALE_DNS_DETECTED=true
        fi
    done
    
    # Check if using Tailscale DNS
    if echo "$DNS_SERVERS" | grep -q "100.100.100.100"; then
        TAILSCALE_DNS_DETECTED=true
        echo "   🔍 Detected Tailscale DNS (100.100.100.100) - checking if Tailscale is working..."
        
        # Check if Tailscale is authenticated and running
        TAILSCALE_STATUS_CHECK=$(sudo tailscale status 2>/dev/null || echo "")
        # Better detection: if status shows IP addresses or tailscale0 exists, it's authenticated
        if [ -z "$TAILSCALE_STATUS_CHECK" ] || echo "$TAILSCALE_STATUS_CHECK" | grep -qi "logged out\|not logged in\|not logged"; then
            echo "   ❌ CRITICAL: Tailscale DNS is configured but Tailscale is LOGGED OUT!"
            echo "   💡 This is why DNS is failing - Tailscale DNS (100.100.100.100) won't work when Tailscale is logged out"
            echo "   💡 Your DNS leak protection is broken because Tailscale isn't authenticated"
            DNS_FAILURE_REASON="Tailscale DNS configured but Tailscale logged out"
            
            if [ "$AUTO_FIX" = true ]; then
                # Check if we can reach internet (needed to authenticate Tailscale)
                if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    echo "   🔧 Internet is available - fixing DNS first, then attempting Tailscale authentication..."
                    echo "   🔧 Step 1: Temporarily switching to public DNS to restore functionality..."
                    echo "   ⚠️  WARNING: This disables DNS leak protection until Tailscale is authenticated"
                    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
                    sudo rm -f /etc/resolv.conf
                    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
                    echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
                    sleep 2
                    
                    # Test DNS with multiple methods
                    DNS_FIXED=false
                    if command -v dig >/dev/null 2>&1; then
                        if timeout 5 dig google.com +short >/dev/null 2>&1; then
                            DNS_FIXED=true
                        fi
                    elif command -v host >/dev/null 2>&1; then
                        if timeout 5 host google.com >/dev/null 2>&1; then
                            DNS_FIXED=true
                        fi
                    elif nslookup google.com >/dev/null 2>&1; then
                        DNS_FIXED=true
                    fi
                    
                    if [ "$DNS_FIXED" = true ]; then
                        FIXES_APPLIED+=("Temporarily switched to public DNS (Tailscale logged out)") && echo "   ✅ Fixed! DNS now working with public DNS"
                        echo "   🔧 Step 2: Attempting to authenticate Tailscale..."
                        echo "   💡 This may require manual authentication - follow the URL shown"
                        if timeout 30 sudo tailscale up 2>&1 | head -10; then
                            sleep 3
                            # Check if authentication succeeded
                            TAILSCALE_STATUS_AFTER=$(sudo tailscale status 2>/dev/null || echo "")
                            if [ -n "$TAILSCALE_STATUS_AFTER" ] && ! echo "$TAILSCALE_STATUS_AFTER" | grep -qi "logged out\|not logged in"; then
                                FIXES_APPLIED+=("Authenticated Tailscale") && echo "   ✅ Tailscale authenticated!"
                                echo "   💡 Tailscale DNS will be restored automatically"
                            else
                                echo "   ⚠️  Tailscale authentication requires manual step - check output above for URL"
                                echo "   💡 Run manually: sudo tailscale up"
                            fi
                        else
                            echo "   ⚠️  Tailscale authentication may require manual step"
                            echo "   💡 Run manually: sudo tailscale up"
                        fi
                    else
                        echo "   ⚠️  DNS fix attempted but still not working"
                        echo "   💡 Cannot authenticate Tailscale until DNS is fixed"
                    fi
                else
                    echo "   ⚠️  No internet connection - cannot authenticate Tailscale"
                    echo "   💡 Fix hotel Wi-Fi connection first, then authenticate Tailscale"
                    echo "   💡 DNS will remain broken until both are fixed"
                fi
            fi
        elif ! ip link show tailscale0 >/dev/null 2>&1; then
            echo "   ❌ Tailscale DNS is configured but tailscale0 interface doesn't exist"
            echo "   💡 Tailscale may not be running or connected"
            DNS_FAILURE_REASON="Tailscale DNS configured but Tailscale not connected"
        else
            echo "   ✅ Tailscale is authenticated and tailscale0 interface exists"
            
            # Test if Tailscale DNS server is reachable
            echo "   🔍 Testing if Tailscale DNS (100.100.100.100) is reachable..."
            if ping -c 1 -W 2 100.100.100.100 >/dev/null 2>&1; then
                echo "   ✅ Tailscale DNS server (100.100.100.100) is reachable"
            else
                echo "   ❌ Tailscale DNS server (100.100.100.100) is NOT reachable!"
                echo "   💡 This is why DNS is failing - can't reach Tailscale DNS server"
                
                # Check routing to Tailscale DNS
                echo "   🔍 Checking routing to 100.100.100.100..."
                ROUTE_TO_DNS=$(ip route get 100.100.100.100 2>/dev/null || echo "")
                if [ -n "$ROUTE_TO_DNS" ]; then
                    echo "   Route: $ROUTE_TO_DNS"
                    if echo "$ROUTE_TO_DNS" | grep -q "tailscale0"; then
                        echo "   ✅ Route goes through tailscale0 (correct)"
                    else
                        echo "   ⚠️  Route does NOT go through tailscale0 (may be the issue)"
                    fi
                else
                    echo "   ⚠️  No route found to 100.100.100.100"
                fi
                
                # Check if Tailscale DNS is enabled
                echo "   🔍 Checking if Tailscale DNS is enabled..."
                TAILSCALE_DNS_ENABLED=$(sudo tailscale status --json 2>/dev/null | grep -i "dns" || echo "")
                if [ -z "$TAILSCALE_DNS_ENABLED" ]; then
                    echo "   ⚠️  Tailscale DNS may not be enabled"
                    echo "   💡 Try: sudo tailscale up --accept-dns"
                else
                    echo "   Tailscale DNS config: $TAILSCALE_DNS_ENABLED"
                fi
                
                DNS_FAILURE_REASON="Tailscale DNS server (100.100.100.100) not reachable"
            fi
            
            # Test DNS resolution with Tailscale DNS directly
            echo "   🔍 Testing DNS resolution with Tailscale DNS (100.100.100.100)..."
            if timeout 3 dig @100.100.100.100 google.com +short >/dev/null 2>&1; then
                echo "   ✅ Tailscale DNS (100.100.100.100) CAN resolve DNS!"
                echo "   💡 The issue is that system DNS isn't using Tailscale DNS properly"
                DNS_FAILURE_REASON="System DNS not using Tailscale DNS correctly"
            elif timeout 3 host google.com 100.100.100.100 >/dev/null 2>&1; then
                echo "   ✅ Tailscale DNS (100.100.100.100) CAN resolve DNS!"
                DNS_FAILURE_REASON="System DNS not using Tailscale DNS correctly"
            else
                echo "   ❌ Tailscale DNS (100.100.100.100) cannot resolve DNS"
                echo "   💡 Tailscale DNS server may not be working properly"
            fi
        fi
    fi
fi

# Test DNS resolution
if nslookup google.com >/dev/null 2>&1; then
    echo "   ✅ DNS resolution working (can resolve google.com)"
    DNS_WORKING=true
else
    echo "   ❌ DNS resolution FAILING (cannot resolve google.com)"
    echo "   💡 Error: 'Temporary failure in name resolution'"
    
    # Test each DNS server individually (use dig/host directly to bypass system DNS)
    echo "   🔍 Testing each DNS server individually (bypassing system DNS)..."
    DNS_SERVERS_COUNT=0
    DNS_SERVERS_WORKING=0
    for dns in $DNS_SERVERS; do
        DNS_SERVERS_COUNT=$((DNS_SERVERS_COUNT + 1))
        DNS_SERVER_WORKS=false
        
        # Try dig first (most reliable)
        if command -v dig >/dev/null 2>&1; then
            if timeout 5 dig @$dns google.com +short +time=2 >/dev/null 2>&1; then
                DNS_SERVER_WORKS=true
            fi
        fi
        
        # Try host if dig failed
        if [ "$DNS_SERVER_WORKS" = false ] && command -v host >/dev/null 2>&1; then
            if timeout 5 host -W 2 google.com $dns >/dev/null 2>&1; then
                DNS_SERVER_WORKS=true
            fi
        fi
        
        # Try nslookup as last resort
        if [ "$DNS_SERVER_WORKS" = false ]; then
            if timeout 5 nslookup -timeout=2 google.com $dns >/dev/null 2>&1; then
                DNS_SERVER_WORKS=true
            fi
        fi
        
        if [ "$DNS_SERVER_WORKS" = true ]; then
            echo "      ✅ $dns: WORKING"
            DNS_SERVERS_WORKING=$((DNS_SERVERS_WORKING + 1))
        else
            echo "      ❌ $dns: FAILING"
            # Check if DNS server is reachable at all
            if ping -c 1 -W 2 $dns >/dev/null 2>&1; then
                echo "         ⚠️  Server is reachable but DNS queries fail (may be firewall blocking port 53)"
            else
                echo "         ⚠️  Server is NOT reachable"
            fi
        fi
    done
    
    if [ "$DNS_SERVERS_COUNT" -eq "0" ]; then
        echo "   ❌ NO DNS SERVERS TO TEST (resolv.conf is empty or broken)"
        DNS_FAILURE_REASON="No DNS servers in resolv.conf"
    elif [ "$DNS_SERVERS_WORKING" -eq "0" ]; then
        echo "   ❌ ALL DNS SERVERS ARE FAILING"
        DNS_FAILURE_REASON="All DNS servers failing"
    else
        echo "   ⚠️  Some DNS servers work but system DNS is broken"
        DNS_FAILURE_REASON="System DNS misconfigured"
    fi
    
    # Test with public DNS as fallback (use dig or host for more reliable testing)
    echo "   🔍 Testing with public DNS (8.8.8.8) as fallback..."
    # Try multiple methods to test DNS - use dig/host directly to bypass system DNS
    PUBLIC_DNS_WORKS=false
    if command -v dig >/dev/null 2>&1; then
        if timeout 5 dig @8.8.8.8 google.com +short +time=2 >/dev/null 2>&1; then
            PUBLIC_DNS_WORKS=true
            echo "   ✅ dig @8.8.8.8 works - DNS server is reachable"
        fi
    fi
    if [ "$PUBLIC_DNS_WORKS" = false ] && command -v host >/dev/null 2>&1; then
        if timeout 5 host -W 2 google.com 8.8.8.8 >/dev/null 2>&1; then
            PUBLIC_DNS_WORKS=true
            echo "   ✅ host @8.8.8.8 works - DNS server is reachable"
        fi
    fi
    if [ "$PUBLIC_DNS_WORKS" = false ]; then
        # Last resort: try nslookup with explicit server
        if timeout 5 nslookup -timeout=2 google.com 8.8.8.8 >/dev/null 2>&1; then
            PUBLIC_DNS_WORKS=true
            echo "   ✅ nslookup @8.8.8.8 works - DNS server is reachable"
        fi
    fi
    
    # If DNS tools fail, check if firewall is blocking DNS
    if [ "$PUBLIC_DNS_WORKS" = false ] && ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "   ⚠️  DNS tools failing but 8.8.8.8 is reachable - checking firewall..."
        if command -v nft >/dev/null 2>&1; then
            # Check if DNS port 53 is blocked
            DNS_BLOCKED=$(sudo nft list chain inet filter input 2>/dev/null | grep -E "udp dport 53|tcp dport 53" || echo "")
            if [ -z "$DNS_BLOCKED" ]; then
                echo "   ⚠️  No explicit DNS rules in firewall - may be blocked by default policy"
            else
                echo "   🔍 Firewall DNS rules: $DNS_BLOCKED"
            fi
        fi
    fi
    
    if [ "$PUBLIC_DNS_WORKS" = true ]; then
        echo "   ✅ DNS works with 8.8.8.8 (system DNS is broken, but internet works)"
        if [ "$AUTO_FIX" = true ]; then
            # Check if we were using Tailscale DNS
            if [ "$TAILSCALE_DNS_DETECTED" = true ]; then
                echo "   ⚠️  WARNING: You were using Tailscale DNS (100.100.100.100) for DNS leak protection"
                echo "   ⚠️  Replacing with public DNS will DISABLE DNS leak protection"
                echo "   💡 Better fix: Authenticate Tailscale to restore Tailscale DNS:"
                echo "      sudo tailscale up"
                echo ""
                echo "   🔧 Auto-fixing: Temporarily switching to public DNS to restore functionality..."
                echo "   ⚠️  WARNING: DNS leak protection disabled until Tailscale is authenticated"
                sudo chattr -i /etc/resolv.conf 2>/dev/null || true
                sudo rm -f /etc/resolv.conf
                echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
                echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
                sleep 2
                if nslookup google.com >/dev/null 2>&1; then
                    FIXES_APPLIED+=("Temporarily switched to public DNS (Tailscale DNS not working)") && echo "   ✅ Fixed! DNS now working with public DNS"
                    echo "   💡 To restore Tailscale DNS: sudo tailscale up"
                    DNS_WORKING=true
                else
                    echo "   ⚠️  DNS fix attempted but still not working"
                fi
            else
                echo "   🔧 Auto-fixing: Replacing broken DNS with working public DNS..."
                sudo chattr -i /etc/resolv.conf 2>/dev/null || true
                sudo rm -f /etc/resolv.conf
                echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
                echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
                sleep 2
                
                # Test DNS with multiple methods
                DNS_FIXED=false
                if command -v dig >/dev/null 2>&1; then
                    if timeout 5 dig google.com +short >/dev/null 2>&1; then
                        DNS_FIXED=true
                    fi
                elif command -v host >/dev/null 2>&1; then
                    if timeout 5 host google.com >/dev/null 2>&1; then
                        DNS_FIXED=true
                    fi
                elif nslookup google.com >/dev/null 2>&1; then
                    DNS_FIXED=true
                fi
                
                if [ "$DNS_FIXED" = true ]; then
                    FIXES_APPLIED+=("Fixed DNS by replacing with public DNS servers") && echo "   ✅ Fixed! DNS now working"
                    DNS_WORKING=true
                else
                    echo "   ⚠️  DNS config fixed but resolution still failing"
                    echo "   💡 Checking if firewall is blocking DNS..."
                    if command -v nft >/dev/null 2>&1; then
                        # Check firewall rules
                        if ! sudo nft list chain inet filter input 2>/dev/null | grep -q "udp dport 53"; then
                            echo "   ⚠️  Firewall may be blocking DNS (port 53) - checking rules..."
                            sudo nft list chain inet filter input 2>/dev/null | grep -E "53|dns" || echo "   (no DNS rules found)"
                        fi
                    fi
                fi
            fi
        else
            if [ "$TAILSCALE_DNS_DETECTED" = true ]; then
                echo "   💡 You're using Tailscale DNS - authenticate Tailscale to fix: sudo tailscale up"
                echo "   💡 Or manually replace DNS: sudo chattr -i /etc/resolv.conf && echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
            else
                echo "   💡 To fix: Replace /etc/resolv.conf with:"
                echo "      nameserver 8.8.8.8"
                echo "      nameserver 1.1.1.1"
            fi
        fi
    else
        echo "   ❌ DNS test with 8.8.8.8 failed (but checking if internet actually works...)"
        # Double-check: can we ping by IP?
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "   ⚠️  Internet works (can ping 8.8.8.8) but DNS resolution tools may be broken"
            echo "   💡 This might be a DNS tool issue, not an internet issue"
            DNS_FAILURE_REASON="DNS resolution tools failing (internet may work)"
            
            # Check if DNS queries are being routed incorrectly
            echo "   🔍 Checking DNS query routing..."
            if [ -n "$HOTEL_WIFI" ]; then
                # Test DNS query bound to hotel Wi-Fi interface
                if command -v dig >/dev/null 2>&1; then
                    HOTEL_WIFI_IP=$(ip addr show $HOTEL_WIFI 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
                    if [ -n "$HOTEL_WIFI_IP" ]; then
                        echo "   🔍 Testing DNS query bound to $HOTEL_WIFI interface ($HOTEL_WIFI_IP)..."
                        if timeout 5 dig @8.8.8.8 google.com +short +time=2 -b $HOTEL_WIFI_IP >/dev/null 2>&1; then
                            echo "   ✅ DNS works when bound to $HOTEL_WIFI interface!"
                            echo "   💡 System DNS resolver may be using wrong interface"
                            DNS_FAILURE_REASON="System DNS resolver routing issue"
                            
                            if [ "$AUTO_FIX" = true ]; then
                                echo "   🔧 Attempting to fix DNS routing..."
                                # Ensure resolv.conf uses the right DNS servers
                                sudo chattr -i /etc/resolv.conf 2>/dev/null || true
                                if ! grep -q "^nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null; then
                                    sudo rm -f /etc/resolv.conf
                                    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
                                    echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
                                    FIXES_APPLIED+=("Fixed DNS routing by updating resolv.conf")
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        else
            echo "   ❌ DNS completely broken (even 8.8.8.8 doesn't work)"
            DNS_FAILURE_REASON="Internet connectivity issue"
        fi
    fi
fi

echo ""
echo "   Testing internet connectivity..."
if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "   ✅ Can reach internet (8.8.8.8)"
    INTERNET_WORKING=true
else
    echo "   ❌ Cannot reach internet (8.8.8.8 unreachable)"
    INTERNET_WORKING=false
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fixing: Checking hotel Wi-Fi connection..."
        if [ -n "$HOTEL_WIFI" ] && ! ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
            echo "   🔧 Hotel Wi-Fi not connected, attempting to connect..."
            sudo ip link set $HOTEL_WIFI up 2>/dev/null
            sleep 2
            sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null && FIXES_APPLIED+=("Attempted to connect hotel Wi-Fi") && echo "   ✅ Attempted fix"
        else
            # Check gateway
            GATEWAY=$(ip route show default | awk '{print $3}' | head -1 || echo "")
            if [ -n "$GATEWAY" ]; then
                echo "   🔍 Testing gateway connectivity: $GATEWAY"
                if ping -c 1 -W 2 $GATEWAY >/dev/null 2>&1; then
                    echo "   ✅ Gateway is reachable"
                else
                    echo "   ❌ Gateway is NOT reachable (connection broken)"
                    echo "   🔧 Attempting to renew DHCP lease..."
                    if [ -n "$HOTEL_WIFI" ]; then
                        sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null && FIXES_APPLIED+=("Renewed DHCP lease") && echo "   ✅ Attempted fix"
                    fi
                fi
            fi
        fi
    fi
fi

echo ""
if ping -c 2 -W 2 google.com >/dev/null 2>&1; then
    echo "   ✅ Can resolve and reach google.com"
else
    echo "   ❌ Cannot reach google.com"
    if [ "$INTERNET_WORKING" = true ] && [ "$DNS_WORKING" = false ]; then
        echo "   💡 Internet works but DNS is broken (this is a DNS-only issue)"
    elif [ "$INTERNET_WORKING" = false ]; then
        echo "   💡 Both internet and DNS are broken (check hotel Wi-Fi connection)"
    fi
fi

# Summary of connectivity issues
echo ""
echo "   📊 Connectivity Summary:"
if [ "$DNS_WORKING" = false ]; then
    echo "      ❌ DNS: FAILING - $DNS_FAILURE_REASON"
else
    echo "      ✅ DNS: Working"
fi

if [ "$INTERNET_WORKING" = false ]; then
    echo "      ❌ Internet: FAILING - Cannot reach 8.8.8.8"
else
    echo "      ✅ Internet: Working"
fi

if [ "$DNS_WORKING" = false ] || [ "$INTERNET_WORKING" = false ]; then
    echo ""
    echo "   🔧 Recommended fixes:"
    if [ "$DNS_WORKING" = false ]; then
        echo "      1. Fix DNS: sudo chattr -i /etc/resolv.conf"
        echo "      2. Edit DNS: sudo nano /etc/resolv.conf"
        echo "         Add: nameserver 8.8.8.8"
        echo "         Add: nameserver 1.1.1.1"
        echo "      3. Test: ping google.com"
    fi
    if [ "$INTERNET_WORKING" = false ]; then
        echo "      1. Check hotel Wi-Fi: ip addr show wlan0"
        echo "      2. Renew DHCP: sudo dhcpcd -n wlan0"
        echo "      3. Check gateway: ip route show default"
        echo "      4. Test gateway: ping <gateway_ip>"
    fi
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
    
    # CRITICAL: Check if DNS port 53 is allowed
    echo ""
    echo "   🔍 Checking if DNS (port 53) is allowed in firewall..."
    DNS_ALLOWED_INPUT=$(sudo nft list chain inet filter input 2>/dev/null | grep -E "udp dport 53|tcp dport 53" || echo "")
    if [ -z "$DNS_ALLOWED_INPUT" ]; then
        echo "   ❌ CRITICAL: DNS port 53 is NOT explicitly allowed in firewall!"
        echo "   💡 This is why DNS resolution is failing even though internet works"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Adding DNS rules to firewall..."
            # Add DNS rules before the final accept/reject
            # Get the line number of the last rule
            LAST_RULE_LINE=$(sudo nft -a list chain inet filter input 2>/dev/null | tail -1 | grep -oP 'handle \K[0-9]+' || echo "")
            if [ -n "$LAST_RULE_LINE" ]; then
                # Insert DNS rules before the last rule
                sudo nft insert rule inet filter input position $LAST_RULE_LINE udp dport 53 accept 2>/dev/null || true
                sudo nft insert rule inet filter input position $LAST_RULE_LINE tcp dport 53 accept 2>/dev/null || true
                echo "   ✅ Added DNS rules to firewall"
                FIXES_APPLIED+=("Added DNS port 53 rules to firewall")
            else
                # Fallback: add at the end
                sudo nft add rule inet filter input udp dport 53 accept 2>/dev/null || true
                sudo nft add rule inet filter input tcp dport 53 accept 2>/dev/null || true
                echo "   ✅ Added DNS rules to firewall (at end)"
                FIXES_APPLIED+=("Added DNS port 53 rules to firewall")
            fi
        else
            echo "   💡 To fix manually:"
            echo "      sudo nft add rule inet filter input udp dport 53 accept"
            echo "      sudo nft add rule inet filter input tcp dport 53 accept"
        fi
    else
        echo "   ✅ DNS port 53 is allowed in firewall"
    fi
else
    echo "   ⚠️  nftables is not running"
fi
echo ""

# 10. Check DHCP lease status (CRITICAL for 30-60 min disconnects)
echo "🔟 DHCP Lease Status (Hotel Wi-Fi):"
# Find the hotel Wi-Fi interface (the one NOT in AP mode)
HOTEL_WIFI=""
for iface in wlan0 wlan1; do
    if iw dev $iface info 2>/dev/null | grep -q "type managed"; then
        HOTEL_WIFI="$iface"
        break
    fi
done

if [ -n "$HOTEL_WIFI" ]; then
    echo "   Hotel Wi-Fi interface: $HOTEL_WIFI"
    # Check DHCP lease info
    if [ -f "/var/lib/dhcpcd5/dhcpcd-$HOTEL_WIFI.lease" ]; then
        echo "   ✅ DHCP lease file exists"
        LEASE_TIME=$(sudo stat -c %Y "/var/lib/dhcpcd5/dhcpcd-$HOTEL_WIFI.lease" 2>/dev/null || echo "0")
        if [ "$LEASE_TIME" != "0" ]; then
            CURRENT_TIME=$(date +%s)
            LEASE_AGE=$((CURRENT_TIME - LEASE_TIME))
            LEASE_AGE_MIN=$((LEASE_AGE / 60))
            echo "   📅 Lease file age: ${LEASE_AGE_MIN} minutes"
            if [ $LEASE_AGE_MIN -gt 30 ]; then
                echo "   ⚠️  Lease file is old (${LEASE_AGE_MIN} min) - may need renewal"
            fi
        fi
    else
        echo "   ⚠️  No DHCP lease file found"
    fi
    
    # Check interface state first
    IFACE_STATE=$(ip link show $HOTEL_WIFI 2>/dev/null | grep -oE "state (UP|DOWN|UNKNOWN)" | awk '{print $2}' || echo "UNKNOWN")
    IFACE_CARRIER=$(ip link show $HOTEL_WIFI 2>/dev/null | grep -oE "(NO-CARRIER|LOWER_UP)" || echo "")
    
    if echo "$IFACE_CARRIER" | grep -q "NO-CARRIER"; then
        echo "   ❌ Interface has NO-CARRIER (not physically connected to Wi-Fi network)"
        echo "   💡 wlan0 is UP but not connected to any Wi-Fi network"
        echo ""
        echo "   🔍 Diagnosing..."
        
        # Check if interface can scan for networks
        echo "   🔍 Testing if interface can scan for networks..."
        SCAN_RESULT=$(timeout 5 sudo iw dev $HOTEL_WIFI scan 2>&1 | head -10)
        if echo "$SCAN_RESULT" | grep -q "BSS\|SSID"; then
            NETWORKS_FOUND=$(timeout 5 sudo iw dev $HOTEL_WIFI scan 2>/dev/null | grep -c "SSID:" || echo "0")
            if [ "$NETWORKS_FOUND" -gt "0" ]; then
                echo "   ✅ Interface CAN scan - found $NETWORKS_FOUND networks in range"
                echo "   💡 Networks are available, but wlan0 is not connected to any"
                
                # Show available networks
                echo "   🔍 Available networks:"
                timeout 5 sudo iw dev $HOTEL_WIFI scan 2>/dev/null | grep "SSID:" | head -5 | sed 's/^[[:space:]]*SSID: /      - /' || echo "      (could not list networks)"
                
                if [ "$AUTO_FIX" = true ]; then
                    echo ""
                    echo "   🔧 Auto-fixing: Attempting to connect to available networks..."
                    # Ensure NetworkManager is managing the interface
                    sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
                    sudo ip link set $HOTEL_WIFI up 2>/dev/null || true
                    sleep 2
                    
                    # Check if NetworkManager can see networks
                    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                        echo "   ✅ NetworkManager is running and managing $HOTEL_WIFI"
                        
                        # Try to scan for networks
                        echo "   🔍 Scanning for available networks..."
                        NM_NETWORKS=$(timeout 10 sudo nmcli device wifi list 2>/dev/null | grep -v "SSID" | head -5 || echo "")
                        
                        # Try to scan for networks with NetworkManager
                        echo "   🔍 Scanning for available networks..."
                        sleep 3  # Give NetworkManager time to scan
                        NM_NETWORKS=$(timeout 15 sudo nmcli device wifi list 2>/dev/null || echo "")
                        
                        if [ -n "$NM_NETWORKS" ] && echo "$NM_NETWORKS" | grep -qE "SSID|BSSID"; then
                            echo "   ✅ Found networks via NetworkManager:"
                            echo "$NM_NETWORKS" | head -10
                            echo ""
                            
                            # Check if there are any saved NetworkManager connections
                            SAVED_CONNECTIONS=$(nmcli connection show 2>/dev/null | grep -i "wifi\|802-11" | head -5 || echo "")
                            if [ -n "$SAVED_CONNECTIONS" ]; then
                                echo "   🔍 Found saved Wi-Fi connections - attempting to activate..."
                                # Try to activate the first saved Wi-Fi connection
                                FIRST_WIFI_CONN=$(echo "$SAVED_CONNECTIONS" | head -1 | awk '{print $1}' || echo "")
                                if [ -n "$FIRST_WIFI_CONN" ]; then
                                    echo "   🔧 Attempting to connect to saved connection: $FIRST_WIFI_CONN"
                                    if timeout 30 sudo nmcli connection up "$FIRST_WIFI_CONN" 2>/dev/null; then
                                        sleep 5
                                        if ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                                            FIXES_APPLIED+=("Connected to saved Wi-Fi: $FIRST_WIFI_CONN") && echo "   ✅ SUCCESS! Connected to $FIRST_WIFI_CONN"
                                        else
                                            echo "   ⚠️  Connection attempt made but no IP yet (may need more time)"
                                        fi
                                    else
                                        echo "   ⚠️  Could not connect to saved connection (may need password or network unavailable)"
                                    fi
                                fi
                            fi
                            
                            # If still not connected, check wpa_supplicant config
                            if ! ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                                if [ -f "/etc/wpa_supplicant/wpa_supplicant.conf" ] && grep -q "network=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
                                    echo "   🔍 Found wpa_supplicant configuration - attempting to use it..."
                                    # Stop NetworkManager temporarily to use wpa_supplicant
                                    sudo systemctl stop NetworkManager 2>/dev/null || true
                                    sleep 2
                                    # Start wpa_supplicant with the config
                                    sudo wpa_supplicant -B -i $HOTEL_WIFI -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
                                    sleep 5
                                    # Try to get DHCP
                                    sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null || true
                                    sleep 5
                                    # Restart NetworkManager
                                    sudo systemctl start NetworkManager 2>/dev/null || true
                                    sleep 3
                                    
                                    if ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                                        FIXES_APPLIED+=("Connected using wpa_supplicant configuration") && echo "   ✅ SUCCESS! Connected using wpa_supplicant config"
                                    else
                                        echo "   ⚠️  wpa_supplicant connection attempt made but no IP yet"
                                        echo "   💡 Use nmtui to connect: sudo nmtui"
                                    fi
                                else
                                    echo "   💡 No saved credentials found - use nmtui to connect: sudo nmtui"
                                    echo "   💡 Or use nmcli: sudo nmcli device wifi connect 'NetworkName' password 'password'"
                                fi
                            fi
                            
                            if ! ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                                FIXES_APPLIED+=("Prepared $HOTEL_WIFI for NetworkManager connection")
                            fi
                        else
                            echo "   ⚠️  NetworkManager scan did not find networks (may need more time)"
                            echo "   💡 Use nmtui to connect: sudo nmtui"
                            echo "   💡 Or list networks: sudo nmcli device wifi list"
                            FIXES_APPLIED+=("Prepared $HOTEL_WIFI for NetworkManager connection")
                        fi
                    else
                        echo "   ⚠️  NetworkManager not running - starting it..."
                        sudo systemctl start NetworkManager 2>/dev/null && sleep 5 && FIXES_APPLIED+=("Started NetworkManager for Wi-Fi connection")
                    fi
                fi
            else
                echo "   ⚠️  Interface can scan but found 0 networks"
                echo "   💡 No Wi-Fi networks in range, or adapter issue"
            fi
        elif echo "$SCAN_RESULT" | grep -qi "command failed\|not supported\|device or resource busy"; then
            echo "   ⚠️  Interface cannot scan (may be blocked by NetworkManager or wpa_supplicant)"
        else
            echo "   ⚠️  Interface scan test inconclusive"
        fi
        
        # Check wpa_supplicant configuration
        echo ""
        echo "   🔍 Checking wpa_supplicant configuration..."
        if [ -f "/etc/wpa_supplicant/wpa_supplicant.conf" ]; then
            WPA_NETWORKS=$(grep -c "network=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || echo "0")
            if [ "$WPA_NETWORKS" -gt "0" ]; then
                echo "   ✅ wpa_supplicant.conf exists with $WPA_NETWORKS network(s) configured"
            else
                echo "   ⚠️  wpa_supplicant.conf exists but has no networks configured"
            fi
        else
            echo "   ❌ wpa_supplicant.conf does NOT exist"
            echo "   💡 Wi-Fi credentials are not configured"
        fi
        
        # Check wpa_supplicant status
        if systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
            WPA_STATUS=$(sudo wpa_cli -i $HOTEL_WIFI status 2>/dev/null | grep "wpa_state" || echo "")
            echo "   ✅ wpa_supplicant is running"
            if [ -n "$WPA_STATUS" ]; then
                echo "   🔍 wpa_supplicant state: $WPA_STATUS"
            fi
        else
            echo "   ⚠️  wpa_supplicant is NOT running"
        fi
        
        echo ""
        echo "   💡 To fix:"
        echo "   1. Use nmtui to connect to a network (NetworkManager is now enabled)"
        echo "   2. Or configure wpa_supplicant: sudo nano /etc/wpa_supplicant/wpa_supplicant.conf"
        echo "   3. Or use nmcli: sudo nmcli device wifi connect 'NetworkName' password 'password'"
        
        if [ "$AUTO_FIX" = true ]; then
            echo ""
            echo "   🔧 Auto-fixing: Ensuring interface is up and NetworkManager can manage it..."
            # Ensure NetworkManager is managing the interface
            sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
            sudo ip link set $HOTEL_WIFI up 2>/dev/null
            sleep 2
            
            # Check if NetworkManager can see networks
            if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                echo "   ✅ NetworkManager is running and managing $HOTEL_WIFI"
                echo "   💡 Use nmtui to connect: sudo nmtui"
                echo "   💡 Or list networks: sudo nmcli device wifi list"
            else
                echo "   ⚠️  NetworkManager not running - starting it..."
                sudo systemctl start NetworkManager 2>/dev/null && sleep 3 && FIXES_APPLIED+=("Started NetworkManager for Wi-Fi connection")
            fi
        fi
    elif ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
        HOTEL_IP=$(ip addr show $HOTEL_WIFI | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        echo "   ✅ Interface has IP: $HOTEL_IP"
        
        # Check if we can reach the gateway
        GATEWAY=$(ip route show dev $HOTEL_WIFI | grep default | awk '{print $3}' | head -1)
        if [ -n "$GATEWAY" ]; then
            echo "   🔍 Gateway: $GATEWAY"
            if ping -c 1 -W 2 $GATEWAY >/dev/null 2>&1; then
                echo "   ✅ Gateway is reachable"
            else
                echo "   ❌ Gateway is NOT reachable (connection may be broken)"
                if [ "$AUTO_FIX" = true ]; then
                    echo "   🔧 Auto-fixing: Renewing DHCP lease..."
                    timeout 10 sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null && FIXES_APPLIED+=("Renewed DHCP lease for $HOTEL_WIFI") && echo "   ✅ Fixed!"
                fi
            fi
        else
            echo "   ❌ No default gateway found for $HOTEL_WIFI"
        fi
    else
        echo "   ❌ Interface has NO IP address (not connected to hotel Wi-Fi)"
        echo "   🔍 Interface state: $IFACE_STATE"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Attempting to connect and renew DHCP..."
            sudo ip link set $HOTEL_WIFI up 2>/dev/null
            sleep 2
            timeout 10 sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null && FIXES_APPLIED+=("Attempted to connect $HOTEL_WIFI and renew DHCP") && echo "   ✅ Attempted fix (check connection manually)"
        fi
    fi
    
    # Check wpa_supplicant status
    if systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
        echo "   ✅ wpa_supplicant is running"
    else
        echo "   ⚠️  wpa_supplicant not running (may affect reconnection)"
    fi
else
    echo "   ⚠️  Could not identify hotel Wi-Fi interface"
fi
echo ""

# 11. NetworkManager interference check
echo "1️⃣1️⃣ NetworkManager Interference Check:"
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "   ⚠️  NetworkManager is RUNNING (may interfere with hotel Wi-Fi)"
    echo "   🔍 Checking if hotel Wi-Fi is managed by NetworkManager:"
    if [ -n "$HOTEL_WIFI" ]; then
        # Check if wlan0 is actually connected and has an IP
        IFACE_CONNECTED=false
        if nmcli device status 2>/dev/null | grep -q "$HOTEL_WIFI.*connected" && ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
            IFACE_CONNECTED=true
        fi
        
        if [ "$IFACE_CONNECTED" = true ]; then
            echo "   ✅ NetworkManager is managing $HOTEL_WIFI and it's connected"
            echo "   💡 This is correct - NetworkManager should manage hotel Wi-Fi for nmtui"
            # NetworkManager managing wlan0 is correct - don't disable it
        elif nmcli device status 2>/dev/null | grep -q "$HOTEL_WIFI.*unmanaged"; then
            echo "   ❌ NetworkManager is NOT managing $HOTEL_WIFI (wlan0 is unmanaged)"
            echo "   💡 This prevents NetworkManager from connecting to Wi-Fi networks!"
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Enabling NetworkManager management of $HOTEL_WIFI so it can connect..."
                sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null && FIXES_APPLIED+=("Enabled NetworkManager management of $HOTEL_WIFI") && echo "   ✅ Fixed! NetworkManager can now connect to Wi-Fi"
            fi
        else
            echo "   ✅ NetworkManager is managing $HOTEL_WIFI (needed for connection)"
        fi
    fi
    
    # Check for recent NetworkManager restarts
    NM_RESTARTS=$(journalctl -u NetworkManager --since "1 hour ago" 2>/dev/null | grep -c "Started\|Stopped" || echo "0")
    if [ "$NM_RESTARTS" -gt "2" ]; then
        echo "   ⚠️  NetworkManager has restarted $NM_RESTARTS times in the last hour"
    fi
else
    echo "   ✅ NetworkManager is not running"
fi
echo ""

# 12. Tailscale connection stability
echo "1️⃣2️⃣ Tailscale Connection Stability:"
if command -v tailscale >/dev/null 2>&1; then
    # First check if Tailscale is authenticated
    TAILSCALE_STATUS=$(sudo tailscale status 2>/dev/null || echo "")
    if echo "$TAILSCALE_STATUS" | grep -qi "logged out\|not logged in"; then
        echo "   ❌ Tailscale is NOT authenticated (logged out)"
        # Check if we have internet before trying to authenticate
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Internet available, but Tailscale needs manual authentication"
                echo "   💡 Run: sudo tailscale up"
                echo "   💡 Then visit the URL shown to authenticate"
            fi
        else
            echo "   ⚠️  Cannot authenticate Tailscale without internet connection"
            echo "   💡 Fix hotel Wi-Fi connection first, then run: sudo tailscale up"
        fi
    elif sudo tailscale status 2>/dev/null | grep -q "active.*exit node"; then
        echo "   ✅ Exit node is active"
    else
        echo "   ❌ Exit node is NOT active (connection lost!)"
        # Check if we have internet before trying to reconnect
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            if [ "$AUTO_FIX" = true ]; then
                echo "   🔧 Auto-fixing: Attempting to reconnect Tailscale (with 10s timeout)..."
                # Try to get exit node IP from config if available
                if [ -f "tunnel.conf" ]; then
                    source tunnel.conf 2>/dev/null
                    if [ -n "$TAILSCALE_EXIT_NODE_IP" ]; then
                        timeout 10 sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns 2>/dev/null && FIXES_APPLIED+=("Attempted Tailscale reconnection") && echo "   ✅ Attempted fix"
                    else
                        echo "   ⚠️  Could not find exit node IP in config"
                    fi
                else
                    echo "   ⚠️  Could not find tunnel.conf to get exit node IP"
                fi
            fi
        else
            echo "   ⚠️  Cannot reconnect Tailscale without internet connection"
            echo "   💡 Fix hotel Wi-Fi connection first"
        fi
    fi
    
    # Check for recent Tailscale reconnections
    TS_RECONNECTS=$(journalctl -u tailscaled --since "1 hour ago" 2>/dev/null | grep -ci "reconnect\|connection.*lost\|peer.*disconnected" || echo "0")
    TS_RECONNECTS=$(echo "$TS_RECONNECTS" | tr -d '\n\r ' | head -1)
    if [ -n "$TS_RECONNECTS" ] && [ "$TS_RECONNECTS" -gt "0" ]; then
        echo "   ⚠️  Found $TS_RECONNECTS Tailscale reconnection events in last hour"
        echo "   🔍 Recent Tailscale events:"
        journalctl -u tailscaled --since "30 minutes ago" 2>/dev/null | grep -i "reconnect\|connection\|peer" | tail -3 || true
    else
        echo "   ✅ No recent Tailscale reconnections"
    fi
    
    # Check Tailscale ping to exit node (only if authenticated)
    if ! echo "$TAILSCALE_STATUS" | grep -qi "logged out\|not logged in"; then
        EXIT_NODE_IP=$(sudo tailscale status 2>/dev/null | grep "exit node" | grep -oE "100\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        if [ -n "$EXIT_NODE_IP" ]; then
            if timeout 5 sudo tailscale ping -c 1 $EXIT_NODE_IP >/dev/null 2>&1; then
                echo "   ✅ Can ping exit node ($EXIT_NODE_IP)"
            else
                echo "   ❌ Cannot ping exit node ($EXIT_NODE_IP) - connection may be broken"
                if [ "$AUTO_FIX" = true ]; then
                    echo "   🔧 Auto-fixing: Restarting Tailscale..."
                    sudo systemctl restart tailscaled 2>/dev/null && sleep 3 && FIXES_APPLIED+=("Restarted tailscaled") && echo "   ✅ Fixed!"
                fi
            fi
        fi
    fi
else
    echo "   ❌ Tailscale not installed"
fi
echo ""

# 13. Service uptime and restart history
echo "1️⃣3️⃣ Service Uptime & Restart History:"
for service in tailscaled hostapd dnsmasq tunnel-watchdog; do
    if systemctl list-unit-files 2>/dev/null | grep -q "$service.service"; then
        UPTIME=$(systemctl show $service -p ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        RESTARTS=$(journalctl -u $service --since "1 hour ago" 2>/dev/null | grep -c "Started\|Stopped" || echo "0")
        RESTARTS=$(echo "$RESTARTS" | tr -d '\n\r ' | head -1)
        if [ -n "$RESTARTS" ] && [ "$RESTARTS" -gt "2" ]; then
            echo "   ⚠️  $service: Restarted $RESTARTS times in last hour (unstable!)"
        else
            echo "   ✅ $service: Stable (uptime since: $UPTIME)"
        fi
    fi
done
echo ""

# 14. Routing table stability
echo "1️⃣4️⃣ Routing Table Stability:"
# Check for default route through Tailscale
if ip route show | grep -q "default.*tailscale0"; then
    echo "   ✅ Default route through Tailscale exists"
else
    echo "   ❌ No default route through Tailscale (routing broken!)"
        if [ "$AUTO_FIX" = true ]; then
            # Only try to fix routing if we have internet and Tailscale is authenticated
            if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                TAILSCALE_STATUS_CHECK=$(sudo tailscale status 2>/dev/null || echo "")
                if ! echo "$TAILSCALE_STATUS_CHECK" | grep -qi "logged out\|not logged in"; then
                    echo "   🔧 Auto-fixing: Attempting to fix routing..."
                    # Remove any broken routes first
                    sudo ip route del default dev tailscale0 2>/dev/null || true
                    sudo ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true
                    sudo ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true
                    # Let Tailscale handle routing automatically
                    if [ -f "tunnel.conf" ]; then
                        source tunnel.conf 2>/dev/null
                        if [ -n "$TAILSCALE_EXIT_NODE_IP" ]; then
                            timeout 10 sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns 2>/dev/null && FIXES_APPLIED+=("Attempted to fix Tailscale routing") && echo "   ✅ Attempted fix"
                        fi
                    fi
                else
                    echo "   ⚠️  Cannot fix routing - Tailscale not authenticated"
                fi
            else
                echo "   ⚠️  Cannot fix routing - no internet connection"
            fi
        fi
fi

# Check for conflicting routes
CONFLICTING_ROUTES=$(ip route show | grep -E "default|0\.0\.0\.0/1|128\.0\.0\.0/1" | wc -l)
if [ "$CONFLICTING_ROUTES" -gt "1" ]; then
    echo "   ⚠️  Multiple default routes detected (may cause conflicts):"
    ip route show | grep -E "default|0\.0\.0\.0/1|128\.0\.0\.0/1"
else
    echo "   ✅ Routing table looks clean"
fi
echo ""

# 15. Recent connection issues (last hour)
echo "1️⃣5️⃣ Recent Connection Issues (Last Hour):"
echo "   🔍 Checking system logs for network issues..."

# Check for interface down events
IFACE_DOWNS=$(journalctl --since "1 hour ago" 2>/dev/null | grep -ci "link.*down\|carrier.*lost" || echo "0")
IFACE_DOWNS=$(echo "$IFACE_DOWNS" | tr -d '\n\r ' | head -1)
if [ -n "$IFACE_DOWNS" ] && [ "$IFACE_DOWNS" -gt "0" ]; then
    echo "   ⚠️  Found $IFACE_DOWNS interface down events in last hour"
    journalctl --since "1 hour ago" 2>/dev/null | grep -i "link.*down\|carrier.*lost" | tail -3 || true
fi

# Check for DHCP failures
DHCP_FAILS=$(journalctl --since "1 hour ago" 2>/dev/null | grep -ci "dhcp.*fail\|dhcp.*error\|dhcp.*timeout" || echo "0")
DHCP_FAILS=$(echo "$DHCP_FAILS" | tr -d '\n\r ' | head -1)
if [ -n "$DHCP_FAILS" ] && [ "$DHCP_FAILS" -gt "0" ]; then
    echo "   ⚠️  Found $DHCP_FAILS DHCP failures in last hour"
    journalctl --since "1 hour ago" 2>/dev/null | grep -i "dhcp.*fail\|dhcp.*error\|dhcp.*timeout" | tail -3 || true
fi

# Check for DNS resolution failures
DNS_FAILS=$(journalctl --since "1 hour ago" 2>/dev/null | grep -ci "dns.*fail\|resolve.*fail\|nameserver.*fail" || echo "0")
DNS_FAILS=$(echo "$DNS_FAILS" | tr -d '\n\r ' | head -1)
if [ -z "$DNS_FAILS" ]; then DNS_FAILS=0; fi
if [ "$DNS_FAILS" -gt "0" ]; then
    echo "   ⚠️  Found $DNS_FAILS DNS failures in last hour"
fi

IFACE_DOWNS_NUM=$(echo "$IFACE_DOWNS" | tr -d '\n\r ' | head -1)
DHCP_FAILS_NUM=$(echo "$DHCP_FAILS" | tr -d '\n\r ' | head -1)
DNS_FAILS_NUM=$(echo "$DNS_FAILS" | tr -d '\n\r ' | head -1)
if [ -z "$IFACE_DOWNS_NUM" ]; then IFACE_DOWNS_NUM=0; fi
if [ -z "$DHCP_FAILS_NUM" ]; then DHCP_FAILS_NUM=0; fi
if [ -z "$DNS_FAILS_NUM" ]; then DNS_FAILS_NUM=0; fi
if [ "$IFACE_DOWNS_NUM" -eq "0" ] && [ "$DHCP_FAILS_NUM" -eq "0" ] && [ "$DNS_FAILS_NUM" -eq "0" ]; then
    echo "   ✅ No obvious connection issues in logs"
fi
echo ""

# 16. Connection timing analysis
echo "1️⃣6️⃣ Connection Timing Analysis:"
echo "   🔍 Analyzing connection patterns..."

# Get service start times
TAILSCALE_START=$(systemctl show tailscaled -p ActiveEnterTimestamp --value 2>/dev/null | date -d "$(cat)" +%s 2>/dev/null || echo "0")
HOSTAPD_START=$(systemctl show hostapd -p ActiveEnterTimestamp --value 2>/dev/null | date -d "$(cat)" +%s 2>/dev/null || echo "0")
CURRENT_TIME=$(date +%s)

if [ "$TAILSCALE_START" != "0" ]; then
    TAILSCALE_UPTIME=$((CURRENT_TIME - TAILSCALE_START))
    TAILSCALE_UPTIME_MIN=$((TAILSCALE_UPTIME / 60))
    echo "   📊 Tailscale uptime: ${TAILSCALE_UPTIME_MIN} minutes"
    
    if [ $TAILSCALE_UPTIME_MIN -lt 30 ]; then
        echo "   ⚠️  Tailscale was recently restarted (${TAILSCALE_UPTIME_MIN} min ago)"
    fi
fi

if [ "$HOSTAPD_START" != "0" ]; then
    HOSTAPD_UPTIME=$((CURRENT_TIME - HOSTAPD_START))
    HOSTAPD_UPTIME_MIN=$((HOSTAPD_UPTIME / 60))
    echo "   📊 hostapd uptime: ${HOSTAPD_UPTIME_MIN} minutes"
fi

# Check if we're near a 30 or 60 minute mark
if [ "$TAILSCALE_UPTIME_MIN" != "0" ]; then
    REMAINDER=$((TAILSCALE_UPTIME_MIN % 30))
    if [ $REMAINDER -ge 25 ] || [ $REMAINDER -le 5 ]; then
        echo "   ⚠️  Near 30-minute interval mark - watch for disconnects"
    fi
fi
echo ""

# 17. Potential root causes summary
echo "1️⃣7️⃣ Potential Root Causes (Based on Analysis):"
ISSUES_FOUND=0

# Check if watchdog service exists and is running
if systemctl list-unit-files 2>/dev/null | grep -q "tunnel-watchdog.service"; then
    if systemctl is-active --quiet tunnel-watchdog 2>/dev/null; then
        echo "   ✅ Watchdog service is running (auto-recovery enabled)"
    else
        echo "   ⚠️  Watchdog service exists but is NOT running (auto-recovery disabled)"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Starting watchdog service..."
            sudo systemctl start tunnel-watchdog 2>/dev/null && FIXES_APPLIED+=("Started tunnel-watchdog service") && echo "   ✅ Fixed!"
        else
            echo "   💡 Start it: sudo systemctl start tunnel-watchdog"
        fi
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
else
    echo "   ⚠️  Watchdog service not found (auto-recovery not configured)"
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Auto-fix: Watchdog service needs to be set up by running tunnel.sh"
        echo "   💡 Run: ./tunnel.sh (or the full path to tunnel.sh)"
    else
        echo "   💡 Run tunnel.sh to set up the watchdog service"
    fi
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ -n "$HOTEL_WIFI" ] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    if nmcli device status 2>/dev/null | grep -q "$HOTEL_WIFI.*connected"; then
        echo "   ❌ NetworkManager managing hotel Wi-Fi (likely cause of periodic disconnects)"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
fi

TS_RECONNECTS=$(echo "$TS_RECONNECTS" | tr -d '\n\r ' | head -1)
if [ -n "$TS_RECONNECTS" ] && [ "$TS_RECONNECTS" -gt "2" ]; then
    echo "   ❌ Tailscale frequently reconnecting (unstable connection)"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

DHCP_FAILS_NUM=$(echo "$DHCP_FAILS" | tr -d '\n\r ' | head -1)
if [ -z "$DHCP_FAILS_NUM" ]; then DHCP_FAILS_NUM=0; fi
if [ "$DHCP_FAILS_NUM" -gt "0" ]; then
    echo "   ❌ DHCP lease renewal failures (hotel Wi-Fi may have short lease times)"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

IFACE_DOWNS_NUM=$(echo "$IFACE_DOWNS" | tr -d '\n\r ' | head -1)
if [ -z "$IFACE_DOWNS_NUM" ]; then IFACE_DOWNS_NUM=0; fi
if [ "$IFACE_DOWNS_NUM" -gt "0" ]; then
    echo "   ❌ Network interface going down periodically"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$ISSUES_FOUND" -eq "0" ]; then
    echo "   ✅ No obvious root causes identified"
    echo "   💡 Consider: Hotel Wi-Fi may have aggressive connection timeouts"
fi
echo ""

# FINAL COMPREHENSIVE RECOVERY CHECK (before ending)
echo ""
echo "🔧 === FINAL RECOVERY CHECK (nmtui readiness) ==="
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    # Check if NetworkManager sees wlan0
    NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
    WIFI_RADIO_FINAL=$(nmcli radio wifi 2>/dev/null || echo "unknown")
    
    # Check what NetworkManager currently sees
    echo "   🔍 Current NetworkManager devices:"
    nmcli device status 2>/dev/null | head -10 || echo "   (no devices found)"
    
    if [ -z "$NM_WLAN0_FINAL" ]; then
        echo ""
        echo "   ❌ CRITICAL: NetworkManager does NOT see wlan0!"
        echo "   💡 This is why nmtui only shows 'tun0 tailscaled' and 'wired'"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 AGGRESSIVE FINAL RECOVERY: Complete reset of wlan0..."
            # Step 1: Remove ALL unmanaged-devices from config
            echo "      Step 1: Removing all unmanaged-devices..."
            sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
            # Step 2: Clean up duplicate sections
            sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
            if [ -f /tmp/nm_conf_fixed ]; then
                sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
            fi
            # Step 2b: Add wlan1 ONLY to unmanaged-devices (CRITICAL for AP mode)
            echo "      Step 1b: Adding wlan1 to unmanaged-devices (for AP mode)..."
            if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
                echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            fi
            if ! grep -q "unmanaged-devices=interface-name:wlan1" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                echo "unmanaged-devices=interface-name:wlan1" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            fi
            # Step 3: Stop wpa_supplicant
            echo "      Step 2: Stopping wpa_supplicant..."
            sudo systemctl stop wpa_supplicant 2>/dev/null || true
            sudo pkill -9 -x wpa_supplicant 2>/dev/null || true
            # Step 4: Configure wlan0 (ROOT CAUSE FIX: Use nmcli, NOT ip link set!)
            # Using 'ip link set wlan0 up' while NetworkManager is running causes
            # NetworkManager to mark wlan0 as unmanaged (reason: 'removed')
            echo "      Step 3: Configuring wlan0 (using NetworkManager to preserve management)..."
            # Only use ip link set if NetworkManager is stopped
            if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
                sudo ip link set wlan0 down 2>/dev/null || true
                sleep 1
                sudo iw dev wlan0 set type managed 2>/dev/null || true
                sudo ip link set wlan0 up 2>/dev/null || true
                sleep 2
            else
                # NetworkManager is running - use nmcli to avoid marking as unmanaged
                sudo iw dev wlan0 set type managed 2>/dev/null || true
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 2
            fi
            # Step 5: Ensure wlan1 is NOT managed
            sudo nmcli device set wlan1 managed no 2>/dev/null || true
            # Step 6: Set wlan0 to managed
            echo "      Step 4: Setting wlan0 to managed..."
            sudo nmcli device set wlan0 managed yes 2>/dev/null || true
            # Step 7: Enable Wi-Fi radio
            echo "      Step 5: Enabling Wi-Fi radio..."
            sudo nmcli radio wifi on 2>/dev/null || true
            # Step 8: Full NetworkManager restart
            echo "      Step 6: Restarting NetworkManager..."
            sudo systemctl stop NetworkManager 2>/dev/null || true
            sleep 3
            sudo pkill -9 NetworkManager 2>/dev/null || true
            sleep 2
            sudo systemctl start NetworkManager 2>/dev/null || true
            sleep 8
            # Verify
            echo "      Step 7: Verifying..."
            sleep 2
            NM_WLAN0_AFTER=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
            if [ -n "$NM_WLAN0_AFTER" ] && ! echo "$NM_WLAN0_AFTER" | grep -qE "(unmanaged|unavailable)"; then
                FIXES_APPLIED+=("AGGRESSIVE FINAL RECOVERY: Made wlan0 visible and managed") && echo "      ✅ SUCCESS! wlan0 is now visible and managed"
            else
                echo "      ⚠️  Still not working - showing current status:"
                nmcli device status 2>/dev/null | grep -E "^(wlan|eth|tailscale)" || echo "      (no devices found)"
            fi
        fi
    elif echo "$NM_WLAN0_FINAL" | grep -qE "(unmanaged|unavailable)"; then
        echo ""
        echo "   ⚠️  wlan0 is visible but $(echo "$NM_WLAN0_FINAL" | awk '{print $3}')"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 FINAL RECOVERY: Setting wlan0 to managed..."
            sudo nmcli device set wlan0 managed yes 2>/dev/null || true
            sudo nmcli radio wifi on 2>/dev/null || true
            sudo systemctl restart NetworkManager 2>/dev/null || true
            sleep 5
            FIXES_APPLIED+=("Final recovery: Set wlan0 to managed")
        fi
    elif [ "$WIFI_RADIO_FINAL" != "enabled" ]; then
        echo ""
        echo "   ⚠️  Wi-Fi radio is not enabled: $WIFI_RADIO_FINAL"
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 FINAL RECOVERY: Enabling Wi-Fi radio..."
            sudo nmcli radio wifi on 2>/dev/null && FIXES_APPLIED+=("Final recovery: Enabled Wi-Fi radio")
        fi
    else
        echo ""
        echo "   ✅ NetworkManager sees wlan0: $(echo "$NM_WLAN0_FINAL" | awk '{print $1, $2, $3}')"
        echo "   ✅ Wi-Fi radio is enabled"
        echo "   ✅ nmtui should show wireless networks!"
    fi
    
    # Show what nmtui will display
    echo ""
    echo "   📱 What nmtui will show (current state):"
    nmcli device status 2>/dev/null | while read line; do
        DEVICE=$(echo "$line" | awk '{print $1}')
        TYPE=$(echo "$line" | awk '{print $2}')
        STATE=$(echo "$line" | awk '{print $3}')
        if [ "$TYPE" = "wifi" ] && [ "$STATE" != "unmanaged" ] && [ "$STATE" != "unavailable" ]; then
            echo "      ✅ $DEVICE ($TYPE) - $STATE (will show wireless networks in nmtui)"
        elif [ "$TYPE" = "wifi" ] && [ "$DEVICE" = "wlan1" ]; then
            # wlan1 should be unmanaged - it's used for the access point (AP mode)
            echo "      ✅ $DEVICE ($TYPE) - $STATE (correctly unmanaged - used for access point)"
        elif [ "$TYPE" = "wifi" ]; then
            echo "      ❌ $DEVICE ($TYPE) - $STATE (will NOT show in nmtui - needs fix)"
        elif [ "$TYPE" = "ethernet" ]; then
            echo "      ℹ️  $DEVICE ($TYPE) - $STATE (Wired connections)"
        elif [ "$DEVICE" = "tailscale0" ]; then
            echo "      ℹ️  $DEVICE (tun) - $STATE (tun0 tailscaled)"
        fi
    done
    
    # If wlan0 still not showing, try one more thing
    if [ -z "$NM_WLAN0_FINAL" ] || echo "$NM_WLAN0_FINAL" | grep -qE "(unmanaged|unavailable)"; then
        echo ""
        echo "   ⚠️  wlan0 still not properly configured for nmtui"
        echo "   💡 Try running these commands manually:"
        echo "      sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
        echo "      sudo nmcli device set wlan0 managed yes"
        echo "      sudo nmcli radio wifi on"
        echo "      sudo systemctl restart NetworkManager"
        echo "      sudo nmtui"
    fi
else
    echo "   ❌ NetworkManager is not running - nmtui will not work"
    if [ "$AUTO_FIX" = true ]; then
        echo "   🔧 Starting NetworkManager..."
        sudo systemctl start NetworkManager 2>/dev/null && sleep 3 && FIXES_APPLIED+=("Started NetworkManager for final recovery")
    fi
fi
echo ""

echo "=== Debug Complete ==="
echo ""

# Summary of fixes applied
if [ ${#FIXES_APPLIED[@]} -gt 0 ]; then
    echo "🔧 === AUTO-FIXES APPLIED ==="
    for fix in "${FIXES_APPLIED[@]}"; do
        echo "   ✅ $fix"
    done
    echo ""
    echo "💡 Re-run this script to verify fixes worked"
    echo ""
fi

# Priority diagnosis
echo "🎯 === PRIORITY DIAGNOSIS ==="

# Check DNS first (most common issue)
if [ "$DNS_WORKING" = false ]; then
    echo "🔴 CRITICAL: DNS Resolution is FAILING"
    echo "   → Error: 'Temporary failure in name resolution'"
    echo "   → This prevents: ping google.com, web browsing, Tailscale authentication"
    echo ""
    echo "   Root cause: $DNS_FAILURE_REASON"
    echo ""
    
    # Check if it's a Tailscale DNS issue
    if echo "$DNS_FAILURE_REASON" | grep -qi "tailscale"; then
        echo "   🎯 TAILSCALE DNS ISSUE DETECTED:"
        echo "   → You're using Tailscale DNS (100.100.100.100) for DNS leak protection"
        
        if [ "$TAILSCALE_IS_AUTHENTICATED" = false ]; then
            echo "   → Tailscale is logged out, so Tailscale DNS doesn't work"
            echo ""
            if [ "$AUTO_FIX" = true ]; then
                # Check if we have internet to authenticate Tailscale
                if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    echo "   🔧 Internet available - attempting to authenticate Tailscale..."
                    echo "   💡 Run: sudo tailscale up"
                    echo "   🔧 Also ensuring DNS works with public DNS as fallback..."
                    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
                    if ! grep -q "^nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null; then
                        sudo rm -f /etc/resolv.conf
                        echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
                        echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
                        FIXES_APPLIED+=("Set public DNS as fallback (Tailscale logged out)")
                    fi
                else
                    echo "   ⚠️  No internet connection - cannot authenticate Tailscale"
                    echo "   💡 Fix hotel Wi-Fi connection first"
                fi
            else
                echo "   Steps to fix (preserve DNS leak protection):"
                echo "   1. Check if you have internet: ping 8.8.8.8"
                echo "   2. Authenticate Tailscale: sudo tailscale up"
                echo "   3. Verify Tailscale DNS is working: ping google.com"
                echo "   4. Check Tailscale status: sudo tailscale status"
            fi
        else
            echo "   → Tailscale is authenticated, but Tailscale DNS (100.100.100.100) isn't working"
            echo ""
            echo "   Possible causes:"
            echo "   1. Tailscale DNS server not reachable (routing issue)"
            echo "   2. Tailscale DNS not enabled (missing --accept-dns flag)"
            echo "   3. Firewall blocking access to 100.100.100.100"
            echo ""
            echo "   Steps to fix:"
            echo "   1. Test if Tailscale DNS is reachable: ping 100.100.100.100"
            echo "   2. Check route: ip route get 100.100.100.100"
            echo "   3. Ensure --accept-dns flag: sudo tailscale up --accept-dns"
            echo "   4. Check Tailscale DNS status: sudo tailscale status --json | grep -i dns"
            echo "   5. If DNS still fails, check if routing goes through tailscale0:"
            echo "      ip route show | grep tailscale0"
        fi
        echo ""
        echo "   ⚠️  If you use public DNS instead, DNS leak protection will be DISABLED"
        echo "   → Only do this if Tailscale DNS can't be fixed"
        echo "   → To temporarily use public DNS:"
        echo "      sudo chattr -i /etc/resolv.conf"
        echo "      echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
        echo "      echo 'nameserver 1.1.1.1' | sudo tee -a /etc/resolv.conf"
    else
        # Not a Tailscale DNS issue - general DNS failure
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Attempting to fix DNS configuration..."
            # Remove immutable flag
            sudo chattr -i /etc/resolv.conf 2>/dev/null || true
            # Stop systemd-resolved if running
            sudo systemctl stop systemd-resolved 2>/dev/null || true
            sudo systemctl disable systemd-resolved 2>/dev/null || true
            # Fix DNS servers (even without internet, this fixes the config)
            sudo rm -f /etc/resolv.conf
            echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf > /dev/null
            FIXES_APPLIED+=("Fixed DNS configuration (set public DNS servers)")
            echo "   ✅ DNS configuration fixed (set to 8.8.8.8 and 1.1.1.1)"
            echo "   💡 DNS will work once internet connection is established"
            sleep 2
            # Test if it works (only if we have internet)
            if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                if nslookup google.com >/dev/null 2>&1; then
                    echo "   ✅ DNS is now working!"
                else
                    echo "   ⚠️  DNS config fixed but resolution still failing (may need more time)"
                fi
            else
                echo "   ⚠️  DNS config fixed but no internet connection yet"
            fi
        else
            echo "   Steps to fix:"
            echo "   1. Check /etc/resolv.conf: cat /etc/resolv.conf"
            echo "   2. Remove immutable flag: sudo chattr -i /etc/resolv.conf"
            echo "   3. Fix DNS servers:"
            echo "      sudo rm /etc/resolv.conf"
            echo "      echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
            echo "      echo 'nameserver 1.1.1.1' | sudo tee -a /etc/resolv.conf"
            echo "   4. Test: ping google.com"
            echo "   5. If still broken, check systemd-resolved: sudo systemctl stop systemd-resolved"
        fi
    fi
    echo ""
fi

if [ -n "$HOTEL_WIFI" ]; then
    IFACE_CARRIER_CHECK=$(ip link show $HOTEL_WIFI 2>/dev/null | grep -oE "(NO-CARRIER|LOWER_UP)" || echo "")
    IFACE_HAS_IP=$(ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet " && echo "yes" || echo "no")
    
    if echo "$IFACE_CARRIER_CHECK" | grep -q "NO-CARRIER"; then
        echo "🔴 CRITICAL: Hotel Wi-Fi ($HOTEL_WIFI) is NOT CONNECTED to any network"
        echo "   → Interface shows NO-CARRIER (not physically connected to Wi-Fi network)"
        echo "   → This is the ROOT CAUSE - blocking everything else (internet, DNS, Tailscale routing)"
        echo "   → Fix this FIRST before anything else will work"
        echo ""
        if [ "$AUTO_FIX" = true ]; then
            echo "   🔧 Auto-fixing: Attempting to connect to available networks..."
            # Ensure NetworkManager is managing the interface
            sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
            sudo ip link set $HOTEL_WIFI up 2>/dev/null || true
            sleep 2
            
            # Ensure NetworkManager is running
            if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
                sudo systemctl start NetworkManager 2>/dev/null && sleep 5
            fi
            
            # Try to scan for networks
            echo "   🔍 Scanning for available networks..."
            sleep 3  # Give NetworkManager time to scan
            NM_NETWORKS=$(timeout 15 sudo nmcli device wifi list 2>/dev/null || echo "")
            
            if [ -n "$NM_NETWORKS" ] && echo "$NM_NETWORKS" | grep -qE "SSID|BSSID"; then
                echo "   ✅ Found networks via NetworkManager:"
                echo "$NM_NETWORKS" | head -10
                echo ""
                
                # Check for saved connections first
                SAVED_CONNECTIONS=$(nmcli connection show 2>/dev/null | grep -i "wifi\|802-11" | head -5 || echo "")
                if [ -n "$SAVED_CONNECTIONS" ]; then
                    echo "   🔍 Found saved Wi-Fi connections - attempting to activate..."
                    FIRST_WIFI_CONN=$(echo "$SAVED_CONNECTIONS" | head -1 | awk '{print $1}' || echo "")
                    if [ -n "$FIRST_WIFI_CONN" ]; then
                        echo "   🔧 Attempting to connect to saved connection: $FIRST_WIFI_CONN"
                        if timeout 30 sudo nmcli connection up "$FIRST_WIFI_CONN" 2>/dev/null; then
                            sleep 5
                            if ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                                FIXES_APPLIED+=("Connected to saved Wi-Fi: $FIRST_WIFI_CONN") && echo "   ✅ SUCCESS! Connected to $FIRST_WIFI_CONN"
                            else
                                echo "   ⚠️  Connection attempt made but no IP yet"
                            fi
                        fi
                    fi
                fi
                
                # If still not connected, try wpa_supplicant
                if ! ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                    if [ -f "/etc/wpa_supplicant/wpa_supplicant.conf" ] && grep -q "network=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
                        echo "   🔍 Found wpa_supplicant configuration - attempting to use it..."
                        sudo systemctl stop NetworkManager 2>/dev/null || true
                        sleep 2
                        sudo wpa_supplicant -B -i $HOTEL_WIFI -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
                        sleep 5
                        sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null || true
                        sleep 5
                        sudo systemctl start NetworkManager 2>/dev/null || true
                        sleep 3
                        
                        if ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                            FIXES_APPLIED+=("Connected using wpa_supplicant configuration") && echo "   ✅ SUCCESS! Connected using wpa_supplicant config"
                        fi
                    fi
                fi
                
                if ! ip addr show $HOTEL_WIFI 2>/dev/null | grep -q "inet "; then
                    echo "   💡 Interface is ready for connection"
                    echo "   💡 Use nmtui to connect: sudo nmtui"
                    echo "   💡 Or use nmcli: sudo nmcli device wifi connect 'NetworkName' password 'password'"
                    FIXES_APPLIED+=("Prepared $HOTEL_WIFI for Wi-Fi connection")
                fi
            else
                echo "   ⚠️  Could not scan networks (interface may need more time)"
                echo "   💡 Steps to fix:"
                echo "      1. Check if hotel Wi-Fi router is in range and powered on"
                echo "      2. Use nmtui to connect: sudo nmtui"
                echo "      3. Or use nmcli: sudo nmcli device wifi list"
                FIXES_APPLIED+=("Prepared $HOTEL_WIFI for Wi-Fi connection")
            fi
        else
            echo "   Steps to fix:"
            echo "   1. Check if hotel Wi-Fi router is in range and powered on"
            echo "   2. Use nmtui to connect (NetworkManager is now enabled):"
            echo "      sudo nmtui"
            echo "      → Select 'Activate a connection'"
            echo "      → Select your hotel Wi-Fi network"
            echo "      → Enter password"
            echo "   3. Or use nmcli:"
            echo "      sudo nmcli device wifi list  # See available networks"
            echo "      sudo nmcli device wifi connect 'NetworkName' password 'password'"
        fi
        echo ""
    elif [ "$IFACE_HAS_IP" = "no" ]; then
        echo "🔴 CRITICAL: Hotel Wi-Fi ($HOTEL_WIFI) interface is UP but has NO IP address"
        echo "   → Interface is active but not connected to a network"
        echo "   → This blocks internet access"
        echo ""
        echo "   Steps to fix:"
        echo "   1. Use nmtui to connect: sudo nmtui"
        echo "   2. Or renew DHCP: sudo dhcpcd -n $HOTEL_WIFI"
        echo "   3. Check wpa_supplicant: sudo wpa_cli status"
        echo ""
    elif [ "$INTERNET_WORKING" = false ]; then
        echo "🟡 WARNING: Hotel Wi-Fi connected but no internet"
        echo "   → Check hotel Wi-Fi portal/login requirements"
        echo "   → Verify gateway is reachable"
        GATEWAY=$(ip route show default | awk '{print $3}' | head -1 || echo "")
        if [ -n "$GATEWAY" ]; then
            echo "   → Test gateway: ping $GATEWAY"
        fi
        echo ""
    fi
fi

# Use the TAILSCALE_IS_AUTHENTICATED variable set earlier in section 3
# If not set, check again
if [ -z "${TAILSCALE_IS_AUTHENTICATED+x}" ]; then
    TAILSCALE_AUTH_CHECK=$(sudo tailscale status 2>/dev/null || echo "")
    TAILSCALE_IS_AUTHENTICATED=false
    if [ -n "$TAILSCALE_AUTH_CHECK" ] && ! echo "$TAILSCALE_AUTH_CHECK" | grep -qi "logged out\|not logged in\|not logged"; then
        if echo "$TAILSCALE_AUTH_CHECK" | grep -qE "^100\.[0-9]+\.[0-9]+\.[0-9]+" || ip link show tailscale0 >/dev/null 2>&1; then
            TAILSCALE_IS_AUTHENTICATED=true
        fi
    fi
fi

if [ "$TAILSCALE_IS_AUTHENTICATED" = false ]; then
    echo "🟡 WARNING: Tailscale is logged out"
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "   → Internet is available, you can authenticate Tailscale"
        echo "   → Run: sudo tailscale up"
    else
        echo "   → Cannot authenticate without internet connection"
        echo "   → Fix hotel Wi-Fi connection first"
    fi
    echo ""
fi

echo "🔧 Quick Fixes to Try:"
echo "1. Fix DNS: sudo chattr -i /etc/resolv.conf && echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
echo "2. Test DNS: dig @8.8.8.8 google.com +short"
echo "3. Authenticate Tailscale (after DNS is fixed): sudo tailscale up"
echo "4. Restart Tailscale: sudo systemctl restart tailscaled"
echo "5. Restart access point: sudo systemctl restart hostapd dnsmasq"
echo "6. Check logs: sudo journalctl -u tailscaled -n 50"
echo "7. Check hostapd logs: sudo journalctl -u hostapd -n 50"
echo ""
echo "🔧 Fixes for Periodic Disconnects (30-60 min):"
echo "6. Check/Start watchdog service:"
echo "   sudo systemctl status tunnel-watchdog"
echo "   sudo systemctl start tunnel-watchdog  # if not running"
echo "   sudo journalctl -u tunnel-watchdog -f  # watch logs"
echo "7. NetworkManager should stay enabled for hotel Wi-Fi (wlan0) - this is correct!"
echo "   (NetworkManager managing wlan0 does NOT interfere with tunnel operation)"
if [ -n "$HOTEL_WIFI" ]; then
    echo "8. Renew DHCP lease manually: sudo dhcpcd -n $HOTEL_WIFI"
else
    echo "8. Renew DHCP lease manually: sudo dhcpcd -n wlan0"
fi
echo "9. Check Tailscale logs for timeouts: sudo journalctl -u tailscaled --since '1 hour ago'"
echo "10. Monitor connection: watch -n 30 './debug-tunnel.sh'"
echo "11. If watchdog not set up, run tunnel.sh to configure it"
echo ""
echo "📋 === WORKFLOW GUIDE ==="
echo ""
echo "When to use debug-tunnel.sh:"
echo "  - Wi-Fi connection issues (can't connect to hotel Wi-Fi)"
echo "  - DNS resolution problems"
echo "  - NetworkManager/nmtui not working"
echo "  - General network diagnostics and fixes"
echo ""
echo "When to use tunnel.sh:"
echo "  - Initial tunnel setup"
echo "  - After changing hotel Wi-Fi (to reconfigure tunnel)"
echo "  - This script keeps NetworkManager enabled for nmtui!"
echo ""
echo "Recommended workflow:"
echo "  1. Run ./tunnel.sh to set up tunnel (NetworkManager stays enabled for nmtui)"
echo "  2. Use nmtui anytime to connect to new hotel Wi-Fi: sudo nmtui"
echo "  3. If issues occur: Run ./debug-tunnel.sh to diagnose and fix"
echo "  4. After fixing: Tunnel continues working, no need to re-run tunnel.sh"
echo ""
echo "💡 Key Point: NetworkManager managing hotel Wi-Fi (wlan0) does NOT interfere"
echo "   with the tunnel. Only USB Wi-Fi (wlan1) is unmanaged (AP mode)."
echo ""

