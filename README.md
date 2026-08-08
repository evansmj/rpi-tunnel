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
