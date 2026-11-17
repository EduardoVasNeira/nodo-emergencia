#!/usr/bin/env bash
# Revisa si este equipo sirve para el nodo de emergencia, sin cambiar nada.
# Uso: ./verificar.sh [--json] [--conf RUTA]
# Cada revisión termina en OK, AVISO (funciona, pero conviene mejorarlo) o FALTA (hay que arreglarlo).
# Sale con código 1 si algo FALTA.
set -uo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
JSON=0
CONF="$AQUI/emergencia.conf"
while [ $# -gt 0 ]; do
	case "$1" in
		--json) JSON=1 ;;
		--conf) CONF="$2"; shift ;;
		*) echo "uso: $0 [--json] [--conf RUTA]" >&2; exit 2 ;;
	esac
	shift
done
# Valores por defecto; si ya hay configuración, se usan los suyos.
WIFI_IF=""; PUERTO_LAN="8090"; STACK_DIR="/opt/docker/emergencia"; BUSCADOR_ZIMS="x"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

RES=()     # estado|qué|detalle|cómo arreglarlo
ok()    { RES+=("OK|$1|$2|"); }
aviso() { RES+=("AVISO|$1|$2|${3:-}"); }
falta() { RES+=("FALTA|$1|$2|${3:-}"); }
tiene() { command -v "$1" >/dev/null 2>&1; }

# --- Sistema -----------------------------------------------------------------
if [ "$(uname -s)" = Linux ]; then
	. /etc/os-release 2>/dev/null || true
	ok "Sistema" "${PRETTY_NAME:-Linux}"
else
	falta "Sistema" "$(uname -s)" "Se necesita Linux (Ubuntu, Debian o Raspberry Pi OS)."
fi
case "$(uname -m)" in
	x86_64|aarch64|arm64) ok "Arquitectura" "$(uname -m)" ;;
	*) falta "Arquitectura" "$(uname -m)" "Se necesita un equipo de 64 bits (x86_64 o arm64)." ;;
esac

# --- Programas ---------------------------------------------------------------
for c in curl python3 sha256sum; do
	if tiene "$c"; then ok "$c" "instalado"; else falta "$c" "no está" "sudo apt install $c"; fi
done
if tiene docker; then
	ok "Docker" "$(docker --version 2>/dev/null | cut -d, -f1)"
	if docker compose version >/dev/null 2>&1; then ok "Docker Compose" "$(docker compose version --short 2>/dev/null)"
	else falta "Docker Compose" "no está" "sudo apt install docker-compose-plugin (o docker-compose-v2)"; fi
	if docker info >/dev/null 2>&1; then ok "Permiso para Docker" "$(id -un) puede usar Docker"
	else falta "Permiso para Docker" "$(id -un) no puede usar Docker" "sudo usermod -aG docker $(id -un) y vuelve a entrar a la sesión"; fi
else
	falta "Docker" "no está" "Instálalo con: curl -fsSL https://get.docker.com | sh"
fi
if tiene nmcli && nmcli -t general status >/dev/null 2>&1; then ok "NetworkManager" "activo"
else falta "NetworkManager" "no está o no corre" "sudo apt install network-manager (la Wi-Fi de emergencia usa NetworkManager)"; fi
if sudo -n true 2>/dev/null; then ok "sudo" "disponible sin contraseña"
elif tiene sudo; then aviso "sudo" "pedirá la contraseña al instalar" "Normal: la Wi-Fi y el firewall necesitan permisos de administrador."
else falta "sudo" "no está" "Instala sudo o ejecuta como administrador."; fi

# --- Wi-Fi con modo punto de acceso -------------------------------------------
if ! tiene iw; then
	falta "Herramienta iw" "no está" "sudo apt install iw"
