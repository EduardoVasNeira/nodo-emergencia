"""Servicio del buscador: GET /api/buscar?q=texto[&n=8] -> artículos que responden la pregunta.
Búsqueda híbrida: por significado (vectores e5), por palabras (el buscador de Kiwix) y por título,
con la pregunta ampliada por un diccionario de lenguaje común -> términos médicos (sinonimos_<idioma>.json).
Se ordena por el parecido del mejor párrafo con la pregunta más bonos de las otras vías.
No genera texto: devuelve título, párrafo relevante y enlace."""
import html
import json
import os
import re
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

from comun import INDICE, Vectorizador

vec = Vectorizador(hilos=int(os.environ.get("HILOS", "2")))
KIWIX = os.environ.get("KIWIX_URL", "http://kiwix:8080/wiki")
# Palabras vacías: con ellas Kiwix exige que aparezcan todas y no encuentra nada.
VACIAS = set("""a al algo ante con contra cual cuando de del desde donde e el ella ellas ellos en entre era es
esa ese eso esta este esto estoy está han hay hace hacer hago la las le les lo los mas me mi mis mucho muy
nada ni no nos o os para pero poco por porque puede que qué quien se según si sin sobre son su sus también
te tengo tiene tu tus un una uno unos unas y ya yo cómo como debo dónde""".split())


def palabras_clave(q):
    return " ".join(w for w in re.findall(r"\w+", q.lower()) if w not in VACIAS and len(w) > 1)


BONO_PALABRAS = float(os.environ.get("BONO_PALABRAS", "0.02"))
BONO_TITULO = float(os.environ.get("BONO_TITULO", "0.04"))
BONO_SECCION = float(os.environ.get("BONO_SECCION", "0.03"))
BONO_FICHA = float(os.environ.get("BONO_FICHA", "0.01"))
MARGEN_FICHA = float(os.environ.get("MARGEN_FICHA", "0.013"))
# Primeras palabras de títulos de fichas que no identifican el tema ("Niño que tomó cloro…").
GENERICAS = {"nino", "persona", "signos", "dolor", "golpe", "crisis", "que", "como"}
# Secciones que dicen qué hacer: se prefiere mostrar ese párrafo antes que la definición.
SECCION_UTIL = re.compile(r"primeros auxilios|qué hacer|que hacer|tratamiento|manejo|urgente|"
                          r"conducta|actuaci|cuidados|atención inicial|rice", re.I)


def _cargar_reglas():
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        f"sinonimos_{os.environ.get('IDIOMA', 'es')}.json")
    try:
        return [(re.compile(p), t) for p, t in json.load(open(ruta, encoding="utf-8"))["reglas"]]
    except (OSError, ValueError, KeyError):
        return []


REGLAS = _cargar_reglas()


def expandir(q):
    """Términos médicos que corresponden a cómo habla la gente ("me torcí" -> esguince)."""
    q = q.lower()
    terminos = []
    for patron, t in REGLAS:
        if patron.search(q) and t not in terminos:
            terminos.append(t)
    return " ".join(terminos)


def normalizar(t):
    t = unicodedata.normalize("NFD", t.lower())
    return " ".join(re.findall(r"\w+", "".join(c for c in t if unicodedata.category(c) != "Mn")))


def ngramas(texto, maximo=3):
    w = normalizar(texto).split()
    return {" ".join(w[i:i + k]) for k in range(1, maximo + 1) for i in range(len(w) - k + 1)}


def buscar_kiwix(q, libros, n=20):
    """Resultados del buscador por palabras de Kiwix: [(url, titulo, fragmento)]."""
    clave = palabras_clave(q)
    if not clave:
        return []
    salida = []
    for libro in libros:
        url = f"{KIWIX}/search?" + urllib.parse.urlencode(
            {"content": libro, "pattern": clave, "format": "xml", "pageLength": n})
        try:
            with urllib.request.urlopen(url, timeout=4) as r:
                raiz = ET.fromstring(r.read())
        except Exception:
            continue
        for it in raiz.iter("item"):
            link = it.findtext("link") or ""
            desc = re.sub(r"<[^>]+>", "", html.unescape(it.findtext("description") or ""))
            salida.append((link, it.findtext("title") or "", " ".join(desc.split())))
    return salida


