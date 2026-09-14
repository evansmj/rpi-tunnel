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
# CONFIGURE Wi-Fi REGULATORY DOMAIN
# =============================================================================

configure_wifi_regulatory_domain() {
    local reg_country="${1:-${REGULATORY_COUNTRY:-US}}"
    local cfg_file="/etc/modprobe.d/cfg80211.conf"

    if [ -z "$reg_country" ]; then
        echo "⚠️  No regulatory country configured; skipping Wi-Fi regulatory domain setup"
        return 0
    fi

    echo "=== Configuring Wi-Fi regulatory domain ($reg_country) ==="

    if command -v iw >/dev/null 2>&1; then
        if sudo iw reg set "$reg_country" 2>/dev/null; then
            CURRENT_REG=$(iw reg get 2>/dev/null | awk '/^country / {gsub(":", "", $2); print $2; exit}' || echo "unknown")
            echo "   ✅ Active regulatory domain: $CURRENT_REG"
        else
            echo "   ⚠️  Could not set active regulatory domain with iw"
        fi
    else
        echo "   ⚠️  iw is not installed yet; persistent regulatory domain will still be configured"
    fi

    # wpa_supplicant re-applies its own country= every time it starts, which runs
    # after this script and silently overrides "iw reg set". The Raspberry Pi
    # Imager writes the locale chosen at flash time (e.g. FR) into
    # wpa_supplicant.conf, so pin it to the configured country here.
    local wpa_conf="/etc/wpa_supplicant/wpa_supplicant.conf"
    if command -v raspi-config >/dev/null 2>&1; then
        sudo raspi-config nonint do_wifi_country "$reg_country" >/dev/null 2>&1 || true
        echo "   ✅ Wi-Fi country set via raspi-config"
    fi
    if [ -f "$wpa_conf" ]; then
        if sudo grep -q '^[[:space:]]*country=' "$wpa_conf"; then
            sudo sed -i -E "s/^[[:space:]]*country=.*/country=$reg_country/" "$wpa_conf"
        else
            echo "country=$reg_country" | sudo tee -a "$wpa_conf" >/dev/null
        fi
        echo "   ✅ country=$reg_country pinned in $wpa_conf"
    fi
    # Tell any already-running wpa_supplicant instances (including the one
    # NetworkManager spawns) about the new country without waiting for a restart.
    if command -v wpa_cli >/dev/null 2>&1; then
        for sock in /var/run/wpa_supplicant/*; do
            [ -e "$sock" ] || continue
            sudo wpa_cli -i "$(basename "$sock")" set country "$reg_country" >/dev/null 2>&1 || true
        done
    fi

    # Make the setting survive reboots so scans include the correct country channels.
    if [ -d "/etc/modprobe.d" ]; then
        if [ -f "$cfg_file" ] && sudo grep -Eq '^[[:space:]]*options[[:space:]]+cfg80211.*ieee80211_regdom=' "$cfg_file"; then
            sudo sed -i -E "s/(ieee80211_regdom=)[A-Za-z0-9_]+/\1$reg_country/g" "$cfg_file"
        elif [ -f "$cfg_file" ] && sudo grep -Eq '^[[:space:]]*options[[:space:]]+cfg80211([[:space:]]|$)' "$cfg_file"; then
            sudo sed -i -E "/^[[:space:]]*options[[:space:]]+cfg80211([[:space:]]|$)/s/$/ ieee80211_regdom=$reg_country/" "$cfg_file"
        else
            echo "options cfg80211 ieee80211_regdom=$reg_country" | sudo tee "$cfg_file" >/dev/null
        fi
        echo "   ✅ Persistent regulatory domain configured in $cfg_file"
    else
        echo "   ⚠️  /etc/modprobe.d not found; could not configure persistent regulatory domain"
    fi
    echo ""
}

ensure_tailscale_installed() {
    if command -v tailscale >/dev/null 2>&1; then
        echo "✅ Tailscale is already installed ($(tailscale --version 2>/dev/null | head -n 1)); skipping install"
        return 0
    fi

    echo "=== Installing Tailscale (from official repo) ==="
    echo "   Tailscale command not found; installing before VPN setup..."

    sudo chattr -i /etc/resolv.conf 2>/dev/null || true

    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ curl is required to install Tailscale but is not available"
        echo "   Install curl first, then rerun this script."
        return 1
    fi

    if curl -fsSL https://tailscale.com/install.sh | sh; then
        if command -v tailscale >/dev/null 2>&1; then
            echo "✅ Tailscale installation completed"
            return 0
        fi
    fi

    echo "❌ Tailscale installation failed"
    echo "   Check internet and DNS connectivity, then rerun this script:"
    echo "   ping -c 3 8.8.8.8"
    echo "   ping -c 3 tailscale.com"
    return 1
}

ensure_tailscale_authenticated() {
    echo "=== Checking Tailscale authentication ==="

    sudo systemctl enable --now tailscaled 2>/dev/null || sudo systemctl start tailscaled 2>/dev/null || true
    sleep 2

    if sudo tailscale ip -4 >/dev/null 2>&1; then
        echo "✅ Tailscale is authenticated"
        return 0
    fi

    echo "❌ Tailscale is installed but not authenticated"
    echo "   Aborting before tunnel DNS/routing changes so normal internet remains usable."
    echo ""
    echo "   Run this first, complete the browser login, then rerun this script:"
    echo "   sudo tailscale up"
    echo ""
    echo "   Current Tailscale status:"
    sudo tailscale status 2>&1 | head -5 || true
    return 1
}

configure_wifi_regulatory_domain "${REGULATORY_COUNTRY:-US}"

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

# =============================================================================
# OPTIONAL ROLE SWAP
# =============================================================================
# Default (SWAP_WIFI_ROLES unset or false): onboard adapter connects to the hotel,
# USB adapter serves the access point. Setting SWAP_WIFI_ROLES="true" reverses that,
# so the USB adapter (usually the better antenna) handles the long-haul hotel link
# and the onboard radio serves devices in the same room.
SWAP_WIFI_ROLES_NORMALIZED=$(echo "${SWAP_WIFI_ROLES:-false}" | tr '[:upper:]' '[:lower:]')
if [ "$SWAP_WIFI_ROLES_NORMALIZED" = "true" ] || [ "$SWAP_WIFI_ROLES_NORMALIZED" = "yes" ] || [ "$SWAP_WIFI_ROLES_NORMALIZED" = "1" ]; then
    if [ "$HOTEL_WIFI" = "$AP_WIFI" ]; then
        echo "⚠️  SWAP_WIFI_ROLES is set but only one Wi-Fi interface was found - ignoring swap"
    else
        SWAPPED_HOTEL="$AP_WIFI"
        AP_WIFI="$HOTEL_WIFI"
        HOTEL_WIFI="$SWAPPED_HOTEL"
        ROLES_SWAPPED=true
        echo ""
        echo "🔄 SWAP_WIFI_ROLES enabled - reversing the default radio roles"
    fi
fi

# For backward compatibility with rest of script.
# NOTE: these names describe the DEFAULT hardware layout. When SWAP_WIFI_ROLES is on,
# ONBOARD_WIFI actually refers to the USB adapter and USB_WIFI to the onboard radio.
# Everything downstream uses them by ROLE (hotel client vs access point), not hardware.
ONBOARD_WIFI="$HOTEL_WIFI"
USB_WIFI="$AP_WIFI"

echo ""
echo "Role Assignment:"
if [ "${ROLES_SWAPPED:-false}" = "true" ]; then
    echo "  - USB Wi-Fi ($HOTEL_WIFI): Will connect to hotel Wi-Fi (swapped)"
    echo "  - Onboard Wi-Fi ($AP_WIFI): Will create access point for your devices (swapped)"
else
    echo "  - Onboard Wi-Fi ($HOTEL_WIFI): Will connect to hotel Wi-Fi"
    echo "  - USB Wi-Fi ($AP_WIFI): Will create access point for your devices (better range)"
fi
echo ""

# =============================================================================
# OPTIONAL ETHERNET INTERNET SHARING
# =============================================================================
# Default (ETH_ENABLE unset or false): no wired interface is touched and behavior
# is 100% unchanged. Setting ETH_ENABLE="true" shares the Tailscale tunnel with a
# laptop plugged into the Pi's ethernet port, exactly parallel to how AP_WIFI
# serves Wi-Fi clients.
ETH_ENABLE_NORMALIZED=$(echo "${ETH_ENABLE:-false}" | tr '[:upper:]' '[:lower:]')
if [ "$ETH_ENABLE_NORMALIZED" = "true" ] || [ "$ETH_ENABLE_NORMALIZED" = "yes" ] || [ "$ETH_ENABLE_NORMALIZED" = "1" ]; then
    ETH_ENABLED=true
else
    ETH_ENABLED=false
fi

ETH_IP_RANGE="${ETH_IP_RANGE:-10.0.60}"
ETH_GATEWAY="${ETH_GATEWAY:-10.0.60.1}"
ETH_DHCP_START="${ETH_DHCP_START:-10.0.60.10}"
ETH_DHCP_END="${ETH_DHCP_END:-10.0.60.50}"

if [ "$ETH_ENABLED" = true ]; then
    echo "=== Detecting ethernet interface for internet sharing ==="
    if [ -n "$ETH_INTERFACE" ]; then
        echo "Using configured ETH_INTERFACE: $ETH_INTERFACE"
    else
        DETECTED_ETH=""
        # Prefer eth0, then end0 (common Raspberry Pi wired NIC names)
        for candidate in eth0 end0; do
            if [ -d "/sys/class/net/$candidate" ]; then
                DETECTED_ETH="$candidate"
                break
            fi
        done
        # Fall back to any other wired-looking interface (en*), excluding wlan*
        if [ -z "$DETECTED_ETH" ]; then
            for iface_path in /sys/class/net/en*; do
                [ -d "$iface_path" ] || continue
                candidate=$(basename "$iface_path")
                case "$candidate" in
                    wlan*) continue ;;
                esac
                DETECTED_ETH="$candidate"
                break
            done
        fi
        ETH_INTERFACE="$DETECTED_ETH"
        if [ -n "$ETH_INTERFACE" ]; then
            echo "✅ Detected ethernet interface: $ETH_INTERFACE"
        fi
    fi

    if [ -z "$ETH_INTERFACE" ]; then
        echo "⚠️  ETH_ENABLE is true but no wired ethernet interface was found - disabling ethernet sharing for this run"
        ETH_ENABLED=false
    else
        echo "Ethernet sharing network: ${ETH_IP_RANGE}.0/24 (gateway $ETH_GATEWAY)"
    fi
    echo ""
fi

# =============================================================================
# OPTIONAL GATEWAY AUTOFIX
# =============================================================================
# Default (GATEWAY_AUTOFIX unset or true): detect and repair a broken
# DHCP-advertised default gateway (see attempt_gateway_autofix below for the
# hotel-typo scenario this covers). Set to "false" to disable auto-repair and
# only ever use whatever gateway DHCP hands out.
GATEWAY_AUTOFIX_NORMALIZED=$(echo "${GATEWAY_AUTOFIX:-true}" | tr '[:upper:]' '[:lower:]')
if [ "$GATEWAY_AUTOFIX_NORMALIZED" = "true" ] || [ "$GATEWAY_AUTOFIX_NORMALIZED" = "yes" ] || [ "$GATEWAY_AUTOFIX_NORMALIZED" = "1" ]; then
    GATEWAY_AUTOFIX="true"
else
    GATEWAY_AUTOFIX="false"
fi

# Compute the NetworkManager [keyfile] unmanaged-devices value for the AP interface,
# appending the ethernet interface when ETH_ENABLE is active so NetworkManager never
# tries to manage it either (hostapd/dnsmasq/static-IP handle it directly, like the AP).
nm_unmanaged_devices_value() {
    local ap_iface="$1"
    if [ "${ETH_ENABLED:-false}" = true ] && [ -n "${ETH_INTERFACE:-}" ]; then
        printf 'interface-name:%s;interface-name:%s' "$ap_iface" "$ETH_INTERFACE"
    else
        printf 'interface-name:%s' "$ap_iface"
    fi
}

# =============================================================================
# CRITICAL: CONFIGURE NetworkManager
# - HOTEL_WIFI (onboard, $HOTEL_WIFI): Must be MANAGED for hotel connection
# - AP_WIFI (USB adapter, $AP_WIFI): Must be UNMANAGED for hostapd access point
# - ETH_INTERFACE (optional, $ETH_INTERFACE): Must be UNMANAGED when ETH_ENABLE=true
# =============================================================================

# Write a clean NetworkManager.conf from scratch (idempotent, no appending)
write_clean_nm_conf() {
    local hotel_iface="${1:-$HOTEL_WIFI}"
    local ap_iface="${2:-$AP_WIFI}"
    local eth_iface="${3:-$ETH_INTERFACE}"
    local nm_conf="/etc/NetworkManager/NetworkManager.conf"

    hotel_iface="${hotel_iface:-wlan0}"
    ap_iface="${ap_iface:-wlan1}"

    local eth_device_block=""
    if [ "${ETH_ENABLED:-false}" = true ] && [ -n "$eth_iface" ]; then
        eth_device_block=$(printf '\n[device-eth]\nmatch-device=interface-name:%s\nmanaged=0\n' "$eth_iface")
    fi
    local unmanaged_value
    unmanaged_value=$(nm_unmanaged_devices_value "$ap_iface")

    sudo bash -c "cat > '$nm_conf'" << NMEOF
[main]
plugins=ifupdown,keyfile
# CRITICAL: dns=none stops NetworkManager rewriting /etc/resolv.conf with the DHCP
# nameservers handed out by the local network. Without it, NM clobbers Tailscale DNS
# on every connect and lease renewal, causing a silent DNS leak (exit IP still looks
# correct, but lookups go to the local ISP).
dns=none

[ifupdown]
managed=false

[device]
wifi.scan-rand-mac-address=no

[device-hotel-wifi]
match-device=interface-name:${hotel_iface}
managed=1

[device-ap-wifi]
match-device=interface-name:${ap_iface}
managed=0
${eth_device_block}
[keyfile]
unmanaged-devices=${unmanaged_value}
NMEOF

    local kf_count
    kf_count=$(grep -c '^\[keyfile\]' "$nm_conf" 2>/dev/null || echo "0")
    if [ "$kf_count" -ne 1 ]; then
        echo "   ⚠️  NetworkManager.conf verification failed ($kf_count [keyfile] sections)"
        return 1
    fi
    return 0
}

# =============================================================================
# CONNECTIVITY CHECK (ICMP-hostile / high-latency network survival)
# =============================================================================
# Real-world case this exists for: a hotel AP with a 300ms beacon interval,
# combined with Wi-Fi power save enabled on the Pi's hotel-facing radio, pushed
# ICMP RTTs to ~8 seconds with 66-100% ping loss -- while TCP connects succeeded
# fine the whole time. Every connectivity gate in this script was `ping -c 1
# -W 2 8.8.8.8`, so the script false-failed with "NO INTERNET" on a network
# that actually worked. Some hotel gateways also rate-limit/drop ICMP outright.
# Ping alone therefore can't be trusted as the sole signal; fall back to raw
# TCP reachability before declaring the network dead.
check_internet() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && return 0
    timeout 3 bash -c '>/dev/tcp/8.8.8.8/53' 2>/dev/null && return 0
    timeout 3 bash -c '>/dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    return 1
}

# =============================================================================
# HOTEL DHCP GATEWAY AUTOFIX
# =============================================================================
# Real-world case this exists for: a hotel's DHCP pool handed out gateway
# 172.10.20.1 to clients on subnet 172.20.10.0/23 -- a transposed-digit typo
# of the real gateway, 172.20.10.1. The Pi associated fine and got a normal
# DHCP lease, but had 100% packet loss: `ip neigh` showed the gateway stuck
# INCOMPLETE (ARP never answers, because nothing on the LAN owns that
# address). Rebooting or re-running this script can never fix it alone --
# every lease re-delivers the same bad gateway option, and DHCP renewals keep
# hitting the same misconfigured server.
#
# Detection: ping to the internet fails AND the default gateway's ARP entry
# is INCOMPLETE/FAILED (or missing an lladdr entirely), OR the advertised
# gateway address falls outside the interface's own subnet. A gateway merely
# failing to answer ping is NOT a signal by itself -- many gateways silently
# drop ICMP addressed to themselves while still forwarding traffic fine; ARP
# state is the trustworthy check.
#
# $1: interface to repair (the hotel Wi-Fi interface)
# Returns 0 and leaves a working default route in place on success.
# Returns 1 (no-op) if GATEWAY_AUTOFIX is disabled, there's nothing to fix, or
# no candidate gateway restores connectivity (original route is restored).
attempt_gateway_autofix() {
    local iface="$1"

    if [ "${GATEWAY_AUTOFIX:-true}" != "true" ]; then
        return 1
    fi

    local gw
    gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -1)
    if [ -z "$gw" ]; then
        return 1
    fi

    # Compute the interface's own subnet (network address) in pure bash -- avoids
    # depending on ipcalc, which is not guaranteed to be installed on Raspberry Pi OS.
    local cidr ip_part prefix
    cidr=$(ip -o -f inet addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$cidr" ]; then
        return 1
    fi
    ip_part="${cidr%/*}"
    prefix="${cidr#*/}"

    local a b c d ip_int mask net_int cand_int candidate_dotone
    IFS='.' read -r a b c d <<< "$ip_part"
    ip_int=$(( (a<<24) + (b<<16) + (c<<8) + d ))
    if [ "$prefix" -eq 0 ] 2>/dev/null; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    net_int=$(( ip_int & mask ))
    # NOTE: this is network-address-plus-one from the REAL prefix, not a naive
    # first-three-octets-plus-.1 -- for a /23 like the hotel above,
    # 172.20.11.78/23 has network 172.20.10.0, so the candidate is 172.20.10.1,
    # not 172.20.11.1.
    cand_int=$(( net_int + 1 ))
    candidate_dotone=$(printf '%d.%d.%d.%d' $(( (cand_int>>24)&255 )) $(( (cand_int>>16)&255 )) $(( (cand_int>>8)&255 )) $(( cand_int&255 )))

    # Is the current gateway outside our own subnet?
    local gw_a gw_b gw_c gw_d gw_int gw_outside_subnet=false
    IFS='.' read -r gw_a gw_b gw_c gw_d <<< "$gw"
    gw_int=$(( (gw_a<<24) + (gw_b<<16) + (gw_c<<8) + gw_d ))
    if [ $(( gw_int & mask )) -ne "$net_int" ]; then
        gw_outside_subnet=true
    fi

    # Trigger ARP resolution, then inspect the neighbor table entry.
    ping -c 1 -W 1 "$gw" >/dev/null 2>&1 || true
    local neigh_line neigh_bad=false
    neigh_line=$(ip neigh show "$gw" dev "$iface" 2>/dev/null)
    if [ -z "$neigh_line" ]; then
        neigh_bad=true
    elif echo "$neigh_line" | grep -qiE 'INCOMPLETE|FAILED'; then
        neigh_bad=true
    elif ! echo "$neigh_line" | grep -q 'lladdr'; then
        neigh_bad=true
    fi

    if [ "$neigh_bad" != true ] && [ "$gw_outside_subnet" != true ]; then
        return 1
    fi

    echo ""
    echo "⚠️  Default gateway $gw looks broken (ARP: ${neigh_line:-no entry}; outside own subnet: $gw_outside_subnet)"
    echo "🔧 Attempting gateway autofix..."

    # Build a deduped candidate list, excluding the known-bad gateway.
    local candidates=()
    if [ "$candidate_dotone" != "$gw" ]; then
        candidates+=("$candidate_dotone")
    fi

    # Best-effort: mine the DHCP options NetworkManager saw for more candidates.
    # NOTE: `nmcli -g DHCP4.OPTION` joins every option into ONE line separated by
    # " | ", so split on '|' before matching -- a naive grep/sed here once produced
    # a garbage "candidate" containing the entire option dump.
    # The `routers` option is the highest-quality source: per RFC 3442, clients
    # must prefer classless-static-routes (option 121) over `routers` when both
    # are present, so a DHCP server can advertise a broken 121 default route while
    # `routers` still carries the correct gateway. Seen in the wild: routers =
    # 172.20.10.1 (right) alongside rfc3442 0.0.0.0/0 via 172.10.20.1 (typo).
    local active_conn dhcp_opts opt_pattern opt_candidate
    active_conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":$iface\$" | cut -d: -f1 | head -1) || true
    if [ -n "$active_conn" ]; then
        dhcp_opts=$(nmcli -g DHCP4.OPTION connection show "$active_conn" 2>/dev/null | tr '|' '\n') || true
        for opt_pattern in 'routers =' 'dhcp_server_identifier ='; do
            opt_candidate=$(echo "$dhcp_opts" | grep -F "$opt_pattern" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true
            if echo "$opt_candidate" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && [ "$opt_candidate" != "$gw" ]; then
                local already_listed=false
                for c in "${candidates[@]}"; do
                    [ "$c" = "$opt_candidate" ] && already_listed=true
                done
                [ "$already_listed" = true ] || candidates+=("$opt_candidate")
            fi
        done
    fi

    if [ ${#candidates[@]} -eq 0 ]; then
        echo "❌ Gateway autofix: no alternative candidate gateway found"
        return 1
    fi

    local cand ping_out
    for cand in "${candidates[@]}"; do
        echo "   Trying candidate gateway $cand..."
        if sudo ip route replace default via "$cand" dev "$iface" 2>/dev/null; then
            ping_out=$(ping -c 2 -W 2 8.8.8.8 2>&1) || true
            tcp_ok=false
            if timeout 3 bash -c '>/dev/tcp/8.8.8.8/53' 2>/dev/null || timeout 3 bash -c '>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
                tcp_ok=true
            fi
            if echo "$ping_out" | grep -qE ", [1-9][0-9]* received" || [ "$tcp_ok" = true ]; then
                if ! echo "$ping_out" | grep -qE ", [1-9][0-9]* received"; then
                    echo "   (ICMP lossy but TCP works - accepting candidate)"
                fi
                echo ""
                echo "🔧 ================================================================"
                echo "🔧 HOTEL DHCP GATEWAY AUTOFIX SUCCEEDED"
                echo "🔧 ================================================================"
                echo "   The hotel's DHCP server advertised a broken gateway ($gw) whose"
                echo "   ARP entry never resolves. Routing through $cand instead restored"
                echo "   internet. This is almost always a typo in the hotel's DHCP"
                echo "   configuration (e.g. serving 172.10.20.1 instead of 172.20.10.1)."
                echo ""
                echo "   To pin this gateway for the rest of your stay on this network:"
                echo "     sudo nmcli connection modify \"$active_conn\" ipv4.gateway $cand"
                echo "   To remove the pin when you check out (so it doesn't affect the"
                echo "   next network you connect to):"
                echo "     sudo nmcli connection modify \"$active_conn\" ipv4.gateway \"\""
                echo ""
                echo "   If the DHCP options show the bad gateway coming from"
                echo "   rfc3442_classless_static_routes (option 121) while 'routers ='"
                echo "   holds the correct one, you can instead make this profile ignore"
                echo "   DHCP-provided routes entirely (also clear at checkout):"
                echo "     sudo nmcli connection modify \"$active_conn\" ipv4.ignore-auto-routes yes"
                echo "🔧 ================================================================"
                echo ""
                return 0
            else
                echo "   ❌ Candidate $cand did not restore connectivity:"
                echo "$ping_out" | tail -3 | sed 's/^/      /'
                echo "      route now: $(ip route show default dev "$iface" 2>/dev/null | head -1)"
                echo "      arp:       $(ip neigh show "$cand" dev "$iface" 2>/dev/null || true)"
            fi
        fi
    done

    # No candidate worked -- restore the original default route exactly as it was.
    sudo ip route replace default via "$gw" dev "$iface" 2>/dev/null || true
    echo "❌ Gateway autofix failed - no candidate gateway restored connectivity"
    return 1
}

# Stop the watchdog and AP services before touching interface roles.
# The watchdog runs with the role assignment baked in from the LAST successful run, and
# every loop it forces the previous AP interface back to unmanaged. If the roles have
# since changed (SWAP_WIFI_ROLES), it steals the radio we now want to use as the hotel
# client -- surfacing as "Device disconnected by user or client" -- and because this
# script exits early when there is no internet, it never reaches the code further down
# that would regenerate the watchdog with the new roles. That is a deadlock: stop it here.
echo "=== Stopping watchdog and AP services before reconfiguring ==="
sudo systemctl stop tunnel-watchdog 2>/dev/null || true
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

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
echo "   Checking NetworkManager configuration..."

# Detect corruption: null bytes, duplicate [keyfile] sections, or missing file
NM_NEEDS_REWRITE=false
if [ ! -f "$NM_CONF" ]; then
    NM_NEEDS_REWRITE=true
elif grep -Pq '\x00' "$NM_CONF" 2>/dev/null; then
    echo "   ⚠️  Detected null bytes (file corruption) — rewriting..."
    NM_NEEDS_REWRITE=true
else
    KEYFILE_COUNT=$(grep -c '^\[keyfile\]' "$NM_CONF" 2>/dev/null || echo "0")
    if [ "$KEYFILE_COUNT" -ne 1 ]; then
        echo "   ⚠️  Found $KEYFILE_COUNT [keyfile] sections (expected 1) — rewriting..."
        NM_NEEDS_REWRITE=true
    fi
    DEVICE_HOTEL_COUNT=$(grep -c '^\[device-hotel-wifi\]' "$NM_CONF" 2>/dev/null || echo "0")
    if [ "$DEVICE_HOTEL_COUNT" -ne 1 ]; then
        NM_NEEDS_REWRITE=true
    fi
    # A conf left over from a different role assignment is structurally valid but has
    # the roles backwards, which leaves the hotel interface unmanaged. The
    # unmanaged-devices line uniquely identifies which interface is the access point
    # (and, when ETH_ENABLE is active, the ethernet interface too), so compare it
    # against the roles in effect for THIS run (see SWAP_WIFI_ROLES). Without this,
    # every run would see a "mismatch" against its own eth-less/eth-enabled format
    # and rewrite the conf in a loop.
    EXPECTED_UNMANAGED_LINE="unmanaged-devices=$(nm_unmanaged_devices_value "$AP_WIFI")"
    if ! grep -qxF "$EXPECTED_UNMANAGED_LINE" "$NM_CONF" 2>/dev/null; then
        echo "   ⚠️  NetworkManager.conf was written for different radio roles — rewriting..."
        NM_NEEDS_REWRITE=true
    fi
fi

if [ "$NM_NEEDS_REWRITE" = true ]; then
    echo "   Writing clean NetworkManager configuration..."
    write_clean_nm_conf "$HOTEL_WIFI" "$AP_WIFI" "$ETH_INTERFACE"
    echo "   Restarting NetworkManager to apply config changes..."
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 5
else
    echo "   ✅ NetworkManager.conf is clean — no changes needed"
fi

# Clear leftover access-point state before using this interface as the hotel client.
# After a role swap the interface that previously served the AP still holds $AP_GATEWAY
# and is still in __ap mode, so it looks "UP with an IP address" while having no route
# to the internet -- which fails the connectivity check for the wrong reason.
HOTEL_IF_TYPE=$(iw dev "$HOTEL_WIFI" info 2>/dev/null | awk '/^\ttype/ {print $2}')
if [ "$HOTEL_IF_TYPE" = "AP" ] || ip addr show "$HOTEL_WIFI" 2>/dev/null | grep -q "inet ${AP_GATEWAY}/"; then
    echo "   🔧 $HOTEL_WIFI has leftover access-point state - clearing it..."
    sudo systemctl stop hostapd 2>/dev/null || true
    sudo systemctl stop dnsmasq 2>/dev/null || true
    # Hand the device to NetworkManager AFTER the raw cleanup, not before. Running
    # "ip link set" / "iw set type" on a device NetworkManager is managing makes it drop
    # the device to unmanaged -- the same trap this script warns about elsewhere. Mark it
    # unmanaged first, do the raw work, then restart NetworkManager so it re-enumerates
    # the device from scratch instead of holding stale state.
    sudo nmcli device set "$HOTEL_WIFI" managed no 2>/dev/null || true
    sleep 1
    sudo ip addr flush dev "$HOTEL_WIFI" 2>/dev/null || true
    sudo ip link set "$HOTEL_WIFI" down 2>/dev/null || true
    sudo iw dev "$HOTEL_WIFI" set type managed 2>/dev/null || true
    sudo ip link set "$HOTEL_WIFI" up 2>/dev/null || true
    sudo systemctl restart NetworkManager 2>/dev/null || true
    sleep 5
    sudo nmcli device set "$HOTEL_WIFI" managed yes 2>/dev/null || true
    sudo nmcli radio wifi on 2>/dev/null || true
    sleep 2
    CLEARED_STATE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" | awk '{print $3}' || echo "")
    if [ "$CLEARED_STATE" = "unmanaged" ] || [ -z "$CLEARED_STATE" ]; then
        echo "   ❌ $HOTEL_WIFI is still unmanaged after clearing access-point state."
        echo "      Recover with: sudo nmcli device set $HOTEL_WIFI managed yes"
        echo "                    sudo systemctl restart NetworkManager"
    else
        echo "   ✅ Cleared - $HOTEL_WIFI is now $CLEARED_STATE"
    fi
fi

# CRITICAL FIX: Check if hotel WiFi interface is managed by NetworkManager
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    HOTEL_WIFI_STATE=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" | awk '{print $3}' || echo "")
    if [ "$HOTEL_WIFI_STATE" = "unmanaged" ] || [ "$HOTEL_WIFI_STATE" = "unavailable" ]; then
        echo "   ⚠️  $HOTEL_WIFI (hotel interface) is $HOTEL_WIFI_STATE - fixing before proceeding..."
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

    # Unpin saved Wi-Fi profiles so they can activate on whichever radio currently holds
    # the hotel role. nmtui records the interface a profile was created on (and sometimes
    # the adapter MAC), which stops that profile activating on the other radio after
    # SWAP_WIFI_ROLES is toggled -- the network is in range and the password is saved, but
    # NetworkManager refuses to use it. Iterate by UUID: profile names contain spaces.
    nmcli -t -f UUID,TYPE connection show 2>/dev/null \
        | grep -E ':(wifi|802-11-wireless)$' | cut -d: -f1 \
        | while IFS= read -r conn_uuid; do
            [ -n "$conn_uuid" ] || continue
            sudo nmcli connection modify uuid "$conn_uuid" connection.interface-name "" 2>/dev/null || true
            sudo nmcli connection modify uuid "$conn_uuid" 802-11-wireless.mac-address "" 2>/dev/null || true
        done

    # Get list of saved connections (wifi only). Strip only the trailing type field --
    # cut -d: would truncate any SSID containing a colon.
    SAVED_CONNECTIONS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -E ':(wifi|802-11-wireless)$' | sed -E 's/:(wifi|802-11-wireless)$//' || echo "")

    # Try to connect to any saved network that's available.
    # NOTE: read line-by-line rather than "for saved in $SAVED_CONNECTIONS" -- word
    # splitting broke every SSID containing a space (e.g. "LA BRiCHE" -> "LA", "BRiCHE").
    CONNECTED=false
    while IFS= read -r saved; do
        [ -n "$saved" ] || continue
        if echo "$AVAILABLE_SSIDS" | grep -qxF "$saved"; then
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
    done <<< "$SAVED_CONNECTIONS"

    if [ "$CONNECTED" = false ]; then
        echo "   ⚠️  Could not auto-connect to any saved network"
        echo "   Available networks:"
        nmcli device wifi list ifname "$HOTEL_WIFI" 2>/dev/null | head -10
    fi
fi

echo ""
echo "=== Checking hotel Wi-Fi connection (via $HOTEL_WIFI) ==="

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

# Clear stale Tailscale exit node BEFORE testing connectivity.
# A previous tunnel.sh run may have configured Tailscale to route all traffic
# through the exit node. If the tunnel isn't fully set up, this blackholes all traffic.
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    CURRENT_EXIT_NODE=$(tailscale status --json 2>/dev/null | grep -o '"ExitNodeStatus":{[^}]*}' || echo "")
    if [ -n "$CURRENT_EXIT_NODE" ] && [ "$CURRENT_EXIT_NODE" != '{}' ]; then
        echo "   ⚠️  Tailscale exit node is active — clearing it to test raw internet..."
        sudo tailscale up --exit-node= --accept-routes=false 2>/dev/null || true
        sleep 2
    fi
fi

# Test internet connectivity BEFORE making any changes
echo "   Testing internet connectivity..."
if check_internet; then
    echo "✅ Internet connectivity confirmed - proceeding with tunnel setup"

    # Disable Wi-Fi power save on the hotel-facing radio. At APs with a long
    # beacon interval, power save leaves the radio dozing between beacons, so
    # buffered frames (including ICMP replies) can sit for seconds before
    # delivery -- the multi-second RTTs / packet loss this script now works
    # around in check_internet(). Turning it off avoids the problem at the
    # source instead of just tolerating it.
    echo "🔧 Disabling Wi-Fi power save on $HOTEL_WIFI..."
    sudo iw dev "$HOTEL_WIFI" set power_save off 2>/dev/null || true
    HOTEL_ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":$HOTEL_WIFI\$" | cut -d: -f1 | head -1) || true
    if [ -n "$HOTEL_ACTIVE_CONN" ]; then
        sudo nmcli connection modify "$HOTEL_ACTIVE_CONN" 802-11-wireless.powersave 2 2>/dev/null || true
    fi
