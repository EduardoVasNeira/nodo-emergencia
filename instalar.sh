#!/usr/bin/env bash
# Instala o actualiza el nodo de emergencia según emergencia.conf.
#   1. revisa requisitos   2. copia el stack a STACK_DIR   3. descarga el contenido   4. levanta los contenedores
#   5. (sudo) Wi-Fi de emergencia, portal cautivo, firewall y vigía automático
# Uso: ./instalar.sh [--sin-descargar] [--sin-asistente]
#   Sin emergencia.conf, abre el asistente web de configuración (o, con --sin-asistente, copia el ejemplo
#   para editarlo a mano).
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
CONF="$AQUI/emergencia.conf"
DESCARGAR=1
ASISTENTE=1
for a in "$@"; do
	case "$a" in
		--sin-descargar) DESCARGAR=0 ;;
		--sin-asistente) ASISTENTE=0 ;;
		*) echo "opción desconocida: $a" >&2; exit 2 ;;
	esac
done

if [ ! -f "$CONF" ]; then
	echo "Revisando el equipo..."
	if ! "$AQUI/verificar.sh"; then
		echo
		echo "Arregla lo marcado como FALTA y vuelve a ejecutar ./instalar.sh"
		exit 1
	fi
	if [ "$ASISTENTE" = 0 ] || ! command -v python3 >/dev/null; then
		cp "$AQUI/emergencia.conf.example" "$CONF"
		chmod 600 "$CONF"
		echo "Se creó $CONF. Edítalo con tu ubicación y vuelve a ejecutar ./instalar.sh"
		exit 1
	fi
	# Si UFW está activo, se abre el puerto del asistente solo mientras dure.
	PUERTO_ASISTENTE=8095
	ufw_abierto=0
	if command -v ufw >/dev/null && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
		sudo ufw allow "$PUERTO_ASISTENTE/tcp" comment "Asistente nodo de emergencia (temporal)" >/dev/null && ufw_abierto=1
	fi
	cerrar_ufw() { [ "$ufw_abierto" = 1 ] && sudo ufw delete allow "$PUERTO_ASISTENTE/tcp" >/dev/null || true; }
	trap cerrar_ufw EXIT
	python3 "$AQUI/asistente/asistente.py" --puerto "$PUERTO_ASISTENTE"
	cerrar_ufw; trap - EXIT
	[ -f "$CONF" ] || exit 1
fi
# shellcheck disable=SC1090
. "$CONF"
BIND_LAN="${BIND_LAN:-127.0.0.1}"

falta=0
for c in docker curl python3 sha256sum; do command -v "$c" >/dev/null || { echo "falta: $c"; falta=1; }; done
docker compose version >/dev/null 2>&1 || { echo "falta: docker compose"; falta=1; }
[ "$falta" = 0 ] || exit 1

# La Wi-Fi de emergencia no existe hasta que se enciende: Docker debe poder publicar en esa IP igual.
if [ "$(sysctl -n net.ipv4.ip_nonlocal_bind)" != 1 ]; then
	echo "Activando net.ipv4.ip_nonlocal_bind=1 (necesita sudo)"
	echo "net.ipv4.ip_nonlocal_bind = 1" | sudo tee /etc/sysctl.d/90-nodo-emergencia.conf >/dev/null
	sudo sysctl -q -p /etc/sysctl.d/90-nodo-emergencia.conf
fi

mkdir -p "$STACK_DIR/data"
install -m 644 "$AQUI/stack/compose.yaml" "$STACK_DIR/compose.yaml"
install -m 644 "$AQUI/stack/Caddyfile" "$STACK_DIR/Caddyfile"
mkdir -p "$STACK_DIR/buscador"
install -m 644 "$AQUI"/stack/buscador/* "$STACK_DIR/buscador/"
COMPOSE_FILE="$STACK_DIR/compose.yaml"

# Extras locales (carpeta local/, no se publica): compose, Caddyfile y tarjetas del inicio.
LOCAL="$AQUI/local"
if [ -f "$LOCAL/compose.yaml" ]; then
	install -m 644 "$LOCAL/compose.yaml" "$STACK_DIR/compose.local.yaml"
	COMPOSE_FILE="$COMPOSE_FILE:$STACK_DIR/compose.local.yaml"
else
	rm -f "$STACK_DIR/compose.local.yaml"
fi
# Siempre existe (Caddy lo importa); se escribe en el mismo archivo porque está montado.
if [ -f "$LOCAL/Caddyfile" ]; then cat "$LOCAL/Caddyfile" > "$STACK_DIR/local.caddy"
else echo "# Sin extras locales." > "$STACK_DIR/local.caddy"; fi

# Se actualiza dentro de la misma carpeta: Caddy la tiene montada y no vería una carpeta reemplazada.
mkdir -p "$STACK_DIR/portal"
find "$STACK_DIR/portal" -mindepth 1 -delete
cp -r "$AQUI/portal/." "$STACK_DIR/portal/"
if [ -f "$LOCAL/tarjetas.json" ]; then install -m 644 "$LOCAL/tarjetas.json" "$STACK_DIR/portal/tarjetas-locales.json"; fi
umask 077
cat > "$STACK_DIR/.env" <<EOF
# Generado por instalar.sh desde $CONF; no editar a mano.
COMPOSE_FILE=$COMPOSE_FILE
BIND_LAN=$BIND_LAN
PUERTO_LAN=$PUERTO_LAN
IP_AP=$IP_AP
UID_GID=$(id -u):$(id -g)
BUSCADOR_ZIMS="${BUSCADOR_ZIMS:-}"
PAIS=$PAIS
EOF
umask 022

# La imagen del buscador se construye aquí (la usa descargar.sh para armar el índice).
[ -n "${BUSCADOR_ZIMS:-}" ] && docker compose --project-directory "$STACK_DIR" build buscador

if [ "$DESCARGAR" = 1 ]; then
	"$AQUI/descargar.sh" --conf "$CONF"
else
	"$AQUI/descargar.sh" --conf "$CONF" --solo config
fi

docker compose --project-directory "$STACK_DIR" up -d
# El Caddyfile montado se reemplazó: reiniciar para que lo lea.
docker compose --project-directory "$STACK_DIR" restart web

# Wi-Fi de emergencia, portal cautivo, firewall y vigía (necesita root).
sudo "$AQUI/sistema/sistema.sh" "$CONF"

echo
echo "Portal en casa: http://$BIND_LAN:$PUERTO_LAN/"
echo "Sin internet:   red Wi-Fi \"$SSID\" → http://$IP_AP/"
