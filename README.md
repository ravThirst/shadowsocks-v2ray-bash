## shadowsocks-v2ray-bash
shadowsocks + v2ray deployment scripts for server and client, support tcp + udp redirect with split tunneling, for use in multitier vpn setups, tested on ubuntu 22.04


## Usage

### Before you continue
shadowsocks + v2ray configuration requires a valid domain name associated with server IP for TLS 
### Server
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/ss-v2ray-server.sh
sed -i 's/\r$//' ./ss-v2ray-server.sh
chmod +x ss-v2ray-server.sh
./ss-v2ray-server.sh
```
script adds a cert renewal cron task, if you need you can remove default task created by acme.sh (first one by default)
```
sudo crontab -e
```
### Client
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/ss-v2ray-client.sh
sed -i 's/\r$//' ./ss-v2ray-client.sh
chmod +x ss-v2ray-client.sh
./ss-v2ray-client.sh
```

client side is whitelist based, call
```
nano /etc/proxy-ips.txt
```
to edit list of networks to be redirected, for example
```
10.10.0.0\16
10.0.10.0\24
10.0.0.0\8
```
than call
```
/usr/local/bin/update-proxy-ips.sh
```
to save current config

## Xray reverse tunnel (VLESS + WS + TLS)
Uses Xray "VLESS Reverse Proxy" (the legacy `reverse` bridges/portals config was removed from Xray), so both sides need a recent Xray; the scripts install the latest.
For when the entry server can NOT connect to the exit server, but the exit server can connect to the entry server.
The exit server (**bridge**) dials out to the entry server (**portal**) and keeps the connection open; the portal sends traffic back through it.
The portal needs a valid domain name associated with its IP for TLS. The bridge needs no open ports.

```
clients --wg--> [portal / entry] <==VLESS+WS+TLS (initiated by bridge)== [bridge / exit] ---> internet
```

### Portal (entry server)
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/xray-reverse-portal.sh
sed -i 's/\r$//' ./xray-reverse-portal.sh
chmod +x xray-reverse-portal.sh
./xray-reverse-portal.sh
```
at the end it prints domain, port, UUID and WS path for the bridge

### Bridge (exit server)
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/xray-reverse-bridge.sh
sed -i 's/\r$//' ./xray-reverse-bridge.sh
chmod +x xray-reverse-bridge.sh
./xray-reverse-bridge.sh
```

portal side is whitelist based as well, networks from
```
nano /etc/reverse-ips.txt
```
are sent through the bridge, apply with
```
/usr/local/bin/update-reverse-ips.sh
```
can coexist with ss-v2ray-client on the same server (separate ipset, chain and port), keep the lists from overlapping

### Migrating an existing client to portal
if the entry server was set up with `ss-v2ray-client.sh`, run this instead of `xray-reverse-portal.sh`.
It disables ss-redir and lets Xray take over its local port, keeping the existing ipset, `/etc/proxy-ips.txt`, `update-proxy-ips.sh` and iptables rules
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/xray-reverse-migrate.sh
sed -i 's/\r$//' ./xray-reverse-migrate.sh
chmod +x xray-reverse-migrate.sh
./xray-reverse-migrate.sh
```
rollback: `systemctl disable --now xray && systemctl enable --now ss-redir`

### 3x-ui panel with user management on portal
moves an existing portal (set up by `xray-reverse-portal.sh` or `xray-reverse-migrate.sh`) under the [3x-ui](https://github.com/MHSanaei/3x-ui) web panel and adds a separate `users` VLESS+REALITY+Vision inbound (default port 8443) whose clients are managed in the panel (traffic limits, expiry, subscription links).
Bridge, WireGuard redirect and cert stay the same, all traffic still exits through the bridge
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/xray-reverse-3xui.sh
sed -i 's/\r$//' ./xray-reverse-3xui.sh
chmod +x xray-reverse-3xui.sh
./xray-reverse-3xui.sh
```
prints panel URL and credentials at the end. If 3x-ui is already installed, the script runs in repair mode (updates the bridge inbound, converts an old WS `users` inbound to REALITY keeping its users, rewrites routing). In the panel don't edit inbounds marked `(do not edit)` or the `bridge` client (its reverse tag `bridge-out`), and keep the first routing rules in Xray settings.

rollback: `systemctl disable --now x-ui && systemctl enable --now xray`