elif attempt_gateway_autofix "$HOTEL_WIFI" && check_internet; then
    echo "✅ Internet connectivity confirmed after gateway autofix - proceeding with tunnel setup"
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
    local onboard_wifi="${ONBOARD_WIFI:-wlan0}"
    local usb_wifi="${USB_WIFI:-wlan1}"
    local eth_wifi="${ETH_INTERFACE:-}"

    write_clean_nm_conf "$onboard_wifi" "$usb_wifi" "$eth_wifi"

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        sudo nmcli device set "$onboard_wifi" managed yes 2>/dev/null || true
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
    local onboard_wifi="${ONBOARD_WIFI:-wlan0}"
    local usb_wifi="${USB_WIFI:-wlan1}"
    local eth_wifi="${ETH_INTERFACE:-}"

    write_clean_nm_conf "$onboard_wifi" "$usb_wifi" "$eth_wifi"
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
# CRITICAL: NEVER reset $HOTEL_WIFI if NetworkManager is running - it will break nmtui!
echo "Resetting network interfaces..."
for iface in $HOTEL_WIFI $AP_WIFI; do
    if ip link show $iface >/dev/null 2>&1; then
        echo "  Resetting $iface..."
        
        # For $HOTEL_WIFI: NEVER reset if NetworkManager is running - it will mark it as unmanaged!
        if [ "$iface" = "$HOTEL_WIFI" ] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "    ($HOTEL_WIFI - SKIPPING reset to preserve NetworkManager management)"
            echo "    (NetworkManager must manage $HOTEL_WIFI for nmtui to work)"
            echo "    (No manual reset needed - NetworkManager handles $HOTEL_WIFI)"
            # Don't touch $HOTEL_WIFI at all - let NetworkManager manage it completely
            continue
        else
            # For $AP_WIFI or if NetworkManager not running: full reset
            sudo ip link set $iface down 2>/dev/null || true
            sudo ip addr flush dev $iface 2>/dev/null || true
            sudo iw dev $iface set type managed 2>/dev/null || true
            sudo ip link set $iface up 2>/dev/null || true
        fi
    fi
