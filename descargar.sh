#!/usr/bin/env bash
# Descarga (o actualiza) el contenido offline según emergencia.conf:
#   librerías del visor de mapas, mapas PMTiles (región detallada + país), archivos .zim de Kiwix.
# Idempotente: lo que ya está bajado y verificado no se vuelve a bajar.
# Uso: descargar.sh [--conf RUTA] [--actualizar-mapas] [--solo vendor|mapas|zim|documentos|indice|config]
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
CONF="$AQUI/emergencia.conf"
ACTUALIZAR_MAPAS=0
SOLO=""
while [ $# -gt 0 ]; do
	case "$1" in
		--conf) CONF="$2"; shift 2 ;;
		--actualizar-mapas) ACTUALIZAR_MAPAS=1; shift ;;
		--solo) SOLO="$2"; shift 2 ;;
		*) echo "opción desconocida: $1" >&2; exit 2 ;;
	esac
done
[ -f "$CONF" ] || { echo "falta $CONF (copia emergencia.conf.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

PMTILES="$AQUI/bin/pmtiles"
DATA="$STACK_DIR/data"
mkdir -p "$DATA/zim" "$DATA/mapas" "$DATA/vendor"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
toca() { [ -z "$SOLO" ] || [ "$SOLO" = "$1" ]; }

# --- Versiones fijadas ----------------------------------------------------------
PMTILES_VER="1.31.2"
case "$(uname -m)" in
	x86_64) PMTILES_ARQ="x86_64"; PMTILES_SHA="3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f" ;;
	aarch64|arm64) PMTILES_ARQ="arm64"; PMTILES_SHA="f8bd47e7ea866863489cad588fbaf2f31f42e5821f7a03f009b3769f05801cb1" ;;
	*) PMTILES_ARQ=""; PMTILES_SHA="" ;;
esac
ASSETS_COMMIT="028c18f713baecad011301ff7a69acc39bcc2ae7"   # protomaps/basemaps-assets
VENDOR=(
	"maplibre-gl.js|https://cdn.jsdelivr.net/npm/maplibre-gl@5.24.0/dist/maplibre-gl.js|45a9b07a9189ce56054c620a947ccf41e291e58c95e9b61533b740aaa65ee5cb"
	"maplibre-gl.css|https://cdn.jsdelivr.net/npm/maplibre-gl@5.24.0/dist/maplibre-gl.css|ab1e70d59ec40465bae7e7030da2f3ccf28133fd502e62bd598eefbadfd7a732"
	"pmtiles.js|https://cdn.jsdelivr.net/npm/pmtiles@4.5.0/dist/pmtiles.js|caf981bc46f6327ee7e65d5dc964d89d38a69f60edca2bd4c5c890c21b554c6c"
	"basemaps.js|https://cdn.jsdelivr.net/npm/@protomaps/basemaps@5.7.2/dist/basemaps.js|551864f01da1bfe3005e99987197f22f56d0c35f9a10fa1727a889e2434af16d"
	"qrcode.js|https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js|18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780"
	# Fuentes del portal (SIL OFL 1.1): Lexend para títulos, Source Sans 3 para el texto.
	"lexend-600.woff2|https://cdn.jsdelivr.net/npm/@fontsource/lexend@5.3.0/files/lexend-latin-600-normal.woff2|c3c291158a48c5172383ec8febb21ca64075b7c9d8413553683b254a247efdda"
	"source-sans-3-400.woff2|https://cdn.jsdelivr.net/npm/@fontsource/source-sans-3@5.3.0/files/source-sans-3-latin-400-normal.woff2|0f73f35e08cde0a2f10c109c6e01d71459d97e4099ecd9a50f1b6c0209e4de2b"
	"source-sans-3-600.woff2|https://cdn.jsdelivr.net/npm/@fontsource/source-sans-3@5.3.0/files/source-sans-3-latin-600-normal.woff2|14527d193b0e30bc32ef931549a246cdfd286573bb12869b7e052b8101a39d38"
	"source-sans-3-700.woff2|https://cdn.jsdelivr.net/npm/@fontsource/source-sans-3@5.3.0/files/source-sans-3-latin-700-normal.woff2|ae35266f2ab0d5314ff9a04127931eb26c793e4f1269bb240046d4d2db4b7bb1"
	"lexend-OFL.txt|https://cdn.jsdelivr.net/npm/@fontsource/lexend@5.3.0/LICENSE|cdfed8f91b0660b004befb744757918b7c7d40dc2201b6c6d0a86b2fab9408f8"
	"source-sans-3-OFL.txt|https://cdn.jsdelivr.net/npm/@fontsource/source-sans-3@5.3.0/LICENSE|18aabf190848725e2576eefb5c29ba06aac1029d02132252a7f312eac2e50cf3"
)

