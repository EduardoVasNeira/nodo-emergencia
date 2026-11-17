"""Arma el índice del buscador: lee los .zim elegidos y las guías del país, los parte en trozos
y guarda un vector por trozo. Se ejecuta una vez (y de nuevo cuando cambia el contenido).

Variables: BUSCADOR_ZIMS (nombres sin fecha, separados por espacio; "nombre@pref1,pref2" indexa solo
las páginas cuya ruta empieza así), PAIS, HILOS.
Entradas: /zim (los .zim), /portal/paises/<PAIS>.json, /portal/fichas/<PAIS>.json. Salida: /indice.
"""
import glob
import hashlib
import json
import os
import re
import sys
import time
from html.parser import HTMLParser

import numpy as np
from libzim.reader import Archive

from comun import INDICE, Vectorizador

PALABRAS_TROZO = 120          # ~ lo que cabe holgado en 256 tokens
MAX_TROZOS_ARTICULO = 16      # lo importante suele estar al principio
MIN_PALABRAS_ARTICULO = 40
GUARDAR_CADA = 20000          # trozos nuevos entre guardados parciales
# Secciones que no ayudan a responder preguntas.
SALTAR = re.compile(r"^(referencias|notas|bibliograf|enlaces externos|véase también|vease también|"
                    r"fuentes|lecturas? adicional|otras lecturas|galería|ver también)", re.I)
BLOQUE = {"p", "li", "dd", "dt", "blockquote"}
TITULO = {"h2", "h3", "h4"}
OMITIR = {"h1", "script", "style", "table", "sup", "figure", "figcaption", "nav", "math", "noscript"}


class Extractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.omitir = 0
        self.en_titulo = False
        self.seccion = ""
        self.saltando = False
        self.buf = []
        self.parrafos = []          # (seccion, texto)

    def handle_starttag(self, tag, attrs):
        if tag in OMITIR:
            self.omitir += 1
        elif tag in TITULO:
            self._cerrar()
            self.en_titulo = True
        elif tag in BLOQUE:
            self._cerrar()

    def handle_endtag(self, tag):
        if tag in OMITIR:
            self.omitir = max(0, self.omitir - 1)
        elif tag in TITULO and self.en_titulo:
            titulo = " ".join("".join(self.buf).split())
            self.buf = []
            self.en_titulo = False
            if tag == "h2" or not self.saltando:
                self.saltando = bool(SALTAR.match(titulo))
                self.seccion = titulo
        elif tag in BLOQUE:
            self._cerrar()

    def handle_data(self, data):
        if not self.omitir:
            self.buf.append(data)

    def _cerrar(self):
        if self.en_titulo:
            return
        texto = " ".join("".join(self.buf).split())
        self.buf = []
        if texto and not self.saltando and len(texto.split()) >= 5:
            self.parrafos.append((self.seccion, texto))

    def close(self):
        super().close()
        self._cerrar()


def trozos_de(parrafos):
    """Junta párrafos consecutivos de la misma sección hasta ~PALABRAS_TROZO palabras."""
    salida, actual, sec, n = [], [], None, 0
    for s, t in parrafos:
        w = len(t.split())
        if actual and (s != sec or n + w > PALABRAS_TROZO):
            salida.append((sec, " ".join(actual)))
            actual, n = [], 0
        if w > PALABRAS_TROZO * 2:              # párrafo enorme: se corta por palabras
            palabras = t.split()
            for i in range(0, len(palabras), PALABRAS_TROZO):
                salida.append((s, " ".join(palabras[i:i + PALABRAS_TROZO])))
            sec = s
            continue
        actual.append(t)
        sec, n = s, n + w
    if actual:
        salida.append((sec, " ".join(actual)))
    return salida[:MAX_TROZOS_ARTICULO]


def articulos_zim(ruta, prefijos=()):
    """Artículos de un .zim. Con prefijos, solo las páginas cuya ruta empieza con alguno."""
    a = Archive(ruta)
    libro = os.path.basename(ruta)[:-4]
    principal = a.main_entry.get_item().path if a.has_main_entry else None
    for i in range(a.all_entry_count):
        e = a._get_entry_by_id(i)
        if e.is_redirect or (prefijos and not e.path.startswith(tuple(prefijos))):
            continue
        item = e.get_item()
        if not item.mimetype.startswith("text/html") or item.path == principal:
            continue
        x = Extractor()
        try:
            x.feed(bytes(item.content).decode("utf-8", "replace"))
            x.close()
        except Exception:
            continue
        if sum(len(t.split()) for _, t in x.parrafos) < MIN_PALABRAS_ARTICULO:
            continue
        yield e.title, f"/wiki/content/{libro}/{item.path}", trozos_de(x.parrafos)


def guias_pais(pais):
    ruta = f"/portal/paises/{pais}.json"
    if not os.path.exists(ruta):
        return
    g = json.load(open(ruta, encoding="utf-8"))
    tel = "; ".join(f"{t['numero']} {t['nombre']}" for t in g.get("telefonos", []))
    if tel:
        yield "Teléfonos de emergencia", "/emergencia", [("", "Números de emergencia: " + tel)]
    for s in g.get("situaciones", []):
        yield s["titulo"], "/emergencia", trozos_de([("", p) for p in s.get("pasos", [])]) or []


