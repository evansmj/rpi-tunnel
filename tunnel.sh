#!/usr/bin/env bash
set -e

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

echo "=== Loading configuration ==="

# Default configuration file locations
CONFIG_FILE=""
if [ -f "tunnel.conf" ]; then
    CONFIG_FILE="tunnel.conf"
    echo "✅ Using configuration: tunnel.conf"
elif [ -f "tunnel.conf.example" ]; then
    echo "❌ No configuration found!"
    echo "   Please copy tunnel.conf.example to tunnel.conf and customize it:"
    echo "   cp tunnel.conf.example tunnel.conf"
    echo "   nano tunnel.conf"
    exit 1
else
    echo "❌ No configuration files found!"
    echo "   Please ensure tunnel.conf.example exists in the current directory."
    exit 1
fi

# Load configuration
echo "Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"

# Validate required configuration
REQUIRED_VARS=(
    "TAILSCALE_EXIT_NODE_IP"
    "TAILSCALE_EXIT_NODE_NAME" 
    "TAILSCALE_EXPECTED_IP"
    "AP_SSID"
    "AP_PASSWORD"
    "AP_IP_RANGE"
    "AP_GATEWAY"
    "DHCP_START"
    "DHCP_END"
)

echo "Validating configuration..."
MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ Missing required configuration variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "   - $var"
    done
    echo "   Please check your configuration file: $CONFIG_FILE"
    exit 1
fi

echo "✅ Configuration loaded successfully"
echo "   Exit Node: $TAILSCALE_EXIT_NODE_NAME ($TAILSCALE_EXIT_NODE_IP)"
echo "   AP SSID: $AP_SSID"
echo "   AP Network: $AP_IP_RANGE.0/24"
echo ""

# =============================================================================
# DETECT Wi-Fi INTERFACES EARLY (needed for NetworkManager config functions)
# =============================================================================
echo "=== Detecting Wi-Fi interfaces ==="
WIFI_INTERFACES=$(iw dev 2>/dev/null | grep Interface | awk '{print $2}' || echo "")

if [ -z "$WIFI_INTERFACES" ]; then
    echo "⚠️  No Wi-Fi interfaces detected yet, using defaults"
    HOTEL_WIFI="wlan0"
    AP_WIFI="wlan1"
else
    echo "Found Wi-Fi interfaces: $WIFI_INTERFACES"

    DETECTED_ONBOARD=""
    DETECTED_USB=""

    for iface in $WIFI_INTERFACES; do
        IFACE_PATH="/sys/class/net/$iface"
        IS_USB=false
        if [ -d "$IFACE_PATH" ]; then
            if udevadm info -p "$IFACE_PATH" 2>/dev/null | grep -qi usb; then
                IS_USB=true
            fi
            if [ "$IS_USB" = false ] && readlink -f "$IFACE_PATH/device" 2>/dev/null | grep -qi usb; then
                IS_USB=true
            fi
        fi

        if [ "$IS_USB" = true ]; then
            if [ -z "$DETECTED_USB" ]; then
                DETECTED_USB="$iface"
                echo "  Detected USB Wi-Fi: $iface"
            fi
        else
            if [ -z "$DETECTED_ONBOARD" ]; then
                DETECTED_ONBOARD="$iface"
                echo "  Detected Onboard Wi-Fi: $iface"
            fi
        fi
    done

    # Fallbacks
    if [ -z "$DETECTED_ONBOARD" ]; then
        DETECTED_ONBOARD="wlan0"
        echo "  Warning: Using default wlan0 for onboard"
    fi
    if [ -z "$DETECTED_USB" ]; then
        DETECTED_USB="wlan1"
        echo "  Warning: Using default wlan1 for USB"
    fi

    # STANDARD ROLE ASSIGNMENT:
    # - Onboard (wlan0) -> connects to hotel Wi-Fi
    # - USB adapter (wlan1) -> creates access point (more range)
    HOTEL_WIFI="$DETECTED_ONBOARD"
    AP_WIFI="$DETECTED_USB"
fi

# For backward compatibility with rest of script
ONBOARD_WIFI="$HOTEL_WIFI"
USB_WIFI="$AP_WIFI"

echo ""
echo "Role Assignment:"
echo "  - Onboard Wi-Fi ($HOTEL_WIFI): Will connect to hotel Wi-Fi"
echo "  - USB Wi-Fi ($AP_WIFI): Will create access point for your devices (better range)"
echo ""

# =============================================================================
# CRITICAL: CONFIGURE NetworkManager
# - HOTEL_WIFI (onboard, $HOTEL_WIFI): Must be MANAGED for hotel connection
# - AP_WIFI (USB adapter, $AP_WIFI): Must be UNMANAGED for hostapd access point
# =============================================================================
echo "=== Pre-flight check: Configuring Wi-Fi interface management ==="

# Check if hotel WiFi interface exists
if ! ip link show "$HOTEL_WIFI" >/dev/null 2>&1; then
    echo "❌ ERROR: $HOTEL_WIFI interface not found!"
    echo "   Make sure your onboard Wi-Fi is working."
    exit 1
fi

# Check if AP interface exists
if ! ip link show "$AP_WIFI" >/dev/null 2>&1; then
    echo "❌ ERROR: $AP_WIFI interface not found!"
    echo "   Make sure your USB Wi-Fi adapter is connected."
    exit 1
fi

NM_CONF="/etc/NetworkManager/NetworkManager.conf"
NM_CONF_CHANGED=false
echo "   Checking NetworkManager configuration..."

# Remove any old device-specific sections that might conflict
for old_section in "device-wlan0" "device-wlan1" "device-hotel-wifi" "device-ap-wifi"; do
    if grep -q "\[$old_section\]" "$NM_CONF" 2>/dev/null; then
        echo "   Removing old [$old_section] section..."
        sudo sed -i "/\[$old_section\]/,/^\[/{ /^\[/!d; /\[$old_section\]/d; }" "$NM_CONF" 2>/dev/null || true
        NM_CONF_CHANGED=true
    fi
done

# Clean up any existing unmanaged-devices line
if grep -q "^unmanaged-devices=" "$NM_CONF" 2>/dev/null; then
    echo "   Cleaning up old unmanaged-devices setting..."
    sudo sed -i "/^unmanaged-devices=/d" "$NM_CONF" 2>/dev/null || true
    NM_CONF_CHANGED=true
fi

# Add proper configuration
echo "   Adding NetworkManager configuration..."
sudo bash -c "cat >> $NM_CONF" << EOF

# Hotel Wi-Fi interface (onboard) - MANAGED by NetworkManager
[device-hotel-wifi]
match-device=interface-name:$HOTEL_WIFI
managed=1

# Access Point interface (USB adapter) - UNMANAGED (hostapd controls it)
[device-ap-wifi]
match-device=interface-name:$AP_WIFI
managed=0

[keyfile]
unmanaged-devices=interface-name:$AP_WIFI
EOF
NM_CONF_CHANGED=true

# Ensure HOTEL_WIFI is NOT in unmanaged-devices (it should be managed)
if grep -q "unmanaged-devices.*$HOTEL_WIFI" "$NM_CONF" 2>/dev/null; then
    echo "   Removing $HOTEL_WIFI from unmanaged-devices..."
    sudo sed -i "s/interface-name:$HOTEL_WIFI[,;]*//g" "$NM_CONF" 2>/dev/null || true
    NM_CONF_CHANGED=true
fi

# Restart NetworkManager if config changed
if [ "$NM_CONF_CHANGED" = true ]; then
    echo "   Restarting NetworkManager to apply config changes..."
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 5
fi

# CRITICAL FIX: Check if hotel WiFi interface is managed by NetworkManager
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    HOTEL_WIFI_STATE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" | awk '{print $3}' || echo "")
    if [ "$HOTEL_WIFI_STATE" = "unmanaged" ] || [ "$HOTEL_WIFI_STATE" = "unavailable" ]; then
        echo "   ⚠️  $HOTEL_WIFI (USB adapter) is $HOTEL_WIFI_STATE - fixing before proceeding..."
        sudo nmcli device set "$HOTEL_WIFI" managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        echo "   Restarting NetworkManager to apply changes..."
        sudo systemctl restart NetworkManager 2>/dev/null || true
        sleep 5
        # Verify the fix worked
        HOTEL_WIFI_STATE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" | awk '{print $3}' || echo "")
        if [ "$HOTEL_WIFI_STATE" = "unmanaged" ]; then
            echo "   ❌ Failed to set $HOTEL_WIFI as managed - check NetworkManager.conf manually"
        else
            echo "   ✅ $HOTEL_WIFI is now: $HOTEL_WIFI_STATE"
        fi
    else
        echo "   ✅ $HOTEL_WIFI (USB adapter) is managed by NetworkManager ($HOTEL_WIFI_STATE)"
    fi
else
    echo "   ⚠️  NetworkManager is not running - starting it..."
    sudo systemctl start NetworkManager 2>/dev/null || true
    sleep 3
fi

# Ensure AP interface is unmanaged (for hostapd)
AP_WIFI_STATE=$(nmcli device status 2>/dev/null | grep "^$AP_WIFI" | awk '{print $3}' || echo "")
if [ "$AP_WIFI_STATE" != "unmanaged" ]; then
    echo "   Setting $AP_WIFI (onboard) to unmanaged for access point..."
    sudo nmcli device set "$AP_WIFI" managed no 2>/dev/null || true
fi

# AUTO-CONNECT: If hotel WiFi is managed but not connected, try to connect to a saved network
HOTEL_WIFI_STATE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" | awk '{print $3}' || echo "")
if [ "$HOTEL_WIFI_STATE" = "disconnected" ]; then
    echo "   $HOTEL_WIFI is disconnected - attempting to auto-connect to saved networks..."

    # First, scan for available networks
    nmcli device wifi rescan ifname "$HOTEL_WIFI" 2>/dev/null || true
    sleep 3

    # Get list of available SSIDs
    AVAILABLE_SSIDS=$(nmcli -t -f SSID device wifi list ifname "$HOTEL_WIFI" 2>/dev/null | sort -u | grep -v "^$" || echo "")

    # Get list of saved connections (wifi only)
    SAVED_CONNECTIONS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi$" | cut -d: -f1 || echo "")

    # Try to connect to any saved network that's available
    CONNECTED=false
    for saved in $SAVED_CONNECTIONS; do
        if echo "$AVAILABLE_SSIDS" | grep -qx "$saved"; then
            echo "   Found saved network '$saved' - attempting to connect..."
            if nmcli device wifi connect "$saved" ifname "$HOTEL_WIFI" 2>/dev/null; then
                echo "   ✅ Connected to '$saved'"
                CONNECTED=true
                sleep 3
                break
            else
                echo "   ⚠️  Failed to connect to '$saved', trying next..."
            fi
        fi
    done

    if [ "$CONNECTED" = false ]; then
        echo "   ⚠️  Could not auto-connect to any saved network"
        echo "   Available networks:"
        nmcli device wifi list ifname "$HOTEL_WIFI" 2>/dev/null | head -10
    fi
fi

echo ""
echo "=== Checking hotel Wi-Fi connection (via USB adapter: $HOTEL_WIFI) ==="

# Get the actual interface state (handle all states, not just UP/DOWN)
HOTEL_IFACE_STATE=$(ip link show "$HOTEL_WIFI" 2>/dev/null | grep -oP 'state \K\S+' || echo "UNKNOWN")
echo "   Interface state: $HOTEL_IFACE_STATE"

