#!/usr/bin/env python3
"""Asistente web de configuración del nodo de emergencia.

Lo lanza instalar.sh cuando todavía no hay emergencia.conf. Abre una página en la red de la casa,
protegida con una clave al azar que se imprime en la terminal y deja de servir al cerrarse. Pregunta dónde vives, el radio
del mapa, qué contenido bajar, la región y la Wi-Fi; escribe emergencia.conf y termina, para que
instalar.sh siga con la descarga.

Solo usa la biblioteca estándar de Python. Uso: python3 asistente/asistente.py [--puerto 8095]
"""
import glob
import hmac
import http.server
import json
import math
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
EJEMPLO = os.path.join(RAIZ, "emergencia.conf.example")
DESTINO = os.path.join(RAIZ, "emergencia.conf")
TOKEN = secrets.token_urlsafe(18)
INACTIVO_MAX = 2 * 3600          # se cierra solo si nadie lo usa en 2 horas
ultimo_uso = time.time()
terminado = threading.Event()

# Contenido que se puede elegir (catálogo Kiwix) con su tamaño aproximado en GB.
CONTENIDO = [
    {"id": "wikipedia_es_medicine:maxi", "titulo": "Medicina (Wikipedia)", "gb": 0.5, "base": True,
     "texto": "Enfermedades, síntomas, primeros auxilios. Con imágenes. Lo usa el buscador."},
    {"id": "wikibooks_es_all:maxi", "titulo": "Manuales (Wikilibros)", "gb": 0.3, "base": True,
     "texto": "Primeros auxilios, supervivencia, agua, fuego y refugio."},
    {"id": "wikivoyage_es_all:maxi", "titulo": "Guía de viaje (Wikiviajes)", "gb": 0.1, "base": False,
     "texto": "Ciudades, rutas y lugares."},
    {"id": "wiktionary_es_all:nopic", "titulo": "Diccionario (Wikcionario)", "gb": 0.7, "base": False,
     "texto": "Significado de palabras."},
    {"id": "wikipedia_es_all:nopic", "titulo": "Wikipedia completa, sin imágenes", "gb": 13.5, "base": False,
     "texto": "Toda la enciclopedia en español. Necesita unos 14 GB."},
]
IDS_CONTENIDO = {c["id"] for c in CONTENIDO}
# Lo que no es contenido Kiwix: programa del buscador, índice, mapa del país, documentos.
GB_FIJO = 0.8


def leer_json(ruta):
    with open(ruta, encoding="utf-8") as f:
        return json.load(f)


def paises():
    """Países con datos en el proyecto: portal/paises/<CC>.json (+ documentos/<CC>.json)."""
    salida = {}
    for ruta in sorted(glob.glob(os.path.join(RAIZ, "portal", "paises", "*.json"))):
        cc = os.path.basename(ruta)[:-5]
        p = leer_json(ruta)
        docs = os.path.join(RAIZ, "documentos", cc + ".json")
        d = leer_json(docs) if os.path.exists(docs) else {}
        salida[cc] = {"nombre": p.get("pais", cc), "bbox": p.get("bbox"),
                      "regiones": sorted(d.get("regiones", {})),
                      "centros": d.get("centros", {}),
                      "docs_region": {r: len(v) for r, v in d.get("regiones", {}).items()}}
    return salida


