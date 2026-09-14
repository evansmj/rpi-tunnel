This program is for people who, while traveling, need all of their devices to use an
internet connection in a different location.  Run a tailscale exit node at home, and run this
program for example on a travel raspberrypi5 Bookworm with a usb wifi adapter.  
Connect this travel raspberrypi to the hotel's internet using the built-in wifi adapter.
Now every device you connect to your travel raspberrypi's wifi network "MyTunnel" will tunnel
to your exit node.  

Benefits:
All your devices automatically think they are at your home location.  No need to configure each
individually to proxy.  
Anyone monitoring your device at the OS level has no way to know your actual location.
Any hackers at the local coffee shop wifi cannot read your traffic.
DNS Leaks are prevented by using tailscale DNS (verify this yourself after setup -
see "Verifying there is no DNS leak" below).
Monitors can't tell you are using a vpn, because you are using your own home connection to reach
the internet.

Setup:
Set up a tailscale exit node at home on a spare computer or raspberrypi.
If you are using umbrel, see my `umbrel-docker-compose.yml` file for help in setting it as an exit node.
On your travel router:
  Make sure you have 2 wifi adapters/antennas.  I've used an Asus USB-N53 and a NetGear usb wifi with success.  The internal raspberrypi5 wifi antenna connects to the hotel wifi, and the usb wifi adapter provides wifi access for your devices to connect to. 
  Flash raspberrypi bookworm os and set it up with a wifi that your computer is also on 
  (for initial setup to be able to run ssh.  Alternatively connect your computer to your
  raspberrypi with an ethernet cable to be able to ssh into the raspberrypi.)
  Create a file tunnel.conf based on tunnel.conf.example. `nano tunnel.conf`
  Copy tunnel.sh to the raspberrypi and run `chmod +X tunnel.sh` to make it executable.
  run `./tunnel.sh` and look for success in the health checks.

If you need to connect the travel router to a new hotel's wifi, run `nmtui` to enter the
new hotel wifi and password.

Plug the USB wifi adapter into a BLACK (USB 2.0) port, not a blue (USB 3.0) one:
  USB 3.0 signalling radiates broadband interference right across the 2.4GHz band, and
  the raspberrypi's onboard antenna sits inches away.  This does not look like
  interference when you debug it - it looks like a weak or congested hotel wifi: low
  negotiated bitrate, poor RSSI, erratic latency on large packets, and throughput that
  collapses under sustained load.  Measured on a Pi 5: 2 Mbps through the tunnel with the
  adapter on USB 3.0, 12 Mbps after moving it (and a phone charger) to the black ports.
  USB 2.0 gives ~300 Mbps, far more than any hotel connection, so there is no speed cost.
  If you need USB 3.0 for something else, use a shielded extension cable to get the
  device away from the antenna.

Traveling outside your home country:
  Set REGULATORY_COUNTRY in tunnel.conf to where you actually are.  It is applied
  globally, so a wrong value also restricts the onboard adapter that connects to the
  hotel - for example a US setting cannot use 2.4GHz channels 12-13, which are legal and
  commonly used in Europe.  Change AP_CHANNEL to a channel that is legal in that country
  at the same time (36-48 are safe about everywhere), otherwise hostapd will refuse to
  start and the watchdog will restart it in a loop.

Verifying there is no DNS leak:
  Connect a device to the tunnel and visit a DNS leak test site.  Every resolver listed
  should be reachable from your exit node's location.  If you see a resolver belonging to
  the local ISP where you are physically sitting, DNS is leaking - your public IP can
  look completely correct while this is happening, so check it explicitly.
  On the travel router, these should all hold:
    cat /etc/resolv.conf        # only "nameserver 100.100.100.100"
    lsattr /etc/resolv.conf     # the "i" (immutable) flag is set
    grep no-resolv /etc/dnsmasq.conf
  `no-resolv` matters because dnsmasq's `server=` line is additive, not exclusive -
  without it dnsmasq also forwards to whatever is in /etc/resolv.conf.

