#!/usr/bin/env python3
# GorilaPlay - pone caratula y etiquetas a los archivos de audio de una carpeta.
"""Busca la portada del disco y la incrusta en cada cancion.

Fuentes de portada, en orden:
  1. Deezer (caratula de 1000x1000, sin clave ni cuenta)
  2. iTunes (caratula de 600x600)
  3. YouTube (miniatura del video, recortada a cuadro)

El audio no se recomprime: solo se le anade la imagen y, si faltan, el titulo,
el artista y el album. Respeta lo que ya tenga caratula salvo que se le pida
reemplazarla.

Uso:
    caratulas.py CARPETA [opciones]

Opciones:
    --reemplazar      cambia tambien las canciones que ya tienen caratula
    --sin-youtube     no usa miniaturas de YouTube como ultimo recurso
    --sin-etiquetas   solo pone la caratula, no toca titulo/artista/album
    --solo-probar     busca y cuenta, pero no escribe nada
    --trabajos N      busquedas en paralelo (por defecto 4)
"""
import argparse
import base64
import concurrent.futures
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

try:
    import mutagen
    from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1
    from mutagen.mp3 import MP3
    from mutagen.mp4 import MP4, MP4Cover
    from mutagen.flac import FLAC, Picture
    from mutagen.oggvorbis import OggVorbis
    from mutagen.oggopus import OggOpus
except ImportError:
    sys.exit("Falta mutagen. Instalalo con:  sudo dnf install python3-mutagen\n"
             "o bien:  pip install --user mutagen")

EXTENSIONES = (".mp3", ".m4a", ".flac", ".ogg", ".opus")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")
YTDLP = os.path.expanduser("~/.local/bin/yt-dlp")
LADO = 600                      # lado de la caratula final, en pixeles

# Palabras que delatan una version distinta de la que se busca.
EXTRAS = ("acustico", "en vivo", "live", "cover", "karaoke", "instrumental",
          "letra", "lyric", "sped up", "reverb", "8d", "remix", "version",
          "tutorial", "reaccion", "reaction")

VERDE, AMARILLO, ROJO, GRIS, FIN = "\033[32m", "\033[33m", "\033[31m", "\033[90m", "\033[0m"


# ---------------------------------------------------------------- texto
def norm(s):
    """Minusculas, sin tildes y sin signos: para comparar titulos."""
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^a-z0-9]+", " ", s.lower())
    return " ".join(s.split())


def similitud(a, b):
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def limpiar_consulta(titulo):
    """Quita sufijos de version para que la busqueda sea mas amplia."""
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", titulo)
    t = re.sub(r"\s+-\s+(version|versión|remaster|remastered|single|en vivo)\b.*$",
               "", t, flags=re.I)
    return " ".join(t.split())


def trocear_artistas(artista):
    partes = re.split(r"[,&]| feat\.? | ft\.? | x ", artista or "", flags=re.I)
    return [norm(p) for p in partes if norm(p)]