done

# DON'T restart NetworkManager if it's already running and managing $HOTEL_WIFI
# Restarting NetworkManager can cause it to lose track of $HOTEL_WIFI
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    # Check if $HOTEL_WIFI is already being managed
    NM_WLAN0_STATUS=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
    if [ -n "$NM_WLAN0_STATUS" ] && ! echo "$NM_WLAN0_STATUS" | grep -qE "(unmanaged|unavailable)"; then
        echo "NetworkManager is managing $HOTEL_WIFI - no restart needed (preserving nmtui)"
        # Just ensure it stays managed
        sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
    else
        # $HOTEL_WIFI is unmanaged - try to fix without restarting NetworkManager first
        echo "$HOTEL_WIFI appears unmanaged - attempting to fix without restart..."
        sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
        sudo nmcli radio wifi on 2>/dev/null || true
        sleep 2
        NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
        if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
            echo "✅ Fixed! $HOTEL_WIFI is now managed: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
        else
            # Only restart as last resort
            echo "Restarting NetworkManager as last resort..."
            ensure_nm_wlan0_managed  # Ensure config is correct before restart
            sudo systemctl restart NetworkManager 2>/dev/null || true
            force_wlan0_managed_after_restart  # Force $HOTEL_WIFI to stay managed after restart
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
if check_internet; then
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

    # Try the gateway autofix first - it's the least drastic option and it directly
    # targets the hotel-DHCP-typo scenario (see attempt_gateway_autofix), which looks
    # exactly like a normal outage otherwise: interface up, IP address present, but
    # the advertised gateway itself is unreachable.
    if attempt_gateway_autofix "$HOTEL_WIFI"; then
        AUTO_FIXED=true
    fi

    # Check if Wi-Fi interface exists
    if ! ip link show $HOTEL_WIFI >/dev/null 2>&1; then
        echo "❌ $HOTEL_WIFI interface does not exist"
        ISSUES_FOUND+=("$HOTEL_WIFI interface missing")
    else
        echo "✅ $HOTEL_WIFI interface exists"
        WLAN0_STATE=$(ip link show $HOTEL_WIFI 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
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
                echo "   🔧 Ensuring NetworkManager is managing $HOTEL_WIFI..."
                sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
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
            sudo iw dev $HOTEL_WIFI set type managed 2>/dev/null || true
            sleep 1
            
            # Fix 5: Try to bring interface up
            # CRITICAL: Use nmcli if NetworkManager is running, NOT ip link set!
            # Using ip link set while NetworkManager is managing $HOTEL_WIFI causes it to become unmanaged
            if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                echo "   🔧 Bringing interface up via NetworkManager (preserving management)..."
                # Use NetworkManager to bring it up - this keeps it managed
                sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
                sudo nmcli radio wifi on 2>/dev/null || true
                sleep 2
                # Try to activate any saved connection
                SAVED_CONN=$(nmcli connection show 2>/dev/null | grep -E "wifi|$HOTEL_WIFI" | head -1 | awk '{print $1}' || echo "")
                if [ -n "$SAVED_CONN" ]; then
                    echo "   🔧 Attempting to activate saved connection: $SAVED_CONN"
                    sudo nmcli connection up "$SAVED_CONN" 2>/dev/null || true
                    sleep 3
                fi
            else
                echo "   🔧 Bringing interface up (NetworkManager not running)..."
                sudo ip link set $HOTEL_WIFI up 2>/dev/null && sleep 2
            fi
            
            # Check if it worked
            WLAN0_STATE=$(ip link show $HOTEL_WIFI 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
            if [ "$WLAN0_STATE" = "UP" ]; then
                echo "   ✅ Interface is now UP"
                AUTO_FIXED=true
            else
                echo "   ❌ Failed to bring interface up"
                
                # Check for hardware issues
                if dmesg | tail -20 | grep -qi "$HOTEL_WIFI.*error\|$HOTEL_WIFI.*fail\|$HOTEL_WIFI.*firmware"; then
                    echo "   ⚠️  Possible hardware/driver issue detected in system logs"
                    ISSUES_FOUND+=("Interface DOWN - possible hardware/driver issue (check dmesg)")
                else
                    ISSUES_FOUND+=("Interface is DOWN and cannot be brought up")
                fi
                
                # Try one more thing: reload driver module
                DRIVER_MODULE=$(ethtool -i $HOTEL_WIFI 2>/dev/null | grep driver | awk '{print $2}' || echo "")
                if [ -n "$DRIVER_MODULE" ]; then
                    echo "   🔧 Attempting to reload driver module: $DRIVER_MODULE"
                    sudo modprobe -r $DRIVER_MODULE 2>/dev/null && sleep 1
                    sudo modprobe $DRIVER_MODULE 2>/dev/null && sleep 2
                    # CRITICAL: Use nmcli if NetworkManager is running
                    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                        sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
                        sudo nmcli radio wifi on 2>/dev/null || true
                        sleep 2
                    else
                        sudo ip link set $HOTEL_WIFI up 2>/dev/null && sleep 2
                    fi
                    WLAN0_STATE=$(ip link show $HOTEL_WIFI 2>/dev/null | awk '/state/ {for(i=1;i<=NF;i++) if($i=="state") print $(i+1)}' || echo "UNKNOWN")
                    if [ "$WLAN0_STATE" = "UP" ]; then
                        echo "   ✅ Interface is now UP after driver reload!"
                        AUTO_FIXED=true
                    fi
                fi
            fi
        fi
        
        # Check if it has an IP address
        if [ "$WLAN0_STATE" = "UP" ]; then
            if ip addr show $HOTEL_WIFI | grep -q "inet "; then
                WLAN0_IP=$(ip addr show $HOTEL_WIFI | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
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
                        sudo dhcpcd -n $HOTEL_WIFI 2>/dev/null && sleep 3
                        if check_internet; then
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
                    if nmcli connection show --active 2>/dev/null | grep -q $HOTEL_WIFI; then
                        echo "   🔧 Attempting to activate saved connection..."
                        SAVED_CONN=$(nmcli connection show 2>/dev/null | grep $HOTEL_WIFI | head -1 | awk '{print $1}' || echo "")
                        if [ -n "$SAVED_CONN" ]; then
                            sudo nmcli connection up "$SAVED_CONN" 2>/dev/null && sleep 5
                            if ip addr show $HOTEL_WIFI | grep -q "inet "; then
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
        
        # Also ensure NetworkManager recognizes $HOTEL_WIFI after auto-fix
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "   🔧 Ensuring NetworkManager recognizes $HOTEL_WIFI after auto-fix..."
            sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
            sudo nmcli radio wifi on 2>/dev/null || true
            sleep 3
            # Verify
            NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
            if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
                echo "   ✅ NetworkManager recognizes $HOTEL_WIFI: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
            else
                echo "   ⚠️  NetworkManager may not recognize $HOTEL_WIFI - fixing WITHOUT restart..."
                # CRITICAL: DO NOT restart NetworkManager - it will set $HOTEL_WIFI to unmanaged!
                # Instead, verify config file and set to managed multiple times
                if grep -q "unmanaged-devices.*$HOTEL_WIFI\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                    echo "   ⚠️  Config file has $HOTEL_WIFI in unmanaged-devices! Fixing..."
                    sudo sed -i "s/unmanaged-devices=.*$HOTEL_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
                    sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
                    sudo nmcli general reload 2>/dev/null || true
                    sleep 2
                fi
                # Set to managed multiple times WITHOUT restarting
                for attempt in 1 2 3 4 5 6 7 8; do
                    sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
                    sleep 0.5
                    sudo nmcli radio wifi on 2>/dev/null || true
                    sleep 0.5
                done
                sleep 2
                # Check again
                NM_WLAN0_CHECK=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
                if [ -n "$NM_WLAN0_CHECK" ] && ! echo "$NM_WLAN0_CHECK" | grep -qE "(unmanaged|unavailable)"; then
                    echo "   ✅ Fixed! $HOTEL_WIFI is now: $(echo "$NM_WLAN0_CHECK" | awk '{print $3}')"
                else
                    echo "   ⚠️  Still unmanaged - but NOT restarting NetworkManager (would make it worse)"
                fi
            fi
        fi
        
        if check_internet; then
            echo "✅ Internet connectivity restored! Continuing..."
        else
            AUTO_FIXED=false
        fi
    fi
    
    # If still no internet, ensure NetworkManager recognizes $HOTEL_WIFI before exiting
    # (Even if internet is broken, we want nmtui to work)
    # CRITICAL: DO NOT restart NetworkManager here - it will set $HOTEL_WIFI to unmanaged!
    if [ "$AUTO_FIXED" = false ] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo ""
        echo "🔧 Ensuring NetworkManager recognizes $HOTEL_WIFI (for nmtui) before exiting..."
        
        # First, verify config file is correct (don't restart NetworkManager!)
        if grep -q "unmanaged-devices.*$HOTEL_WIFI\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "   ⚠️  Config file has $HOTEL_WIFI in unmanaged-devices! Fixing..."
            sudo sed -i "s/unmanaged-devices=.*$HOTEL_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            # Reload config WITHOUT restarting
            sudo nmcli general reload 2>/dev/null || true
            sleep 2
        fi
        
        # Set to managed multiple times WITHOUT restarting NetworkManager
        for attempt in 1 2 3 4 5; do
            sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
            sleep 1
            sudo nmcli radio wifi on 2>/dev/null || true
            sleep 1
        done
        
        # Final check with delay to catch any reversions
        sleep 3
        NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
        
        # Also verify config file one more time
        if grep -q "unmanaged-devices.*$HOTEL_WIFI\|unmanaged-devices.*$ONBOARD_WIFI" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            echo "   ⚠️  Config file STILL has $HOTEL_WIFI in unmanaged-devices! Fixing again..."
            sudo sed -i "s/unmanaged-devices=.*$HOTEL_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            sudo nmcli general reload 2>/dev/null || true
            sleep 2
            # Set to managed again
            for i in 1 2 3 4 5; do
                sudo nmcli device set $HOTEL_WIFI managed yes 2>/dev/null || true
                sleep 0.5
            done
            sleep 2
            NM_WLAN0_FINAL=$(nmcli device status 2>/dev/null | grep "^$HOTEL_WIFI" || echo "")
        fi
        
        # Check the actual status - need to verify it's NOT unmanaged (explicit check)
        WLAN0_STATUS=$(echo "$NM_WLAN0_FINAL" | awk '{print $3}' || echo "unknown")
        if [ -n "$NM_WLAN0_FINAL" ] && [ "$WLAN0_STATUS" != "unmanaged" ] && [ "$WLAN0_STATUS" != "unavailable" ]; then
            echo "   ✅ NetworkManager recognizes $HOTEL_WIFI: $WLAN0_STATUS"
            echo "   ✅ nmtui should show wireless networks"
            # Show config file contents for debugging
            echo "   📋 Config file unmanaged-devices: $(grep 'unmanaged-devices' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo 'none')"
        else
            echo "   ⚠️  $HOTEL_WIFI status: $(echo "$NM_WLAN0_FINAL" | awk '{print $3}' || echo 'not found')"
            echo "   📋 Config file unmanaged-devices: $(grep 'unmanaged-devices' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo 'none')"
            echo "   🔧 Attempting AGGRESSIVE fix to force $HOTEL_WIFI to be managed..."
            
            # AGGRESSIVE FIX: Ensure config is perfect, then force NetworkManager to apply it
            ensure_nm_config_correct
            
            # Remove any NetworkManager connection profiles that might be interfering
            sudo nmcli connection delete $HOTEL_WIFI 2>/dev/null || true
            
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
                    echo "   📋 Or re-run this script which will rewrite NetworkManager.conf cleanly"
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
    if check_internet; then
        echo "✅ Network connectivity confirmed"
        NETWORK_READY=1
        break
    fi
    # A broken DHCP-advertised gateway never heals by waiting -- and the
    # NetworkManager restart just above re-ran DHCP, which re-installs the bad
    # gateway and wipes any repair made during the earlier connectivity check.
    # Try the autofix once, a few seconds in.
    if [ $WAIT_COUNT -eq 10 ]; then
        attempt_gateway_autofix "$HOTEL_WIFI" || true
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

        # The renew above re-installs whatever gateway DHCP hands out -- if that
        # gateway is the broken one, repair it again before the final test.
        attempt_gateway_autofix "$HOTEL_WIFI" || true

        # Test again
        if check_internet; then
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
    read -t 5 -p "   Update system packages? (y/n) [n]: " UPDATE_PACKAGES || true
    UPDATE_PACKAGES=${UPDATE_PACKAGES:-n}
    echo ""
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

if ! ensure_tailscale_installed; then
    echo "❌ EXITING: Tailscale is required before tunnel routing can be configured"
    exit 1
fi

if ! ensure_tailscale_authenticated; then
    echo "❌ EXITING: Authenticate Tailscale before running tunnel setup"
    exit 1
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

# Write Tailscale DNS directly into resolv.conf.
# With systemd-resolved disabled, Tailscale often cannot update resolv.conf on its own.
# ONLY Tailscale DNS is used -- no public fallback to prevent DNS leaks.
sudo rm -f /etc/resolv.conf
echo "nameserver 100.100.100.100" | sudo tee /etc/resolv.conf > /dev/null
# Lock the file so NetworkManager/dhcpcd cannot overwrite it with local DHCP DNS.
sudo chattr +i /etc/resolv.conf 2>/dev/null || true

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

# =============================================================================
# SET REGULATORY DOMAIN FOR 5GHz CHANNELS
# =============================================================================
configure_wifi_regulatory_domain "${REGULATORY_COUNTRY:-US}"

# Properly configure the USB Wi-Fi interface for AP mode
echo "Setting up $USB_WIFI for Access Point mode..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true
sudo pkill hostapd || true

# Disable Wi-Fi power saving while the adapter is still in managed mode. Some
# drivers (notably mt7921u) accept the command in AP mode but immediately report
# "Power save: on" again. Applying it before the type change gives the setting a
# chance to persist when hostapd takes ownership.
sudo ip link set $USB_WIFI down || true
sudo iw dev $USB_WIFI set type managed 2>/dev/null || true
sudo ip link set $USB_WIFI up || true
sudo iw dev $USB_WIFI set power_save off 2>/dev/null || true
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

# Make power saving default to off for every Wi-Fi connection NetworkManager
# creates. The AP is unmanaged once hostapd owns it, but this also protects the
# hotel/uplink radio and preserves the setting while interfaces change roles.
NM_POWERSAVE_CONF="/etc/NetworkManager/conf.d/90-tunnel-wifi-powersave-off.conf"
sudo tee "$NM_POWERSAVE_CONF" > /dev/null <<'EOF'
[connection]
wifi.powersave=2
EOF
sudo nmcli general reload 2>/dev/null || true
echo "   Created persistent NetworkManager Wi-Fi power-save override"

# Disable WiFi power save on BOTH interfaces
sudo iw dev "$USB_WIFI" set power_save off 2>/dev/null || true
USB_POWER_SAVE=$(iw dev "$USB_WIFI" get power_save 2>/dev/null | awk '{print $3}' || echo "unknown")
if [ "$USB_POWER_SAVE" = "off" ]; then
    echo "   Disabled WiFi power save on $USB_WIFI (AP)"
else
    echo "   ⚠️  $USB_WIFI driver still reports power save '$USB_POWER_SAVE' in AP mode"
fi

sudo iw dev "$HOTEL_WIFI" set power_save off 2>/dev/null || true
HOTEL_POWER_SAVE=$(iw dev "$HOTEL_WIFI" get power_save 2>/dev/null | awk '{print $3}' || echo "unknown")
if [ "$HOTEL_POWER_SAVE" = "off" ]; then
    echo "   Disabled WiFi power save on $HOTEL_WIFI (hotel WiFi)"
else
    echo "   ⚠️  $HOTEL_WIFI driver still reports power save '$HOTEL_POWER_SAVE'"
fi

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

# Write a clean NetworkManager.conf from scratch (replaces all awk/sed cleanup)
echo "Writing clean NetworkManager configuration..."
write_clean_nm_conf "$ONBOARD_WIFI" "$USB_WIFI" "$ETH_INTERFACE"
echo "✅ NetworkManager.conf is clean"

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
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    fi
    
    # Verify config file structure is clean (no duplicate [keyfile] sections)
    KEYFILE_COUNT=$(grep -c "^\[keyfile\]" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo "0")
    if [ "$KEYFILE_COUNT" -gt 1 ]; then
        echo "   ⚠️  Found $KEYFILE_COUNT [keyfile] sections! Cleaning up..."
        # Use the same cleanup method as before
        sudo awk -v unmanaged_val="$(nm_unmanaged_devices_value "$USB_WIFI")" '
            BEGIN { in_keyfile=0; keyfile_added=0 }
            /^\[keyfile\]/ {
                if (!keyfile_added) {
                    print ""
                    print "[keyfile]"
                    print "unmanaged-devices=" unmanaged_val
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
                    print "unmanaged-devices=" unmanaged_val
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
        sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
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
    
    echo "   Step 1: Rewriting clean NetworkManager config..."
    write_clean_nm_conf "$ONBOARD_WIFI" "$USB_WIFI" "$ETH_INTERFACE"
    
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
        echo "   📋 Manual fix required: Re-run ./tunnel.sh (it will rewrite NetworkManager.conf cleanly)"
        echo "      sudo nmcli device set $ONBOARD_WIFI managed yes"
        echo "      sudo nmcli radio wifi on"
    fi
fi

# Determine correct hw_mode value for hostapd
# hostapd uses: g (2.4GHz), a (5GHz), n (2.4GHz), but NOT "ac" directly
# For "ac" mode, we use hw_mode=a and enable 802.11ac features
HOSTAPD_HW_MODE="${AP_HW_MODE:-g}"
if [ "$HOSTAPD_HW_MODE" = "ac" ] || [ "$HOSTAPD_HW_MODE" = "n" ]; then
    # hostapd only accepts a/b/g here; n and ac are expressed via the
    # ieee80211n/ieee80211ac flags below.
    if [ "$HOSTAPD_HW_MODE" = "ac" ]; then HOSTAPD_HW_MODE="a"; else HOSTAPD_HW_MODE="g"; fi
fi

# Without ieee80211n=1 hostapd ignores ieee80211ac/ax and falls back to legacy
# 11a/11g rates (54 Mbps PHY, ~5-20 Mbps real). Derive the HT40 secondary
# channel side and the 80 MHz center for the configured channel; channels with
# no 40/80 MHz partner (e.g. 165) simply stay at 20 MHz.
HT40_SIDE=""
VHT_CENTER=""
case "${AP_CHANNEL:-6}" in
    36|44|149|157) HT40_SIDE="[HT40+]" ;;
    40|48|153|161) HT40_SIDE="[HT40-]" ;;
esac
case "${AP_CHANNEL:-6}" in
    36|40|44|48)     VHT_CENTER=42 ;;
    149|153|157|161) VHT_CENTER=155 ;;
esac
HT_CAPAB="[SHORT-GI-20]"
[ -n "$HT40_SIDE" ] && HT_CAPAB="${HT40_SIDE}[SHORT-GI-20][SHORT-GI-40]"

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=$USB_WIFI
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ssid=$AP_SSID
hw_mode=$HOSTAPD_HW_MODE
channel=${AP_CHANNEL:-6}
country_code=${REGULATORY_COUNTRY:-US}
ieee80211d=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211n=1
ht_capab=$HT_CAPAB
$(if [ "${AP_HW_MODE:-g}" = "a" ] || [ "${AP_HW_MODE:-g}" = "ac" ]; then
  echo "ieee80211ac=1"
  echo "vht_capab=[SHORT-GI-80]"
  if [ -n "$VHT_CENTER" ]; then
    echo "vht_oper_chwidth=1"
    echo "vht_oper_centr_freq_seg0_idx=$VHT_CENTER"
  fi
  echo "ieee80211ax=1"
  if [ -n "$VHT_CENTER" ]; then
    echo "he_oper_chwidth=1"
    echo "he_oper_centr_freq_seg0_idx=$VHT_CENTER"
  fi
fi)
EOF

sudo sed -i 's|#DAEMON_CONF="".*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# --- DHCP / DNS ---
echo "=== Configuring dnsmasq ==="
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup || true

# Build the optional ethernet fragment up front so the single heredoc below stays
# unchanged when ETH_ENABLE is not active. Both dhcp-ranges are tagged (ap/eth) so
# each subnet only gets its own gateway/DNS options instead of cross-serving them.
ETH_DNSMASQ_BLOCK=""
if [ "$ETH_ENABLED" = true ]; then
    ETH_DNSMASQ_BLOCK=$(cat <<ETHEOF

# Ethernet internet sharing (ETH_ENABLE=true)
interface=$ETH_INTERFACE
dhcp-range=set:eth,$ETH_DHCP_START,$ETH_DHCP_END,${DHCP_LEASE_TIME:-12h}
dhcp-option=tag:eth,3,$ETH_GATEWAY
dhcp-option=tag:eth,6,$ETH_GATEWAY
ETHEOF
)
fi

sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=$USB_WIFI
dhcp-range=set:ap,$DHCP_START,$DHCP_END,${DHCP_LEASE_TIME:-12h}
dhcp-option=tag:ap,3,$AP_GATEWAY
dhcp-option=tag:ap,6,$AP_GATEWAY
# CRITICAL: no-resolv stops dnsmasq merging /etc/resolv.conf nameservers into its
# upstream pool. Without it, "server=" is additive, not exclusive -- if anything
# (NetworkManager, dhcpcd) writes the local network's DNS into resolv.conf, client
# queries leak to the local ISP even though the exit node is working.
no-resolv
server=${TAILSCALE_DNS:-100.100.100.100}
log-queries
log-dhcp
${ETH_DNSMASQ_BLOCK}
EOF

# --- Static IP for USB Wi-Fi (access point) ---
echo "=== Setting static IP for $USB_WIFI ==="
# Remove the block added by a previous run before appending a new one. This used to be
# a blind "tee -a", so every run stacked another copy -- and after a role swap the stale
# entry kept assigning the AP address to what is now the hotel interface.
sudo sed -i '/# >>> tunnel.sh managed block >>>/,/# <<< tunnel.sh managed block <<</d' /etc/dhcpcd.conf 2>/dev/null || true

# Optional ethernet fragment: "nolink" is required so the static address exists at
# boot even with no cable plugged in yet -- dnsmasq needs it to be able to serve DHCP
# the moment a laptop is connected, without dhcpcd waiting for link-up first.
ETH_DHCPCD_BLOCK=""
if [ "$ETH_ENABLED" = true ]; then
    ETH_DHCPCD_BLOCK=$(cat <<ETHEOF

# Ethernet interface (internet sharing, ETH_ENABLE=true)
interface $ETH_INTERFACE
    static ip_address=${ETH_GATEWAY}/24
    nolink
ETHEOF
)
fi

sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF
# >>> tunnel.sh managed block >>>
# Access Point interface
interface $USB_WIFI
    static ip_address=${AP_GATEWAY}/24
    nohook wpa_supplicant

# Hotel Wi-Fi interface (keep DHCP)
interface $ONBOARD_WIFI
    # This will use DHCP to connect to hotel Wi-Fi
${ETH_DHCPCD_BLOCK}
# <<< tunnel.sh managed block <<<
EOF

# Assign the ethernet static address immediately so it works without a reboot
# (dhcpcd's "nolink" handles it on future boots, but won't apply it retroactively
# to an interface dhcpcd already brought up during this same run).
if [ "$ETH_ENABLED" = true ]; then
    echo "Assigning $ETH_GATEWAY to $ETH_INTERFACE now (no reboot required)..."
    sudo ip addr flush dev "$ETH_INTERFACE" 2>/dev/null || true
    sudo ip link set "$ETH_INTERFACE" up 2>/dev/null || true
    sudo ip addr add ${ETH_GATEWAY}/24 dev "$ETH_INTERFACE" 2>/dev/null || echo "IP address already assigned to $ETH_INTERFACE"
fi

# --- More permissive nftables rules ---
echo "=== Configuring nftables (permissive for setup) ==="

# Optional ethernet fragments. Note: no eth<->hotel-Wi-Fi forwarding rule is added
# here -- only eth<->tailscale0 -- so the wired client fails closed exactly like the
# AP does if the tunnel ever drops, instead of silently falling back to raw internet.
ETH_NFT_INPUT_BLOCK=""
ETH_NFT_FORWARD_BLOCK=""
if [ "$ETH_ENABLED" = true ]; then
    ETH_NFT_INPUT_BLOCK="        # Allow ethernet internet-sharing traffic
        iifname \"$ETH_INTERFACE\" accept
"
    ETH_NFT_FORWARD_BLOCK="        # Forward only between ethernet and Tailscale (force all traffic through VPN)
        iifname \"$ETH_INTERFACE\" oifname \"tailscale0\" accept
        iifname \"tailscale0\" oifname \"$ETH_INTERFACE\" accept
"
fi

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

${ETH_NFT_INPUT_BLOCK}        # Allow Tailscale when it comes up
        iifname "tailscale0" accept
    }

    chain forward {
        type filter hook forward priority 0;
        policy accept;  # Permissive for now

        # Forward only between access point and Tailscale (force all traffic through VPN)
        iifname "$USB_WIFI" oifname "tailscale0" accept
        iifname "tailscale0" oifname "$USB_WIFI" accept
${ETH_NFT_FORWARD_BLOCK}    }

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
# When ETH_ENABLE is active, mirror the AP's local-routing rules for the ethernet
# subnet too, so Tailscale doesn't hijack traffic to/from the wired client.
ETH_ROUTING_RULES=""
if [ "$ETH_ENABLED" = true ]; then
    ETH_ROUTING_RULES="ip rule add from ${ETH_IP_RANGE}.0/24 to ${ETH_IP_RANGE}.0/24 table main priority 100 2>/dev/null || true; ip rule add to ${ETH_IP_RANGE}.0/24 table main priority 50 2>/dev/null || true; "