else
	ifs="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')"
	if [ -z "$ifs" ]; then
		falta "Tarjeta Wi-Fi" "no se encontró ninguna" "Se necesita Wi-Fi para crear la red de emergencia (una tarjeta interna o un adaptador USB con modo AP)."
	else
		for i in $ifs; do
			phy="$(iw dev "$i" info 2>/dev/null | awk '$1=="wiphy"{print "phy"$2}')"
			if iw phy "$phy" info 2>/dev/null | sed -n '/Supported interface modes/,/^\t[^\t]/p' | grep -q '\* AP$'; then
				ok "Wi-Fi $i" "puede crear una red (modo AP)"
				[ -z "$WIFI_IF" ] && WIFI_IF="$i"
			else
				aviso "Wi-Fi $i" "no permite crear una red (sin modo AP)" "Usa otra tarjeta o un adaptador USB con modo AP."
			fi
		done
		if [ -n "$WIFI_IF" ] && tiene nmcli; then
			estado="$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v i="$WIFI_IF" '$1==i{print $2}')"
			case "$estado" in
				unmanaged) falta "Wi-Fi gestionada" "NetworkManager no controla $WIFI_IF" "Revisa /etc/NetworkManager/conf.d (unmanaged-devices) o netplan (renderer: NetworkManager)." ;;
				connected*) aviso "Wi-Fi en uso" "$WIFI_IF está conectada a otra red" "Mejor conecta el equipo por cable: la tarjeta Wi-Fi queda para la red de emergencia." ;;
				"") ;;
				*) ok "Wi-Fi libre" "$WIFI_IF lista para la red de emergencia" ;;
			esac
		fi
	fi
fi

# --- Recursos ----------------------------------------------------------------
ram_gb="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
if awk "BEGIN{exit !($ram_gb >= 3.5)}"; then ok "Memoria" "$ram_gb GB"
elif awk "BEGIN{exit !($ram_gb >= 1.8)}"; then aviso "Memoria" "$ram_gb GB" "Funciona, pero el buscador con IA necesita unos 2 GB libres. Con menos, deja BUSCADOR_ZIMS vacío."
else falta "Memoria" "$ram_gb GB" "Se necesitan al menos 2 GB."; fi
dir="$STACK_DIR"; while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
libre_gb="$(df -Pk "$dir" | awk 'NR==2{printf "%d", $4/1048576}')"
if [ "$libre_gb" -ge 25 ]; then ok "Disco libre" "$libre_gb GB en $dir"
elif [ "$libre_gb" -ge 3 ]; then aviso "Disco libre" "$libre_gb GB en $dir" "Alcanza para lo básico (mapas, medicina, documentos). Para la Wikipedia completa se necesitan unos 20 GB."
else falta "Disco libre" "$libre_gb GB en $dir" "Se necesitan al menos 3 GB."; fi
nucleos="$(nproc)"
if [ "$nucleos" -ge 2 ]; then ok "Procesador" "$nucleos núcleos"; else aviso "Procesador" "$nucleos núcleo" "Armar el índice del buscador tomará muchas horas."; fi

# --- Red ---------------------------------------------------------------------
ocupado() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])$1\$"; }
if ocupado "$PUERTO_LAN" && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^emergencia-web$'; then
	falta "Puerto $PUERTO_LAN" "lo usa otro programa" "Elige otro PUERTO_LAN en la configuración."
else ok "Puerto $PUERTO_LAN" "libre para el portal en la casa"; fi
if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):80$' && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^emergencia-web$'; then
	falta "Puerto 80" "otro programa escucha en todas las direcciones" "El portal cautivo necesita el puerto 80 en la IP de la Wi-Fi de emergencia. Limita ese programa a otra IP."
else ok "Puerto 80" "disponible para el portal cautivo"; fi
if curl -fsS -m 8 -o /dev/null https://download.kiwix.org/ 2>/dev/null; then ok "Internet" "hay conexión para descargar el contenido"
else aviso "Internet" "no se pudo llegar a download.kiwix.org" "La instalación necesita internet para descargar mapas y bibliotecas."; fi

# --- Resultado ---------------------------------------------------------------
if [ "$JSON" = 1 ]; then
	printf '%s\n' "${RES[@]}" | WIFI_IF="$WIFI_IF" python3 -c '
import json, os, sys
r = [dict(zip(("estado", "que", "detalle", "arreglo"), l.rstrip("\n").split("|", 3))) for l in sys.stdin if l.strip()]
print(json.dumps({"resultados": r, "wifi_if": os.environ["WIFI_IF"],
                  "falta": any(x["estado"] == "FALTA" for x in r)}, ensure_ascii=False))'
else
	for l in "${RES[@]}"; do
		IFS='|' read -r e q d a <<<"$l"
		printf '%-6s %-22s %s\n' "$e" "$q" "$d"
		[ -n "$a" ] && printf '       %-22s → %s\n' "" "$a"
	done
fi
printf '%s\n' "${RES[@]}" | grep -q '^FALTA|' && exit 1
exit 0