# ---------------------------------------------------------------- red
def _json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def _bajar(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def buscar_deezer(consulta):
    """Devuelve candidatos con portada de 1000x1000."""
    url = "https://api.deezer.com/search?" + urllib.parse.urlencode(
        {"q": consulta, "limit": 8})
    try:
        datos = _json(url).get("data") or []
    except (urllib.error.URLError, ValueError, TimeoutError):
        return []
    salida = []
    for d in datos:
        album = d.get("album") or {}
        salida.append({
            "fuente": "Deezer",
            "titulo": d.get("title") or "",
            "artista": (d.get("artist") or {}).get("name") or "",
            "album": album.get("title") or "",
            "dur": d.get("duration") or 0,
            "portada": album.get("cover_xl") or album.get("cover_big") or "",
            "recortar": False,
        })
    return [c for c in salida if c["portada"]]


def buscar_itunes(consulta):
    """Devuelve candidatos con portada de 600x600."""
    url = "https://itunes.apple.com/search?" + urllib.parse.urlencode(
        {"term": consulta, "entity": "song", "limit": 8, "country": "ES"})
    try:
        datos = _json(url).get("results") or []
    except (urllib.error.URLError, ValueError, TimeoutError):
        return []
    salida = []
    for d in datos:
        portada = d.get("artworkUrl100") or d.get("artworkUrl60") or ""
        if portada:
            portada = re.sub(r"/\d+x\d+bb\.", f"/{LADO}x{LADO}bb.", portada)
        salida.append({
            "fuente": "iTunes",
            "titulo": d.get("trackName") or "",
            "artista": d.get("artistName") or "",
            "album": d.get("collectionName") or "",
            "dur": int((d.get("trackTimeMillis") or 0) / 1000),
            "portada": portada,
            "recortar": False,
        })
    return [c for c in salida if c["portada"]]


def buscar_youtube(consulta):
    """Ultimo recurso: miniatura del video mas parecido."""
    if not (os.access(YTDLP, os.X_OK) or _en_path("yt-dlp")):
        return []
    exe = YTDLP if os.access(YTDLP, os.X_OK) else "yt-dlp"
    try:
        p = subprocess.run([exe, "--flat-playlist", "-J", f"ytsearch3:{consulta}",
                            "--no-warnings"], capture_output=True, text=True,
                           timeout=90)
        datos = json.loads(p.stdout)
    except (subprocess.SubprocessError, ValueError):
        return []
    salida = []
    for e in datos.get("entries") or []:
        miniaturas = e.get("thumbnails") or []
        url = ""
        if miniaturas:
            mejor = max(miniaturas, key=lambda m: (m.get("width") or 0) *
                        (m.get("height") or 0))
            url = mejor.get("url") or ""
        if url:
            salida.append({
                "fuente": "YouTube",
                "titulo": e.get("title") or "",
                "artista": e.get("channel") or e.get("uploader") or "",
                "album": "",
                "dur": int(e.get("duration") or 0),
                "portada": url,
                "recortar": True,
            })
    return salida


def _en_path(programa):
    return any(os.access(os.path.join(d, programa), os.X_OK)
               for d in os.environ.get("PATH", "").split(os.pathsep) if d)


# ---------------------------------------------------------------- eleccion
def elegir(candidatos, titulo, artista, dur):
    """Puntua los candidatos y devuelve (mejor, seguro)."""
    t_limpio = norm(limpiar_consulta(titulo))
    t_bruto = norm(titulo)
    artistas = trocear_artistas(artista)
    mejor, mejor_p, mejor_st, mejor_dd = None, -1e9, 0.0, None
    for c in candidatos:
        ct_bruto = norm(c["titulo"])
        ct_limpio = norm(limpiar_consulta(c["titulo"]))
        # comparar titulo con y sin parentesis: hay discos que meten el nombre
        # de la serie entre parentesis y otros con guiones
        st = max(similitud(ct_limpio, t_limpio),
                 similitud(ct_bruto, t_bruto),
                 similitud(ct_bruto, t_limpio))
        sa = max([similitud(norm(c["artista"]), a) for a in artistas] or [0.0])
        dd = abs(c["dur"] - dur) if (c["dur"] and dur) else None

        p = 3.0 * st + 1.6 * sa
        if dd is not None:
            p += 2.0 * (1.0 if dd <= 2 else .8 if dd <= 5 else .55 if dd <= 10
                        else .15 if dd <= 20 else 0.0)
        # no aceptar versiones (remix, en vivo...) que el original no pedia
        for w in EXTRAS:
            if norm(w) in ct_bruto and norm(w) not in t_bruto:
                p -= 0.9
        if p > mejor_p:
            mejor, mejor_p, mejor_st, mejor_dd = c, p, st, dd

    if mejor is None:
        return None, False
    # margen de seguridad: el titulo tiene que parecerse de verdad
    seguro = mejor_st >= 0.62 and (
        mejor_dd is None or mejor_dd <= 12 or mejor_st >= 0.92)
    return mejor, seguro


def consultas(titulo, artista):
    """Variantes de busqueda, de la mas concreta a la mas amplia."""
    limpio = limpiar_consulta(titulo)
    variantes = [limpio]
    trozos = [x.strip() for x in limpio.split(" - ") if x.strip()]
    if len(trozos) > 1:
        variantes.append(trozos[0])
    artista1 = re.split(r"[,&]", artista or "")[0].strip()
    salida = []
    for v in variantes:
        if artista:
            salida.append(f"{artista} {v}".strip())
        if artista1 and artista1 != artista:
            salida.append(f"{artista1} {v}".strip())
        salida.append(v)
    vistas, final = set(), []
    for q in salida:
        if q and q not in vistas:
            vistas.add(q)
            final.append(q)
    return final[:4]


def buscar_portada(titulo, artista, dur, usar_youtube=True):
    """Devuelve el candidato ganador o None."""
    lista = consultas(titulo, artista)
    for consulta in lista:
        for buscador in (buscar_deezer, buscar_itunes):
            cands = buscador(consulta)
            if cands:
                c, seguro = elegir(cands, titulo, artista, dur)
                if c and seguro:
                    return c
    if usar_youtube:
        for consulta in lista[:2]:
            cands = buscar_youtube(consulta)
            if cands:
                c, seguro = elegir(cands, titulo, artista, dur)
                if c and seguro:
                    return c
    return None


# ---------------------------------------------------------------- imagen
def preparar_imagen(url, recortar):
    """Descarga la portada y la deja en JPEG de LADO x LADO."""
    crudo = _bajar(url)
    with tempfile.TemporaryDirectory() as tmp:
        entrada = os.path.join(tmp, "entrada")
        salida = os.path.join(tmp, "portada.jpg")
        with open(entrada, "wb") as f:
            f.write(crudo)
        filtro = (f"crop='min(iw,ih)':'min(iw,ih)'," if recortar else "")
        filtro += (f"scale={LADO}:{LADO}:force_original_aspect_ratio=decrease,"
                   f"pad={LADO}:{LADO}:(ow-iw)/2:(oh-ih)/2:color=black")
        p = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", entrada,
                            "-vf", filtro, "-q:v", "3", "-frames:v", "1", salida],
                           capture_output=True, text=True)
        if p.returncode != 0 or not os.path.exists(salida):
            raise RuntimeError("no pude convertir la imagen: " + p.stderr.strip()[-200:])
        with open(salida, "rb") as f:
            return f.read()