fi
sudo tee /etc/systemd/system/tailscale-routing.service > /dev/null <<EOF
[Unit]
Description=Ensure Tailscale routing and fix conflicts
After=tailscale-exit.service
Wants=tailscale-exit.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 5; ip rule add from ${AP_IP_RANGE}.0/24 to ${AP_IP_RANGE}.0/24 table main priority 100 2>/dev/null || true; ip rule add to ${AP_IP_RANGE}.0/24 table main priority 50 2>/dev/null || true; ${ETH_ROUTING_RULES}ip route del default dev tailscale0 2>/dev/null || true; ip route del 0.0.0.0/1 dev tailscale0 2>/dev/null || true; ip route del 128.0.0.0/1 dev tailscale0 2>/dev/null || true'
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
ExecStart=/bin/bash -c 'ip link set $AP_WIFI down 2>/dev/null || true; iw dev $AP_WIFI set type managed 2>/dev/null || true; ip link set $AP_WIFI up 2>/dev/null || true; iw dev $AP_WIFI set power_save off 2>/dev/null || true; ip link set $AP_WIFI down 2>/dev/null || true; iw dev $AP_WIFI set type __ap 2>/dev/null || true; ip link set $AP_WIFI up 2>/dev/null || true; iw dev $AP_WIFI set power_save off 2>/dev/null || true; ip addr flush dev $AP_WIFI 2>/dev/null || true; ip addr add ${AP_GATEWAY}/24 dev $AP_WIFI 2>/dev/null || true'
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
ETH_ENABLED="$ETH_ENABLED"
ETH_INTERFACE="$ETH_INTERFACE"
ETH_GATEWAY="$ETH_GATEWAY"
GATEWAY_AUTOFIX="$GATEWAY_AUTOFIX"
AP_POWER_SAVE_WARNING_REPORTED=false