def ip_lan():
    """IP de este equipo en la red de la casa (la que usaría para salir a internet)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))          # no envía nada: solo elige la interfaz
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def verificar():
    try:
        r = subprocess.run([os.path.join(RAIZ, "verificar.sh"), "--json"], capture_output=True,
                           text=True, timeout=60)
        return json.loads(r.stdout)
    except Exception as e:                      # noqa: BLE001 - se informa en la página
        return {"resultados": [{"estado": "AVISO", "que": "Verificación", "detalle": str(e), "arreglo": ""}],
                "wifi_if": "", "falta": False}


def disco_libre_gb():
    d = "/opt/docker"
    while not os.path.isdir(d):
        d = os.path.dirname(d)
    st = os.statvfs(d)
    return round(st.f_bavail * st.f_frsize / 1e9, 1)


def buscar_lugar(q, pais):
    """Busca la ciudad en OpenStreetMap (Nominatim). Solo se envía lo que la persona escribió."""
    params = {"q": q, "format": "jsonv2", "limit": "6", "addressdetails": "1", "accept-language": "es"}
    if pais:
        params["countrycodes"] = pais.lower()
    req = urllib.request.Request("https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(params),
                                 headers={"User-Agent": "nodo-emergencia-instalador/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        datos = json.load(r)
    salida = []
    for x in datos:
        a = x.get("address", {})
        # El nombre propio primero ("Ñuñoa"); "city" a veces es la ciudad grande ("Santiago").
        nombre = x.get("name") or a.get("city") or a.get("town") or a.get("village") or a.get("municipality") or ""
        salida.append({"nombre": nombre or x.get("display_name", "").split(",")[0],
                       "detalle": x.get("display_name", ""), "lat": round(float(x["lat"]), 4),
                       "lon": round(float(x["lon"]), 4), "estado": a.get("state", ""),
                       "pais": (a.get("country_code") or "").upper()})
    return salida


def region_cercana(pais, lat, lon, estado=""):
    """Región para los documentos: por el nombre que dio el mapa o, si no, la capital más cercana."""
    info = paises().get(pais, {})
    plano = lambda s: re.sub(r"[^a-z]", "", s.lower().translate(str.maketrans("áéíóúüñ'", "aeiouun ")))
    if estado:
        for r in info.get("regiones", []) + list(info.get("centros", {})):
            if plano(r) and plano(r) in plano(estado):
                return r
    mejor, dist = "", 1e9
    for r, (la, lo) in info.get("centros", {}).items():
        d = math.hypot(la - lat, (lo - lon) * math.cos(math.radians(lat)))
        if d < dist:
            mejor, dist = r, d
    return mejor


# --- Validación: emergencia.conf se lee como shell, así que nada raro entra. ---
TEXTO_SEGURO = re.compile(r"^[\w .,'()\-áéíóúüñÁÉÍÓÚÜÑ]{1,60}$")
SSID_SEGURO = re.compile(r"^[A-Za-z0-9 ._\-]{1,32}$")
IFACE = re.compile(r"^[a-zA-Z0-9_.\-]{1,15}$")
IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")


def validar(d):
    errores = []
    pais_info = paises()
    pais = str(d.get("pais", ""))
    if pais not in pais_info:
        errores.append("País sin datos en el proyecto.")
    lugar = str(d.get("lugar", "")).strip()
    if not TEXTO_SEGURO.match(lugar):
        errores.append("Nombre del lugar: usa solo letras, números y espacios.")
    try:
        lat, lon = float(d.get("lat")), float(d.get("lon"))
        assert -90 <= lat <= 90 and -180 <= lon <= 180
    except (TypeError, ValueError, AssertionError):
        errores.append("Coordenadas inválidas.")
        lat = lon = 0.0
    try:
        radio = int(d.get("radio_km"))
        assert 10 <= radio <= 500
    except (TypeError, ValueError, AssertionError):
        errores.append("El radio debe estar entre 10 y 500 km.")
        radio = 0
    region = str(d.get("region", ""))
    if region and region not in pais_info.get(pais, {}).get("regiones", []):
        errores.append("Región desconocida.")
    contenido = [c for c in d.get("contenido", []) if c in IDS_CONTENIDO]
    if not contenido:
        errores.append("Elige al menos un contenido.")
    ssid = str(d.get("ssid", "")).strip()
    if not SSID_SEGURO.match(ssid):
        errores.append("Nombre de la Wi-Fi: hasta 32 letras, números, espacios, punto o guion.")
    wifi_if = str(d.get("wifi_if", ""))
    if not IFACE.match(wifi_if):
        errores.append("Falta la tarjeta Wi-Fi.")
    bind = str(d.get("bind_lan", "")).strip()
    m = IPV4.match(bind)
    if bind and not (m and all(int(x) <= 255 for x in m.groups())):
        errores.append("IP de la casa inválida.")
    try:
        puerto = int(d.get("puerto_lan"))
        assert 1024 <= puerto <= 65535
    except (TypeError, ValueError, AssertionError):
        errores.append("Puerto de la casa: entre 1024 y 65535.")
        puerto = 0
    if errores:
        return None, errores
    bbox = pais_info[pais].get("bbox") or [lon - 3, lat - 3, lon + 3, lat + 3]
    usa_buscador = "wikipedia_es_medicine:maxi" in contenido
    buscador = ""
    if usa_buscador:
        buscador = "wikipedia_es_medicine"
        if "wikibooks_es_all:maxi" in contenido:
            buscador += (" wikibooks_es_all@Asistencia_sanitaria_inmediata,Manual_básico_de_primeros_auxilios,"
                         "Montañismo/Primeros_auxilios,Excursionismo/Primeros_auxilios,"
                         "Excursionismo/Supervivencia,Técnicas_de_supervivencia")
    return {
        "LUGAR": lugar, "LAT": f"{lat:.4f}", "LON": f"{lon:.4f}", "RADIO_KM": str(radio),
        "PAIS": pais, "PAIS_NOMBRE": pais_info[pais]["nombre"], "REGION": region,
        "PAIS_BBOX": ",".join(str(x) for x in bbox),
        "ZIMS": " ".join(c for c in (x["id"] for x in CONTENIDO) if c in contenido),
        "BUSCADOR_ZIMS": buscador, "BIND_LAN": bind, "PUERTO_LAN": str(puerto),
        "WIFI_IF": wifi_if, "SSID": ssid,
    }, []


def escribir_conf(valores):
    """Parte del ejemplo (con todos sus comentarios) y reemplaza los valores elegidos."""
    with open(EJEMPLO, encoding="utf-8") as f:
        lineas = f.read().splitlines()
    vistos = set()
    for i, l in enumerate(lineas):
        m = re.match(r"^([A-Z_]+)=", l)
        if m and m.group(1) in valores:
            lineas[i] = f'{m.group(1)}="{valores[m.group(1)]}"'
            vistos.add(m.group(1))
    for k in valores.keys() - vistos:
        lineas.append(f'{k}="{valores[k]}"')
    lineas.insert(2, f"# Generado por el asistente de configuración el {time.strftime('%Y-%m-%d %H:%M')}.")
    tmp = DESTINO + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lineas) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, DESTINO)


class Manejador(http.server.BaseHTTPRequestHandler):
    server_version = "asistente"

    def autorizado(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        dado = q.get("t", [""])[0] or self.headers.get("X-Token", "")
        return hmac.compare_digest(dado.encode(), TOKEN.encode())

    def responder(self, codigo, cuerpo, tipo="application/json; charset=utf-8"):
        if not isinstance(cuerpo, bytes):
            cuerpo = json.dumps(cuerpo, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        global ultimo_uso
        ruta = urllib.parse.urlsplit(self.path).path
        estaticos = {"/estilo.css": ("portal/estilo.css", "text/css; charset=utf-8"),
                     "/iconos.svg": ("portal/iconos.svg", "image/svg+xml")}
        if ruta in estaticos:
            archivo, tipo = estaticos[ruta]
            with open(os.path.join(RAIZ, archivo), "rb") as f:
                return self.responder(200, f.read(), tipo)
        if not self.autorizado():
            return self.responder(403, "Falta la clave: usa el enlace completo que aparece en la terminal.".encode(),
                                  "text/plain; charset=utf-8")
        ultimo_uso = time.time()
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if ruta == "/":
            with open(os.path.join(AQUI, "asistente.html"), "rb") as f:
                return self.responder(200, f.read(), "text/html; charset=utf-8")
        if ruta == "/api/estado":
            v = verificar()
            return self.responder(200, {"verificacion": v, "wifi_if": v.get("wifi_if", ""), "ip_lan": ip_lan(),
                                        "disco_libre_gb": disco_libre_gb(), "paises": paises(),
                                        "contenido": CONTENIDO, "gb_fijo": GB_FIJO})
        if ruta == "/api/lugar":
            try:
                return self.responder(200, buscar_lugar(q.get("q", [""])[0][:100], q.get("pais", [""])[0][:2]))
            except Exception as e:              # noqa: BLE001
                return self.responder(502, {"error": f"No se pudo buscar ({e}). Escribe las coordenadas a mano."})
        if ruta == "/api/region":
            try:
                lat, lon = float(q["lat"][0]), float(q["lon"][0])
            except (KeyError, ValueError):
                return self.responder(400, {"error": "coordenadas"})
            return self.responder(200, {"region": region_cercana(q.get("pais", [""])[0], lat, lon,
                                                                 q.get("estado", [""])[0])})
        self.responder(404, {"error": "no existe"})

    def do_POST(self):
        global ultimo_uso
        if not self.autorizado() or urllib.parse.urlsplit(self.path).path != "/api/guardar":
            return self.responder(403, {"error": "sin permiso"})
        ultimo_uso = time.time()
        try:
            largo = min(int(self.headers.get("Content-Length", "0")), 20000)
            datos = json.loads(self.rfile.read(largo) or b"{}")
        except ValueError:
            return self.responder(400, {"errores": ["Datos ilegibles."]})
        valores, errores = validar(datos)
        if errores:
            return self.responder(400, {"errores": errores})
        escribir_conf(valores)
        self.responder(200, {"ok": True, "conf": valores})
        terminado.set()

    def log_message(self, fmt, *args):
        pass


def main():
    puerto = 8095
    if "--puerto" in sys.argv:
        puerto = int(sys.argv[sys.argv.index("--puerto") + 1])
    if os.path.exists(DESTINO) and "--forzar" not in sys.argv:
        sys.exit(f"Ya existe {DESTINO}. Bórralo o usa --forzar para configurarlo de nuevo.")
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", puerto), Manejador)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    ip = ip_lan()
    print("\n  Asistente de configuración del nodo de emergencia")
    print("  Ábrelo en el navegador de un computador o celular de esta misma red:\n")
    print(f"     http://{ip}:{puerto}/?t={TOKEN}\n")
    print("  (La clave del enlace sirve solo mientras el asistente esté abierto.", flush=True)
    print("   Ctrl+C para cancelar y editar emergencia.conf a mano.)\n", flush=True)
    try:
        while not terminado.wait(5):
            if time.time() - ultimo_uso > INACTIVO_MAX:
                sys.exit("El asistente se cerró por inactividad. Vuelve a ejecutar ./instalar.sh")
        time.sleep(1)                     # deja salir la respuesta antes de cerrar
        print("  Configuración guardada en emergencia.conf. Sigue la instalación...\n", flush=True)
    except KeyboardInterrupt:
        sys.exit("\nCancelado. Puedes copiar emergencia.conf.example a emergencia.conf y editarlo a mano.")
    finally:
        srv.shutdown()


if __name__ == "__main__":
    main()
