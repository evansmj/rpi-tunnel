#!/usr/bin/env bash
# Script to check WiFi channels and find the best channel for your access point
# Works on both macOS and Linux (Raspberry Pi)

echo "=== Checking Current WiFi Connection Channel ==="
echo ""

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "🖥️  Detected: macOS"
    echo ""
    
    # Check current WiFi connection
    CURRENT_SSID=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '{print $2}')
    if [ -n "$CURRENT_SSID" ] && [ "$CURRENT_SSID" != "You are not associated with an AirPort network." ]; then
        echo "✅ Current WiFi connection: $CURRENT_SSID"
        
        # Get channel info from system_profiler
        WIFI_INFO=$(system_profiler SPAirPortDataType 2>/dev/null | grep -A 20 "Current Network Information:")
        CHANNEL=$(echo "$WIFI_INFO" | grep "Channel:" | awk '{print $2}' | head -1)
        BAND=$(echo "$WIFI_INFO" | grep "PHY Mode:" | awk '{print $3}' | head -1)
        
        if [ -n "$CHANNEL" ]; then
            echo "   Channel: $CHANNEL"
            if [ -n "$BAND" ]; then
                echo "   Band: $BAND"
            fi
        else
            echo "   ⚠️  Channel info not available (may need to check manually)"
        fi
    else
        echo "⚠️  Not connected to WiFi or could not determine current network"
    fi
    
    echo ""
    echo "=== Scanning for Nearby WiFi Networks ==="
    echo ""
    
    # Try airport utility first (may be deprecated but still works on some Macs)
    AIRPORT_PATH="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    
    # Try wdutil (newer method, but may require different approach)
    WIFI_SCAN_OUTPUT=""
    
    if [ -f "$AIRPORT_PATH" ]; then
        echo "Scanning WiFi networks (this may take a few seconds)..."
        echo ""
        
        # Try airport scan (may show deprecation warning but still work)
        WIFI_SCAN_OUTPUT=$("$AIRPORT_PATH" -s 2>/dev/null | tail -n +2)
        
        if [ -n "$WIFI_SCAN_OUTPUT" ]; then
            # Parse and show 5GHz networks
            echo "$WIFI_SCAN_OUTPUT" | while IFS= read -r line; do
                if [ -n "$line" ] && [ "$line" != "WARNING:"* ]; then
                    SSID=$(echo "$line" | awk '{print $1}')
                    CH=$(echo "$line" | awk '{print $4}' | tr -d '[:alpha:]')
                    BAND=$(echo "$line" | awk '{print $5}')
                    SIGNAL=$(echo "$line" | awk '{print $3}')
                    
                    # Only show 5GHz networks (since you're using ac mode)
                    # Check if channel is numeric and >= 36 (5GHz range)
                    if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 36 ] 2>/dev/null; then
                        echo "   Channel $CH ($BAND): $SSID (Signal: $SIGNAL)"
                    elif [ "$BAND" = "5" ] || [ "$BAND" = "5GHz" ]; then
                        echo "   Channel $CH ($BAND): $SSID (Signal: $SIGNAL)"
                    fi
                fi
            done
            
            # Count 5GHz networks found
            COUNT=$(echo "$WIFI_SCAN_OUTPUT" | awk '{print $4}' | grep -E '^[0-9]+$' | awk '$1 >= 36' | wc -l | tr -d ' ')
            if [ "$COUNT" -gt 0 ]; then
                echo ""
                echo "   Found $COUNT 5GHz network(s) in your area"
            else
                echo "   (No 5GHz networks detected in scan - they may be on different channels)"
            fi
        else
            echo "   ⚠️  Could not scan networks (airport command may be restricted)"
        fi
        
        echo ""
        echo "💡 Alternative methods to check WiFi channels on Mac:"
        echo "   1. Hold Option key and click WiFi icon in menu bar (shows channel info)"
        echo "   2. Open Wireless Diagnostics: Press Option and click WiFi → Open Wireless Diagnostics"
        echo "   3. Try airport command directly: $AIRPORT_PATH -s"
    else
        echo "⚠️  Airport utility not found."
        echo ""
        echo "💡 To check WiFi channels on Mac:"
        echo "   1. Hold Option key and click WiFi icon in menu bar"
        echo "   2. Open Wireless Diagnostics app"
    fi
    