# Same rationale as check_internet() in tunnel.sh: ICMP-hostile gateways and
# Wi-Fi power save against a long-beacon-interval AP can make ping unreliable
# while TCP still works. Fall back to TCP reachability before declaring the
# link dead.
wd_check_internet() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && return 0
    timeout 3 bash -c '>/dev/tcp/8.8.8.8/53' 2>/dev/null && return 0
    timeout 3 bash -c '>/dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    return 1
}

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

    # Keep power save off on the AP when the driver supports changing it in AP
    # mode. Verify the result: mt7921u can return success while continuing to
    # report "on", so an unverified command creates a misleading log loop.
    AP_POWER_SAVE=\$(iw dev "\$AP_WIFI" get power_save 2>/dev/null | grep -o "on\|off" || echo "unknown")
    if [ "\$AP_POWER_SAVE" = "on" ]; then
        iw dev "\$AP_WIFI" set power_save off 2>/dev/null || true
        sleep 1
        AP_POWER_SAVE_AFTER=\$(iw dev "\$AP_WIFI" get power_save 2>/dev/null | grep -o "on\|off" || echo "unknown")
        if [ "\$AP_POWER_SAVE_AFTER" = "off" ]; then
            echo "[Watchdog] Disabled power save on \$AP_WIFI"
            AP_POWER_SAVE_WARNING_REPORTED=false
        elif [ "\$AP_POWER_SAVE_WARNING_REPORTED" != "true" ]; then
            echo "[Watchdog] \$AP_WIFI driver refuses power_save=off in AP mode; applied before AP startup and will keep retrying silently"
            AP_POWER_SAVE_WARNING_REPORTED=true
        fi
    else
        AP_POWER_SAVE_WARNING_REPORTED=false
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
    if ! wd_check_internet; then
        # --- Hotel DHCP gateway autofix (route-level only, never persisted) ---
        # Same failure mode as the one-shot check in tunnel.sh: a hotel DHCP server
        # can hand out a bogus gateway (e.g. a transposed-digit typo like 172.10.20.1
        # instead of 172.20.10.1). Every DHCP renewal re-installs the bad gateway, so
        # unlike tunnel.sh's one-shot fix, the watchdog must keep re-applying this on
        # every loop instead of fixing it once. Deliberately does NOT call nmcli to
        # pin the gateway - route-only, so nothing stale outlives this network.
        WD_AUTOFIX_OK=false
        if [ "\$GATEWAY_AUTOFIX" = "true" ]; then
            WD_GW=\$(ip route show default dev "\$HOTEL_WIFI" 2>/dev/null | awk '{print \$3}' | head -1)
            if [ -n "\$WD_GW" ]; then
                WD_CIDR=\$(ip -o -f inet addr show "\$HOTEL_WIFI" 2>/dev/null | awk '{print \$4}' | head -1)
                if [ -n "\$WD_CIDR" ]; then
                    WD_IP_PART="\${WD_CIDR%/*}"
                    WD_PREFIX="\${WD_CIDR#*/}"
                    IFS='.' read -r WD_A WD_B WD_C WD_D <<< "\$WD_IP_PART"
                    WD_IP_INT=\$(( (WD_A<<24) + (WD_B<<16) + (WD_C<<8) + WD_D ))
                    if [ "\$WD_PREFIX" -eq 0 ] 2>/dev/null; then
                        WD_MASK=0
                    else
                        WD_MASK=\$(( (0xFFFFFFFF << (32 - WD_PREFIX)) & 0xFFFFFFFF ))
                    fi
                    WD_NET_INT=\$(( WD_IP_INT & WD_MASK ))
                    WD_CAND_INT=\$(( WD_NET_INT + 1 ))
                    WD_CANDIDATE=\$(printf '%d.%d.%d.%d' \$(( (WD_CAND_INT>>24)&255 )) \$(( (WD_CAND_INT>>16)&255 )) \$(( (WD_CAND_INT>>8)&255 )) \$(( WD_CAND_INT&255 )))

                    IFS='.' read -r WD_GA WD_GB WD_GC WD_GD <<< "\$WD_GW"
                    WD_GW_INT=\$(( (WD_GA<<24) + (WD_GB<<16) + (WD_GC<<8) + WD_GD ))
                    WD_GW_OUTSIDE=false
                    if [ \$(( WD_GW_INT & WD_MASK )) -ne "\$WD_NET_INT" ]; then
                        WD_GW_OUTSIDE=true
                    fi

                    ping -c 1 -W 1 "\$WD_GW" >/dev/null 2>&1 || true
                    WD_NEIGH=\$(ip neigh show "\$WD_GW" dev "\$HOTEL_WIFI" 2>/dev/null)
                    WD_NEIGH_BAD=false
                    if [ -z "\$WD_NEIGH" ] || echo "\$WD_NEIGH" | grep -qiE 'INCOMPLETE|FAILED' || ! echo "\$WD_NEIGH" | grep -q 'lladdr'; then
                        WD_NEIGH_BAD=true
                    fi

                    if { [ "\$WD_NEIGH_BAD" = true ] || [ "\$WD_GW_OUTSIDE" = true ]; } && [ "\$WD_CANDIDATE" != "\$WD_GW" ]; then
                        echo "[Watchdog] Gateway \$WD_GW looks broken (ARP bad: \$WD_NEIGH_BAD, outside subnet: \$WD_GW_OUTSIDE) - trying \$WD_CANDIDATE (route-only, not persisted)..."
                        if ip route replace default via "\$WD_CANDIDATE" dev "\$HOTEL_WIFI" 2>/dev/null && wd_check_internet; then
                            echo "[Watchdog] Gateway autofix succeeded - now routing via \$WD_CANDIDATE"
                            WD_AUTOFIX_OK=true
                        else
                            echo "[Watchdog] Gateway autofix candidate \$WD_CANDIDATE did not restore connectivity - reverting"
                            ip route replace default via "\$WD_GW" dev "\$HOTEL_WIFI" 2>/dev/null || true
                        fi
                    fi
                fi
            fi
        fi

        # If the autofix above restored internet, skip the reconnect logic below for
        # this cycle. A reconnect renews DHCP, which re-installs the bad gateway --
        # and the real gateway may drop ping-to-self (this exact hotel's did), so the
        # gateway ping below would be a false negative that undoes the repair.
        if [ "\$WD_AUTOFIX_OK" = true ]; then
            echo "[Watchdog] Gateway autofix restored internet - skipping reconnect this cycle"
        else
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

    # ==========================================================================
    # ETHERNET SHARING MONITORING - Check if the wired interface still holds its
    # static gateway address (ETH_ENABLE=true only)
    # ==========================================================================
    if [ "\$ETH_ENABLED" = "true" ]; then
        if ! ip addr show "\$ETH_INTERFACE" 2>/dev/null | grep -q "\$ETH_GATEWAY"; then
            echo "[Watchdog] Ethernet interface \$ETH_INTERFACE lost \$ETH_GATEWAY - re-applying..."
            ip addr add "\$ETH_GATEWAY/24" dev "\$ETH_INTERFACE" 2>/dev/null || true
        fi
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
# hostapd may reset driver power state while bringing up the AP. Apply once more
# after startup and report the actual state instead of assuming success.
sudo iw dev "$AP_WIFI" set power_save off 2>/dev/null || true
AP_POWER_SAVE_AFTER_START=$(iw dev "$AP_WIFI" get power_save 2>/dev/null | awk '{print $3}' || echo "unknown")
if [ "$AP_POWER_SAVE_AFTER_START" = "off" ]; then
    echo "✅ AP Wi-Fi power save is off"
