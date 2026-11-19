# Cómo contribuir

Lo más valioso es **información confiable para más lugares**. No hace falta saber programar: casi todo son
archivos JSON.

## Agregar un país

Usa el código de dos letras del país (ISO 3166-1, ej. `PE`, `AR`, `MX`) y crea tres archivos, copiando los de
Chile (`CL`) como modelo:

1. **`portal/paises/<PAÍS>.json`**: nombre, `bbox` (oeste, sur, este, norte) para el mapa general, teléfonos
   de emergencia y "qué hacer" en las situaciones típicas del país (sismo, huracán, inundación…). Los tres
   primeros teléfonos aparecen en el inicio: pon primero ambulancia, bomberos y policía.
2. **`portal/fichas/<PAÍS>.json`**: fichas de primeros auxilios. Cada ficha lleva `tambien` (cómo lo diría la
   gente, para el buscador), `urgente_si`, `pasos`, `no_hacer`, `llamar` y `fuentes`. Muchas fichas sirven
   entre países: copia las de Chile y cambia los teléfonos y las fuentes por las de tu país.
   Arriba del archivo van `revision` (`fecha`, `por`, `profesional`: true solo si lo revisó un profesional de la
   salud; una ficha puede tener su propia `revision`) y `sin_senal` (qué hacer si no se puede llamar).
3. **`documentos/<PAÍS>.json`**: PDFs oficiales para guardar. `general` se baja siempre; `regiones` según la
   región elegida; `centros` da la capital de cada región (lat, lon) para que el asistente elija la más cercana.

## Reglas para el contenido

- **Solo fuentes oficiales o reconocidas** (ministerios de salud, protección civil, Cruz Roja, universidades).
  Cada ficha cita su fuente con enlace.
- **No inventes pasos.** Si las fuentes no coinciden, usa la del país y explícalo en `nota`.
- **Nada de dosis de medicamentos.**
- Si eres profesional de la salud y revisaste fichas, dilo en el issue o PR: se marca `profesional: true` con
  tu fecha de revisión.
- Lenguaje simple, frases cortas, en segunda persona ("Lava la zona con agua y jabón").
- Antes de agregar un PDF, verifica que la URL descargue un PDF real (`curl -sL URL | head -c4` debe dar `%PDF`)
  y que pese menos de 100 MB.

## Código

- Bash con `set -euo pipefail`, sin dependencias nuevas si se puede evitar.
- Todo lo que se descarga va con **versión fija y sha256** (ver `VENDOR` y `MODELO` en `descargar.sh`).
- Las imágenes Docker van con digest fijo.
- El portal no carga nada desde internet: tiene que funcionar sin conexión.
- Prueba en un equipo real: `./verificar.sh`, `./instalar.sh` y un corte de internet (desenchufa el cable del router).

## Reportar errores

Abre un issue con lo que pasó, lo que esperabas y la salida de `./verificar.sh`. **Si es un error en una ficha
de primeros auxilios, es prioridad**: indica la ficha y la fuente que lo contradice.