def fichas_pais(pais):
    """Fichas "qué hacer" revisadas (portal/fichas/<PAIS>.json). El buscador las pone primero."""
    ruta = f"/portal/fichas/{pais}.json"
    if not os.path.exists(ruta):
        return
    for f in json.load(open(ruta, encoding="utf-8")).get("fichas", []):
        ts = [("Qué hacer", " ".join(f.get("pasos", [])))]
        if f.get("urgente_si"):
            ts.append(("Urgente si", " ".join(f["urgente_si"])))
        if f.get("tambien"):
            ts.append(("", "; ".join(f["tambien"])))
        yield f["titulo"], f"/ficha#{f['id']}", [(s, t[:600]) for s, t in ts if t.strip()]


def main():
    nombres = os.environ.get("BUSCADOR_ZIMS", "").split()
    pais = os.environ.get("PAIS", "")
    hilos = int(os.environ.get("HILOS", "3"))
    zims = []                    # (ruta, prefijos, nombre para estado.json)
    for n in nombres:
        base, _, pref = n.partition("@")
        encontrados = sorted(glob.glob(f"/zim/{base}_*.zim"))
        if not encontrados:
            print(f"AVISO: no está {base}, se omite", flush=True)
            continue
        z = encontrados[-1]
        zims.append((z, [p for p in pref.split(",") if p],
                     os.path.basename(z) + (f"@{pref}" if pref else "")))
    vec = Vectorizador(hilos=hilos)
    cache = cargar_cache()
    if cache:
        print(f"reutilizando {len(cache)} vectores ya calculados", flush=True)

    docs, trozos, hashes, filas = [], [], [], []
    pendientes = []              # (posición en filas, texto)
    nuevos, t0 = 0, time.time()
    ultimo_guardado = 0

    def vaciar():
        nonlocal nuevos
        if pendientes:
            v = vec([t for _, t in pendientes]).astype(np.float16)
            for (i, _), fila in zip(pendientes, v):
                filas[i] = fila
            nuevos += len(pendientes)
            pendientes.clear()

    estado_base = {"zims": [e for _, _, e in zims], "pais": pais}
    fuentes = [("fichas", fichas_pais(pais)), ("guías", guias_pais(pais))] + \
              [(e, articulos_zim(z, p)) for z, p, e in zims]
    for nombre, articulos in fuentes:
        print(f"indexando {nombre}", flush=True)
        for titulo, url, ts in articulos:
            d = len(docs)
            docs.append([titulo, url])
            for sec, texto in ts:
                entrada = f"passage: {titulo}. {sec + '. ' if sec else ''}{texto}"
                h = hashlib.sha1(entrada.encode("utf-8")).hexdigest()[:16]
                trozos.append([d, sec, texto[:600]])
                hashes.append(h)
                filas.append(cache.get(h))
                if filas[-1] is None:
                    pendientes.append((len(filas) - 1, entrada))
                    if len(pendientes) >= 32:
                        vaciar()
            if len(docs) % 500 == 0:
                print(f"  {len(docs)} artículos, {len(trozos)} trozos ({nuevos} nuevos), "
                      f"{time.time() - t0:.0f} s", flush=True)
            # Guardado parcial: el buscador ya responde con lo avanzado y, si se corta, se retoma.
            if nuevos + len(pendientes) - ultimo_guardado >= GUARDAR_CADA:
                vaciar()
                guardar(docs, trozos, hashes, filas, dict(estado_base, parcial=True), t0)
                ultimo_guardado = nuevos
    vaciar()
    if not trozos:
        sys.exit("nada que indexar")
    estado = guardar(docs, trozos, hashes, filas, dict(estado_base, parcial=False), t0)
    print("listo:", estado, flush=True)


def cargar_cache():
    """Vectores de un índice anterior (completo o parcial), por hash del texto."""
    try:
        d = json.load(open(os.path.join(INDICE, "datos.json"), encoding="utf-8"))
        M = np.load(os.path.join(INDICE, "vectores.npy"))
        return dict(zip(d["hashes"], M))
    except Exception:
        return {}


def guardar(docs, trozos, hashes, filas, estado, t0):
    os.makedirs(INDICE, exist_ok=True)
    np.save(os.path.join(INDICE, "vectores.tmp.npy"), np.stack(filas).astype(np.float16))
    json.dump({"docs": docs, "trozos": trozos, "hashes": hashes},
              open(os.path.join(INDICE, "datos.tmp.json"), "w", encoding="utf-8"),
              ensure_ascii=False, separators=(",", ":"))
    os.replace(os.path.join(INDICE, "vectores.tmp.npy"), os.path.join(INDICE, "vectores.npy"))
    os.replace(os.path.join(INDICE, "datos.tmp.json"), os.path.join(INDICE, "datos.json"))
    estado.update(articulos=len(docs), trozos=len(trozos), segundos=round(time.time() - t0),
                  fecha=time.strftime("%F %T"))
    json.dump(estado, open(os.path.join(INDICE, "estado.tmp.json"), "w", encoding="utf-8"), ensure_ascii=False)
    os.replace(os.path.join(INDICE, "estado.tmp.json"), os.path.join(INDICE, "estado.json"))
    if estado.get("parcial"):
        print(f"  guardado parcial: {len(docs)} artículos, {len(trozos)} trozos", flush=True)
    return estado


if __name__ == "__main__":
    main()