else
    echo "⚠️  $AP_WIFI driver reports power save '$AP_POWER_SAVE_AFTER_START' in AP mode"
fi
sudo systemctl start dnsmasq
sudo systemctl start tunnel-watchdog

# Check service status
echo "=== Service Status ==="
sudo systemctl --no-pager status hostapd
sudo systemctl --no-pager status dnsmasq

# --- Configure Tailscale routing ---
echo "=== Configuring Tailscale routing ==="
echo "Checking if Tailscale is authenticated..."

if ! sudo tailscale ip -4 >/dev/null 2>&1; then
    echo "❌ EXITING: Tailscale authentication was lost; leaving routing unchanged"
    sudo tailscale status 2>&1 | head -5 || true
    exit 1
fi

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

# Fix Tailscale hijacking local ethernet client traffic (ETH_ENABLE=true)
if [ "$ETH_ENABLED" = true ]; then
    sudo ip rule add from ${ETH_IP_RANGE}.0/24 to ${ETH_IP_RANGE}.0/24 table main priority 100 2>/dev/null || echo "Local ethernet routing rule already exists"
    sudo ip rule add to ${ETH_IP_RANGE}.0/24 table main priority 50 2>/dev/null || echo "Ethernet return traffic routing rule already exists"
fi

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

# Remove immutable flag if still set from earlier package-update protection
if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
    echo "   Removing immutable flag from /etc/resolv.conf..."
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
fi

