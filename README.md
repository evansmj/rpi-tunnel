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
DNS Leaks are prevented by using tailscale DNS.
Monitors can't tell you are using a vpn, because you are using your own home connection to reach
the internet.

Setup:
Set up a tailscale exit node at home on a spare computer or raspberrypi.
On your travel router: 
  Flash raspberrypi bookworm os and set it up with a wifi that your computer is also on 
  (for initial setup to be able to run ssh.  Alternatively connect your computer to your
  raspberrypi with an ethernet cable to be able to ssh into the raspberrypi.)
  Create a file tunnel.conf based on tunnel.conf.example. `nano tunnel.conf`
  Copy tunnel.sh to the raspberrypi and run `chmod +X tunnel.sh` to make it executable.
  run `./tunnel.sh` and look for success in the health checks.

If you need to connect the travel router to a new hotel's wifi, run `nmtui` to enter the
new hotel wifi and password.

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