bajar_verificado() { # destino url sha256
	local dst="$1" url="$2" sha="$3"
	if [ -f "$dst" ] && echo "$sha  $dst" | sha256sum -c --status -; then return 0; fi
	curl -fsSL --retry 3 -o "$dst.part" "$url"
	echo "$sha  $dst.part" | sha256sum -c --status - || { echo "checksum incorrecto: $url" >&2; rm -f "$dst.part"; return 1; }
	mv "$dst.part" "$dst"
	log "ok $(basename "$dst")"
}

# --- 1. Herramienta pmtiles -----------------------------------------------------
if toca mapas && [ ! -x "$PMTILES" ]; then
	[ -n "$PMTILES_ARQ" ] || { echo "arquitectura no soportada para mapas: $(uname -m)" >&2; exit 1; }
	mkdir -p "$AQUI/bin"; t="$(mktemp -d)"
	bajar_verificado "$t/p.tgz" "https://github.com/protomaps/go-pmtiles/releases/download/v$PMTILES_VER/go-pmtiles_${PMTILES_VER}_Linux_${PMTILES_ARQ}.tar.gz" "$PMTILES_SHA"
	tar xzf "$t/p.tgz" -C "$t" pmtiles && install -m 755 "$t/pmtiles" "$PMTILES"; rm -rf "$t"
fi

# --- 2. Librerías del visor y tipografías del mapa ------------------------------
if toca vendor; then
	for v in "${VENDOR[@]}"; do IFS='|' read -r f u s <<<"$v"; bajar_verificado "$DATA/vendor/$f" "$u" "$s"; done
	if [ ! -f "$DATA/vendor/assets.commit" ] || [ "$(cat "$DATA/vendor/assets.commit")" != "$ASSETS_COMMIT" ]; then
		log "bajando tipografías e íconos del mapa ($ASSETS_COMMIT)"
		t="$(mktemp -d)"
		curl -fsSL --retry 3 "https://codeload.github.com/protomaps/basemaps-assets/tar.gz/$ASSETS_COMMIT" | tar xz -C "$t"
		src="$t/basemaps-assets-$ASSETS_COMMIT"
		rm -rf "$DATA/vendor/fonts" "$DATA/vendor/sprites"; mkdir -p "$DATA/vendor/fonts" "$DATA/vendor/sprites"
		for f in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do cp -r "$src/fonts/$f" "$DATA/vendor/fonts/"; done
		cp -r "$src/sprites/v4" "$DATA/vendor/sprites/"
		rm -rf "$t"; echo "$ASSETS_COMMIT" > "$DATA/vendor/assets.commit"
	fi
fi

# --- 3. Mapas -------------------------------------------------------------------
if toca mapas; then
	if [ "$ACTUALIZAR_MAPAS" = 1 ] || [ ! -f "$DATA/mapas/region.pmtiles" ] || [ ! -f "$DATA/mapas/pais.pmtiles" ]; then
		BUILD="$(curl -fsSL https://build-metadata.protomaps.dev/builds.json | python3 -c 'import sys,json; print(sorted(b["key"] for b in json.load(sys.stdin))[-1])')"
		URL="https://build.protomaps.com/$BUILD"
		log "mapa base Protomaps $BUILD"
		python3 - "$LAT" "$LON" "$RADIO_KM" > "$DATA/mapas/region.geojson" <<'PY'
import json, math, sys
lat, lon, r = map(float, sys.argv[1:4]); R = 6371.0; d = r / R
la, lo = math.radians(lat), math.radians(lon); pts = []
for i in range(73):
    b = math.radians(i * 5)
    la2 = math.asin(math.sin(la)*math.cos(d) + math.cos(la)*math.sin(d)*math.cos(b))
    lo2 = lo + math.atan2(math.sin(b)*math.sin(d)*math.cos(la), math.cos(d) - math.sin(la)*math.sin(la2))
    pts.append([round(math.degrees(lo2), 5), round(math.degrees(la2), 5)])
