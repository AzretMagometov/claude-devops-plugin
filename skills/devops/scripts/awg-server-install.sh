#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${SERVER_IP:?SERVER_IP is required}" "${AWG_BINARY:?AWG_BINARY is required}"
[ "$(uname -m)" = x86_64 ] || { echo 'Only x86_64 is supported' >&2; exit 1; }
[ ! -e /etc/amnezia/amneziawg/awg0.conf ] || { echo 'AWG configuration exists; refusing to overwrite' >&2; exit 1; }
[ ! -e /var/lib/awg-clients/user-01.conf ] || { echo 'Existing AWG client found; refusing to overwrite' >&2; exit 1; }
python3 - <<'CHECK_ROUTES'
import ipaddress, json, subprocess, sys
vpn = ipaddress.ip_network('10.77.0.0/24')
routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'table', 'all']))
for route in routes:
    dst = route.get('dst', 'default')
    if dst != 'default' and ipaddress.ip_network(dst, strict=False).overlaps(vpn):
        sys.exit('VPN subnet conflicts with an existing route: ' + dst)
CHECK_ROUTES
[ ! -d /sys/module/amneziawg ] || { echo 'Existing kernel module detected' >&2; exit 1; }
! command -v awg >/dev/null || { echo 'Existing awg installation detected' >&2; exit 1; }
! ss -Hlun 'sport = :51820' | grep -q . || { echo 'UDP port 51820 already in use' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -q
apt-get install -y -q build-essential pkg-config git
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q https://github.com/amnezia-vpn/amneziawg-tools.git "$work/tools"
git -C "$work/tools" checkout -q ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
make -C "$work/tools/src" -j2
make -C "$work/tools/src" install WITH_SYSTEMDUNITS=yes
install -m 755 "$AWG_BINARY" /usr/local/bin/amneziawg-go
D=/etc/amnezia/amneziawg
C=$D/awg0.conf
[ ! -e "$C" ] || { echo 'AWG config already exists, refusing to overwrite' >&2; exit 1; }
[ ! -d /sys/module/amneziawg ] || { echo 'Existing kernel module detected, refusing to proceed' >&2; exit 1; }
! ss -Hlun 'sport = :51820' | grep -q . || { echo 'UDP port 51820 already in use' >&2; exit 1; }
iface=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[[ "$iface" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
install -d -m 700 "$D" /var/lib/awg-clients
server_private=$(awg genkey); server_public=$(printf '%s' "$server_private" | awg pubkey)
client_private=$(awg genkey); client_public=$(printf '%s' "$client_private" | awg pubkey)
header_key=$(awg genkey)
cat > "$C" <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $server_private
Jc = 6
Jmin = 50
Jmax = 1000
S1 = 76
S2 = 47
S3 = 33
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $header_key
ContentPaddingAddition = 10-100
PostUp = iptables -I FORWARD 1 -i %i -o $iface -s 10.77.0.0/24 -j ACCEPT; iptables -I FORWARD 1 -i $iface -o %i -d 10.77.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $iface -s 10.77.0.0/24 -j ACCEPT; iptables -D FORWARD -i $iface -o %i -d 10.77.0.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.77.0.0/24 -o $iface -j MASQUERADE

[Peer]
PublicKey = $client_public
AllowedIPs = 10.77.0.2/32
EOF
cat > /var/lib/awg-clients/user-01.conf <<EOF
[Interface]
PrivateKey = $client_private
Address = 10.77.0.2/32
DNS = 1.1.1.1
MTU = 1280
Jc = 6
Jmin = 50
Jmax = 1000
S1 = 76
S2 = 47
S3 = 33
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $header_key
ContentPaddingAddition = 10-100

[Peer]
PublicKey = $server_public
Endpoint = $SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-awg-forward.conf
sysctl -p /etc/sysctl.d/90-awg-forward.conf
ufw allow 51820/udp
rm -f /etc/apt/apt.conf.d/52-auto-reboot
systemctl daemon-reload
systemctl enable --now awg-quick@awg0
systemctl is-active awg-quick@awg0
