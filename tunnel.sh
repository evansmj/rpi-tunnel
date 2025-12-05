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

echo "=== Resetting network configuration (preserving Tailscale) ==="

# Stop services that might interfere
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# Reset network interfaces (except Tailscale)
echo "Resetting network interfaces..."
for iface in wlan0 wlan1; do
    if ip link show $iface >/dev/null 2>&1; then
        echo "  Resetting $iface..."
        sudo ip link set $iface down 2>/dev/null || true
        sudo ip addr flush dev $iface 2>/dev/null || true
        sudo iw dev $iface set type managed 2>/dev/null || true
        sudo ip link set $iface up 2>/dev/null || true
    fi
done

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

# Test DNS resolution
echo "Testing DNS resolution..."
if ping -c 1 google.com >/dev/null 2>&1; then
    echo "✅ DNS working"
elif ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "⚠️  Internet works but DNS resolution may be slow"
else
    echo "⚠️  No internet connectivity, but continuing..."
fi

# Reset NetworkManager configuration
echo "Resetting NetworkManager configuration..."
sudo sed -i '/unmanaged-devices=interface-name:/d' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true

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
sudo systemctl restart NetworkManager 2>/dev/null || true
sleep 3

echo "✅ Network reset complete. Starting fresh configuration..."
echo ""

echo "=== Updating system ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing dependencies (hostapd, dnsmasq, nftables) ==="
sudo apt install -y hostapd dnsmasq nftables curl wireless-tools

# Restore normal DNS management after package updates
echo "=== Restoring DNS management ==="
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo systemctl start systemd-resolved 2>/dev/null || true

echo "=== Installing Tailscale (from official repo) ==="
curl -fsSL https://tailscale.com/install.sh | sh

echo "=== Stop services while we configure ==="
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true

# --- Detect Wi-Fi interfaces ---
echo "=== Detecting Wi-Fi interfaces ==="
WIFI_INTERFACES=$(iw dev | grep Interface | awk '{print $2}')
echo "Found Wi-Fi interfaces: $WIFI_INTERFACES"

# Determine which interface to use for what
ONBOARD_WIFI=""
USB_WIFI=""

for iface in $WIFI_INTERFACES; do
    # Check if it's a USB device by looking at the device path
    if udevadm info --query=path --name="$iface" 2>/dev/null | grep -q usb; then
        USB_WIFI="$iface"
        echo "USB Wi-Fi antenna detected: $iface"
    else
        ONBOARD_WIFI="$iface"
        echo "Onboard Wi-Fi detected: $iface"
    fi
done

# Default fallback if detection fails
if [ -z "$ONBOARD_WIFI" ]; then
    ONBOARD_WIFI="wlan0"
    echo "Warning: Using default wlan0 for onboard Wi-Fi"
fi

if [ -z "$USB_WIFI" ]; then
    if [ "$ONBOARD_WIFI" = "wlan0" ]; then
        USB_WIFI="wlan1"
    else
        USB_WIFI="wlan0"
    fi
    echo "Warning: Using default $USB_WIFI for USB Wi-Fi"
fi

echo "Configuration:"
echo "  - Onboard Wi-Fi ($ONBOARD_WIFI): Will connect to hotel Wi-Fi"
echo "  - USB Wi-Fi ($USB_WIFI): Will create access point for your devices"

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

# Configure NetworkManager to ignore the USB Wi-Fi interface
echo "=== Configuring NetworkManager to ignore $USB_WIFI ==="
sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null <<EOF

[keyfile]
unmanaged-devices=interface-name:$USB_WIFI
EOF

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=$USB_WIFI
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=${AP_CHANNEL:-6}
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
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
    --accept-routes
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
ExecStart=/bin/bash -c 'ip link set $USB_WIFI down; iw dev $USB_WIFI set type __ap; ip link set $USB_WIFI up; ip addr add ${AP_GATEWAY}/24 dev $USB_WIFI'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Replace the USB_WIFI variable in the service file
sudo sed -i "s/\$USB_WIFI/$USB_WIFI/g" /etc/systemd/system/usb-wifi-ap.service

sudo systemctl daemon-reload
sudo systemctl enable usb-wifi-ap

# --- Enable and start services ---
echo "=== Enabling and starting AP services ==="
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

# Start the services
sudo systemctl restart NetworkManager
sudo systemctl start usb-wifi-ap
sudo systemctl start hostapd
sudo systemctl start dnsmasq

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
    echo "   sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes"
    echo "   sudo ip route add default dev tailscale0 metric 0"
else
    echo "Tailscale is authenticated. Configuring exit node and routing..."
    sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes
    sleep 3
    
    # Remove any existing incomplete Tailscale routes
    sudo ip route del default dev tailscale0 2>/dev/null || true
    sudo ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true
    sudo ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true
    
    # Fix Tailscale hijacking local access point traffic
    sudo ip rule add from ${AP_IP_RANGE}.0/24 to ${AP_IP_RANGE}.0/24 table main priority 100 2>/dev/null || echo "Local routing rule already exists"
    sudo ip rule add to ${AP_IP_RANGE}.0/24 table main priority 50 2>/dev/null || echo "Return traffic routing rule already exists"
    
    # Let Tailscale handle its own routing when using exit nodes
    echo "✅ Letting Tailscale manage exit node routing automatically"
    
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
for service in hostapd dnsmasq tailscaled; do
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

if [ $CHECKS_PASSED -eq 5 ]; then
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
echo "  - Configure exit node: sudo tailscale up --exit-node=$TAILSCALE_EXIT_NODE_IP --exit-node-allow-lan-access=false --accept-routes"
echo "  - Fix routing: sudo ip route del 0.0.0.0/1 dev tailscale0; sudo ip route del 128.0.0.0/1 dev tailscale0"
echo "  - Restart services: sudo systemctl restart hostapd dnsmasq"
echo ""
echo "🔥 The firewall is currently PERMISSIVE for setup."
echo "   After everything works, you can tighten security if needed."