# Give Tailscale a moment to update resolv.conf
sleep 3

# Check if Tailscale is managing DNS; if not, force it
if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
    echo "✅ Tailscale DNS is active"
else
    echo "   Tailscale DNS not detected in resolv.conf - forcing Tailscale DNS..."
    
    # Tailscale on Linux without systemd-resolved often cannot write resolv.conf
    # on its own. Write it directly to prevent DNS leaks.
    # ONLY Tailscale DNS -- no public fallback to prevent DNS leaks.
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    sudo rm -f /etc/resolv.conf
    echo "nameserver 100.100.100.100" | sudo tee /etc/resolv.conf > /dev/null
    
    # Lock the file so NetworkManager/dhcpcd cannot overwrite it with local DHCP DNS.
    sudo chattr +i /etc/resolv.conf 2>/dev/null || true

    # Verify the write worked
    if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
        echo "✅ Tailscale DNS forced into resolv.conf"
    else
        echo "❌ Failed to write Tailscale DNS to resolv.conf"
    fi
    
    # Verify DNS actually resolves through Tailscale
    sleep 1
    if ping -c 1 -W 3 google.com >/dev/null 2>&1; then
        echo "✅ DNS resolution working through Tailscale"
    else
        echo "⚠️  DNS resolution not working yet (Tailscale DNS may need a moment)"
    fi
