# Nodo de emergencia

Convierte un computador viejo (o una Raspberry Pi) en una **fuente de información que funciona sin internet**.
Cuando se corta internet, crea sola una **Wi-Fi abierta**: cualquier celular que se conecte ve una página
con lo necesario para una emergencia, aunque no haya señal ni datos.

- **Primeros auxilios paso a paso:** 40 fichas resumidas de fuentes oficiales (MINSAL, SAMU, CITUC, Cruz Roja…),
  cada una con su fuente y fecha de revisión.
- **Buscador que entiende cómo habla la gente:** "me picó una araña" o "se cortó y sangra mucho" llevan a la
  ficha correcta y a los artículos de medicina. Usa un modelo de IA pequeño que corre en el mismo equipo y no
  inventa texto: solo encuentra y muestra. Si no encuentra algo claro, lo dice.
- **Mapa sin internet** de tu zona, con calles, hospitales, bomberos, carabineros, farmacias y albergues.
- **Documentos oficiales:** planos de evacuación por tsunami y volcán, y planes de emergencia de tu región.
- **Biblioteca:** Wikipedia en español (completa o solo medicina), manuales, diccionario y guía de viaje,
  gracias a [Kiwix](https://kiwix.org).
- **Teléfonos de emergencia** a la vista y qué hacer en sismo, tsunami, incendio o corte de luz.

En la casa, el portal queda siempre visible en la red (por ejemplo `http://192.168.1.10:8090`).
Si se corta internet, a los 2 minutos aparece la Wi-Fi `EMERGENCIA-Info-Offline` y la página se abre sola
en los celulares. Cuando internet vuelve y se mantiene estable, la Wi-Fi se apaga.

## Qué necesitas

| | Mínimo | Recomendado |
|---|---|---|
| Equipo | 64 bits (x86_64 o arm64), Linux con NetworkManager | Mini PC o Raspberry Pi 4/5 conectado por cable |
| Wi-Fi | Tarjeta con **modo AP** (punto de acceso) | La interna del equipo o un adaptador USB compatible |
| Memoria | 2 GB | 4 GB o más |
| Disco | 3 GB (mapas, medicina, documentos) | 25 GB (con la Wikipedia completa) |
| Software | Docker con Compose, Python 3, curl | |
| Energía | | Batería para el equipo (UPS, o power bank / 12 V en una Raspberry Pi): sin luz no hay nodo. El router no hace falta: la Wi-Fi de emergencia la crea el propio equipo |

`./verificar.sh` revisa todo esto sin cambiar nada y dice cómo arreglar lo que falte.

## Instalación

```bash
git clone https://github.com/eduardovasneira/nodo-emergencia.git
cd nodo-emergencia
./instalar.sh
```

1. Revisa el equipo (`verificar.sh`).
2. Abre un **asistente web**: la terminal muestra un enlace con una clave. Ábrelo desde cualquier computador
   o celular de la casa y responde: dónde vives, cuánto mapa con calles quieres, qué contenido guardar
   (con el espacio que ocupa), tu región y el nombre de la Wi-Fi.
3. Descarga todo, verificando cada archivo (sha256 o sumas publicadas por Kiwix). Según lo que elijas, toma
   desde minutos hasta un par de horas.
4. Levanta los servicios (Docker) y, con `sudo`, configura la Wi-Fi de emergencia, el portal cautivo,
   el firewall y el vigía que detecta la caída de internet.

¿Prefieres editar a mano? `./instalar.sh --sin-asistente` copia `emergencia.conf.example` a `emergencia.conf`
para que lo completes; cada opción está explicada ahí.

**Actualizar:** `git pull && ./instalar.sh`. Solo se baja lo que cambió.
**Actualizar el mapa:** `./descargar.sh --actualizar-mapas`.
**Desinstalar:** `./desinstalar.sh` quita el vigía, el firewall y la Wi-Fi de emergencia y deja la red como
estaba (`--simular` muestra antes lo que haría). Lo descargado no se borra: te dice dónde está.

**Dónde ponerlo:** la Wi-Fi alcanza decenas de metros. Rinde más en un lugar al que la gente llega en una
emergencia (sede vecinal, escuela, cuartel de bomberos) que dentro de una casa. El cartel con QR (`/cartel`)
avisa que la red existe; piensa bien dónde lo pegas.

## Cómo funciona

```
          internet OK                               internet caído (2 min)
 ┌──────────────────────────┐              ┌──────────────────────────────────────┐
 │ portal en la red de casa │   vigía      │ + Wi-Fi abierta "EMERGENCIA-…"         │
 │ http://IP:8090           │ ───────────► │   DNS y portal cautivo → http://10.42.0.1│
 └──────────────────────────┘ (cada 30 s)  │   firewall: solo el portal, nada más   │
                                           └──────────────────────────────────────┘
```

- `stack/`: los servicios en Docker, con versiones y digests fijos: Caddy (portal), kiwix-serve
  (biblioteca) y el buscador (Python + ONNX, modelo multilingual-e5-small cuantizado).
- `portal/`: la página. HTML, CSS y JavaScript simples, sin dependencias externas: todo se sirve desde el equipo.
- `sistema/`: lo que necesita root. La Wi-Fi de NetworkManager en modo compartido, el DNS del portal cautivo,
  el firewall que aísla la red abierta (los clientes no llegan a SSH, a la red de la casa ni a internet, ni
  se ven entre sí) y el vigía (`systemd timer`). El portal no guarda registro de visitas ni de búsquedas.
- `asistente/`: el asistente web de configuración (solo biblioteca estándar de Python).
- `documentos/<PAÍS>.json`, `portal/paises/<PAÍS>.json`, `portal/fichas/<PAÍS>.json`: los datos de cada país.

### Avisos (opcional)

`AVISAR_CMD` en `emergencia.conf` puede apuntar a cualquier comando que reciba un texto y un nivel
(por ejemplo, un script que mande un mensaje por Telegram). Si el aviso no sale por falta de internet,
queda en cola y se envía cuando vuelve.

### Extras locales (opcional)

Para mostrar servicios propios en el portal (por ejemplo, una biblioteca de música o de películas en tu red),
crea la carpeta `local/`, que no se publica:

| Archivo | Qué hace |
|---|---|
| `local/compose.yaml` | Se suma al `compose.yaml` del stack (servicios, puertos o redes extra). |
| `local/Caddyfile` | Sitios extra de Caddy, por ejemplo `:8096 { reverse_proxy 192.168.1.20:8096 }`. |
| `local/tarjetas.json` | Tarjetas extra en el inicio: `[{"titulo": "Películas", "texto": "…", "icono": "library", "puerto": 8096}]`. |

Los puertos que deban verse desde la Wi-Fi de emergencia van en `PUERTOS_AP_EXTRA`.

## Países

Por ahora el proyecto incluye **Chile**: teléfonos, qué hacer, 40 fichas de primeros auxilios y documentos
oficiales por región. Agregar otro país es agregar tres archivos JSON: ver [CONTRIBUTING.md](CONTRIBUTING.md).

## Estado: qué está probado y qué no

El proyecto es joven. Esto es lo que se ha probado de verdad y lo que falta:

| Prueba | Estado |
|---|---|
| Corte de internet (cable del router desenchufado): la Wi-Fi aparece a los 2 min y se apaga al volver | ✅ Probado |
| Celular Android se conecta y ve el portal | ✅ Probado |
| Buscador: 29 preguntas reales con la ficha o el artículo correcto primero; preguntas sin relación avisan "no encontré" | ✅ Probado |
| Instalación en un mini PC con Ubuntu | ✅ Probado |
| Instalación desde cero en otro equipo y en Raspberry Pi 4/5 | ⏳ Pendiente |
| Corte de **luz** real con batería: horas de autonomía y arranque automático | ⏳ Pendiente |
| iPhone y varios Android; varios celulares a la vez | ⏳ Pendiente |
| Personas que no conocen el proyecto encuentran una ficha y el mapa sin ayuda | ⏳ Pendiente |
| Revisión de las fichas por un profesional de la salud | ⏳ Pendiente |

Si pruebas alguna de las pendientes, cuéntalo en un issue: es la ayuda más valiosa.

## Importante

Esta información orienta, **no reemplaza a un profesional de la salud ni a las instrucciones de la autoridad**.
Las fichas resumen fuentes oficiales; cada una indica su fuente y quién la revisó y cuándo. Los artículos de la
biblioteca (Wikipedia) explican, pero no son instrucciones y pueden mencionar medicamentos y dosis. El mapa no
está en tiempo real. Si encuentras un error, abre un issue.

## Licencias

El código está bajo licencia [MIT](LICENSE). El contenido que se descarga o se incluye tiene sus propias
licencias: ver [AVISOS.md](AVISOS.md).
