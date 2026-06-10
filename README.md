## shadowsocks-v2ray-bash
shadowsocks + v2ray deployment scripts for server and client, support tcp + udp redirect with split tunneling, for use in multitier vpn setups, tested on ubuntu 22.04


## Usage
### Server
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/ss-v2ray-server.sh
sed -i 's/\r$//' ./ss-v2ray-server.sh
chmod +x ss-v2ray-server.sh
./ss-v2ray-server.sh
```
### Client
```
wget -q https://raw.githubusercontent.com/ravThirst/shadowsocks-v2ray-bash/refs/heads/main/ss-v2ray-client.sh
sed -i 's/\r$//' ./ss-v2ray-client.sh
chmod +x ss-v2ray-client.sh
./ss-v2ray-client.sh
```