class Indice:
    def __init__(self):
        self.marca = None
        self.lock = threading.Lock()
        self.M = None

    def actualizar(self):
        """Carga el índice, y lo recarga si indexar.py generó uno nuevo."""
        ruta = os.path.join(INDICE, "estado.json")
        try:
            marca = os.path.getmtime(ruta)
        except OSError:
            return
        if marca == self.marca:
            return
        with self.lock:
            if marca == self.marca:
                return
            M = np.load(os.path.join(INDICE, "vectores.npy")).astype(np.float32)
            d = json.load(open(os.path.join(INDICE, "datos.json"), encoding="utf-8"))
            if len(M) != len(d["trozos"]):        # justo se estaba guardando: se reintenta luego
                return
            self.M, self.docs, self.trozos = M, d["docs"], d["trozos"]
            self.estado = json.load(open(ruta, encoding="utf-8"))
            # Para cruzar con Kiwix: url -> artículo, y el rango de trozos de cada artículo.
            self.por_url = {urllib.parse.unquote(u): i for i, (_, u) in enumerate(self.docs)}
            self.rango = {}
            for i, (doc, _, _) in enumerate(self.trozos):
                a, _ = self.rango.get(doc, (i, i))
                self.rango[doc] = (a, i + 1)
            self.libros = [z.split("@")[0][:-4] for z in self.estado.get("zims", [])]
            # Bonos fijos por trozo: secciones que dicen qué hacer (para elegir qué párrafo mostrar)
            # y fichas revisadas (para que salgan primero).
            self.bono_sec = np.array([BONO_SECCION if SECCION_UTIL.search(sec or "") else 0.0
                                      for _, sec, _ in self.trozos], dtype=np.float32)
            self.bono_ficha = np.array([BONO_FICHA if self.docs[d][1].startswith("/ficha") else 0.0
                                        for d, _, _ in self.trozos], dtype=np.float32)
            # Título -> artículos. También sin el paréntesis ni lo que va tras ":" ("Ataque cerebral
            # (ACV)" responde a "ataque cerebral"; "Persona que no respira: RCP…" a "persona que no respira").
            self.por_titulo = {}
            for i, (t, u) in enumerate(self.docs):
                variantes = {t, re.sub(r"\s*\(.*?\)", "", t), t.split(":")[0]}
                if u.startswith("/ficha"):   # fichas: también lo del paréntesis y las primeras palabras
                    variantes |= set(re.findall(r"\((.*?)\)", t))
                    for parte in re.sub(r"\s*\(.*?\)", "", t).split(":"):
                        w = normalizar(parte).split()
                        variantes |= {" ".join(w[:k]) for k in (1, 2, 3)
                                      if w[:k] and not (k == 1 and w[0] in GENERICAS)}
                for v in variantes:
                    lista = self.por_titulo.setdefault(normalizar(v), [])
                    if i not in lista:
                        lista.append(i)
            self.marca = marca
            print(f"índice cargado: {len(self.docs)} artículos, {len(self.trozos)} trozos", flush=True)

    def buscar(self, q, n):
        self.actualizar()
        if self.M is None:
            return None
        extra = expandir(q)
        v = vec(["query: " + q + (f" ({extra})" if extra else "")])[0]
        base = self.M @ v + self.bono_ficha
        s = base + self.bono_sec                  # para elegir el párrafo de cada artículo
        k = min(len(s), 300)
        mejores = np.argpartition(-s, k - 1)[:k]
        mejores = mejores[np.argsort(-s[mejores])]

        def mejor_trozo(d):
            a, b = self.rango[d]
            return a + int(np.argmax(s[a:b]))

        # Candidatos: {artículo: {"trozo", "via"}}. El orden final lo da el parecido de su mejor trozo
        # con la pregunta, más un bono si además lo encontró la búsqueda por palabras o por título.
        cand = {}
        # 1) Por significado.
        for i in mejores:
            d = self.trozos[i][0]
            if d not in cand:
                cand[d] = {"trozo": int(i), "via": {"significado"}, "bono": 0.0}
            if len(cand) >= 30:
                break
        # 2) Por palabras (Kiwix), con la pregunta tal cual y con los términos médicos agregados.
        for consulta in filter(None, {palabras_clave(q), extra}):
            for r, (url, _, _) in enumerate(buscar_kiwix(consulta, self.libros)):
                d = self.por_url.get(urllib.parse.unquote(url))
                if d is None:
                    continue
                x = cand.setdefault(d, {"trozo": mejor_trozo(d), "via": set(), "bono": 0.0})
                x["via"].add("palabras")
                x["bono"] = max(x["bono"], BONO_PALABRAS * (1 - r / 20))
        # 3) Por título: un artículo que se llama como el término médico agregado o como una frase
        #    de la pregunta. Las palabras sueltas de la pregunta ("cara", "sangre") valen la mitad.
        clave = normalizar(palabras_clave(q))
        titulos = {t: BONO_TITULO for t in ngramas(clave)}
        titulos.update({t: BONO_TITULO / 2 for t in titulos if " " not in t and t != clave})
        titulos.update({t: BONO_TITULO for t in ngramas(extra)})
        for t, bono in titulos.items():
            for d in self.por_titulo.get(t, ()):
                x = cand.setdefault(d, {"trozo": mejor_trozo(d), "via": set(), "bono": 0.0})
                x["via"].add("titulo")
                x["bono"] += bono

        def puntaje(d):   # el artículo se ordena por su mejor parecido, no por la sección elegida
            a, b = self.rango[d]
            return float(base[a:b].max()) + float(self.bono_sec[cand[d]["trozo"]]) / 3 + cand[d]["bono"]

        orden = sorted(cand, key=puntaje, reverse=True)
        # Si una ficha revisada queda casi empatada con el primero, va primero: dice qué hacer.
        fichas = [d for d in orden[:4] if self.docs[d][1].startswith("/ficha")]
        if fichas and orden[0] != fichas[0] and puntaje(orden[0]) - puntaje(fichas[0]) <= MARGEN_FICHA:
            orden.remove(fichas[0])
            orden.insert(0, fichas[0])
        salida = []
        for d in orden[:n]:
            x = cand[d]
            _, sec, texto = self.trozos[x["trozo"]]
            titulo, url = self.docs[d]
            salida.append({"titulo": titulo, "url": url, "seccion": sec, "fragmento": texto[:400],
                           "puntaje": round(puntaje(d) * 100, 1), "via": sorted(x["via"]),
                           "ficha": url.startswith("/ficha")})
        return salida


indice = Indice()


class Manejador(BaseHTTPRequestHandler):
    def _json(self, codigo, datos):
        cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        p = urllib.parse.parse_qs(u.query)
        if u.path == "/api/salud":
            indice.actualizar()
            return self._json(200, {"listo": indice.M is not None,
                                    "estado": getattr(indice, "estado", None)})
        if u.path != "/api/buscar":
            return self._json(404, {"error": "no existe"})
        q = " ".join(p.get("q", [""])[0].split())[:300]
        if not q:
            return self._json(400, {"error": "falta la pregunta"})
        try:
            n = max(1, min(20, int(p.get("n", ["8"])[0])))
        except ValueError:
            n = 8
        t0 = time.time()
        r = indice.buscar(q, n)
        if r is None:
            return self._json(503, {"error": "el índice todavía no está listo"})
        self._json(200, {"q": q, "resultados": r, "ms": round((time.time() - t0) * 1000)})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    indice.actualizar()
    ThreadingHTTPServer(("0.0.0.0", 8000), Manejador).serve_forever()