json.dump({"type": "Polygon", "coordinates": [pts]}, sys.stdout)
PY
		log "extrayendo región: ${RADIO_KM} km alrededor de $LUGAR, zoom $ZOOM_REGION"
		"$PMTILES" extract "$URL" "$DATA/mapas/region.pmtiles.part" --region="$DATA/mapas/region.geojson" --maxzoom="$ZOOM_REGION"
		mv "$DATA/mapas/region.pmtiles.part" "$DATA/mapas/region.pmtiles"
		log "extrayendo país: $PAIS_NOMBRE, zoom $ZOOM_PAIS"
		"$PMTILES" extract "$URL" "$DATA/mapas/pais.pmtiles.part" --bbox="$PAIS_BBOX" --maxzoom="$ZOOM_PAIS"
		mv "$DATA/mapas/pais.pmtiles.part" "$DATA/mapas/pais.pmtiles"
		echo "$BUILD" > "$DATA/mapas/build.txt"
	else
		log "mapas ya presentes ($(cat "$DATA/mapas/build.txt" 2>/dev/null)); usa --actualizar-mapas para renovarlos"
	fi
	# Puntos útiles en emergencia (OpenStreetMap vía Overpass) dentro del radio.
	if [ "$ACTUALIZAR_MAPAS" = 1 ] || [ ! -f "$DATA/mapas/puntos.geojson" ]; then
		log "bajando puntos útiles (hospitales, bomberos, farmacias…) en ${RADIO_KM} km"
		A="(around:$((RADIO_KM * 1000)),$LAT,$LON)"
		Q="[out:json][timeout:240];(nwr[\"amenity\"~\"^(hospital|clinic|fire_station|police|pharmacy|fuel|drinking_water)$\"]$A;nwr[\"healthcare\"=\"centre\"]$A;nwr[\"emergency\"=\"assembly_point\"]$A;nwr[\"social_facility\"=\"shelter\"]$A;);out center tags;"
		if curl -fsS -m 300 --retry 2 -A "nodo-emergencia" --data-urlencode "data=$Q" https://overpass-api.de/api/interpreter -o "$DATA/mapas/osm.json.part"; then
			python3 - "$DATA/mapas/osm.json.part" "$DATA/mapas/puntos.geojson.part" <<'PY'
import json, sys
TIPO = {"hospital": "hospital", "clinic": "salud", "centre": "salud", "fire_station": "bomberos",
        "police": "policia", "pharmacy": "farmacia", "fuel": "bencina", "drinking_water": "agua",
        "assembly_point": "encuentro", "shelter": "albergue"}
feats = []
for e in json.load(open(sys.argv[1], encoding="utf-8"))["elements"]:
    t = e.get("tags", {})
    a = t.get("amenity")
    k = a if a in TIPO else (t.get("emergency") or t.get("social_facility") or t.get("healthcare"))
    if k not in TIPO: continue
    lat, lon = (e["lat"], e["lon"]) if "lat" in e else (e["center"]["lat"], e["center"]["lon"])
    calle = " ".join(x for x in (t.get("addr:street"), t.get("addr:housenumber")) if x)
    p = {"t": TIPO[k], "n": t.get("name", "")}
    for clave, val in (("tel", t.get("phone") or t.get("contact:phone")), ("dir", calle),
                       ("h", t.get("opening_hours")), ("emerg", t.get("emergency") == "yes" and "sí")):
        if val: p[clave] = val
    feats.append({"type": "Feature", "properties": p,
                  "geometry": {"type": "Point", "coordinates": [round(lon, 5), round(lat, 5)]}})
json.dump({"type": "FeatureCollection", "features": feats}, open(sys.argv[2], "w", encoding="utf-8"),
          ensure_ascii=False, separators=(",", ":"))
print(len(feats), "puntos")
PY
			mv "$DATA/mapas/puntos.geojson.part" "$DATA/mapas/puntos.geojson"
		else
			log "AVISO: no se pudieron bajar los puntos de OpenStreetMap (se reintenta en la próxima ejecución)"
		fi
		rm -f "$DATA/mapas/osm.json.part"
	fi
fi

