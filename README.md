<p align="center">
  <img src="assets/icono-512.png" alt="GorilaPlay" width="180">
</p>

<h1 align="center">GorilaPlay</h1>

<p align="center">
  Descargador de playlists de YouTube y Spotify con interfaz gráfica.<br>
  Pega la URL, elige formato y carpeta, y listo.
</p>

---

## Qué es

GorilaPlay es un lanzador sencillo para [yt-dlp](https://github.com/yt-dlp/yt-dlp)
pensado para no tener que escribir comandos. Acepta:

- **YouTube**: playlists, álbumes, vídeos sueltos y canales.
- **Spotify**: playlists, álbumes y canciones (los metadatos se leen de Spotify
  y el audio se descarga de YouTube, porque Spotify no permite descargar su
  audio).
- Cualquier otro sitio que soporte yt-dlp (SoundCloud, Bandcamp, Vimeo...).

Formatos: MP3 320 kbps, MP3 192 kbps, audio original m4a o vídeo hasta 1080p.

## Características

- Diálogos nativos: sin terminal ni comandos para el uso diario.
- Crea una subcarpeta por playlist con el nombre de la lista.
- Nombra los archivos como `Artista - Título.mp3` e incrusta carátula y etiquetas.
- **Carátula propia en cada canción**: si la descarga no trae una buena, la busca
  en Deezer/iTunes y, si no la encuentra, usa la de la lista de Spotify o la
  miniatura de YouTube.
- **Pone carátula a una carpeta ya descargada**: útil para discos bajados antes
  de tener esta función o para música que ya tenías.
- Registro de descargas: lo que ya has bajado no se vuelve a descargar.
- Log de cada ejecución para poder revisar errores.
- Al buscar en YouTube descarta lyric, cover, karaoke, en vivo, etc., y prefiere
  canales oficiales (`... - Topic`, VEVO) y la duración que marca Spotify.

## Instalación en Linux (probado en KDE / Nobara)

Dependencias:

```bash
# yt-dlp (elige una)
pipx install yt-dlp
# o
pip install --user yt-dlp

# ffmpeg
sudo dnf install ffmpeg        # Fedora / Nobara
sudo apt install ffmpeg        # Debian / Ubuntu

# carátulas (Python + mutagen)
sudo dnf install python3-mutagen    # o: pip install --user mutagen

# diálogos y terminal
sudo dnf install kdialog konsole
```

Instalación:

```bash
git clone https://github.com/4M4L4K4Ky/GorilaPlay.git
cd GorilaPlay
./linux/instalar.sh
```

Queda en el menú de aplicaciones como **GorilaPlay**. También puedes lanzarlo
desde una terminal con `descargar-playlist` y poner carátulas con
`gorilaplay-caratulas <carpeta>`.

## Instalación en Windows

El programa también funciona en Windows con un port en PowerShell.

1. Instala **ffmpeg**:

   ```powershell
   winget install Gyan.FFmpeg
   ```

   Cierra y abre la terminal para que coja el PATH.

2. Descarga este repositorio (botón *Code → Download ZIP*) y descomprímelo.

3. Haz doble clic en `windows\GorilaPlay.cmd`.

La primera vez descarga `yt-dlp.exe` automáticamente en `windows\bin\`.
Si Windows SmartScreen avisa, elige *Más información → Ejecutar de todas formas*
(el script es texto plano, puedes leerlo antes).

El botón **CARÁTULAS** hace lo mismo que en Linux: elige una carpeta y pone
portada a cada mp3/m4a que no la tenga (necesita `ffmpeg` y `ffprobe`, los dos
vienen en el paquete de Gyan.FFmpeg).

> La versión de Windows está portada pero menos probada que la de Linux. Si algo
> falla, abre un issue con el mensaje de error.

## Uso

1. Abre **GorilaPlay**.
2. Elige **Descargar vídeo o playlist**.
3. Pega la URL de la playlist.
4. Elige el formato.
5. Elige la carpeta de destino (por defecto `~/Música`).
6. Pulsa **Descargar** y espera.

Resultado:

```
~/Música/
└── Mi lista de ejemplo/
    ├── Artista Uno - Título Uno.mp3
    ├── Artista Dos - Título Dos.mp3
    └── ...
```

### Spotify

Pega la URL de la playlist, álbum o canción de Spotify. GorilaPlay lee la lista
de pistas públicas y busca cada una en YouTube, comparando duración y título.

Limitación: la vista pública de Spotify muestra como máximo **100 pistas**.
Si tu playlist es más larga, se descargarán las 100 primeras (te avisa en el log).

### Carátulas

Cada canción se queda con la portada del disco incrustada dentro del archivo (no
como imagen suelta), así que se ve en cualquier reproductor, en el móvil o en el
coche.

Al descargar se hace solo. Para música que ya tienes, GorilaPlay también pone
carátulas a una carpeta entera:

1. Abre **GorilaPlay**.
2. Elige **Poner carátula a las canciones de una carpeta**.
3. Selecciona la carpeta.
4. Elige si solo toca las que no tienen carátula o si las reemplaza todas.

Desde una terminal:

```bash
gorilaplay-caratulas ~/Música/"Mi playlist"                # solo las que faltan
gorilaplay-caratulas ~/Música/"Mi playlist" --reemplazar   # todas otra vez
gorilaplay-caratulas ~/Música/"Mi playlist" --solo-probar  # ver qué encontraría
```

Busca primero en Deezer y después en iTunes, comparando título, artista y
duración; si no hay coincidencia clara, usa la miniatura de YouTube
(`--sin-youtube` para desactivarlo). También rellena título, artista y álbum
cuando faltan (`--sin-etiquetas` para no tocarlos).

Soporta MP3, M4A, FLAC, OGG y OPUS. No recomprime el audio: solo le añade la
imagen y las etiquetas. Si una canción se queda sin carátula, el programa lo
dice al final con la lista de las que han fallado.

### Datos y registros

| Qué | Dónde (Linux) | Dónde (Windows) |
|---|---|---|
| Descargas ya hechas | `~/.local/state/gorilaplay/descargados.txt` | `%LOCALAPPDATA%\GorilaPlay\descargados.txt` |
| Logs | `~/.local/state/gorilaplay/*.log` | `%LOCALAPPDATA%\GorilaPlay\*.log` |

Borra el archivo de registro si quieres volver a descargar algo que ya bajaste.

## Problemas frecuentes

**No aparece la ventana / no sale el selector de carpeta**
Falta `kdialog` o `konsole`: instálalos con el gestor de paquetes.

**"No encuentro yt-dlp"**
Instálalo con `pipx install yt-dlp` y comprueba que `~/.local/bin` está en el PATH.

**YouTube pide iniciar sesión o dice que el vídeo no está disponible**
Actualiza yt-dlp (`yt-dlp -U`). Si sigue, exporta las cookies del navegador y
añade `--cookies-from-browser firefox` en el script.

**La descarga se corta o va lenta**
Es límite de YouTube. El script ya espera un segundo entre peticiones; puedes
subir `--sleep-requests` para ir más despacio.

**Alguna canción se queda sin carátula**
Deezer/iTunes no la tienen con ese título exacto. Prueba con
`gorilaplay-caratulas <carpeta> --reemplazar` (a veces la encuentra al segundo
intento) o ponle la portada a mano con tu reproductor. También puedes probar a
renombrar el archivo como `Artista - Título.mp3`, que es lo que usa para buscar.

## Estructura del repositorio

```
GorilaPlay/
├── assets/          icono (svg, png 1024/512/256, ico)
├── linux/           lanzador bash + Spotify + carátulas + instalador
├── windows/         port en PowerShell + lanzador .cmd
├── LICENSE
└── README.md
```

## Aviso legal

GorilaPlay solo descarga contenido que tú tengas derecho a descargar. Respeta
los términos de servicio de cada plataforma y los derechos de autor de las obras.
El proyecto no aloja ni distribuye audio.

## Créditos

- Motor de descarga: [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- Conversión de audio: [FFmpeg](https://ffmpeg.org/)
- Icono e interfaz: proyecto GorilaPlay

Licencia MIT.
