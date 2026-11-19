#!/usr/bin/env bash
# Desinstala el nodo de emergencia y deja la red como estaba antes de instalar.sh:
#   1. detiene los contenedores   2. (sudo) quita el vigía, el firewall, la Wi-Fi de emergencia,
#   el DNS del portal cautivo, las reglas de UFW y los archivos de sistema.
# No borra lo descargado (mapas, biblioteca, índice): al final dice dónde está y cómo borrarlo.
# Uso: ./desinstalar.sh [--simular]     (--simular muestra lo que haría, sin cambiar nada)
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
CONF="$AQUI/emergencia.conf"
SIMULAR=0
for a in "$@"; do
	case "$a" in
		--simular) SIMULAR=1 ;;
		*) echo "opción desconocida: $a" >&2; exit 2 ;;
	esac
done
[ -f "$CONF" ] || CONF=/etc/nodo-emergencia.conf
[ -f "$CONF" ] || { echo "No encuentro emergencia.conf: ¿está instalado?" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

hacer() { # ejecuta, o solo muestra con --simular
	if [ "$SIMULAR" = 1 ]; then echo "  [simular] $*"; else "$@"; fi
}
# Igual que hacer(), pero sin cortar el script si no había nada que quitar.
quitar() { hacer "$@" 2>/dev/null || true; }

echo "1. Contenedores"
if [ -n "${STACK_DIR:-}" ] && [ -f "$STACK_DIR/compose.yaml" ]; then
	quitar docker compose --project-directory "$STACK_DIR" down
else
	echo "  (no hay stack en ${STACK_DIR:-?})"
fi

echo "2. Vigía, firewall y Wi-Fi de emergencia (necesita sudo)"
S=sudo
[ "$(id -u)" = 0 ] && S=
for u in emergencia-vigia.timer emergencia-vigia.service emergencia-firewall.service; do
	quitar $S systemctl disable --now "$u"
done
quitar $S rm -f /etc/systemd/system/emergencia-vigia.timer /etc/systemd/system/emergencia-vigia.service \
	/etc/systemd/system/emergencia-firewall.service
quitar $S systemctl daemon-reload

# Reglas del firewall (cadena NODO-EMERGENCIA en mangle, IPv4 e IPv6).
for T in /usr/sbin/iptables /usr/sbin/ip6tables; do
	while $S "$T" -t mangle -C PREROUTING -i "$WIFI_IF" -j NODO-EMERGENCIA 2>/dev/null; do
		hacer $S "$T" -t mangle -D PREROUTING -i "$WIFI_IF" -j NODO-EMERGENCIA
		[ "$SIMULAR" = 1 ] && break
	done
	quitar $S "$T" -t mangle -F NODO-EMERGENCIA
	quitar $S "$T" -t mangle -X NODO-EMERGENCIA
done

# Wi-Fi de emergencia y portal cautivo.
quitar $S nmcli connection delete emergencia-ap
quitar $S rm -f /etc/NetworkManager/dnsmasq-shared.d/nodo-emergencia.conf /etc/modprobe.d/nodo-emergencia.conf

# UFW: las mismas reglas que agregó sistema.sh.
if command -v ufw >/dev/null && $S ufw status 2>/dev/null | grep -q "Status: active"; then
	quitar $S ufw delete allow in on "$WIFI_IF" to any port 67 proto udp
	quitar $S ufw delete allow in on "$WIFI_IF" to "$IP_AP" port 53
fi

# Programas y configuración de root.
quitar $S rm -f /usr/local/sbin/nodo-emergencia /etc/nodo-emergencia.conf
quitar $S rm -f /usr/local/lib/nodo-emergencia/vigia.sh /usr/local/lib/nodo-emergencia/firewall.sh
quitar $S rmdir /usr/local/lib/nodo-emergencia
# ip_nonlocal_bind vuelve a su valor normal en el próximo reinicio.
quitar $S rm -f /etc/sysctl.d/90-nodo-emergencia.conf

echo
echo "Listo. Se quitó todo lo de sistema; la red de la casa no se tocó."
if [ -n "${STACK_DIR:-}" ] && [ -d "$STACK_DIR" ]; then
	echo "Lo descargado sigue en $STACK_DIR ($(du -sh "$STACK_DIR" 2>/dev/null | cut -f1))."
	echo "Para borrarlo:  sudo rm -r \"$STACK_DIR\""
fi
[ -n "${LOG_FILE:-}" ] && [ -e "$LOG_FILE" ] && echo "Registro del vigía: $LOG_FILE (puedes borrarlo)."
[ "$SIMULAR" = 1 ] && echo "(Simulación: no se cambió nada.)"
exit 0