else
    # Linux (Raspberry Pi)
    echo "🖥️  Detected: Linux"
    echo ""
    
    # Check the channel of your current WiFi connection (wlan0 - hotel WiFi)
    if iw dev wlan0 info 2>/dev/null | grep -q "type managed"; then
        CURRENT_CHANNEL=$(iw dev wlan0 link 2>/dev/null | grep -i "freq:" | awk '{print $2}' | head -1)
        if [ -n "$CURRENT_CHANNEL" ]; then
            # Convert frequency to channel
            FREQ=${CURRENT_CHANNEL}
            if [ "$FREQ" -ge 2412 ] && [ "$FREQ" -le 2484 ]; then
                # 2.4GHz: channel = (freq - 2412) / 5 + 1
                CHANNEL=$(( (FREQ - 2412) / 5 + 1 ))
                BAND="2.4GHz"
            elif [ "$FREQ" -ge 5180 ] && [ "$FREQ" -le 5825 ]; then
                # 5GHz: channel = (freq - 5000) / 5
                CHANNEL=$(( (FREQ - 5000) / 5 ))
                BAND="5GHz"
            else
                CHANNEL="unknown"
                BAND="unknown"
            fi
            echo "✅ Current WiFi connection (wlan0):"
            echo "   Frequency: ${FREQ} MHz"
            echo "   Channel: ${CHANNEL} (${BAND})"
        else
            echo "⚠️  Could not determine current channel (not connected?)"
        fi
    else
        echo "⚠️  wlan0 is not in managed mode or not available"
    fi
    
    echo ""
    echo "=== Scanning for Nearby WiFi Networks ==="
    echo ""
    
    # Scan for nearby networks
    echo "Scanning 5GHz networks..."
    iw dev wlan0 scan 2>/dev/null | grep -E "(freq:|SSID:)" | while read line; do
        if echo "$line" | grep -q "freq:"; then
            FREQ=$(echo "$line" | awk '{print $2}')
            if [ "$FREQ" -ge 5180 ] && [ "$FREQ" -le 5825 ]; then
                CHANNEL=$(( (FREQ - 5000) / 5 ))
                echo -n "   Channel $CHANNEL: "
            fi
        elif echo "$line" | grep -q "SSID:"; then
            SSID=$(echo "$line" | awk '{print $2}')
            echo "$SSID"
        fi
    done
fi

echo ""
echo "=== Recommended 5GHz Channels for 802.11ac ==="
echo ""
echo "Since you're using AP_HW_MODE=\"ac\" (5GHz), you need a 5GHz channel:"
echo ""
echo "📡 Indoor channels (most common, less power):"
echo "   - 36 (5180 MHz) - Recommended starting point"
echo "   - 40 (5200 MHz)"
echo "   - 44 (5220 MHz)"
echo "   - 48 (5240 MHz)"
echo ""
echo "📡 Outdoor/High-power channels (better range, may require DFS):"
echo "   - 149 (5745 MHz)"
echo "   - 153 (5765 MHz)"
echo "   - 157 (5785 MHz)"
echo "   - 161 (5805 MHz)"
echo "   - 165 (5825 MHz)"
echo ""
echo "💡 Recommendation: Start with channel 36 or 149 (least congested)"
echo ""
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "💡 Mac tip: Hold Option key and click WiFi icon to see channel info"
    echo "   Or run: /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s"
else
    echo "To check which channels are least congested, run:"
    echo "   sudo iw dev wlan0 scan | grep -E '(freq:|SSID:)' | grep -A 1 'freq: 5'"
fi