# --- 4. Kiwix (.zim) ------------------------------------------------------------
ZIM_NUEVO=0
# Kiwix asigna un espejo que a veces es muy lento: se prueban todos (~6 s c/u) y se usa el más rápido.
# La integridad no depende del espejo: el sha256 se baja siempre desde kiwix.org.
mejor_espejo() { # url -> url del espejo más rápido (o la original)
	local u="$1" mejor="$1" vel=0 e v
	for e in $(curl -fsSL -m 20 "$u.meta4" 2>/dev/null | grep -oE '<url[^>]*>[^<]+\.zim' | sed 's/.*>//'); do
		# Si no termina en 6 s curl sale con error, pero igual informa la velocidad medida.
		v="$(curl -s -o /dev/null -m 6 -r 0-50000000 -w '%{speed_download}' "$e" 2>/dev/null || true)"
		v="${v%.*}"; v="${v//[^0-9]/}"
		if [ "${v:-0}" -gt "$vel" ]; then vel="$v"; mejor="$e"; fi
	done
	echo "$mejor"
}
if toca zim; then
	CAT="$(mktemp)"
	curl -fsSL "https://library.kiwix.org/catalog/v2/entries?count=2000&lang=$(python3 -c "print({'es':'spa','en':'eng','pt':'por','fr':'fra'}.get('$IDIOMA','$IDIOMA'))")" -o "$CAT"
	for item in $ZIMS; do
		nombre="${item%%:*}"; variante="${item#*:}"
		url="$(python3 - "$CAT" "$nombre" "$variante" <<'PY'
import re, sys
x = open(sys.argv[1], encoding="utf-8").read()
for e in re.findall(r"<entry>(.*?)</entry>", x, re.S):
    n = re.search(r"<name>([^<]+)</name>", e); f = re.search(r"<flavour>([^<]*)</flavour>", e)
    if n and n.group(1) == sys.argv[2] and (f.group(1) if f else "") == sys.argv[3]:
        m = re.search(r'href="([^"]+\.zim)\.meta4"', e)
        if m: print(m.group(1)); break
PY
)"
		[ -n "$url" ] || { log "AVISO: $item no está en el catálogo de Kiwix, se omite"; continue; }
		archivo="$(basename "$url")"
		if [ -f "$DATA/zim/$archivo" ]; then log "ya está $archivo"; continue; fi
		espejo="$(mejor_espejo "$url")"
		log "bajando $archivo desde ${espejo%%/zim/*}"
		curl -fL --retry 5 --retry-delay 10 -C - -o "$DATA/zim/$archivo.part" "$espejo"
		sha="$(curl -fsSL "$url.sha256" | cut -d' ' -f1)"
		echo "$sha  $DATA/zim/$archivo.part" | sha256sum -c --status - || { log "ERROR checksum $archivo"; rm -f "$DATA/zim/$archivo.part"; continue; }
		# Quita versiones anteriores del mismo contenido.
		find "$DATA/zim" -maxdepth 1 -name "${nombre}_${variante}_*.zim" ! -name "$archivo" -print -delete
		mv "$DATA/zim/$archivo.part" "$DATA/zim/$archivo"; ZIM_NUEVO=1
		log "ok $archivo"
	done
	rm -f "$CAT"
fi

# --- 4b. Documentos oficiales (PDF) del país y la región --------------------------
if toca documentos && [ -f "$AQUI/documentos/$PAIS.json" ]; then
	mkdir -p "$DATA/documentos"
	python3 - "$AQUI/documentos/$PAIS.json" "${REGION:-}" > "$DATA/documentos/lista.tsv" <<'PY'
import json, re, sys, unicodedata
d = json.load(open(sys.argv[1], encoding="utf-8"))
items = d.get("general", []) + d.get("regiones", {}).get(sys.argv[2], [])
for x in items:
    slug = unicodedata.normalize("NFKD", x["grupo"] + "-" + x["titulo"]).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", slug.lower()).strip("-")[:80] + ".pdf"
    print("\t".join([slug, x["grupo"], x["titulo"], x["url"]]))
PY
	while IFS=$'\t' read -r f g t u; do
		[ -s "$DATA/documentos/$f" ] && continue
		# De a uno y con pausa: BiblioGRD responde 429 (demasiadas solicitudes) si se le pide rápido;
		# --retry espera lo que indique el servidor (Retry-After) antes de reintentar.
		if curl -fsSL --retry 4 --retry-delay 5 -m 600 --max-filesize 100000000 -o "$DATA/documentos/$f.part" "$u" \
			&& [ "$(head -c 4 "$DATA/documentos/$f.part")" = "%PDF" ]; then
			mv "$DATA/documentos/$f.part" "$DATA/documentos/$f"; log "ok $t"
		else
			rm -f "$DATA/documentos/$f.part"; log "AVISO: no se pudo bajar \"$t\" ($u)"
		fi
		sleep 1.5
	done < "$DATA/documentos/lista.tsv"
	# Índice para el portal: solo lo que efectivamente está bajado.
	python3 - "$DATA/documentos" <<'PY'
