# Mullvad-pi (for wireguard)

```bash
git clone git@github.com:gco/mullvadvpn-app.git
cd mullvadvpn-app
git submodule update --init --recursive
. ./env.sh
( cd dist-assets/binaries && mkdir aarch64-unknown-linux-gnu && gmake libnftnl )
( cd wireguard  && ./build-wireguard-go.sh )
cargo build --release
```

```bash
./update-relays.sh
./update-api-address.sh
```

```bash
mkdir /etc/mullvad-vpn
mkdir -p /opt/Mullvad\ VPN/resources
cp target/release/mullvad-daemon dist-assets/api-ip-address.txt dist-assets/relays.json dist-assets/linux/mullvad-daemon.server "/opt/Mullvad VPN/resources/"
cp target/release/mullvad /usr/bin

systemctl enable "/opt/Mullvad VPN/resources/mullvad-daemon.service"
systemctl start mullvad-daemon.service
```