# ---------------------------------------------------------------- archivo
def abrir(ruta):
    return mutagen.File(ruta)


def tiene_portada(m):
    if isinstance(m, MP3):
        return bool(m.tags and m.tags.getall("APIC"))
    if isinstance(m, MP4):
        return bool(m.tags and m.tags.get("covr"))
    if isinstance(m, FLAC):
        return bool(m.pictures)
    if isinstance(m, (OggVorbis, OggOpus)):
        return bool(m.tags and m.tags.get("metadata_block_picture"))
    return False


def leer_campo(m, nombre):
    tags = m.tags
    if not tags:
        return ""
    if isinstance(m, MP3):
        clave = {"title": "TIT2", "artist": "TPE1", "album": "TALB"}[nombre]
        valor = tags.get(clave)
    elif isinstance(m, MP4):
        clave = {"title": "\xa9nam", "artist": "\xa9ART", "album": "\xa9alb"}[nombre]
        valor = tags.get(clave)
    else:
        valor = tags.get(nombre)
    if not valor:
        return ""
    if isinstance(valor, list):
        valor = valor[0] if valor else ""
    return str(valor).strip()


def escribir_campo(m, nombre, valor):
    if not valor:
        return
    if isinstance(m, MP3):
        marco = {"title": TIT2, "artist": TPE1, "album": TALB}[nombre]
        m.tags.setall(marco.__name__, [marco(encoding=3, text=[valor])])
    elif isinstance(m, MP4):
        clave = {"title": "\xa9nam", "artist": "\xa9ART", "album": "\xa9alb"}[nombre]
        m.tags[clave] = [valor]
    else:
        m.tags[nombre] = [valor]


def incrustar(m, imagen):
    if isinstance(m, MP3):
        m.tags.delall("APIC")
        m.tags.add(APIC(encoding=3, mime="image/jpeg", type=3,
                        desc="Cover", data=imagen))
    elif isinstance(m, MP4):
        m.tags["covr"] = [MP4Cover(imagen, imageformat=MP4Cover.FORMAT_JPEG)]
    elif isinstance(m, FLAC):
        m.clear_pictures()
        foto = Picture()
        foto.type, foto.mime, foto.desc, foto.data = 3, "image/jpeg", "Cover", imagen
        m.add_picture(foto)
    elif isinstance(m, (OggVorbis, OggOpus)):
        foto = Picture()
        foto.type, foto.mime, foto.desc, foto.data = 3, "image/jpeg", "Cover", imagen
        m["metadata_block_picture"] = [
            base64.b64encode(foto.write()).decode("ascii")]


def datos_de_archivo(ruta):
    """Saca titulo, artista y duracion de las etiquetas o del nombre."""
    m = abrir(ruta)
    if m is None:
        raise RuntimeError("formato no soportado")
    titulo = leer_campo(m, "title")
    artista = leer_campo(m, "artist")
    base = os.path.splitext(os.path.basename(ruta))[0]
    if not titulo or not artista:
        if " - " in base:
            a, t = base.split(" - ", 1)
            artista = artista or a.strip()
            titulo = titulo or t.strip()
        else:
            titulo = titulo or base
    dur = int(getattr(m.info, "length", 0) or 0)
    return m, titulo, artista, dur


