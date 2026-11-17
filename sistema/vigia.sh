#!/usr/bin/env bash
# Vigía del nodo de emergencia: si no hay internet, enciende la Wi-Fi de emergencia; si vuelve, la apaga.
# Lo ejecuta cada 30 s el timer emergencia-vigia.timer (como root).
#
# Uso: nodo-emergencia [revisar|estado|on|off|auto]
#   revisar  (por defecto) un ciclo del vigía
#   estado   muestra modo, red y contadores
#   on       fuerza la Wi-Fi de emergencia encendida (hasta "auto")
#   off      la fuerza apagada (hasta "auto")
#   auto     vuelve al modo automático
set -uo pipefail

CONF="${CONF:-/etc/nodo-emergencia.conf}"
# shellcheck disable=SC1090
. "$CONF"
EST=/var/lib/nodo-emergencia
LOG_FILE="${LOG_FILE:-/var/log/nodo-emergencia.log}"
FALLOS_PARA_ACTIVAR="${FALLOS_PARA_ACTIVAR:-4}"          # 4 x 30 s = 2 min sin internet
EXITOS_PARA_DESACTIVAR="${EXITOS_PARA_DESACTIVAR:-10}"   # 10 x 30 s = 5 min con internet estable
CON=emergencia-ap
mkdir -p "$EST"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
leer() { cat "$EST/$1" 2>/dev/null || echo "${2:-0}"; }
escribir() { echo "$2" > "$EST/$1"; }
avisar() { # texto nivel; si no sale (sin internet), queda en cola y se reenvía cuando vuelva
	[ -n "${AVISAR_CMD:-}" ] || return 0
	# shellcheck disable=SC2086
	$AVISAR_CMD "$1" "${2:-info}" >/dev/null 2>&1 && return 0
	printf '%s\t[%s] %s\n' "${2:-info}" "$(date '+%d-%m %H:%M')" "$1" >> "$EST/pendientes"
}
reenviar_pendientes() {
	[ -n "${AVISAR_CMD:-}" ] && [ -s "$EST/pendientes" ] || return 0
	local nivel texto resto=""
	while IFS=$'\t' read -r nivel texto; do
		# shellcheck disable=SC2086
		$AVISAR_CMD "$texto" "$nivel" >/dev/null 2>&1 || resto+="$nivel"$'\t'"$texto"$'\n'
	done < "$EST/pendientes"
	printf '%s' "$resto" > "$EST/pendientes"
}

hay_internet() { # por IP, para no depender del DNS; basta con que responda uno
	local u
	for u in https://1.1.1.1/cdn-cgi/trace https://8.8.8.8/ https://9.9.9.9/; do
		curl -fsS -m 5 -o /dev/null "$u" 2>/dev/null && return 0
	done
	return 1
}
ap_activo() { nmcli -t -f GENERAL.STATE connection show "$CON" 2>/dev/null | grep -q activated; }

encender() {
	ap_activo && return 0
	nmcli radio wifi on
	local i
	for i in 1 2 3 4 5; do
		nmcli connection up "$CON" >/dev/null 2>&1 && return 0
		sleep 3
	done
	log "ERROR: no se pudo levantar $CON"; return 1
}
apagar() {
	ap_activo && nmcli connection down "$CON" >/dev/null 2>&1
	nmcli radio wifi off
}
duracion() { # segundos -> "1 h 23 min"
	local s=$1; printf '%d h %02d min' $((s / 3600)) $((s % 3600 / 60))
}

exec 9>"$EST/lock"
flock -n 9 || exit 0

MODO="$(leer modo auto)"
case "${1:-revisar}" in
	estado)
		echo "modo:        $MODO"
		echo "wifi:        $(ap_activo && echo "ENCENDIDA ($SSID, http://$IP_AP)" || echo apagada)"
		echo "fallos:      $(leer fallos) (activa en $FALLOS_PARA_ACTIVAR)"
		echo "éxitos:      $(leer exitos) (desactiva en $EXITOS_PARA_DESACTIVAR)"
		[ -f "$EST/activo_desde" ] && echo "activa desde: $(date -d "@$(leer activo_desde)" '+%F %T')"
		hay_internet && echo "internet:    sí" || echo "internet:    NO"
		ap_activo && echo "conectados:  $(iw dev "$WIFI_IF" station dump 2>/dev/null | grep -c '^Station')"
		exit 0 ;;
	on)   escribir modo on;   log "modo manual: ON";  encender; exit $? ;;
	off)  escribir modo off;  log "modo manual: OFF"; apagar; rm -f "$EST/activo_desde"; exit 0 ;;
	auto) escribir modo auto; escribir fallos 0; escribir exitos 0; log "modo automático"; exit 0 ;;
	revisar) ;;
	*) sed -n '3,12p' "$0"; exit 2 ;;
esac

case "$MODO" in
	on)  ap_activo || encender; exit 0 ;;
	off) ap_activo && apagar; exit 0 ;;
esac

if hay_internet; then
	escribir fallos 0
	exitos=$(( $(leer exitos) + 1 )); escribir exitos "$exitos"
	reenviar_pendientes
	if [ -f "$EST/activo_desde" ] && [ "$exitos" -eq 1 ]; then
		log "volvió internet: la Wi-Fi de emergencia se apaga si sigue estable"
		avisar "Volvió internet. Si se mantiene estable, la Wi-Fi de emergencia se apaga en $((EXITOS_PARA_DESACTIVAR * 30 / 60)) min." info
	fi
	if [ -f "$EST/activo_desde" ] && [ "$exitos" -ge "$EXITOS_PARA_DESACTIVAR" ]; then
		desde="$(leer activo_desde)"; dur="$(duracion $(( $(date +%s) - desde )))"
		apagar; rm -f "$EST/activo_desde"
		log "internet estable: Wi-Fi de emergencia APAGADA (estuvo activa $dur)"
		avisar "Internet estable. La Wi-Fi de emergencia estuvo encendida $dur (desde $(date -d "@$desde" '+%d-%m %H:%M')) y ya se apagó." ok
	fi
else
	escribir exitos 0
	fallos=$(( $(leer fallos) + 1 )); escribir fallos "$fallos"
	[ "$fallos" -eq 1 ] && log "sin internet (1.er fallo)"
	if [ "$fallos" -ge "$FALLOS_PARA_ACTIVAR" ]; then
		if [ ! -f "$EST/activo_desde" ]; then
			if encender; then
				date +%s > "$EST/activo_desde"
				log "sin internet hace $((fallos * 30)) s: Wi-Fi de emergencia ENCENDIDA ($SSID, http://$IP_AP)"
				avisar "Sin internet: se encendió la Wi-Fi de emergencia $SSID (http://$IP_AP)." aviso
			fi
		elif ! ap_activo; then
			log "la Wi-Fi de emergencia se cayó: reintentando"
			encender
		fi
	fi
fi