fi

echo "✅ Tailscale routing configured"

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
EXIT_NODE_WORKING=false

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
        EXIT_NODE_WORKING=true
    else
        echo "   ❌ Internet working but NOT through exit node ($MYIP)"
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

# Check 7: DNS Leak
echo ""
echo "7️⃣ DNS Leak Check:"
if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
    echo "   ✅ Tailscale DNS (100.100.100.100) is primary in resolv.conf"
else
    echo "   ❌ DNS LEAK: Tailscale DNS not in resolv.conf!"
    echo "   🔍 Current resolv.conf:"
    grep nameserver /etc/resolv.conf 2>/dev/null | head -3 | while read -r line; do echo "      $line"; done
    echo "   🔧 Fixing DNS leak now..."
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    sudo rm -f /etc/resolv.conf
    echo "nameserver 100.100.100.100" | sudo tee /etc/resolv.conf > /dev/null
    if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null; then
        echo "   ✅ DNS leak fixed - Tailscale DNS is now primary"
    else
        echo "   ❌ Failed to fix DNS leak"
    fi
fi

# Check 8: Ethernet Sharing (only when ETH_ENABLE=true)
ETH_SHARING_OK=false
if [ "$ETH_ENABLED" = true ]; then
    echo ""
    echo "8️⃣ Ethernet Sharing:"
    if ip addr show "$ETH_INTERFACE" 2>/dev/null | grep -q "$ETH_GATEWAY"; then
        echo "   ✅ $ETH_INTERFACE has $ETH_GATEWAY - clients can connect via ethernet"
        echo "   💡 ssh/VNC to $ETH_GATEWAY works even with no upstream internet"
        ETH_SHARING_OK=true
    else
        echo "   ❌ $ETH_INTERFACE is missing $ETH_GATEWAY"
    fi
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
if [ "$ETH_ENABLED" = true ]; then
    echo "  - Ethernet ($ETH_INTERFACE): Internet sharing at $ETH_GATEWAY"
    echo "    Clients can connect a cable and reach the tunnel via $ETH_INTERFACE ($ETH_GATEWAY)"
    echo "    ssh/VNC to $ETH_GATEWAY works even with no upstream internet"
fi
echo ""

# Check if everything is working
TOTAL_CHECKS=6
CHECKS_PASSED=0
if iwconfig $ONBOARD_WIFI 2>/dev/null | grep -q "ESSID:"; then ((CHECKS_PASSED++)); fi
if sudo iw dev $USB_WIFI info | grep -q "type AP" && ip addr show $USB_WIFI | grep -q "$AP_GATEWAY"; then ((CHECKS_PASSED++)); fi
if systemctl is-active --quiet hostapd && systemctl is-active --quiet dnsmasq; then ((CHECKS_PASSED++)); fi
if sudo tailscale status | grep -q "$TAILSCALE_EXIT_NODE_NAME.*active.*exit node"; then ((CHECKS_PASSED++)); fi
if ! ip route show | grep -q "0.0.0.0/1 dev tailscale0" && ! ip route show | grep -q "128.0.0.0/1 dev tailscale0"; then ((CHECKS_PASSED++)); fi
if systemctl is-active --quiet tunnel-watchdog; then ((CHECKS_PASSED++)); fi
if [ "$ETH_ENABLED" = true ]; then
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ "$ETH_SHARING_OK" = true ]; then ((CHECKS_PASSED++)); fi
fi

if [ "$EXIT_NODE_WORKING" = true ] && [ $CHECKS_PASSED -eq $TOTAL_CHECKS ]; then
    echo "🎉 ALL SYSTEMS GO! Your tunnel is ready!"
    echo "   Connect your devices to '$AP_SSID' and enjoy secure browsing!"
elif [ $CHECKS_PASSED -ge 3 ]; then
    echo "⚠️  MOSTLY WORKING - Some issues detected above"
    echo "   Your tunnel should work but may need manual fixes"
else
    echo "❌ SETUP INCOMPLETE - Multiple issues detected"
    echo "   Please review the checks above and fix the issues"
fi

# CRITICAL: Fail the script if traffic is not going through the exit node
if [ "$EXIT_NODE_WORKING" != true ]; then
    echo ""
    echo "❌ =========================================="
    echo "❌  TUNNEL SETUP FAILED"
    echo "❌ =========================================="
    echo ""
    echo "   Traffic is NOT going through your exit node."
    echo "   Expected IP: $TAILSCALE_EXPECTED_IP"
    echo ""
    echo "   Possible causes:"
    echo "   1. Exit node '$TAILSCALE_EXIT_NODE_NAME' ($TAILSCALE_EXIT_NODE_IP) is not advertising as an exit node"
    echo "      Fix on the exit node machine: sudo tailscale up --advertise-exit-node"
    echo "   2. Exit node is offline or unreachable"
    echo "      Check: sudo tailscale status | grep $TAILSCALE_EXIT_NODE_NAME"
    echo "   3. Tailscale routing is misconfigured"
    echo "      Check: sudo tailscale status"
    echo ""
    echo "   After fixing, re-run: ./tunnel.sh"
    echo ""
    exit 1
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
    sudo sed -i "s/unmanaged-devices=.*wlan0.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    sudo sed -i "s/unmanaged-devices=.*$ONBOARD_WIFI.*/unmanaged-devices=$(nm_unmanaged_devices_value "$USB_WIFI")/g" /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
    echo "   ✅ Config file fixed"
fi

# Check current status
NM_WLAN0_FINAL_CHECK=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" || echo "")
if [ -n "$NM_WLAN0_FINAL_CHECK" ] && ! echo "$NM_WLAN0_FINAL_CHECK" | grep -qE "(unmanaged|unavailable)"; then
    echo "✅ $ONBOARD_WIFI is managed: $(echo "$NM_WLAN0_FINAL_CHECK" | awk '{print $3}')"
    echo "✅ nmtui is ready to use!"
else
    echo "⚠️  $ONBOARD_WIFI is NOT managed! Attempting aggressive fix..."
    
    write_clean_nm_conf "$ONBOARD_WIFI" "$USB_WIFI" "$ETH_INTERFACE"
    
    # Reload NetworkManager config
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
        echo "📋 Please re-run ./tunnel.sh (it will rewrite NetworkManager.conf cleanly)"
        echo "   Or manually: sudo systemctl restart NetworkManager"
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
    write_clean_nm_conf "$ONBOARD_WIFI" "$USB_WIFI" "$ETH_INTERFACE"
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
        echo "   📋 Re-run ./tunnel.sh (it will rewrite NetworkManager.conf cleanly)"
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