import json, os, sys
base = sys.argv[1]; out = []
for linea in open(os.path.join(base, "lista.tsv"), encoding="utf-8"):
    f, g, t, u = linea.rstrip("\n").split("\t")
    p = os.path.join(base, f)
    if os.path.exists(p):
        out.append({"grupo": g, "titulo": t, "archivo": f, "mb": round(os.path.getsize(p) / 1e6, 1), "fuente": u})
json.dump(out, open(os.path.join(base, "indice.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
fi

# --- 5. Buscador por significado: modelo e índice --------------------------------
MODELO_REV="761b726dd34fb83930e26aab4e9ac3899aa1fa78"   # Xenova/multilingual-e5-small
MODELO=(
	"model.onnx|onnx/model_quantized.onnx|f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193"
	"tokenizer.json|tokenizer.json|0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"
)
if [ -n "${BUSCADOR_ZIMS:-}" ] && { toca indice || [ -z "$SOLO" ]; }; then
	mkdir -p "$DATA/modelo" "$DATA/indice"
	for m in "${MODELO[@]}"; do IFS='|' read -r f r s <<<"$m"
		bajar_verificado "$DATA/modelo/$f" "https://huggingface.co/Xenova/multilingual-e5-small/resolve/$MODELO_REV/$r" "$s"
	done
	# Se rehace si cambió algún .zim indexado, la lista, las guías o las fichas del país.
	# Un nombre puede llevar "@prefijo1,prefijo2" para indexar solo esas páginas (ej. libros de Wikilibros).
	quiero="$(for n in $BUSCADOR_ZIMS; do
		z="$(ls "$DATA/zim/${n%%@*}"_*.zim 2>/dev/null | sort | tail -1 | xargs -r basename)"
		if [ -z "$z" ]; then continue; fi
		if [ "$n" = "${n%%@*}" ]; then echo "$z"; else echo "$z@${n#*@}"; fi
	done | LC_ALL=C sort | tr '\n' ' ')"
	tengo="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print("" if e.get("parcial") else " ".join(sorted(e["zims"]))+" ")' "$DATA/indice/estado.json" 2>/dev/null || true)"
	cambio=""
	for g in "$AQUI/portal/paises/$PAIS.json" "$AQUI/portal/fichas/$PAIS.json"; do
		if [ -f "$g" ] && [ "$g" -nt "$DATA/indice/estado.json" ]; then cambio=1; fi
	done
	if [ "$quiero" != "$tengo" ] || [ ! -f "$DATA/indice/estado.json" ] || [ -n "$cambio" ]; then
		log "armando el índice del buscador (${BUSCADOR_ZIMS}); puede tardar"
		docker compose --project-directory "$STACK_DIR" --profile indexar run --rm indexador
	else
		log "índice del buscador al día"
	fi
fi

# --- 6. Configuración que lee el portal -----------------------------------------
if toca config || [ -z "$SOLO" ]; then
	LUGAR="$LUGAR" LAT="$LAT" LON="$LON" RADIO_KM="$RADIO_KM" PAIS="$PAIS" PAIS_NOMBRE="$PAIS_NOMBRE" \
	IDIOMA="$IDIOMA" SSID="$SSID" IP_AP="$IP_AP" \
	python3 - "$DATA/config.json" <<'PY'
import json, os, sys
e = os.environ
json.dump({
  "lugar": e["LUGAR"], "lat": float(e["LAT"]), "lon": float(e["LON"]), "radio_km": int(e["RADIO_KM"]),
  "pais": e["PAIS"], "pais_nombre": e["PAIS_NOMBRE"], "idioma": e["IDIOMA"],
  "ssid": e["SSID"], "ip_ap": e["IP_AP"],
}, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
fi

if [ "$ZIM_NUEVO" = 1 ] && docker ps --format '{{.Names}}' | grep -qx emergencia-kiwix; then
	log "reiniciando kiwix para cargar el contenido nuevo"
	docker restart emergencia-kiwix >/dev/null
fi
log "listo. Uso de disco: $(du -sh "$DATA" | cut -f1)"
