#!/bin/sh
# Aislamiento de la Wi-Fi de emergencia (red abierta).
# Desde esa interfaz solo se permite: DHCP, DNS y ping al nodo, el portal (80) y los puertos de
# extras locales que se declaren en PUERTOS_AP_EXTRA (ej. "8096").
# Todo lo demás se descarta en mangle/PREROUTING, ANTES del DNAT de Docker y de UFW:
# así no se llega a SSH, ni a los puertos publicados por Docker en otras IPs, ni a la LAN, ni a internet.
# No depende del orden de DOCKER-USER ni de UFW. Idempotente.
set -e
CONF="${CONF:-/etc/nodo-emergencia.conf}"
# shellcheck disable=SC1090
. "$CONF"
C=NODO-EMERGENCIA
for T in /usr/sbin/iptables /usr/sbin/ip6tables; do
	$T -t mangle -N $C 2>/dev/null || $T -t mangle -F $C
	$T -t mangle -C PREROUTING -i "$WIFI_IF" -j $C 2>/dev/null || $T -t mangle -I PREROUTING 1 -i "$WIFI_IF" -j $C
done
I="/usr/sbin/iptables -t mangle -A $C"
$I -p udp --sport 68 --dport 67 -j RETURN
$I -d "$IP_AP" -p udp --dport 53 -j RETURN
$I -d "$IP_AP" -p tcp --dport 53 -j RETURN
$I -d "$IP_AP" -p icmp -j RETURN
PUERTOS="80"
for p in ${PUERTOS_AP_EXTRA:-}; do
	case "$p" in *[!0-9]*|"") echo "PUERTOS_AP_EXTRA: '$p' no es un puerto" >&2; exit 1 ;; esac
	PUERTOS="$PUERTOS,$p"
done
$I -d "$IP_AP" -p tcp -m multiport --dports "$PUERTOS" -j RETURN
$I -j DROP
# IPv6 está desactivado en la red de emergencia: se descarta todo (incluye link-local hacia SSH).
/usr/sbin/ip6tables -t mangle -A $C -j DROP
