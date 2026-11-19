#!/usr/bin/env bash
# Parte de la instalación que necesita root: Wi-Fi de emergencia, portal cautivo, firewall y vigía.
# La llama instalar.sh con sudo. Uso: sudo sistema/sistema.sh RUTA/emergencia.conf
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "ejecutar con sudo" >&2; exit 1; }
AQUI="$(cd "$(dirname "$0")" && pwd)"
CONF_ORIGEN="${1:?falta la ruta a emergencia.conf}"
# shellcheck disable=SC1090
. "$CONF_ORIGEN"
LIB=/usr/local/lib/nodo-emergencia

command -v nmcli >/dev/null || { echo "falta NetworkManager (nmcli)" >&2; exit 1; }
nmcli -t -f DEVICE device | grep -qx "$WIFI_IF" || { echo "no existe la interfaz $WIFI_IF" >&2; exit 1; }

# 1. Programas y configuración (copias de root: el servicio no ejecuta archivos editables por el usuario)
install -d -m 755 "$LIB"
install -m 755 "$AQUI/vigia.sh" "$LIB/vigia.sh"
install -m 755 "$AQUI/firewall.sh" "$LIB/firewall.sh"
install -m 644 "$CONF_ORIGEN" /etc/nodo-emergencia.conf
ln -sf "$LIB/vigia.sh" /usr/local/sbin/nodo-emergencia
if [ -n "${LOG_FILE:-}" ] && [ ! -e "$LOG_FILE" ]; then
	touch "$LOG_FILE"; [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$LOG_FILE"
fi

# 2. Perfil de la Wi-Fi de emergencia (abierta, 2,4 GHz, sin autoconexión: la enciende el vigía).
#    ap-isolation: los celulares conectados no se ven entre sí (solo al nodo).
P=(802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.ap-isolation 1
   802-11-wireless.channel "${CANAL:-6}" ipv4.method shared ipv4.addresses "$IP_AP/24"
   ipv6.method disabled connection.autoconnect no connection.interface-name "$WIFI_IF")
if nmcli -t -f NAME connection show | grep -qx emergencia-ap; then
	nmcli connection modify emergencia-ap 802-11-wireless.ssid "$SSID" "${P[@]}"
else
	nmcli connection add type wifi con-name emergencia-ap ifname "$WIFI_IF" ssid "$SSID" "${P[@]}" >/dev/null
fi
# Otras redes Wi-Fi guardadas con autoconexión le quitarían la antena al punto de acceso.
nmcli -t -f NAME,TYPE,AUTOCONNECT connection show | awk -F: '$2=="802-11-wireless" && $3=="yes" && $1!="emergencia-ap"{print $1}' |
	while read -r n; do echo "AVISO: la red Wi-Fi guardada '$n' se conecta sola; considera: nmcli connection modify '$n' connection.autoconnect no"; done

# 3. Portal cautivo: el DNS de la red de emergencia responde todo con la IP del nodo
install -d /etc/NetworkManager/dnsmasq-shared.d
cat > /etc/NetworkManager/dnsmasq-shared.d/nodo-emergencia.conf <<EOF
# Nodo de emergencia: todo nombre apunta al portal (portal cautivo). Generado por sistema.sh.
address=/#/$IP_AP
EOF

# 4. País de la radio (canales y potencia legales)
if [ -n "${PAIS:-}" ]; then
	echo "options cfg80211 ieee80211_regdom=$PAIS" > /etc/modprobe.d/nodo-emergencia.conf
	command -v iw >/dev/null && iw reg set "$PAIS" 2>/dev/null || true
fi

# 5. UFW (si está activo): DHCP y DNS hacia el nodo desde la red de emergencia
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
	ufw allow in on "$WIFI_IF" to any port 67 proto udp comment "Emergencia: DHCP" >/dev/null
	ufw allow in on "$WIFI_IF" to "$IP_AP" port 53 comment "Emergencia: DNS" >/dev/null
fi

# 6. Servicios
cat > /etc/systemd/system/emergencia-firewall.service <<EOF
[Unit]
Description=Nodo de emergencia: aislamiento de la Wi-Fi de emergencia
After=network-pre.target ufw.service
Before=NetworkManager.service docker.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB/firewall.sh

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/emergencia-vigia.service <<EOF
[Unit]
Description=Nodo de emergencia: revisa internet y enciende/apaga la Wi-Fi de emergencia
After=NetworkManager.service emergencia-firewall.service
Requires=emergencia-firewall.service

[Service]
Type=oneshot
ExecStart=$LIB/vigia.sh revisar
EOF
cat > /etc/systemd/system/emergencia-vigia.timer <<EOF
[Unit]
Description=Nodo de emergencia: vigía cada 30 s

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now emergencia-firewall.service >/dev/null
systemctl restart emergencia-firewall.service
systemctl enable --now emergencia-vigia.timer >/dev/null
echo "Vigía activo. Estado: sudo nodo-emergencia estado"