def poner(ruta, titulo=None, artista=None, album=None, dur=None,
          reemplazar=True, etiquetas=True, usar_youtube=True,
          portada_respaldo=None):
    """Pone caratula a un archivo concreto.

    Devuelve (estado, detalle) donde estado es 'ok', 'tenia' o 'fallo'.
    'portada_respaldo' es una URL que se usa si no hay coincidencia en
    internet (por ejemplo la portada de la playlist de Spotify).
    """
    m = abrir(ruta)
    if m is None:
        return "fallo", "formato no soportado"
    if tiene_portada(m) and not reemplazar:
        return "tenia", ""

    if titulo is None or artista is None:
        _, titulo_t, artista_t, dur_t = datos_de_archivo(ruta)
        titulo = titulo or titulo_t
        artista = artista or artista_t
        dur = dur or dur_t

    cand = buscar_portada(titulo, artista, dur or 0, usar_youtube)
    if cand is None and portada_respaldo:
        cand = {"fuente": "Spotify", "portada": portada_respaldo,
                "recortar": False, "album": album or ""}
    if cand is None:
        return "fallo", "sin caratula"

    imagen = preparar_imagen(cand["portada"], cand["recortar"])
    if m.tags is None:
        m.add_tags()
    incrustar(m, imagen)
    if etiquetas:
        escribir_campo(m, "title", titulo)
        escribir_campo(m, "artist", artista)
        escribir_campo(m, "album", album or cand.get("album") or "")
    m.save()
    detalle = cand["fuente"]
    if cand.get("album"):
        detalle += f" · {cand['album']}"
    return "ok", detalle


# ---------------------------------------------------------------- lote
def listar(carpeta):
    for raiz, _, archivos in os.walk(carpeta):
        for nombre in sorted(archivos):
            if os.path.splitext(nombre)[1].lower() in EXTENSIONES:
                yield os.path.join(raiz, nombre)


def main():
    ap = argparse.ArgumentParser(
        description="Pone caratula a las canciones de una carpeta.")
    ap.add_argument("carpeta")
    ap.add_argument("--reemplazar", action="store_true",
                    help="cambia tambien las que ya tienen caratula")
    ap.add_argument("--sin-youtube", action="store_true",
                    help="no usa miniaturas de YouTube")
    ap.add_argument("--sin-etiquetas", action="store_true",
                    help="no toca titulo, artista ni album")
    ap.add_argument("--solo-probar", action="store_true",
                    help="no escribe nada, solo informa")
    ap.add_argument("--trabajos", type=int, default=4,
                    help="busquedas en paralelo (por defecto 4)")
    a = ap.parse_args()

    carpeta = os.path.expanduser(a.carpeta)
    if not os.path.isdir(carpeta):
        sys.exit(f"No existe la carpeta: {carpeta}")

    archivos = list(listar(carpeta))
    total = len(archivos)
    if not total:
        sys.exit("No hay archivos de audio en esa carpeta.")

    print(f"GorilaPlay · caratulas · {total} archivos en {carpeta}\n")
    cuenta = {"ok": 0, "tenia": 0, "fallo": 0}
    fallos = []
    bloqueo = __import__("threading").Lock()

    def trabajo(i_ruta):
        i, ruta = i_ruta
        nombre = os.path.basename(ruta)
        try:
            m = abrir(ruta)
            if m is not None and tiene_portada(m) and not a.reemplazar:
                with bloqueo:
                    cuenta["tenia"] += 1
                    print(f"[{i}/{total}] {GRIS}ya tiene caratula{FIN} · {nombre}")
                return
            if a.solo_probar:
                _, titulo, artista, dur = datos_de_archivo(ruta)
                cand = buscar_portada(titulo, artista, dur,
                                      not a.sin_youtube)
                with bloqueo:
                    if cand:
                        cuenta["ok"] += 1
                        print(f"[{i}/{total}] {VERDE}{cand['fuente']}{FIN} · "
                              f"{artista} - {titulo} {GRIS}→ {cand['titulo']}{FIN}")
                    else:
                        cuenta["fallo"] += 1
                        fallos.append(nombre)
                        print(f"[{i}/{total}] {ROJO}sin caratula{FIN} · {nombre}")
                return
            estado, detalle = poner(ruta, reemplazar=True,
                                    etiquetas=not a.sin_etiquetas,
                                    usar_youtube=not a.sin_youtube)
            with bloqueo:
                cuenta[estado] += 1
                if estado == "ok":
                    print(f"[{i}/{total}] {VERDE}ok{FIN} {GRIS}{detalle}{FIN} · {nombre}")
                else:
                    fallos.append(nombre)
                    print(f"[{i}/{total}] {ROJO}{detalle}{FIN} · {nombre}")
        except Exception as e:
            with bloqueo:
                cuenta["fallo"] += 1
                fallos.append(nombre)
                print(f"[{i}/{total}] {ROJO}error: {e}{FIN} · {nombre}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.trabajos)) as ex:
        list(ex.map(trabajo, enumerate(archivos, 1)))

    print(f"\n{cuenta['ok']} con caratula nueva · {cuenta['tenia']} ya la tenian"
          f" · {cuenta['fallo']} sin caratula")
    if fallos:
        print("Sin caratula: " + ", ".join(fallos[:15]) +
              ("..." if len(fallos) > 15 else ""))
        print("Puedes buscarlas a mano o volver a probar con --reemplazar.")
        sys.exit(1)


if __name__ == "__main__":
    main()
