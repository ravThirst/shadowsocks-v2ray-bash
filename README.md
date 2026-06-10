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