Ethernet sharing:
  Set ETH_ENABLE="true" in tunnel.conf to also share the tunnel over the Pi's ethernet
  port. Plug a laptop into it and it gets a DHCP lease automatically, on its own subnet
  (ETH_IP_RANGE, separate from the access point's AP_IP_RANGE) tunneled through the exit
  node the same way Wi-Fi clients are.
  The ethernet gateway (ETH_GATEWAY, e.g. 10.0.60.1) is always reachable from a plugged-in
  laptop, even with no hotel Wi-Fi configured yet - `ssh pi@10.0.60.1` works before the
  Pi has any upstream internet at all. Use the IP, not the hostname: mDNS/hostname
  resolution may not be up yet. This is the easiest way to do headless setup: ssh in over
  the cable and run `sudo nmtui` to join the hotel Wi-Fi, or use TigerVNC over the cable
  to click through a captive portal.
  Ethernet-to-hotel-Wi-Fi forwarding is deliberately blocked, so if the tunnel is down,
  ethernet client traffic fails closed instead of leaking out the hotel connection.
  Turn off (or deprioritize) the laptop's own Wi-Fi once it's plugged in, otherwise it may
  keep routing over Wi-Fi instead of the cable.
  Verify the same way as a Wi-Fi client: `curl ifconfig.me` should match
  TAILSCALE_EXPECTED_IP, and you still need to run the DNS leak test above - a correct
  exit IP by itself proves nothing about DNS.

Broken hotel gateway autofix:
  Some hotel routers hand out a DHCP gateway that simply doesn't work - e.g. a
  transposed-digit typo like 172.10.20.1 on a 172.20.10.0/23 network, instead of
  the real gateway 172.20.10.1. The Pi gets a normal-looking DHCP lease and IP
  address, but has 100% packet loss, because nothing on the LAN answers ARP for
  that address (`ip neigh` shows it stuck INCOMPLETE). Rebooting or re-running
  tunnel.sh can never fix this by itself, since every DHCP lease re-delivers the
  same bad gateway.
  tunnel.sh detects this (ARP INCOMPLETE/FAILED, not just "ping fails" - many
  real gateways silently drop ICMP to themselves while still forwarding fine)
  and tries likely-correct candidate gateways - the interface's own subnet .1
  address and the DHCP server identifier, if available - until one restores
  internet. The installed watchdog re-applies the same fix on every check,
  since DHCP renewals keep re-installing the bad gateway.
  This is controlled by GATEWAY_AUTOFIX in tunnel.conf (default "true"). The fix
  is route-only and deliberately non-persistent, so nothing stale outlives the
  network - it prints the exact `sudo nmcli connection modify ... ipv4.gateway
  <ip>` command if you want to pin it yourself for the rest of your stay.

ICMP-hostile networks and Wi-Fi power save:
  At one hotel, the AP used a 300ms beacon interval, and the Pi's hotel-facing
  radio had Wi-Fi power save enabled. That combination pushed ping RTTs to the
  Pi's own gateway lookups to ~8 seconds with 66-100% loss, even though TCP
  connections worked fine the whole time - the radio was dozing between beacons
  and buffering frames (including ICMP replies) for seconds. Since every
  connectivity gate in tunnel.sh was a single `ping -c 1 8.8.8.8`, the script
  false-failed with "NO INTERNET" on a network that actually worked fine.
  tunnel.sh now checks connectivity with `check_internet()`, which falls back to
  a raw TCP connect (port 53 and 443 on public DNS resolvers) when ping fails or
  times out, so a slow/lossy-but-working ICMP path no longer aborts setup. It
  also disables power save on the hotel Wi-Fi interface as soon as the internet
  check succeeds (`iw dev ... set power_save off`, persisted best-effort via
  `nmcli ... 802-11-wireless.powersave 2`), and the watchdog re-asserts this
  every loop since NetworkManager can silently re-enable it on reconnect.

```
✅ Letting Tailscale manage exit node routing automatically
✅ Tailscale routing configured

🔍 === SYSTEM HEALTH CHECKS ===

1️⃣ Wi-Fi Interface Status:
   Onboard Wi-Fi (wlan0):
   ✅ Connected to: MotelWifi
   USB Wi-Fi (wlan1):
   ✅ Access Point mode with IP 10.0.50.1

2️⃣ Service Status:
   ✅ hostapd: Running
   ✅ dnsmasq: Running
   ✅ tailscaled: Running

3️⃣ Tailscale Status:
   ✅ Connected to exit node 'myexitnodeathome'

4️⃣ Routing Configuration:
   ✅ Tailscale managing routing automatically (no manual routes)

5️⃣ Internet Connectivity Test:
   🔍 Debug: Testing basic connectivity...
   ✅ Internet reachable via IP (8.8.8.8)
   ✅ DNS resolution working
   🔍 Testing web connectivity...
   ✅ Internet working through exit node (your-home-ip-address)
   🔍 Current routing table:
default via redacted-ip dev wlan0 proto dhcp src redacted-ip metric 600 
redacted-ip/24 dev wlan1 proto kernel scope link src redacted-ip 
redacted-ip/24 dev wlan0 proto kernel scope link src redacted-ip metric 600 

6️⃣ NAT Configuration:
   ✅ NAT rules configured for Tailscale

🎯 === SETUP SUMMARY ===

🔧 Configuration:
  - Onboard Wi-Fi (wlan0): Hotel connection
  - USB Wi-Fi (wlan1): Access point 'MyTravelWifi'
  - Access Point IP: 10.0.50.1
  - SSID: MyTravelWifi
  - Password: SecurePass123

```