# Check if we have an IP address on hotel WiFi interface
HOTEL_WIFI_IP=$(ip addr show "$HOTEL_WIFI" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
if [ -n "$HOTEL_WIFI_IP" ]; then
    echo "   IP address: $HOTEL_WIFI_IP"
else
    echo "   IP address: NONE"
fi

# Test internet connectivity BEFORE making any changes
echo "   Testing internet connectivity..."
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ Internet connectivity confirmed - proceeding with tunnel setup"
else
    echo ""
    echo "❌ NO INTERNET CONNECTION DETECTED!"
    echo ""
    echo "   You must connect to hotel Wi-Fi FIRST before running this script."
    echo ""
    echo "   📋 To connect to hotel Wi-Fi:"
    echo "      1. Run: sudo nmtui"
    echo "      2. Select 'Activate a connection'"
    echo "      3. Choose your hotel's Wi-Fi network"
    echo "      4. Enter the password if required"
    echo "      5. Complete any captive portal login in a browser"
    echo "      6. Test with: ping -c 3 8.8.8.8"
    echo "      7. Run this script again: ./tunnel.sh"
    echo ""

    # Show current status for debugging
    echo "   📊 Current Wi-Fi status:"
    nmcli device status 2>/dev/null | grep -E "^(DEVICE|wlan)" || echo "   Could not get device status"
    echo ""
    echo "❌ EXITING: Please connect to hotel Wi-Fi first, then run this script again."
    exit 1
fi
echo ""

# =============================================================================
# HELPER FUNCTION: Ensure NetworkManager config is correct and wlan0 stays managed
# =============================================================================
ensure_nm_wlan0_managed() {
    # This function ensures wlan0 is NOT in unmanaged-devices and stays managed
    # Call this BEFORE any NetworkManager restart to prevent wlan0 from becoming unmanaged
    # CRITICAL: Removes ALL unmanaged-devices lines first to prevent duplicates
    
    # Ensure variables have defaults if not set
    local onboard_wifi="${ONBOARD_WIFI:-wlan0}"
    local usb_wifi="${USB_WIFI:-wlan1}"
    
    # Step 1: Remove ALL unmanaged-devices lines first (prevents duplicates)
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    
    # Step 2: Remove wlan0 from unmanaged-devices if present (safety check)
    # This check happens AFTER removing all lines, so it's just a safety net
    # We check the file again in case something added wlan0 back
    if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$onboard_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$onboard_wifi.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        # Also handle semicolon-separated lists
        sudo sed -i "s/unmanaged-devices=interface-name:$onboard_wifi;interface-name:$usb_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$usb_wifi;interface-name:$onboard_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Step 2: Clean up duplicate [keyfile] sections
    KEYFILE_COUNT=$(grep -c "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo "0")
    if [ "$KEYFILE_COUNT" -gt 1 ]; then
        # Remove all [keyfile] sections and add one clean one
        sudo awk -v usb_wifi="$usb_wifi" '
            BEGIN { in_keyfile=0; keyfile_added=0 }
            /^\[keyfile\]/ { 
                if (!keyfile_added) {
                    print ""
                    print "[keyfile]"
                    print "unmanaged-devices=interface-name:" usb_wifi
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
                    print "unmanaged-devices=interface-name:" usb_wifi
                }
            }
        ' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_clean_func 2>/dev/null
        if [ -f /tmp/nm_conf_clean_func ]; then
            sudo mv /tmp/nm_conf_clean_func /etc/NetworkManager/NetworkManager.conf
        fi
    else
        # No duplicate [keyfile] sections, but ensure [keyfile] section exists with unmanaged-devices
        if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        fi
        # Add unmanaged-devices line ONLY if it doesn't exist (we already removed all above)
        if ! grep -q "unmanaged-devices=interface-name:$usb_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "unmanaged-devices=interface-name:$usb_wifi" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        fi
    fi
    
    # Step 3: Final safety check - ensure wlan0 is NOT in unmanaged-devices
    if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$onboard_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        # This should never happen, but fix it if it does
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$onboard_wifi.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        # Also handle semicolon-separated lists
        sudo sed -i "s/unmanaged-devices=interface-name:$onboard_wifi;interface-name:$usb_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$usb_wifi;interface-name:$onboard_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Step 4: Set wlan0 to managed (before any restart)
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        sudo nmcli device set $onboard_wifi managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
    fi
}

# =============================================================================
# HELPER: Force wlan0 to be managed after NetworkManager restart
# =============================================================================
force_wlan0_managed_after_restart() {
    local onboard_wifi="${ONBOARD_WIFI:-wlan0}"
    
    # Wait for NetworkManager to fully start
    sleep 3
    
    # Set to managed multiple times (NetworkManager sometimes takes time to apply)
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sudo nmcli device set $onboard_wifi managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 0.5
    done
    
    # Final check
    sleep 2
    NM_STATUS=$(nmcli device status 2>/dev/null | grep "^$onboard_wifi" | awk '{print $3}' || echo "unknown")
    if [ "$NM_STATUS" = "unmanaged" ] || [ "$NM_STATUS" = "unavailable" ]; then
        echo "   ⚠️  wlan0 still unmanaged after restart - trying one more time..."
        for i in 1 2 3 4 5; do
            sudo nmcli device set $onboard_wifi managed yes 2>/dev/null || true
            sleep 1
        done
        sleep 2
        NM_STATUS=$(nmcli device status 2>/dev/null | grep "^$onboard_wifi" | awk '{print $3}' || echo "unknown")
    fi
    
    if [ "$NM_STATUS" != "unmanaged" ] && [ "$NM_STATUS" != "unavailable" ]; then
        echo "   ✅ wlan0 is now managed: $NM_STATUS"
        return 0
    else
        echo "   ❌ wlan0 still unmanaged: $NM_STATUS"
        return 1
    fi
}

# =============================================================================
# HELPER: Ensure NetworkManager config file is correct (prevents wlan0 from becoming unmanaged)
# =============================================================================
ensure_nm_config_correct() {
    # This function ensures the config file has:
    # 1. Only ONE [keyfile] section
    # 2. Only ONE unmanaged-devices line (with ONLY USB Wi-Fi, NOT onboard Wi-Fi)
    # 3. No duplicate lines
    
    # Ensure variables have defaults if not set
    local onboard_wifi="${ONBOARD_WIFI:-wlan0}"
    local usb_wifi="${USB_WIFI:-wlan1}"
    
    # Step 1: Remove ALL unmanaged-devices lines first
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    
    # Step 2: Remove all [keyfile] sections
    sudo sed -i '/^\[keyfile\]$/,/^\[/ { /^\[keyfile\]$/d; /^\[/!d; }' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i '/^\[keyfile\]$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    
    # Step 3: Add ONE clean [keyfile] section with ONLY wlan1
    if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    # Add unmanaged-devices line ONLY if it doesn't exist
    if ! grep -q "unmanaged-devices=interface-name:$usb_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "unmanaged-devices=interface-name:$usb_wifi" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    
    # Step 4: Verify wlan0 is NOT in unmanaged-devices (safety check)
    if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$onboard_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        # Remove wlan0 from the line
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$onboard_wifi.*/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$onboard_wifi;interface-name:$usb_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$usb_wifi;interface-name:$onboard_wifi/unmanaged-devices=interface-name:$usb_wifi/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Step 5: Final verification - ensure no empty or malformed unmanaged-devices lines
    # Remove any lines with empty interface names (these can cause NetworkManager to default incorrectly)
    sudo sed -i '/unmanaged-devices=interface-name:$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i '/unmanaged-devices=interface-name:\s*$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    
    # If we removed the line and usb_wifi is set, add it back
    if [ -n "$usb_wifi" ] && ! grep -q "unmanaged-devices=interface-name:$usb_wifi" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
            echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        fi
        echo "unmanaged-devices=interface-name:$usb_wifi" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
}

# Call helper function at start to ensure config is correct from the beginning
ensure_nm_wlan0_managed

echo "=== Resetting network configuration (preserving Tailscale) ==="

# Ensure config file is correct BEFORE doing anything
ensure_nm_config_correct

# Stop services that might interfere
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# Reset network interfaces (except Tailscale)
# CRITICAL: NEVER reset wlan0 if NetworkManager is running - it will break nmtui!
echo "Resetting network interfaces..."
for iface in wlan0 wlan1; do
    if ip link show $iface >/dev/null 2>&1; then
        echo "  Resetting $iface..."
        
        # For wlan0: NEVER reset if NetworkManager is running - it will mark it as unmanaged!
        if [ "$iface" = "wlan0" ] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "    (wlan0 - SKIPPING reset to preserve NetworkManager management)"
            echo "    (NetworkManager must manage wlan0 for nmtui to work)"
            echo "    (No manual reset needed - NetworkManager handles wlan0)"
            # Don't touch wlan0 at all - let NetworkManager manage it completely
            continue
        else
            # For wlan1 or if NetworkManager not running: full reset
            sudo ip link set $iface down 2>/dev/null || true
            sudo ip addr flush dev $iface 2>/dev/null || true
            sudo iw dev $iface set type managed 2>/dev/null || true
            sudo ip link set $iface up 2>/dev/null || true
        fi
    fi
done

# DON'T restart NetworkManager if it's already running and managing wlan0
# Restarting NetworkManager can cause it to lose track of wlan0
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    # Check if wlan0 is already being managed
    NM_WLAN0_STATUS=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
    if [ -n "$NM_WLAN0_STATUS" ] && ! echo "$NM_WLAN0_STATUS" | grep -qE "(unmanaged|unavailable)"; then
        echo "NetworkManager is managing wlan0 - no restart needed (preserving nmtui)"
        # Just ensure it stays managed
        sudo nmcli device set wlan0 managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
    else
        # wlan0 is unmanaged - try to fix without restarting NetworkManager first
        echo "wlan0 appears unmanaged - attempting to fix without restart..."
        sudo nmcli device set wlan0 managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 2
        NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
        if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
            echo "✅ Fixed! wlan0 is now managed: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
        else
            # Only restart as last resort
            echo "Restarting NetworkManager as last resort..."
            ensure_nm_wlan0_managed  # Ensure config is correct before restart
            sudo systemctl restart NetworkManager 2>/dev/null || true
            force_wlan0_managed_after_restart  # Force wlan0 to stay managed after restart
        fi
    fi
fi

# Reset routing table (preserve hotel Wi-Fi route, remove broken Tailscale routes)
echo "Cleaning up routing table..."
sudo ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true
sudo ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true
sudo ip route del default dev tailscale0 2>/dev/null || true

# Reset DNS to use hotel Wi-Fi DNS temporarily for package updates
echo "Temporarily resetting DNS for package updates..."
sudo cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true

# Stop systemd-resolved if it's managing DNS
sudo systemctl stop systemd-resolved 2>/dev/null || true

# Force DNS to use public DNS servers
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf
echo "nameserver ${FALLBACK_DNS_PRIMARY:-8.8.8.8}" | sudo tee /etc/resolv.conf > /dev/null
echo "nameserver ${FALLBACK_DNS_SECONDARY:-1.1.1.1}" | sudo tee -a /etc/resolv.conf > /dev/null
echo "nameserver 192.168.1.1" | sudo tee -a /etc/resolv.conf > /dev/null

# Make it immutable temporarily to prevent Tailscale from overwriting
sudo chattr +i /etc/resolv.conf 2>/dev/null || true

# Test internet connectivity (early check)
echo "Testing internet connectivity..."
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ Internet connectivity confirmed"
    if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        echo "✅ DNS working"
    else
        echo "⚠️  Internet works but DNS resolution may be slow"
    fi
else
    echo "❌ No internet connectivity detected"
    echo ""
    echo "🔧 ATTEMPTING AUTO-TROUBLESHOOTING..."
    echo ""
    
    ISSUES_FOUND=()
    AUTO_FIXED=false
    
    # Check if Wi-Fi interface exists
    if ! ip link show wlan0 >/dev/null 2>&1; then
        echo "❌ wlan0 interface does not exist"
        ISSUES_FOUND+=("wlan0 interface missing")
    else
        echo "✅ wlan0 interface exists"
        WLAN0_STATE=$(ip link show wlan0 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
        echo "   Interface state: $WLAN0_STATE"
        
        # Try to bring interface up if it's down
        if [ "$WLAN0_STATE" = "DOWN" ]; then
            echo "   🔧 Attempting to bring interface up..."
            
            # Fix 1: Check rfkill (hardware/software blocks)
            if command -v rfkill >/dev/null 2>&1; then
                RFKILL_BLOCKED=$(sudo rfkill list wifi 2>/dev/null | grep -c "yes" || echo "0")
                RFKILL_BLOCKED=$(echo "$RFKILL_BLOCKED" | tr -d '\n\r ' | head -1)
                RFKILL_BLOCKED=${RFKILL_BLOCKED:-0}
                if [ "$RFKILL_BLOCKED" -gt "0" ] 2>/dev/null; then
                    echo "   🔧 Wi-Fi is blocked by rfkill - unblocking..."
                    sudo rfkill unblock wifi 2>/dev/null && sleep 1
                fi
            fi
            
            # Fix 2: Ensure NetworkManager is managing it (needed for some interfaces)
            if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                echo "   🔧 Ensuring NetworkManager is managing wlan0..."
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 1
            fi
            
            # Fix 3: Stop wpa_supplicant if it's interfering
            if systemctl is-active --quiet wpa_supplicant 2>/dev/null || pgrep -x wpa_supplicant >/dev/null 2>&1; then
                echo "   🔧 Stopping wpa_supplicant (may be blocking interface)..."
                sudo systemctl stop wpa_supplicant 2>/dev/null || true
                sudo pkill -x wpa_supplicant 2>/dev/null || true
                sleep 1
            fi
            
            # Fix 4: Set interface type to managed (required before bringing up)
            echo "   🔧 Setting interface type to managed..."
            sudo iw dev wlan0 set type managed 2>/dev/null || true
            sleep 1
            
            # Fix 5: Try to bring interface up
            # CRITICAL: Use nmcli if NetworkManager is running, NOT ip link set!
            # Using ip link set while NetworkManager is managing wlan0 causes it to become unmanaged
            if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                echo "   🔧 Bringing interface up via NetworkManager (preserving management)..."
                # Use NetworkManager to bring it up - this keeps it managed
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 2
                # Try to activate any saved connection
                SAVED_CONN=$(nmcli connection show 2>/dev/null | grep -E "wifi|wlan0" | head -1 | awk '{print $1}' || echo "")
                if [ -n "$SAVED_CONN" ]; then
                    echo "   🔧 Attempting to activate saved connection: $SAVED_CONN"
                    sudo nmcli connection up "$SAVED_CONN" 2>/dev/null || true
                    sleep 3
                fi
            else
                echo "   🔧 Bringing interface up (NetworkManager not running)..."
                sudo ip link set wlan0 up 2>/dev/null && sleep 2
            fi
            
            # Check if it worked
            WLAN0_STATE=$(ip link show wlan0 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
            if [ "$WLAN0_STATE" = "UP" ]; then
                echo "   ✅ Interface is now UP"
                AUTO_FIXED=true
            else
                echo "   ❌ Failed to bring interface up"
                
                # Check for hardware issues
                if dmesg | tail -20 | grep -qi "wlan0.*error\|wlan0.*fail\|wlan0.*firmware"; then
                    echo "   ⚠️  Possible hardware/driver issue detected in system logs"
                    ISSUES_FOUND+=("Interface DOWN - possible hardware/driver issue (check dmesg)")
                else
                    ISSUES_FOUND+=("Interface is DOWN and cannot be brought up")
                fi
                
                # Try one more thing: reload driver module
                DRIVER_MODULE=$(ethtool -i wlan0 2>/dev/null | grep driver | awk '{print $2}' || echo "")
                if [ -n "$DRIVER_MODULE" ]; then
                    echo "   🔧 Attempting to reload driver module: $DRIVER_MODULE"
                    sudo modprobe -r $DRIVER_MODULE 2>/dev/null && sleep 1
                    sudo modprobe $DRIVER_MODULE 2>/dev/null && sleep 2
                    # CRITICAL: Use nmcli if NetworkManager is running
                    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                        sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                        sudo nmcli radio wifi on 2>/dev/null || true
                        sleep 2
                    else
                        sudo ip link set wlan0 up 2>/dev/null && sleep 2
                    fi
                    WLAN0_STATE=$(ip link show wlan0 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
                    if [ "$WLAN0_STATE" = "UP" ]; then
                        echo "   ✅ Interface is now UP after driver reload!"
                        AUTO_FIXED=true
                    fi
                fi
            fi
        fi
        
        # Check if it has an IP address
        if [ "$WLAN0_STATE" = "UP" ]; then
            if ip addr show wlan0 | grep -q "inet "; then
                WLAN0_IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
                echo "   ✅ Has IP address: $WLAN0_IP"
                
                # Check gateway
                GATEWAY=$(ip route show default | awk '{print $3}' | head -1 || echo "")
                if [ -n "$GATEWAY" ]; then
                    echo "   Gateway: $GATEWAY"
                    if ping -c 1 -W 2 $GATEWAY >/dev/null 2>&1; then
                        echo "   ✅ Gateway is reachable"
                    else
                        echo "   ❌ Gateway is NOT reachable"
                        ISSUES_FOUND+=("Gateway $GATEWAY not reachable")
                        # Try to renew DHCP
                        echo "   🔧 Attempting to renew DHCP lease..."
                        sudo dhcpcd -n wlan0 2>/dev/null && sleep 3
                        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                            echo "   ✅ Internet connectivity restored!"
                            AUTO_FIXED=true
                        fi
                    fi
                else
                    echo "   ❌ No default gateway configured"
                    ISSUES_FOUND+=("No default gateway")
                fi
            else
                echo "   ❌ No IP address assigned (not connected to Wi-Fi network)"
                ISSUES_FOUND+=("No IP address - not connected to Wi-Fi")
                
                # Check if NetworkManager can help
                if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                    echo "   🔧 NetworkManager is running - checking for saved connections..."
                    if nmcli connection show --active 2>/dev/null | grep -q wlan0; then
                        echo "   🔧 Attempting to activate saved connection..."
                        SAVED_CONN=$(nmcli connection show 2>/dev/null | grep wlan0 | head -1 | awk '{print $1}' || echo "")
                        if [ -n "$SAVED_CONN" ]; then
                            sudo nmcli connection up "$SAVED_CONN" 2>/dev/null && sleep 5
                            if ip addr show wlan0 | grep -q "inet "; then
                                echo "   ✅ Connected to saved Wi-Fi network!"
                                AUTO_FIXED=true
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    # Test again after auto-fixes
    if [ "$AUTO_FIXED" = true ]; then
        echo ""
        echo "🔄 Re-testing internet connectivity..."
        sleep 2
        
        # Also ensure NetworkManager recognizes wlan0 after auto-fix
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "   🔧 Ensuring NetworkManager recognizes wlan0 after auto-fix..."
            sudo nmcli device set wlan0 managed yes 2>/dev/null || true
            sudo nmcli radio wifi on 2>/dev/null || true
            sleep 3
            # Verify
            NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
            if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
                echo "   ✅ NetworkManager recognizes wlan0: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
            else
                echo "   ⚠️  NetworkManager may not recognize wlan0 - fixing WITHOUT restart..."
                # CRITICAL: DO NOT restart NetworkManager - it will set wlan0 to unmanaged!
                # Instead, verify config file and set to managed multiple times
                if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                    echo "   ⚠️  Config file has wlan0 in unmanaged-devices! Fixing..."
                    sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
                    sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
                    sudo nmcli general reload 2>/dev/null || true
                    sleep 2
                fi
                # Set to managed multiple times WITHOUT restarting
                for attempt in 1 2 3 4 5 6 7 8; do
                    sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                    sleep 0.5
                    sudo nmcli radio wifi on 2>/dev/null || true
                    sleep 0.5
                done
                sleep 2
                # Check again
                NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
                if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
                    echo "   ✅ Fixed! wlan0 is now: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
                else
                    echo "   ⚠️  Still unmanaged - but NOT restarting NetworkManager (would make it worse)"
                fi
            fi
        fi
        
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "✅ Internet connectivity restored! Continuing..."
        else
            AUTO_FIXED=false
        fi
    fi
    
    # If still no internet, ensure NetworkManager recognizes wlan0 before exiting
    # (Even if internet is broken, we want nmtui to work)
    # CRITICAL: DO NOT restart NetworkManager here - it will set wlan0 to unmanaged!
    if [ "$AUTO_FIXED" = false ] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo ""
        echo "🔧 Ensuring NetworkManager recognizes wlan0 (for nmtui) before exiting..."
        
        # First, verify config file is correct (don't restart NetworkManager!)
        if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "   ⚠️  Config file has wlan0 in unmanaged-devices! Fixing..."
            sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            # Reload config WITHOUT restarting
            sudo nmcli general reload 2>/dev/null || true
            sleep 2
        fi
        
        # Set to managed multiple times WITHOUT restarting NetworkManager
        for attempt in 1 2 3 4 5; do
            sudo nmcli device set wlan0 managed yes 2>/dev/null || true
            sleep 1
            sudo nmcli radio wifi on 2>/dev/null || true
            sleep 1
        done
        
        # Final check with delay to catch any reversions
        sleep 3
        NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
        
        # Also verify config file one more time
        if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "   ⚠️  Config file STILL has wlan0 in unmanaged-devices! Fixing again..."
            sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo nmcli general reload 2>/dev/null || true
            sleep 2
            # Set to managed again
            for i in 1 2 3 4 5; do
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sleep 0.5
            done
            sleep 2
            NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
        fi
        
        # Check the actual status - need to verify it's NOT unmanaged (explicit check)
        WLAN0_STATUS=$(echo "$NM_WLAN0_FINAL" | awk '{print $3}' || echo "unknown")
        if [ -n "$NM_WLAN0_FINAL" ] && [ "$WLAN0_STATUS" != "unmanaged" ] && [ "$WLAN0_STATUS" != "unavailable" ]; then
            echo "   ✅ NetworkManager recognizes wlan0: $WLAN0_STATUS"
            echo "   ✅ nmtui should show wireless networks"
            # Show config file contents for debugging
            echo "   📋 Config file unmanaged-devices: $(grep 'unmanaged-devices' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo 'none')"
        else
            echo "   ⚠️  wlan0 status: $(echo "$NM_WLAN0_FINAL" | awk '{print $3}' || echo 'not found')"
            echo "   📋 Config file unmanaged-devices: $(grep 'unmanaged-devices' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo 'none')"
            echo "   🔧 Attempting AGGRESSIVE fix to force wlan0 to be managed..."
            
            # AGGRESSIVE FIX: Ensure config is perfect, then force NetworkManager to apply it
            ensure_nm_config_correct
            
            # Remove any NetworkManager connection profiles that might be interfering
            sudo nmcli connection delete wlan0 2>/dev/null || true
            
            # Force reload and set managed with multiple attempts
            sudo nmcli general reload 2>/dev/null || true
            sleep 2
            
            # Set to managed 10 times with delays
            for i in 1 2 3 4 5 6 7 8 9 10; do
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 0.3
            done
            
            # Check one more time
            sleep 2
            NM_FINAL_CHECK=$(nmcli device status 2>/dev/null | grep "^wlan0" || echo "")
            WLAN0_FINAL_STATUS=$(echo "$NM_FINAL_CHECK" | awk '{print $3}' || echo "unknown")
            if [ -n "$NM_FINAL_CHECK" ] && [ "$WLAN0_FINAL_STATUS" != "unmanaged" ] && [ "$WLAN0_FINAL_STATUS" != "unavailable" ]; then
                echo "   ✅ AGGRESSIVE fix succeeded! wlan0 is now: $WLAN0_FINAL_STATUS"
            else
                # Last resort: restart NetworkManager (config is correct now, so restart should help)
                echo "   ⚠️  Reload didn't work - restarting NetworkManager (config is correct)..."
                ensure_nm_wlan0_managed  # Ensure config is perfect before restart
                sudo systemctl restart NetworkManager 2>/dev/null || true
                if force_wlan0_managed_after_restart; then
                    echo "   ✅ Restart succeeded! wlan0 is now managed"
                else
                    echo "   ❌ Restart failed. wlan0 still unmanaged"
                    echo "   📋 Manual fix: Run ./fix-wlan0-unmanaged.sh"
                    echo "   📋 Or run these commands:"
                    echo "      sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
                    echo "      echo '[keyfile]' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
                    echo "      echo 'unmanaged-devices=interface-name:$USB_WIFI' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
                    echo "      sudo systemctl restart NetworkManager"
                    echo "      sleep 5"
                    echo "      sudo nmcli device set wlan0 managed yes"
                    echo "      nmcli device status | grep wlan0"
                fi
            fi
        fi
    fi
    
    # If still no internet, save diagnostic commands and exit
    if [ "$AUTO_FIXED" = false ]; then
        echo ""
        echo "❌ Auto-troubleshooting did not resolve the issue"
        echo ""
        echo "📋 Issues found:"
        for issue in "${ISSUES_FOUND[@]}"; do
            echo "   - $issue"
        done
        echo ""
        
        # Save diagnostic commands to a file
        DIAG_FILE="internet-diagnostics.txt"
        cat > "$DIAG_FILE" << 'DIAGEOF'
# Internet Connection Diagnostic Commands
# Run these commands to troubleshoot your internet connection

# 1. Check if Wi-Fi interface is up
ip link show wlan0

# 2. Check if connected to a Wi-Fi network (look for 'inet' line with IP address)
ip addr show wlan0

# 3. Check if NetworkManager sees Wi-Fi networks
sudo nmcli device wifi list

# 4. Check NetworkManager connection status
nmcli device status

# 5. Check routing table (should show 'default via <gateway>' route)
ip route show

# 6. Test gateway connectivity (if you have an IP)
GATEWAY=$(ip route show default | awk '{print $3}')
echo "Gateway: $GATEWAY"
ping -c 3 $GATEWAY

# 7. Connect to Wi-Fi network (if not connected)
sudo nmtui
# Select 'Activate a connection' → choose your hotel Wi-Fi → enter password

# 8. Check Wi-Fi interface details (should show ESSID if connected)
iwconfig wlan0

# 9. Check if hotel Wi-Fi requires portal/login
curl -I http://google.com
# If redirected, open browser and complete login

# 10. Test DNS resolution
ping -c 1 8.8.8.8
ping -c 1 google.com

# 11. Check rfkill (hardware/software Wi-Fi blocks)
sudo rfkill list wifi
# If blocked, unblock with: sudo rfkill unblock wifi

# 12. Check NetworkManager logs
sudo journalctl -u NetworkManager -n 50

# 13. Check system logs for network issues
sudo journalctl --since "10 minutes ago" | grep -i "network\|wifi\|wlan"

# 14. Check for hardware/driver errors
dmesg | grep -i "wlan0\|wifi\|firmware" | tail -20

# 15. Check driver module
ethtool -i wlan0
# If driver found, try reloading: sudo modprobe -r <driver> && sudo modprobe <driver>

# 16. Check if interface exists in system
ls -la /sys/class/net/ | grep wlan0

# 17. Check interface capabilities
iw phy | grep -A 10 "Wiphy"

# 18. Try manual interface bring-up with more verbose output
sudo ip link set wlan0 up
# Check for errors in output

# 19. Check if NetworkManager is managing the interface
nmcli device status | grep wlan0
# If unmanaged, try: sudo nmcli device set wlan0 managed yes

# 20. Check wpa_supplicant status (may be blocking)
sudo systemctl status wpa_supplicant
# If running and causing issues: sudo systemctl stop wpa_supplicant
DIAGEOF
        
        echo "📄 Diagnostic commands saved to: $DIAG_FILE"
        echo "   Run: cat $DIAG_FILE"
        echo ""
        echo "❌ EXITING: Internet connection required for tunnel setup"
        echo "   Please fix your internet connection, then run this script again"
        exit 1
    fi
fi

# Reset NetworkManager configuration
echo "Resetting NetworkManager configuration..."
# DON'T remove unmanaged-devices here - let ensure_nm_wlan0_managed handle it properly
# Removing all lines here can cause wlan0 to become unmanaged when NetworkManager restarts

# Remove old configuration files
echo "Cleaning up old configuration files..."
sudo rm -f /etc/hostapd/hostapd.conf
sudo rm -f /etc/dnsmasq.conf.backup
sudo mv /etc/dnsmasq.conf.backup /etc/dnsmasq.conf 2>/dev/null || true

# Reset dhcpcd configuration
echo "Resetting dhcpcd configuration..."
sudo cp /etc/dhcpcd.conf /etc/dhcpcd.conf.backup 2>/dev/null || true
sudo sed -i '/# Access Point interface/,$d' /etc/dhcpcd.conf 2>/dev/null || true

# Restart NetworkManager to apply changes
ensure_nm_wlan0_managed  # Ensure config is correct before restart
sudo systemctl restart NetworkManager 2>/dev/null || true
force_wlan0_managed_after_restart  # Force wlan0 to stay managed after restart

echo "✅ Network reset complete. Starting fresh configuration..."
echo ""

# Wait for network connectivity before updating packages
echo "=== Waiting for network connectivity ==="
echo "Checking internet connectivity before updating packages..."
MAX_WAIT=60
WAIT_COUNT=0
NETWORK_READY=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Network connectivity confirmed"
        NETWORK_READY=1
        break
    fi
    echo "   Waiting for network... ($WAIT_COUNT/$MAX_WAIT seconds)"
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done

if [ $NETWORK_READY -eq 0 ]; then
    echo ""
    echo "❌ ERROR: Network connectivity not confirmed after $MAX_WAIT seconds"
    echo ""
    echo "🔧 ATTEMPTING FINAL AUTO-TROUBLESHOOTING..."
    echo ""
    
    # Try one more time to fix things
    if ip link show wlan0 >/dev/null 2>&1; then
        # Bring interface up if down
        # ROOT CAUSE FIX: Use nmcli if NetworkManager is running to preserve management
        if ! ip link show wlan0 | grep -q "state UP"; then
            if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                echo "   🔧 Bringing wlan0 up via NetworkManager (preserving management)..."
                sudo nmcli device set wlan0 managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 2
            else
                echo "   🔧 Bringing wlan0 up (NetworkManager not running)..."
                sudo ip link set wlan0 up 2>/dev/null && sleep 2
            fi
        fi
        
        # Try to renew DHCP if we have an IP but no internet
        if ip addr show wlan0 | grep -q "inet "; then
            echo "   🔧 Renewing DHCP lease..."
            sudo dhcpcd -n wlan0 2>/dev/null && sleep 3
        fi
        
        # Test again
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "   ✅ Internet connectivity restored! Continuing..."
            NETWORK_READY=1
        fi
    fi
    
    if [ $NETWORK_READY -eq 0 ]; then
        # Save diagnostic commands to file
        DIAG_FILE="internet-diagnostics.txt"
        cat > "$DIAG_FILE" << 'DIAGEOF'
# Internet Connection Diagnostic Commands
# Run these commands to troubleshoot your internet connection

# 1. Check Wi-Fi interface status
ip link show wlan0

# 2. Check if you have an IP address (look for 'inet' line)
ip addr show wlan0

# 3. Check if connected to a Wi-Fi network (should show ESSID)
iwconfig wlan0

# 4. Check NetworkManager status
nmcli device status

# 5. Check available Wi-Fi networks
sudo nmcli device wifi list

# 6. Connect to Wi-Fi network
sudo nmtui
# Select 'Activate a connection' → choose your hotel Wi-Fi

# 7. Check routing table (should show 'default via <gateway>')
ip route show

# 8. Test gateway connectivity
GATEWAY=$(ip route show default | awk '{print $3}')
echo "Gateway: $GATEWAY"
ping -c 3 $GATEWAY

# 9. Check if hotel Wi-Fi requires portal/login
curl -I http://google.com

# 10. Test DNS resolution
ping -c 1 8.8.8.8
ping -c 1 google.com

# 11. Check NetworkManager logs
sudo journalctl -u NetworkManager -n 50

# 12. Check system logs for network issues
sudo journalctl --since "10 minutes ago" | grep -i "network\|wifi\|wlan"
DIAGEOF
        
        echo "📄 Diagnostic commands saved to: $DIAG_FILE"
        echo "   View with: cat $DIAG_FILE"
        echo ""
        echo "❌ EXITING: Internet connection required for tunnel setup"
        echo "   Please fix your internet connection, then run this script again"
        exit 1
    fi
fi

# Check if dependencies are already installed
echo "=== Checking dependencies ==="
MISSING_DEPS=()
for pkg in hostapd dnsmasq nftables curl wireless-tools; do
    if ! dpkg -l | grep -q "^ii.*$pkg "; then
        MISSING_DEPS+=("$pkg")
    fi
done

if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    echo "✅ All dependencies are already installed"
    UPDATE_PACKAGES="n"
else
    echo "⚠️  Missing dependencies: ${MISSING_DEPS[*]}"
    UPDATE_PACKAGES="y"
fi

# Ask if user wants to update packages (if dependencies are installed)
if [ "$UPDATE_PACKAGES" = "n" ] && [ -t 0 ] && [ -t 1 ]; then
    echo ""
    read -p "   Update system packages? (y/n) [n]: " UPDATE_PACKAGES
    UPDATE_PACKAGES=${UPDATE_PACKAGES:-n}
fi

if [[ "$UPDATE_PACKAGES" =~ ^[Yy]$ ]]; then
    echo "=== Updating system ==="
    if sudo apt update; then
        sudo apt upgrade -y || echo "⚠️  Package upgrade failed, but continuing..."
    else
        echo "⚠️  Package list update failed (may be due to system clock issues), but continuing..."
        echo "   💡 If packages fail to install, check your system clock: date"
    fi
else
    echo "=== Skipping system updates ==="
    # Still need to update package list for installs
    if ! sudo apt update; then
        echo "⚠️  Package list update failed (may be due to system clock issues), but continuing..."
        echo "   💡 If packages fail to install, check your system clock: date"
    fi
fi

# Install missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "=== Installing missing dependencies: ${MISSING_DEPS[*]} ==="
    if sudo apt install -y "${MISSING_DEPS[@]}"; then
        echo "✅ Dependencies installed successfully"
    else
        echo "⚠️  Failed to install some dependencies, but continuing..."
        echo "   💡 You may need to install them manually later"
        echo "   💡 If this is due to package list errors, check your system clock: date"
    fi
else
    echo "=== All dependencies already installed, skipping installation ==="
fi

# Restore normal DNS management after package updates
echo "=== Restoring DNS management ==="
sudo chattr -i /etc/resolv.conf 2>/dev/null || true

# Configure systemd-resolved to work with Tailscale (or disable it)
# Tailscale needs to manage DNS for exit nodes to work properly
echo "Configuring DNS for Tailscale compatibility..."
# Stop systemd-resolved to prevent DNS conflicts with Tailscale
sudo systemctl stop systemd-resolved 2>/dev/null || true
sudo systemctl disable systemd-resolved 2>/dev/null || true

# Create a simple resolv.conf that Tailscale can manage
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
echo "nameserver ::1" | sudo tee -a /etc/resolv.conf > /dev/null
# Don't make it immutable - let Tailscale manage it

echo "=== Installing Tailscale (from official repo) ==="
if curl -fsSL https://tailscale.com/install.sh | sh; then
    echo "✅ Tailscale installation completed"
else
    echo "⚠️  Tailscale installation failed, but continuing..."
    echo "   💡 Tailscale may already be installed, or you may need to install it manually"
fi

echo "=== Stop services while we configure ==="
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true

# --- Verify Wi-Fi interface configuration (detected earlier in script) ---
echo "=== Verifying Wi-Fi interface configuration ==="
echo "Using interfaces detected earlier:"
echo "  - Hotel Wi-Fi ($HOTEL_WIFI / onboard): Connects to hotel/home Wi-Fi"
echo "  - Access Point ($AP_WIFI / USB adapter): Creates AP for your devices (better range)"

# Verify interfaces exist
if ! ip link show "$HOTEL_WIFI" >/dev/null 2>&1; then
    echo "Warning: Hotel Wi-Fi interface $HOTEL_WIFI not found!"
fi
if ! ip link show "$AP_WIFI" >/dev/null 2>&1; then
    echo "Warning: Access Point interface $AP_WIFI not found!"
fi

# --- Helper function to enable nmtui (fix NetworkManager for Wi-Fi management) ---
enable_nmtui() {
    local iface="$1"
    echo ""
    echo "=== Enabling nmtui for $iface (NetworkManager Wi-Fi management) ==="
    
    # Problem 1: Remove unmanaged-devices from config file
    echo "1️⃣ Removing unmanaged-devices from NetworkManager.conf..."
    if grep -q "unmanaged-devices" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "   Found unmanaged-devices line - removing..."
        sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf
        echo "   ✅ Removed"
    else
        echo "   ✅ No unmanaged-devices found"
    fi
    
    # Problem 2: Clean up duplicate [keyfile] sections
    echo ""
    echo "2️⃣ Cleaning up duplicate [keyfile] sections..."
    sudo awk '/^\[keyfile\]/ { if (!seen) { seen=1; print } next } { print }' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_fixed 2>/dev/null
    if [ -f /tmp/nm_conf_fixed ]; then
        sudo mv /tmp/nm_conf_fixed /etc/NetworkManager/NetworkManager.conf
        echo "   ✅ Cleaned up duplicate sections"
    else
        echo "   ⚠️  Could not clean up (may not be necessary)"
    fi
    
    # Problem 3: Stop wpa_supplicant to avoid conflicts
    echo ""
    echo "3️⃣ Stopping wpa_supplicant to avoid conflicts..."
    sudo systemctl stop wpa_supplicant 2>/dev/null || true
    sudo pkill -x wpa_supplicant 2>/dev/null || true
    sleep 1
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
        echo "   ✅ wpa_supplicant stopped"
    else
        echo "   ⚠️  wpa_supplicant may still be running"
    fi
    
    # Problem 4: Set interface to managed
    echo ""
    echo "4️⃣ Setting $iface to managed..."
    sudo nmcli device set $iface managed yes 2>/dev/null || true
    echo "   ✅ Set to managed"
    
    # Problem 5: Restart NetworkManager properly
    echo ""
    echo "5️⃣ Restarting NetworkManager..."
    sudo systemctl stop NetworkManager 2>/dev/null || true
    sleep 2
    sudo systemctl start NetworkManager 2>/dev/null || true
    sleep 5
    echo "   ✅ NetworkManager restarted"
    
    # Verify it worked
    echo ""
    echo "6️⃣ Verifying fix..."
    sleep 2
    IFACE_STATUS=$(nmcli device status 2>/dev/null | grep "$iface" | awk '{print $3}' || echo "unknown")
    echo "   $iface status: $IFACE_STATUS"
    
    if [ "$IFACE_STATUS" != "unmanaged" ] && [ "$IFACE_STATUS" != "unavailable" ]; then
        echo ""
        echo "   ✅ SUCCESS! $iface is now $IFACE_STATUS"
        echo "   ✅ nmtui should now show wireless networks!"
        echo ""
        echo "   To use nmtui:"
        echo "     1. Run: sudo nmtui"
        echo "     2. Select 'Activate a connection'"
        echo "     3. You should see wireless networks listed"
        return 0
    else
        echo ""
        echo "   ⚠️  Still showing as $IFACE_STATUS"
        echo "   💡 You may need to manually configure the connection"
        return 1
    fi
}

# --- Wi-Fi Access Point (using USB Wi-Fi) ---
echo "=== Configuring Wi-Fi access point on $USB_WIFI ==="

# Properly configure the USB Wi-Fi interface for AP mode
echo "Setting up $USB_WIFI for Access Point mode..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true
sudo pkill hostapd || true

# Configure interface for AP mode
sudo ip link set $USB_WIFI down || true
sudo iw dev $USB_WIFI set type __ap || echo "Interface $USB_WIFI already in AP mode or busy"
sudo ip link set $USB_WIFI up || true
sudo ip addr add ${AP_GATEWAY}/24 dev $USB_WIFI 2>/dev/null || echo "IP address already assigned to $USB_WIFI"

echo "USB Wi-Fi interface $USB_WIFI configured for AP mode"

# =============================================================================
# DISABLE USB POWER MANAGEMENT - Prevents USB WiFi adapter from being suspended
# =============================================================================
echo ""
echo "=== Disabling USB power management to prevent adapter suspension ==="

# Disable auto-suspend for all USB devices immediately
for i in /sys/bus/usb/devices/*/power/control; do
    echo "on" | sudo tee "$i" > /dev/null 2>&1 || true
done
echo "   Disabled USB auto-suspend for current session"

# Create udev rule to make it permanent across reboots
UDEV_RULE="/etc/udev/rules.d/50-usb-power.rules"
if [ ! -f "$UDEV_RULE" ]; then
    echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"' | sudo tee "$UDEV_RULE" > /dev/null
    sudo udevadm control --reload-rules
    echo "   Created permanent udev rule: $UDEV_RULE"
else
    echo "   USB power management rule already exists"
fi

# Disable WiFi power save on BOTH interfaces
sudo iw dev $USB_WIFI set power_save off 2>/dev/null || true
echo "   Disabled WiFi power save on $USB_WIFI (AP)"

sudo iw dev $HOTEL_WIFI set power_save off 2>/dev/null || true
echo "   Disabled WiFi power save on $HOTEL_WIFI (hotel WiFi)"

# NetworkManager will remain enabled for hotel Wi-Fi (wlan0) so nmtui works
# Only USB Wi-Fi (wlan1) will be unmanaged (AP mode)
echo ""
echo "💡 NetworkManager will remain enabled for hotel Wi-Fi ($ONBOARD_WIFI) - nmtui will work!"
echo "   Only USB Wi-Fi ($USB_WIFI) will be unmanaged (AP mode)"

# Configure NetworkManager to ignore ONLY the USB Wi-Fi (access point)
# IMPORTANT: Keep NetworkManager managing the onboard Wi-Fi (wlan0) so nmtui works!
echo ""
echo "=== Configuring NetworkManager to ignore USB Wi-Fi (access point) only ==="
echo "   (NetworkManager will continue managing $ONBOARD_WIFI for nmtui)"
echo "   (Only $USB_WIFI is unmanaged because it's in AP mode)"

# Backup original config
sudo cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup.$(date +%s) 2>/dev/null || true

# Remove ALL unmanaged-devices lines (including any that might have wlan0)
sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true

# Clean up duplicate [keyfile] sections and add ONE clean [keyfile] section
# Remove all [keyfile] sections and their content, then add one clean one with unmanaged-devices
# CRITICAL: Also remove ALL unmanaged-devices lines first to prevent duplicates
sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
sudo awk -v usb_wifi="$USB_WIFI" '
    BEGIN { in_keyfile=0; keyfile_added=0 }
    /^\[keyfile\]/ { 
        if (!keyfile_added) {
            print ""
            print "[keyfile]"
            print "unmanaged-devices=interface-name:" usb_wifi
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
            print "unmanaged-devices=interface-name:" usb_wifi
        }
    }
' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_clean 2>/dev/null
if [ -f /tmp/nm_conf_clean ]; then
    sudo mv /tmp/nm_conf_clean /etc/NetworkManager/NetworkManager.conf
    echo "✅ Cleaned up duplicate [keyfile] sections and added clean config"
else
    echo "⚠️  Could not clean config file - attempting alternative method..."
    # Alternative: Just remove all [keyfile] sections and append one
    sudo sed -i '/^\[keyfile\]/,/^\[/ { /^\[keyfile\]/d; /^\[/!d; }' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i '/^\[keyfile\]$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    # Remove any unmanaged-devices lines
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    # Append clean [keyfile] section
    echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    echo "unmanaged-devices=interface-name:$USB_WIFI" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
fi

# CRITICAL: Verify wlan0 is NOT in unmanaged-devices
echo "Verifying wlan0 is NOT in unmanaged-devices..."
if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "   ⚠️  WARNING: wlan0 found in unmanaged-devices! Removing it..."
    # Remove wlan0 from unmanaged-devices if it's there
    sudo sed -i "s/unmanaged-devices=interface-name:$ONBOARD_WIFI;interface-name:$USB_WIFI/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i "s/unmanaged-devices=interface-name:$USB_WIFI;interface-name:$ONBOARD_WIFI/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i "s/unmanaged-devices=interface-name:$ONBOARD_WIFI/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
fi

# Ensure USB Wi-Fi is explicitly unmanaged
echo "Ensuring USB Wi-Fi ($USB_WIFI) is unmanaged (AP mode)..."
sudo nmcli device set $USB_WIFI managed no 2>/dev/null || true

# Ensure onboard Wi-Fi IS managed (for nmtui) - do this BEFORE restarting NetworkManager
echo "Ensuring onboard Wi-Fi ($ONBOARD_WIFI) is managed (for nmtui)..."
sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true

# Apply config changes WITHOUT restarting NetworkManager if possible
# Restarting NetworkManager can cause wlan0 to become unmanaged
echo "Applying NetworkManager configuration..."
# Reload config without full restart (less disruptive)
sudo nmcli general reload 2>/dev/null || true
sleep 2

# Set devices to correct state (do this BEFORE any restart)
sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
sudo nmcli device set $USB_WIFI managed no 2>/dev/null || true
sudo nmcli radio wifi on 2>/dev/null || true
sleep 2

# Check if we need to restart (only if config reload didn't work)
NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
if [ -z "$NM_WLAN0_CHECK" ] || echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
    echo "⚠️  Config reload didn't work - verifying config file before restart..."
    
    # CRITICAL: Verify config file is PERFECT before restarting NetworkManager
    # If config is wrong, NetworkManager will set wlan0 to unmanaged on restart
    if grep -q "unmanaged-devices.*$ONBOARD_WIFI\|unmanaged-devices.*wlan0" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "   ⚠️  Config file still has wlan0 in unmanaged-devices! Fixing..."
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Verify config file structure is clean (no duplicate [keyfile] sections)
    KEYFILE_COUNT=$(grep -c "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo "0")
    if [ "$KEYFILE_COUNT" -gt 1 ]; then
        echo "   ⚠️  Found $KEYFILE_COUNT [keyfile] sections! Cleaning up..."
        # Use the same cleanup method as before
        sudo awk -v usb_wifi="$USB_WIFI" '
            BEGIN { in_keyfile=0; keyfile_added=0 }
            /^\[keyfile\]/ { 
                if (!keyfile_added) {
                    print ""
                    print "[keyfile]"
                    print "unmanaged-devices=interface-name:" usb_wifi
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
                    print "unmanaged-devices=interface-name:" usb_wifi
                }
            }
        ' /etc/NetworkManager/NetworkManager.conf > /tmp/nm_conf_pre_restart 2>/dev/null
        if [ -f /tmp/nm_conf_pre_restart ]; then
            sudo mv /tmp/nm_conf_pre_restart /etc/NetworkManager/NetworkManager.conf
            echo "   ✅ Config file cleaned"
        fi
    fi
    
    # CRITICAL: Ensure config file is PERFECT before restarting NetworkManager
    # If config has wlan0 in unmanaged-devices, NetworkManager will set it to unmanaged on restart
    echo "   Verifying config file is perfect before restart..."
    if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "   ⚠️  Config file has wlan0 in unmanaged-devices! Fixing..."
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$ONBOARD_WIFI;interface-name:$USB_WIFI/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=interface-name:$USB_WIFI;interface-name:$ONBOARD_WIFI/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    echo "   Restarting NetworkManager (last resort)..."
    ensure_nm_wlan0_managed  # Ensure config is correct before restart
    sudo systemctl restart NetworkManager 2>/dev/null || true
    force_wlan0_managed_after_restart  # Force wlan0 to stay managed after restart
    # Verify it stayed managed
    NM_CHECK_AFTER=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
    if [ -n "$NM_CHECK_AFTER" ] && ! echo "$NM_CHECK_AFTER" | grep -qE "(unmanaged|unavailable)"; then
        echo "   ✅ wlan0 stayed managed after restart: $(echo "$NM_CHECK_AFTER" | awk '{print $3}')"
    else
        echo "   ⚠️  wlan0 became unmanaged after restart - config file may still have issues"
    fi
else
    echo "✅ Config applied without restart (wlan0 preserved)"
fi

# Final verification and AGGRESSIVE fix if needed
NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
if [ -n "$NM_WLAN0_FINAL" ] && ! echo "$NM_WLAN0_FINAL" | grep -qE "(unmanaged|unavailable)"; then
    echo "✅ $ONBOARD_WIFI is managed: $(echo "$NM_WLAN0_FINAL" | awk '{print $3}')"
    echo "✅ nmtui should show wireless networks"
else
    echo "⚠️  $ONBOARD_WIFI status: $(echo "$NM_WLAN0_FINAL" | awk '{print $3}' || echo 'not found')"
    echo "   🔧 Attempting AGGRESSIVE emergency fix..."
    
    # Step 1: Verify config file doesn't have wlan0 in unmanaged-devices
    echo "   Step 1: Cleaning config file..."
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
    # Remove all [keyfile] sections
    sudo sed -i '/^\[keyfile\]$/,/^\[/ { /^\[keyfile\]$/d; /^\[/!d; }' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i '/^\[keyfile\]$/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    # Add clean [keyfile] section with ONLY USB Wi-Fi
    if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "unmanaged-devices=interface-name:$USB_WIFI" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    
    # Step 2: Verify wlan0 is NOT in unmanaged-devices
    if grep -q "unmanaged-devices.*$ONBOARD_WIFI\|unmanaged-devices.*wlan0" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "   ⚠️  Found wlan0 in unmanaged-devices! Removing..."
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Step 3: Restart NetworkManager
    echo "   Step 2: Restarting NetworkManager..."
    ensure_nm_wlan0_managed  # Ensure config is correct before restart
    sudo systemctl restart NetworkManager 2>/dev/null || true
    force_wlan0_managed_after_restart  # Force wlan0 to stay managed after restart
    
    # Step 5: Final check
    sleep 3
    NM_WLAN0_AFTER_FIX=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
    if [ -n "$NM_WLAN0_AFTER_FIX" ] && ! echo "$NM_WLAN0_AFTER_FIX" | grep -qE "(unmanaged|unavailable)"; then
        echo "   ✅ Emergency fix successful! $ONBOARD_WIFI is now: $(echo "$NM_WLAN0_AFTER_FIX" | awk '{print $3}')"
    else
        echo "   ❌ Emergency fix failed. $ONBOARD_WIFI status: $(echo "$NM_WLAN0_AFTER_FIX" | awk '{print $3}' || echo 'not found')"
        echo "   📋 Manual fix required. Run these commands:"
        echo "      sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
        echo "      echo '[keyfile]' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "      echo 'unmanaged-devices=interface-name:$USB_WIFI' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "      sudo systemctl restart NetworkManager"
        echo "      sleep 5"
        echo "      sudo nmcli device set $ONBOARD_WIFI managed yes"
        echo "      sudo nmcli radio wifi on"
    fi
fi

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=$USB_WIFI
driver=nl80211
ssid=$AP_SSID
hw_mode=${AP_HW_MODE:-g}
channel=${AP_CHANNEL:-6}
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
$(if [ "${AP_HW_MODE:-g}" = "a" ] || [ "${AP_HW_MODE:-g}" = "ac" ]; then
  echo "ieee80211ac=1"
  echo "ieee80211ax=1"
fi)
EOF

sudo sed -i 's|#DAEMON_CONF="".*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# --- DHCP / DNS ---
echo "=== Configuring dnsmasq ==="
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup || true
sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=$USB_WIFI
dhcp-range=$DHCP_START,$DHCP_END,${DHCP_LEASE_TIME:-12h}
dhcp-option=3,$AP_GATEWAY
dhcp-option=6,$AP_GATEWAY
server=${TAILSCALE_DNS:-100.100.100.100}
log-queries
log-dhcp
EOF

# --- Static IP for USB Wi-Fi (access point) ---
echo "=== Setting static IP for $USB_WIFI ==="
sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF

# Access Point interface
interface $USB_WIFI
    static ip_address=${AP_GATEWAY}/24
    nohook wpa_supplicant

# Hotel Wi-Fi interface (keep DHCP)
interface $ONBOARD_WIFI
    # This will use DHCP to connect to hotel Wi-Fi
EOF

# --- More permissive nftables rules ---
echo "=== Configuring nftables (permissive for setup) ==="
sudo tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;
        policy accept;  # More permissive during setup
        
        # Always allow loopback
        iifname "lo" accept
        
        # Allow established connections
        ct state established,related accept
        
        # Allow SSH from anywhere (for setup)
        tcp dport 22 accept
        
        # Allow DHCP
        udp dport { 67, 68 } accept
        
        # Allow DNS
        udp dport 53 accept
        tcp dport 53 accept
        
        # Allow access point traffic
        iifname "$USB_WIFI" accept
        
        # Allow hotel Wi-Fi traffic  
        iifname "$ONBOARD_WIFI" accept
        
        # Allow Tailscale when it comes up
        iifname "tailscale0" accept
    }

    chain forward {
        type filter hook forward priority 0;
        policy accept;  # Permissive for now
        
        # Forward only between access point and Tailscale (force all traffic through VPN)
        iifname "$USB_WIFI" oifname "tailscale0" accept
        iifname "tailscale0" oifname "$USB_WIFI" accept
    }

    chain output {
        type filter hook output priority 0;
        policy accept;  # Allow all outgoing for now
    }
}

# NAT table for internet sharing
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
    }
    
    chain postrouting {
        type nat hook postrouting priority 100;
        
        # NAT traffic from access point only through Tailscale (force VPN)
        oifname "tailscale0" masquerade
    }
}
EOF

# Enable IP forwarding
echo "=== Enabling IP forwarding ==="
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Load nftables rules (no safety timer for now - rules are permissive)
echo "=== Loading nftables rules ==="
sudo systemctl enable nftables

# Disable iptables NAT to prevent conflicts with nftables
echo "Disabling iptables NAT to prevent conflicts..."
sudo iptables -t nat -F 2>/dev/null || true
sudo iptables -t nat -X 2>/dev/null || true

sudo nft -f /etc/nftables.conf
sudo systemctl restart nftables

# --- Tailscale exit node service ---
echo "=== Configuring Tailscale autoconnect ==="
sudo tee /etc/systemd/system/tailscale-exit.service > /dev/null <<EOF
[Unit]
Description=Force Tailscale to use exit node '$TAILSCALE_EXIT_NODE_NAME'
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/tailscale up \\
    --exit-node=$TAILSCALE_EXIT_NODE_IP \\
    --exit-node-allow-lan-access=false \\
    --accept-routes \\
    --accept-dns
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tailscale-exit

# --- Create service to ensure Tailscale routing persists ---
echo "=== Creating Tailscale routing service ==="
sudo tee /etc/systemd/system/tailscale-routing.service > /dev/null <<EOF
[Unit]
Description=Ensure Tailscale default route
After=tailscale-exit.service
Wants=tailscale-exit.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 5; ip route del default dev tailscale0 2>/dev/null || true; ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true; ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tailscale-routing

# Update the routing service to include all fixes
sudo tee /etc/systemd/system/tailscale-routing.service > /dev/null <<EOF
[Unit]
Description=Ensure Tailscale routing and fix conflicts
After=tailscale-exit.service
Wants=tailscale-exit.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 5; ip rule add from ${AP_IP_RANGE}.0/24 to ${AP_IP_RANGE}.0/24 table main priority 100 2>/dev/null || true; ip rule add to ${AP_IP_RANGE}.0/24 table main priority 50 2>/dev/null || true; ip route del default dev tailscale0 2>/dev/null || true; ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true; ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- Create service to configure USB Wi-Fi on boot ---
echo "=== Creating USB Wi-Fi configuration service ==="
sudo tee /etc/systemd/system/usb-wifi-ap.service > /dev/null <<EOF
[Unit]
Description=Configure USB Wi-Fi for Access Point mode
Before=hostapd.service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link set $AP_WIFI down 2>/dev/null || true; iw dev $AP_WIFI set type __ap 2>/dev/null || true; ip link set $AP_WIFI up 2>/dev/null || true; ip addr flush dev $AP_WIFI 2>/dev/null || true; ip addr add ${AP_GATEWAY}/24 dev $AP_WIFI 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Replace the AP_WIFI and AP_GATEWAY variables in the service file
sudo sed -i "s/\$AP_WIFI/$AP_WIFI/g" /etc/systemd/system/usb-wifi-ap.service
sudo sed -i "s/\${AP_GATEWAY}/$AP_GATEWAY/g" /etc/systemd/system/usb-wifi-ap.service

sudo systemctl daemon-reload
sudo systemctl enable usb-wifi-ap

# --- Create watchdog service to monitor and auto-recover from disconnects ---
echo "=== Creating connection watchdog service ==="

# Create the watchdog script with variables hardcoded (substituted at creation time)
cat > /tmp/tunnel-watchdog.sh <<SCRIPTEOF
#!/bin/bash
# Tunnel Connection Watchdog Script
# Monitors and auto-recovers from connection drops
# Uses NetworkManager (nmcli) instead of dhcpcd to avoid conflicts
#
# ROLES:
# - HOTEL_WIFI (onboard wlan0) = connects to hotel Wi-Fi
# - AP_WIFI (USB adapter wlan1) = creates access point (hostapd manages it)

HOTEL_WIFI="$HOTEL_WIFI"
AP_WIFI="$AP_WIFI"
TAILSCALE_EXIT_NODE_IP="$TAILSCALE_EXIT_NODE_IP"

while true; do
    sleep 30  # Check every 30 seconds for faster recovery

    # CRITICAL: Ensure hotel Wi-Fi (onboard) stays managed by NetworkManager
    if nmcli device status 2>/dev/null | grep -q "\$HOTEL_WIFI.*unmanaged"; then
        echo "[Watchdog] \$HOTEL_WIFI (hotel Wi-Fi) became unmanaged, fixing..."
        nmcli device set "\$HOTEL_WIFI" managed yes 2>/dev/null || true
        sleep 2
    fi

    # CRITICAL: Keep power save OFF on hotel WiFi to prevent disconnections
    POWER_SAVE=\$(iw dev "\$HOTEL_WIFI" get power_save 2>/dev/null | grep -o "on\|off" || echo "unknown")
    if [ "\$POWER_SAVE" = "on" ]; then
        echo "[Watchdog] Power save was re-enabled on \$HOTEL_WIFI, disabling..."
        iw dev "\$HOTEL_WIFI" set power_save off 2>/dev/null || true
    fi

    # Ensure AP interface stays unmanaged (hostapd controls it)
    AP_STATE=\$(nmcli device status 2>/dev/null | grep "^\$AP_WIFI" | awk '{print \$3}')
    if [ "\$AP_STATE" != "unmanaged" ] && [ -n "\$AP_STATE" ]; then
        nmcli device set "\$AP_WIFI" managed no 2>/dev/null || true
    fi

    # Check if hotel Wi-Fi is connected (has IP address)
    if ! ip addr show "\$HOTEL_WIFI" 2>/dev/null | grep -q "inet "; then
        echo "[Watchdog] Hotel Wi-Fi (\$HOTEL_WIFI) lost IP, attempting to reconnect..."

        # Use nmcli instead of dhcpcd to avoid NetworkManager conflicts
        CURRENT_CONNECTION=\$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":\$HOTEL_WIFI\$" | cut -d: -f1)
        if [ -n "\$CURRENT_CONNECTION" ]; then
            echo "[Watchdog] Reconnecting to '\$CURRENT_CONNECTION'..."
            nmcli connection down "\$CURRENT_CONNECTION" 2>/dev/null || true
            sleep 2
            nmcli connection up "\$CURRENT_CONNECTION" 2>/dev/null || true
        else
            # No active connection - try to connect to any saved wifi network
            echo "[Watchdog] No active connection, scanning for saved networks..."
            nmcli device wifi rescan ifname "\$HOTEL_WIFI" 2>/dev/null || true
            sleep 3

            # Get available SSIDs
            AVAILABLE_SSIDS=\$(nmcli -t -f SSID device wifi list ifname "\$HOTEL_WIFI" 2>/dev/null | sort -u | grep -v "^\$" || echo "")

            # Try each saved wifi connection
            for SAVED in \$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi\$" | cut -d: -f1); do
                if echo "\$AVAILABLE_SSIDS" | grep -qx "\$SAVED"; then
                    echo "[Watchdog] Found saved network '\$SAVED', connecting..."
                    if nmcli device wifi connect "\$SAVED" ifname "\$HOTEL_WIFI" 2>/dev/null; then
                        echo "[Watchdog] Connected to '\$SAVED'"
                        break
                    fi
                fi
            done
        fi
        sleep 5
    fi

    # Check if Tailscale exit node is active
    if ! tailscale status 2>/dev/null | grep -q "active.*exit node"; then
        echo "[Watchdog] Tailscale exit node not active, reconnecting..."
        tailscale up --exit-node="\$TAILSCALE_EXIT_NODE_IP" --exit-node-allow-lan-access=false --accept-routes --accept-dns 2>/dev/null || true
        sleep 5
    fi

    # Check if we can reach internet
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "[Watchdog] Internet unreachable, checking hotel Wi-Fi gateway..."
        GATEWAY=\$(ip route show dev "\$HOTEL_WIFI" | grep default | awk '{print \$3}' | head -1)
        if [ -n "\$GATEWAY" ]; then
            if ! ping -c 1 -W 2 "\$GATEWAY" >/dev/null 2>&1; then
                echo "[Watchdog] Gateway unreachable, attempting to reconnect..."

                # Get the current or last connection name for this device
                CURRENT_CONN=\$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":\$HOTEL_WIFI\$" | cut -d: -f1)

                if [ -n "\$CURRENT_CONN" ]; then
                    # Connection exists but gateway unreachable - restart it
                    echo "[Watchdog] Restarting connection '\$CURRENT_CONN'..."
                    nmcli connection down "\$CURRENT_CONN" 2>/dev/null || true
                    sleep 2
                    nmcli connection up "\$CURRENT_CONN" 2>/dev/null || true
                else
                    # No active connection - scan and connect to saved network
                    echo "[Watchdog] No active connection, scanning for saved networks..."
                    nmcli device wifi rescan ifname "\$HOTEL_WIFI" 2>/dev/null || true
                    sleep 3

                    AVAILABLE=\$(nmcli -t -f SSID device wifi list ifname "\$HOTEL_WIFI" 2>/dev/null | sort -u | grep -v "^\$")
                    for SAVED in \$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi\$" | cut -d: -f1); do
                        if echo "\$AVAILABLE" | grep -qx "\$SAVED"; then
                            echo "[Watchdog] Connecting to saved network '\$SAVED'..."
                            if nmcli device wifi connect "\$SAVED" ifname "\$HOTEL_WIFI" 2>/dev/null; then
                                echo "[Watchdog] Connected to '\$SAVED'"
                                break
                            fi
                        fi
                    done
                fi
                sleep 5
            fi
        else
            # No gateway means no connection at all - try to connect
            echo "[Watchdog] No gateway found, WiFi likely disconnected. Reconnecting..."
            nmcli device wifi rescan ifname "\$HOTEL_WIFI" 2>/dev/null || true
            sleep 3

            AVAILABLE=\$(nmcli -t -f SSID device wifi list ifname "\$HOTEL_WIFI" 2>/dev/null | sort -u | grep -v "^\$")
            for SAVED in \$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi\$" | cut -d: -f1); do
                if echo "\$AVAILABLE" | grep -qx "\$SAVED"; then
                    echo "[Watchdog] Connecting to saved network '\$SAVED'..."
                    if nmcli device wifi connect "\$SAVED" ifname "\$HOTEL_WIFI" 2>/dev/null; then
                        echo "[Watchdog] Connected to '\$SAVED'"
                        break
                    fi
                fi
            done
        fi
    fi

    # ==========================================================================
    # ACCESS POINT MONITORING - Check if AP (wlan1) is healthy
    # ==========================================================================

    # Check if AP interface has an IP address
    if ! ip addr show "\$AP_WIFI" 2>/dev/null | grep -q "inet "; then
        echo "[Watchdog] AP interface \$AP_WIFI has no IP - restarting AP services..."
        systemctl restart usb-wifi-ap 2>/dev/null || true
        sleep 2
        systemctl restart hostapd 2>/dev/null || true
        sleep 2
        systemctl restart dnsmasq 2>/dev/null || true
        sleep 3

        # Verify fix worked
        if ip addr show "\$AP_WIFI" 2>/dev/null | grep -q "inet "; then
            echo "[Watchdog] AP interface \$AP_WIFI recovered successfully"
        else
            echo "[Watchdog] AP recovery failed - manually assigning IP..."
            ip addr add 10.0.50.1/24 dev "\$AP_WIFI" 2>/dev/null || true
            systemctl restart hostapd 2>/dev/null || true
            systemctl restart dnsmasq 2>/dev/null || true
        fi
    fi

    # Check if hostapd is running
    if ! systemctl is-active --quiet hostapd 2>/dev/null; then
        echo "[Watchdog] hostapd is not running - restarting..."
        systemctl restart usb-wifi-ap 2>/dev/null || true
        sleep 2
        systemctl restart hostapd 2>/dev/null || true
        sleep 2
        systemctl restart dnsmasq 2>/dev/null || true
    fi

    # Check if dnsmasq is running
    if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
        echo "[Watchdog] dnsmasq is not running - restarting..."
        systemctl restart dnsmasq 2>/dev/null || true
    fi
done
SCRIPTEOF

# Copy script to final location and make executable
sudo cp /tmp/tunnel-watchdog.sh /usr/local/bin/tunnel-watchdog.sh
sudo chmod +x /usr/local/bin/tunnel-watchdog.sh
rm -f /tmp/tunnel-watchdog.sh

# Verify script was created correctly
if [ ! -f /usr/local/bin/tunnel-watchdog.sh ]; then
    echo "❌ Failed to create watchdog script!"
    exit 1
fi

# Create the systemd service file
sudo tee /etc/systemd/system/tunnel-watchdog.service > /dev/null <<'SERVICEEOF'
[Unit]
Description=Tunnel Connection Watchdog - Auto-recover from disconnects
After=network-online.target tailscaled.service hostapd.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=30
ExecStart=/usr/local/bin/tunnel-watchdog.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Verify service file was created
if [ ! -f /etc/systemd/system/tunnel-watchdog.service ]; then
    echo "❌ Failed to create watchdog service file!"
    exit 1
fi

sudo systemctl daemon-reload
sudo systemctl enable tunnel-watchdog

# --- Enable and start services ---
echo "=== Enabling and starting AP services ==="
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

# Start the services
ensure_nm_wlan0_managed  # Ensure config is correct before restart
sudo systemctl restart NetworkManager
force_wlan0_managed_after_restart  # Force wlan0 to stay managed after restart
# Ensure NetworkManager manages hotel Wi-Fi (for nmtui) but not USB Wi-Fi (AP mode)
sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
sudo nmcli device set $USB_WIFI managed no 2>/dev/null || true
sudo systemctl start usb-wifi-ap
sudo systemctl start hostapd
sudo systemctl start dnsmasq
sudo systemctl start tunnel-watchdog

# Check service status
echo "=== Service Status ==="
sudo systemctl --no-pager status hostapd
sudo systemctl --no-pager status dnsmasq

# --- Configure Tailscale routing ---
echo "=== Configuring Tailscale routing ==="
echo "Checking if Tailscale is authenticated..."

if sudo tailscale status | grep -q "logged out\|not logged in"; then
    echo "⚠️  Tailscale needs authentication. Run these commands manually:"
    echo "   sudo tailscale up"
    echo "   (Follow the URL to authenticate)"
    echo "   sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns"
    echo "   sudo ip route add default dev tailscale0 metric 0"
else
    echo "Tailscale is authenticated. Configuring exit node and routing..."
    echo "   Attempting to connect to exit node: $TAILSCALE_EXIT_NODE_IP"
    echo "   (This may take up to 30 seconds if the exit node is not immediately reachable)..."
    
    # Use timeout to prevent hanging indefinitely (30 seconds should be enough)
    # Also redirect stderr to capture any errors
    if timeout 30 sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns 2>&1; then
        echo "   ✅ Tailscale exit node connection command completed"
    else
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "   ⚠️  WARNING: tailscale up command timed out after 30 seconds"
            echo "   💡 This usually means the exit node is not reachable or there's a network issue"
            echo "   💡 The connection may still work - checking status..."
        else
            echo "   ⚠️  WARNING: tailscale up command failed with exit code $EXIT_CODE"
            echo "   💡 This may be normal if the exit node is not immediately available"
            echo "   💡 Checking current Tailscale status..."
        fi
    fi
    
    sleep 3
    
    # Remove any existing incomplete Tailscale routes
    sudo ip route del default dev tailscale0 2>/dev/null || true
    sudo ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true
    sudo ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true
    
    # Fix Tailscale hijacking local access point traffic
    sudo ip rule add from ${AP_IP_RANGE}.0/24 to ${AP_IP_RANGE}.0/24 table main priority 100 2>/dev/null || echo "Local routing rule already exists"
    sudo ip rule add to ${AP_IP_RANGE}.0/24 table main priority 50 2>/dev/null || echo "Return traffic routing rule already exists"
    
    # Fix Tailscale hijacking local home network traffic
    # Get local network from wlan0 (home WiFi)
    if ip addr show $ONBOARD_WIFI 2>/dev/null | grep -q "inet "; then
        LOCAL_NET=$(ip route show dev $ONBOARD_WIFI | grep -E "^[0-9]" | head -1 | awk '{print $1}')
        if [ -n "$LOCAL_NET" ] && [ "$LOCAL_NET" != "${AP_IP_RANGE}.0/24" ]; then
            echo "Excluding local network $LOCAL_NET from Tailscale routing..."
            sudo ip rule add from $LOCAL_NET to $LOCAL_NET table main priority 90 2>/dev/null || echo "Local network routing rule already exists"
            sudo ip rule add to $LOCAL_NET table main priority 40 2>/dev/null || echo "Local network return routing rule already exists"
        fi
    fi
    
    # Let Tailscale handle its own routing when using exit nodes
    echo "✅ Letting Tailscale manage exit node routing automatically"
    
    # Check if exit node is actually active (may not be if connection failed)
    echo ""
    echo "Verifying exit node connection..."
    if sudo tailscale status 2>/dev/null | grep -q "$TAILSCALE_EXIT_NODE_NAME.*active.*exit node"; then
        echo "   ✅ Exit node is active and connected!"
    else
        echo "   ⚠️  Exit node is not yet active (this is normal if network is still connecting)"
        echo "   💡 The exit node will connect automatically when network is available"
        echo "   💡 You can check status later with: sudo tailscale status"
    fi
    
    # Verify DNS is properly configured
    echo ""
    echo "Verifying DNS configuration..."
    sleep 2
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
        echo "⚠️  Warning: /etc/resolv.conf is still immutable - removing flag..."
        sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    # Check if Tailscale is managing DNS
    if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
        echo "✅ Tailscale DNS is active"
    else
        echo "⚠️  Tailscale DNS not detected in resolv.conf - may need manual configuration"
    fi
    
    echo "✅ Tailscale routing configured"
fi

# --- System Health Checks ---
echo ""
echo "🔍 === SYSTEM HEALTH CHECKS ==="
echo ""

# Check 1: Wi-Fi Interfaces
echo "1️⃣ Wi-Fi Interface Status:"
echo "   Onboard Wi-Fi ($ONBOARD_WIFI):"
if iwconfig $ONBOARD_WIFI 2>/dev/null | grep -q "ESSID:"; then
    ONBOARD_SSID=$(iwconfig $ONBOARD_WIFI 2>/dev/null | grep ESSID | cut -d'"' -f2)
    echo "   ✅ Connected to: $ONBOARD_SSID"
else
    echo "   ❌ Not connected to hotel Wi-Fi"
fi

echo "   USB Wi-Fi ($USB_WIFI):"
if sudo iw dev $USB_WIFI info | grep -q "type AP"; then
    if ip addr show $USB_WIFI | grep -q "$AP_GATEWAY"; then
        echo "   ✅ Access Point mode with IP $AP_GATEWAY"
    else
        echo "   ⚠️  AP mode but missing IP address"
    fi
else
    echo "   ❌ Not in Access Point mode"
fi

# Check 2: Services
echo ""
echo "2️⃣ Service Status:"
for service in hostapd dnsmasq tailscaled tunnel-watchdog; do
    if systemctl is-active --quiet $service; then
        echo "   ✅ $service: Running"
    else
        echo "   ❌ $service: Not running"
    fi
done

# Check 3: Tailscale
echo ""
echo "3️⃣ Tailscale Status:"
if sudo tailscale status | grep -q "$TAILSCALE_EXIT_NODE_NAME.*active.*exit node"; then
    echo "   ✅ Connected to exit node '$TAILSCALE_EXIT_NODE_NAME'"
else
    echo "   ❌ Exit node not active"
    echo "   🔍 Current Tailscale status:"
    sudo tailscale status | head -3
    echo "   🔍 Looking for: $TAILSCALE_EXIT_NODE_NAME.*active.*exit node"
fi

# Check 4: Routing
echo ""
echo "4️⃣ Routing Configuration:"
if ! ip route show | grep -q "0.0.0.0/1 dev tailscale0" && ! ip route show | grep -q "128.0.0.0/1 dev tailscale0"; then
    echo "   ✅ Tailscale managing routing automatically (no manual routes)"
else
    echo "   ❌ Manual Tailscale routes detected (may cause conflicts)"
    echo "   🔍 Current routes:"
    ip route show | grep -E "(default|tailscale0|0\.0\.0\.0|128\.0\.0\.0)"
    echo "   🔍 Manual routes can break Tailscale exit node functionality"
fi

# Check 5: Internet Connectivity
echo ""
echo "5️⃣ Internet Connectivity Test:"
echo "   🔍 Debug: Testing basic connectivity..."

# Test 1: Can we reach internet via IP?
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "   ✅ Internet reachable via IP (8.8.8.8)"
else
    echo "   ❌ Internet unreachable via IP (8.8.8.8)"
fi

# Test 2: Can we resolve DNS?
if ping -c 1 google.com >/dev/null 2>&1; then
    echo "   ✅ DNS resolution working"
else
    echo "   ❌ DNS resolution failing"
    echo "   🔍 Current DNS servers:"
    cat /etc/resolv.conf | grep nameserver | head -3
fi

# Test 3: Can we reach web services?
echo "   🔍 Testing web connectivity..."
if timeout 10 curl -s ifconfig.me > /tmp/myip 2>/dev/null; then
    MYIP=$(cat /tmp/myip)
    if [ "$MYIP" = "$TAILSCALE_EXPECTED_IP" ]; then
        echo "   ✅ Internet working through exit node ($MYIP)"
    else
        echo "   ⚠️  Internet working but not through exit node ($MYIP)"
        echo "   🔍 Expected: $TAILSCALE_EXPECTED_IP, Got: $MYIP"
    fi
    rm -f /tmp/myip
else
    echo "   ❌ Web connectivity failing"
    echo "   🔍 Curl error details:"
    timeout 10 curl -v ifconfig.me 2>&1 | head -5 || echo "   Curl completely failed"
fi

# Show current routing for debugging
echo "   🔍 Current routing table:"
ip route show | head -5

# Check 6: NAT Rules
echo ""
echo "6️⃣ NAT Configuration:"
if sudo nft list table ip nat 2>/dev/null | grep -q 'oifname "tailscale0" masquerade'; then
    echo "   ✅ NAT rules configured for Tailscale"
else
    echo "   ❌ NAT rules missing or incorrect"
fi

# Summary
echo ""
echo "🎯 === SETUP SUMMARY ==="
echo ""
echo "🔧 Configuration:"
echo "  - Onboard Wi-Fi ($ONBOARD_WIFI): Hotel connection"
echo "  - USB Wi-Fi ($USB_WIFI): Access point '$AP_SSID'"
echo "  - Access Point IP: $AP_GATEWAY"
echo "  - SSID: $AP_SSID"
echo "  - Password: $AP_PASSWORD"
echo ""

# Check if everything is working
CHECKS_PASSED=0
if iwconfig $ONBOARD_WIFI 2>/dev/null | grep -q "ESSID:"; then ((CHECKS_PASSED++)); fi
if sudo iw dev $USB_WIFI info | grep -q "type AP" && ip addr show $USB_WIFI | grep -q "$AP_GATEWAY"; then ((CHECKS_PASSED++)); fi
if systemctl is-active --quiet hostapd && systemctl is-active --quiet dnsmasq; then ((CHECKS_PASSED++)); fi
if sudo tailscale status | grep -q "$TAILSCALE_EXIT_NODE_NAME.*active.*exit node"; then ((CHECKS_PASSED++)); fi
if ! ip route show | grep -q "0.0.0.0/1 dev tailscale0" && ! ip route show | grep -q "128.0.0.0/1 dev tailscale0"; then ((CHECKS_PASSED++)); fi
if systemctl is-active --quiet tunnel-watchdog; then ((CHECKS_PASSED++)); fi

if [ $CHECKS_PASSED -eq 6 ]; then
    echo "🎉 ALL SYSTEMS GO! Your tunnel is ready!"
    echo "   Connect your devices to '$AP_SSID' and enjoy secure browsing!"
elif [ $CHECKS_PASSED -ge 3 ]; then
    echo "⚠️  MOSTLY WORKING - Some issues detected above"
    echo "   Your tunnel should work but may need manual fixes"
else
    echo "❌ SETUP INCOMPLETE - Multiple issues detected"
    echo "   Please review the checks above and fix the issues"
fi

echo ""
echo "📋 Manual Commands (if needed):"
echo "  - Authenticate Tailscale: sudo tailscale up"
echo "  - Configure exit node: sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes --accept-dns"
echo "  - Fix routing: sudo ip route del 0.0.0.0/1 dev tailscale0; sudo ip route del 128.0.0.0/1 dev tailscale0"
echo "  - Restart services: sudo systemctl restart hostapd dnsmasq"
echo "  - Check watchdog logs: sudo journalctl -u tunnel-watchdog -f"
echo ""
echo "🛡️  Connection Stability Features:"
echo "  - NetworkManager manages hotel Wi-Fi ($ONBOARD_WIFI) - nmtui works!"
echo "  - NetworkManager does NOT manage USB Wi-Fi ($USB_WIFI) - AP mode only"
echo "  - Watchdog service monitors and auto-recovers from connection drops"
echo "  - DHCP lease renewal is handled automatically"
echo ""
echo "📡 nmtui (NetworkManager Text UI) Usage:"
echo "  - NetworkManager is ENABLED for hotel Wi-Fi ($ONBOARD_WIFI)"
echo "  - You can use nmtui anytime to connect to new hotel Wi-Fi networks:"
echo "    1. Run: sudo nmtui"
echo "    2. Select 'Activate a connection'"
echo "    3. Choose your hotel Wi-Fi network"
echo "    4. Enter password"
echo "  - No need to run debug-tunnel.sh - nmtui works directly!"
echo ""
echo "🔥 The firewall is currently PERMISSIVE for setup."
echo "   After everything works, you can tighten security if needed."
echo ""

# FINAL CHECK: Ensure wlan0 is managed for nmtui (critical!)
echo "🔍 === FINAL CHECK: Ensuring nmtui functionality ==="

# First, verify config file is correct
echo "   Checking NetworkManager config file..."
if grep -q "unmanaged-devices.*$ONBOARD_WIFI\|unmanaged-devices.*wlan0" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
    echo "   ⚠️  Found $ONBOARD_WIFI in unmanaged-devices! Removing..."
    sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    echo "   ✅ Config file fixed"
fi

# Check current status
NM_WLAN0_FINAL_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
if [ -n "$NM_WLAN0_FINAL_CHECK" ] && ! echo "$NM_WLAN0_FINAL_CHECK" | grep -qE "(unmanaged|unavailable)"; then
    echo "✅ $ONBOARD_WIFI is managed: $(echo "$NM_WLAN0_FINAL_CHECK" | awk '{print $3}')"
    echo "✅ nmtui is ready to use!"
else
    echo "⚠️  $ONBOARD_WIFI is NOT managed! Attempting aggressive fix..."
    
    # Step 1: Ensure config is correct
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
    if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    if ! grep -q "unmanaged-devices=interface-name:$USB_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "unmanaged-devices=interface-name:$USB_WIFI" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    
    # Step 2: Reload NetworkManager config
    sudo nmcli general reload 2>/dev/null || true
    sleep 3
    
    # Step 3: Set to managed multiple times with delays
    for attempt in 1 2 3 4 5; do
        sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
        sleep 1
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 1
    done
    
    # Step 4: Final verification
    sleep 3
    NM_WLAN0_LAST_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
    if [ -n "$NM_WLAN0_LAST_CHECK" ] && ! echo "$NM_WLAN0_LAST_CHECK" | grep -qE "(unmanaged|unavailable)"; then
        echo "✅ Fixed! $ONBOARD_WIFI is now managed: $(echo "$NM_WLAN0_LAST_CHECK" | awk '{print $3}')"
        echo "✅ nmtui is ready to use!"
    else
        echo "❌ Could not fix automatically. $ONBOARD_WIFI status: $(echo "$NM_WLAN0_LAST_CHECK" | awk '{print $3}' || echo 'not found')"
        echo ""
        echo "📋 Please run these commands manually:"
        echo "   sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
        echo "   echo '[keyfile]' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "   echo 'unmanaged-devices=interface-name:$USB_WIFI' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "   sudo systemctl restart NetworkManager"
        echo "   sleep 8"
        echo "   sudo nmcli device set $ONBOARD_WIFI managed yes"
        echo "   sudo nmcli device set $ONBOARD_WIFI managed yes"
        echo "   sudo nmcli radio wifi on"
        echo "   nmcli device status | grep $ONBOARD_WIFI"
    fi
fi

# ABSOLUTE FINAL VERIFICATION: Check one more time after a delay
# Sometimes NetworkManager takes a moment to apply changes
echo ""
echo "🔍 === ABSOLUTE FINAL VERIFICATION (after delay) ==="
sleep 5
FINAL_FINAL_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
if [ -n "$FINAL_FINAL_CHECK" ] && ! echo "$FINAL_FINAL_CHECK" | grep -qE "(unmanaged|unavailable)"; then
    echo "✅ FINAL: $ONBOARD_WIFI is managed: $(echo "$FINAL_FINAL_CHECK" | awk '{print $3}')"
    echo "✅ nmtui is ready to use!"
else
    echo "❌ FINAL: $ONBOARD_WIFI became unmanaged! Status: $(echo "$FINAL_FINAL_CHECK" | awk '{print $3}' || echo 'not found')"
    echo ""
    echo "🔧 LAST RESORT FIX - Running one more time..."
    # Remove wlan0 from config one more time
    sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null
    if ! grep -q "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
        echo "[keyfile]" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    if ! grep -q "unmanaged-devices=interface-name:$USB_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        echo "unmanaged-devices=interface-name:$USB_WIFI" | sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null
    fi
    # Verify wlan0 is NOT in there
    if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=interface-name:$USB_WIFI/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    # Reload and set managed
    sudo nmcli general reload 2>/dev/null || true
    sleep 3
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
        sleep 0.5
    done
    sudo nmcli radio wifi on 2>/dev/null || true
    sleep 2
    LAST_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
    if [ -n "$LAST_CHECK" ] && ! echo "$LAST_CHECK" | grep -qE "(unmanaged|unavailable)"; then
        echo "✅ SUCCESS! $ONBOARD_WIFI is now managed: $(echo "$LAST_CHECK" | awk '{print $3}')"
    else
        echo "❌ FAILED. Please run: sudo nmcli device set $ONBOARD_WIFI managed yes"
        echo "   Then check: nmcli device status | grep $ONBOARD_WIFI"
    fi
fi

# =============================================================================
# FINAL VERIFICATION: Ensure wlan0 is managed before script exits
# =============================================================================
echo ""
echo "🔍 === FINAL VERIFICATION: Ensuring wlan0 stays managed ==="
# Check one more time RIGHT before exiting
FINAL_NM_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
FINAL_STATUS=$(echo "$FINAL_NM_CHECK" | awk '{print $3}' || echo "unknown")

if [ "$FINAL_STATUS" = "unmanaged" ] || [ "$FINAL_STATUS" = "unavailable" ]; then
    echo "   ⚠️  wlan0 is unmanaged right before exit! Fixing one last time..."
    
    # Check for other NetworkManager config files that might have wlan0
    echo "   🔍 Checking for other NetworkManager config files..."
    for conf_file in /etc/NetworkManager/conf.d/*.conf; do
        if [ -f "$conf_file" ]; then
            if grep -q "unmanaged-devices.*wlan0\|unmanaged-devices.*$ONBOARD_WIFI" "$conf_file" 2>/dev/null; then
                echo "   ⚠️  Found wlan0 in $conf_file! Removing..."
                sudo sed -i '/unmanaged-devices.*wlan0/d' "$conf_file" 2>/dev/null || true
                sudo sed -i '/unmanaged-devices.*'"$ONBOARD_WIFI"'/d' "$conf_file" 2>/dev/null || true
            fi
        fi
    done
    
    # Ensure main config is correct
    ensure_nm_config_correct
    
    # Force reload and set managed
    sudo nmcli general reload 2>/dev/null || true
    sleep 2
    
    # Set to managed aggressively
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 0.3
    done
    
    # If still unmanaged, restart NetworkManager
    sleep 2
    FINAL_CHECK_AFTER=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '{print $3}' || echo "unknown")
    if [ "$FINAL_CHECK_AFTER" = "unmanaged" ] || [ "$FINAL_CHECK_AFTER" = "unavailable" ]; then
        echo "   ⚠️  Still unmanaged - restarting NetworkManager one last time..."
        ensure_nm_wlan0_managed
        sudo systemctl restart NetworkManager 2>/dev/null || true
        force_wlan0_managed_after_restart
    fi
    
    # Final check
    sleep 2
    ABSOLUTE_FINAL=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '{print $3}' || echo "unknown")
    if [ "$ABSOLUTE_FINAL" != "unmanaged" ] && [ "$ABSOLUTE_FINAL" != "unavailable" ]; then
        echo "   ✅ Fixed! wlan0 is now: $ABSOLUTE_FINAL"
    else
        echo "   ❌ FAILED. wlan0 is still unmanaged: $ABSOLUTE_FINAL"
        echo "   📋 Run this manually:"
        echo "      sudo sed -i '/unmanaged-devices/d' /etc/NetworkManager/NetworkManager.conf"
        echo "      sudo find /etc/NetworkManager/conf.d/ -name '*.conf' -exec sed -i '/unmanaged-devices.*wlan0/d' {} \\;"
        echo "      echo '[keyfile]' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "      echo 'unmanaged-devices=interface-name:$USB_WIFI' | sudo tee -a /etc/NetworkManager/NetworkManager.conf"
        echo "      sudo systemctl restart NetworkManager"
        echo "      sleep 5"
        echo "      sudo nmcli device set wlan0 managed yes"
    fi
else
    echo "   ✅ wlan0 status: $FINAL_STATUS"
    echo "   🔍 Waiting 3 seconds and checking again (NetworkManager might change it)..."
    sleep 3
    FINAL_CHECK_AGAIN=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '{print $3}' || echo "unknown")
    if [ "$FINAL_CHECK_AGAIN" = "unmanaged" ] || [ "$FINAL_CHECK_AGAIN" = "unavailable" ]; then
        echo "   ⚠️  wlan0 became unmanaged after delay! Fixing..."
        ensure_nm_config_correct
        sudo nmcli general reload 2>/dev/null || true
        sleep 2
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true
            sudo nmcli radio wifi on 2>/dev/null || true
            sleep 0.3
        done
        sleep 2
        FINAL_AFTER_DELAY=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '{print $3}' || echo "unknown")
        if [ "$FINAL_AFTER_DELAY" != "unmanaged" ] && [ "$FINAL_AFTER_DELAY" != "unavailable" ]; then
            echo "   ✅ Fixed after delay! wlan0 is now: $FINAL_AFTER_DELAY"
        else
            echo "   ⚠️  Still unmanaged - restarting NetworkManager..."
            ensure_nm_wlan0_managed
            sudo systemctl restart NetworkManager 2>/dev/null || true
            force_wlan0_managed_after_restart
        fi
    else
        echo "   ✅ wlan0 stayed managed: $FINAL_CHECK_AGAIN"
    fi
fi
echo ""
