#!/usr/bin/env python3
# GorilaPlay - lectura de listas de musica de varias plataformas.
"""Detecta de que plataforma es un enlace y devuelve sus pistas.

Plataformas que se leen directamente, sin cuenta ni clave:

  - Spotify       (pagina publica del reproductor incrustado)
  - Deezer         (API publica api.deezer.com)
  - YouTube        (yt-dlp)
  - YouTube Music  (yt-dlp)
  - SoundCloud     (yt-dlp, listas y canciones sueltas)
  - Mixcloud       (yt-dlp, cada programa es una pista)
  - Amazon Music   (API web publica: listas, albumes, artistas y canciones)
  - Bandcamp y demas sitios que soporte yt-dlp

Nonoki (Zozoki) no publica sus listas: para esa hay que pegar el texto de las
canciones (una por linea, "Artista - Titulo") o guardarlo en un .txt.

Cada pista se devuelve como diccionario con las claves:
    titulo, artista, dur (segundos), album, portada, url (opcional)
"""
import html
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid

AQUI = os.path.dirname(os.path.abspath(__file__))
YTDLP = os.path.expanduser("~/.local/bin/yt-dlp")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")

PLATAFORMAS = {
    "spotify": "Spotify",
    "deezer": "Deezer",
    "youtube": "YouTube",
    "youtube_music": "YouTube Music",
    "soundcloud": "SoundCloud",
    "mixcloud": "Mixcloud",
    "amazon": "Amazon Music",
    "nonoki": "Nonoki",
    "texto": "lista de texto",
    "otro": "enlace compatible con yt-dlp",
}

# Plataformas sin API publica: se explica que hacer en vez de fallar en seco.
SIN_LECTURA = {
    "nonoki": ("Nonoki (Zozoki) no publica sus listas ni tiene API abierta.\n\n"
               "Copia las canciones en un archivo .txt, una por linea con el\n"
               "formato:  Artista - Titulo\n"
               "Luego pega la ruta del .txt en 'Descargar musica o playlist'."),
}

# Amazon Music: endpoints web que usa su propio reproductor. No hace falta
# cuenta para leer el catalogo, solo el token CSRF de config.json.
AMAZON_SKILL = {
    "na": "https://na.web.skill.music.a2z.com",
    "eu": "https://eu.web.skill.music.a2z.com",
    "fe": "https://fe.web.skill.music.a2z.com",
}
AMAZON_REGIONES = {
    "music.amazon.com": ("na", "en_US", "USD"),
    "music.amazon.ca": ("na", "en_CA", "CAD"),
    "music.amazon.com.mx": ("na", "es_MX", "MXN"),
    "music.amazon.com.br": ("na", "pt_BR", "BRL"),
    "music.amazon.co.uk": ("eu", "en_GB", "GBP"),
    "music.amazon.de": ("eu", "de_DE", "EUR"),
    "music.amazon.fr": ("eu", "fr_FR", "EUR"),
    "music.amazon.it": ("eu", "it_IT", "EUR"),
    "music.amazon.es": ("eu", "es_ES", "EUR"),
    "music.amazon.in": ("eu", "en_IN", "INR"),
    "music.amazon.co.jp": ("fe", "ja_JP", "JPY"),
    "music.amazon.com.au": ("fe", "en_AU", "AUD"),
}
AMAZON_RUTAS = {
    "artists": "/api/showCatalogArtist",
    "albums": "/api/showCatalogAlbum",
    "playlists": "/api/showCatalogPlaylist",
    "user-playlists": "/api/showLibraryPlaylist",
}
# Cabeceras (traducidas) del carrusel de canciones mas escuchadas del artista.
AMAZON_TOP = ("canciones populares", "top songs", "popular songs", "las mas",
              "mejores canciones", "músicas populares", "mais tocadas",
              "canzoni popolari", "chansons populaires", "populare",
              "populäre", "beliebte", "populaire", "populära", "populære")
_AMAZON_CONFIG = {}

# Sufijos de los titulos de YouTube que no forman parte del nombre.
BASURA = re.compile(
    r"\s*[\(\[]\s*(official|oficial|video|videoclip|audio|lyric|letra|hd|hq|4k|"
    r"visualizer|music video|mv|remaster(ed)?(\s+\d{4})?|explicit|clean)\s*[^\)\]]*[\)\]]",
    re.I)


class ErrorLista(Exception):
    """Fallo legible al leer la lista."""


# ---------------------------------------------------------------- utilidades
def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^a-z0-9]+", " ", s.lower())
    return " ".join(s.split())


def limpiar_titulo(titulo):
    """Quita coletillas de YouTube y separa 'Artista - Tema'."""
    t = BASURA.sub("", titulo or "")
    t = re.sub(r"\s*[\|\-–]\s*(tema|audio|video|oficial|official)\s*$", "", t, flags=re.I)
    t = re.sub(r"\s{2,}", " ", t).strip(" -–|")
    return t


def separar_titulo(texto):
    """'Artista - Tema' -> ('Artista', 'Tema'); si no hay guion, ('', texto)."""
    limpio = limpiar_titulo(texto)
    if " - " in limpio:
        artista, titulo = limpio.split(" - ", 1)
        return artista.strip(), titulo.strip()
    return "", limpio


def _json(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise ErrorLista(f"La plataforma respondio {e.code} "
                         "(puede que la lista sea privada).")
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise ErrorLista(f"No pude leer el enlace: {e}")


def _html(url, timeout=30, ua=None):
    req = urllib.request.Request(
        url, headers={"User-Agent": ua or UA,
                      "Accept-Language": "es-ES,es;q=0.9,en;q=0.8"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise ErrorLista(f"La plataforma respondio {e.code} "
                         "(puede que la lista sea privada).")
    except (urllib.error.URLError, TimeoutError) as e:
        raise ErrorLista(f"No pude leer el enlace: {e}")


def _resolver(url):
    """Sigue acortadores (spotify.link, deezer.page.link, on.soundcloud.com)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.geturl() or url
    except (urllib.error.URLError, ValueError, TimeoutError):
        return url


def _ytdlp_json(url, plano=True, extra=()):
    exe = YTDLP if os.access(YTDLP, os.X_OK) else "yt-dlp"
    args = [exe, "-J", "--no-warnings", *extra, url]
    if plano:
        args.insert(1, "--flat-playlist")
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=900)
    except (subprocess.SubprocessError, OSError) as e:
        raise ErrorLista(f"yt-dlp fallo: {e}")
    if not p.stdout.strip():
        error = (p.stderr or "").strip().splitlines()
        raise ErrorLista(error[-1] if error else "yt-dlp no devolvio datos")
    try:
        datos = json.loads(p.stdout)
    except ValueError:
        raise ErrorLista("yt-dlp devolvio algo que no es JSON")
    if not isinstance(datos, dict):
        error = (p.stderr or "").strip().splitlines()
        raise ErrorLista(error[-1] if error else "yt-dlp no devolvio datos de ese enlace")
    return datos


# ---------------------------------------------------------------- deteccion
def detectar(entrada):
    """Devuelve la plataforma de la entrada (o 'texto')."""
    texto = (entrada or "").strip()
    if not texto:
        raise ErrorLista("La entrada esta vacia.")

    # un .txt existente o un texto con varias lineas = lista pegada a mano
    posible = os.path.expanduser(texto)
    if os.path.isfile(posible) and posible.lower().endswith(".txt"):
        return "texto"
    if "\n" in texto:
        return "texto"
    if not re.match(r"https?://", texto, re.I):
        return "texto"

    url = _resolver(texto) if re.search(
        r"(spotify\.link|deezer\.page\.link|link\.deezer\.com|on\.soundcloud\.com)",
        texto, re.I) else texto
    host = urllib.parse.urlparse(url).netloc.lower()
    ruta = urllib.parse.urlparse(url).path.lower()

    # acortadores: si no se pudieron resolver, al menos se sabe la plataforma
    if re.search(r"(deezer\.page\.link|link\.deezer\.com)", host):
        return "deezer"
    if "spotify.link" in host or "spoti.fi" in host:
        return "spotify"
    if "on.soundcloud.com" in host:
        return "soundcloud"

    if "music.youtube.com" in host:
        return "youtube_music"
    if re.search(r"(youtube\.com|youtu\.be|youtube-nocookie\.com)", host):
        return "youtube"
    if "spotify.com" in host:
        return "spotify"
    if "deezer.com" in host:
        return "deezer"
    if "soundcloud.com" in host:
        return "soundcloud"
    if "mixcloud.com" in host:
        return "mixcloud"
    if "music.amazon." in host or ("amazon." in host and "/music" in ruta):
        return "amazon"
    if re.search(r"(nonoki|zozoki)\.com", host):
        return "nonoki"
    return "otro"


# ---------------------------------------------------------------- spotify
def pistas_spotify(url):
    m = re.search(r"(playlist|album|track|artist)/([A-Za-z0-9]+)", url)
    if not m:
        raise ErrorLista("Enlace de Spotify no reconocido.")
    tipo, sid = m.groups()
    html = _html(f"https://open.spotify.com/embed/{tipo}/{sid}")
    mm = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
                   html, re.S)
    if not mm:
        raise ErrorLista("No pude leer la lista de Spotify (puede ser privada).")
    datos = json.loads(mm.group(1))

    def buscar(o, clave):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == clave:
                    yield v
                yield from buscar(v, clave)
        elif isinstance(o, list):
            for v in o:
                yield from buscar(v, clave)

    ent = next(buscar(datos, "entity"), {}) or {}
    nombre = ent.get("name") or ent.get("title") or "Spotify"

    portada = ""
    for cover in buscar(ent, "coverArt"):
        fuentes = (cover or {}).get("sources") or []
        if fuentes:
            portada = fuentes[-1].get("url") or ""
            if portada:
                break

    pistas = []
    for lista in buscar(datos, "trackList"):
        for t in lista:
            titulo = (t.get("title") or "").strip()
            artista = re.sub(r"\s*,\s*", ", ", (t.get("subtitle") or "")
                             .replace("\xa0", " ")).strip()
            if titulo:
                pistas.append({"titulo": titulo, "artista": artista,
                               "dur": (t.get("duration") or 0) / 1000.0,
                               "album": nombre, "portada": portada, "url": ""})

    if not pistas and ent.get("title"):
        artistas = ", ".join(a.get("name", "") for a in (ent.get("artists") or []))
        pistas.append({"titulo": ent["title"], "artista": artistas,
                       "dur": (ent.get("duration") or 0) / 1000.0,
                       "album": nombre, "portada": portada, "url": ""})
    if not pistas:
        raise ErrorLista("La lista de Spotify esta vacia o es privada.")
    return {"plataforma": "spotify", "nombre": nombre, "portada": portada,
            "pistas": pistas}


# ---------------------------------------------------------------- deezer
def _deezer_paginas(url):
    """Recorre las paginas de resultados de Deezer."""
    vistos = 0
    while url and vistos < 5000:
        d = _json(url)
        if isinstance(d, dict) and d.get("error"):
            raise ErrorLista(f"Deezer: {d['error'].get('message', 'error')}")
        for t in d.get("data") or []:
            vistos += 1
            yield t
        url = d.get("next")


def pistas_deezer(url):
    m = re.search(r"(playlist|album|track)/(\d+)", url)
    if not m:
        raise ErrorLista("Enlace de Deezer no reconocido.")
    tipo, did = m.groups()

    def convertir(t, album="", portada=""):
        return {
            "titulo": (t.get("title") or "").strip(),
            "artista": (t.get("artist") or {}).get("name") or "",
            "dur": t.get("duration") or 0,
            "album": (t.get("album") or {}).get("title") or album,
            "portada": (t.get("album") or {}).get("cover_xl") or portada,
            "url": t.get("link") or "",
        }

    if tipo == "track":
        d = _json(f"https://api.deezer.com/track/{did}")
        if d.get("error"):
            raise ErrorLista("Deezer no encuentra esa cancion.")
        pista = convertir(d)
        return {"plataforma": "deezer", "nombre": pista["album"] or pista["titulo"],
                "portada": pista["portada"], "pistas": [pista]}

    if tipo == "album":
        d = _json(f"https://api.deezer.com/album/{did}")
        if d.get("error"):
            raise ErrorLista("Deezer no encuentra ese disco.")
        nombre = d.get("title") or "Deezer"
        portada = d.get("cover_xl") or ""
        pistas = [convertir(t, nombre, portada) for t in _deezer_paginas(
            f"https://api.deezer.com/album/{did}/tracks?limit=100")]
    else:
        d = _json(f"https://api.deezer.com/playlist/{did}")
        if d.get("error"):
            raise ErrorLista("Deezer no encuentra esa lista (puede ser privada).")
        nombre = d.get("title") or "Deezer"
        portada = d.get("picture_xl") or ""
        pistas = [convertir(t, nombre, portada) for t in _deezer_paginas(
            f"https://api.deezer.com/playlist/{did}/tracks?limit=100")]

    pistas = [p for p in pistas if p["titulo"]]
    if not pistas:
        raise ErrorLista("La lista de Deezer esta vacia.")
    return {"plataforma": "deezer", "nombre": nombre, "portada": portada,
            "pistas": pistas}


# ---------------------------------------------------------------- amazon
def _amazon_parametros(host):
    if host in AMAZON_REGIONES:
        return AMAZON_REGIONES[host]
    if re.search(r"\.co\.jp$|\.com\.au$", host):
        return "fe", "en_US", "USD"
    if re.search(r"(^music\.amazon\.com$|\.com\.mx$|\.com\.br$|\.ca$)", host):
        return "na", "en_US", "USD"
    return "eu", "en_US", "EUR"


def _amazon_config(host):
    """Pide el token CSRF anonimo que usa el reproductor web de Amazon."""
    if host in _AMAZON_CONFIG:
        return _AMAZON_CONFIG[host]
    url = f"https://{host}/config.json?skipToken=false&clientApplication=skyfire"
    req = urllib.request.Request(
        url, data=b"",
        headers={"accept": "*/*", "accept-language": "es-ES,es;q=0.9",
                 "content-type": "text/plain;charset=UTF-8",
                 "origin": f"https://{host}", "referer": f"https://{host}/",
                 "user-agent": UA},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            cfg = json.load(r)
    except urllib.error.HTTPError as e:
        raise ErrorLista(f"Amazon Music respondio {e.code} al pedir la sesion.")
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise ErrorLista(f"No pude conectar con Amazon Music: {e}")
    if not isinstance(cfg, dict) or not cfg.get("csrf"):
        raise ErrorLista("Amazon Music no devolvio una sesion valida.")
    _AMAZON_CONFIG[host] = cfg
    return cfg


def _amazon_cabeceras(cfg, host, pagina, idioma, moneda):
    csrf = cfg.get("csrf") or {}
    return {
        "x-amzn-authentication": json.dumps({
            "interface": "ClientAuthenticationInterface.v1_0.ClientTokenElement",
            "accessToken": cfg.get("accessToken") or ""}),
        "x-amzn-device-model": "WEBPLAYER",
        "x-amzn-device-width": "1920",
        "x-amzn-device-family": "WebPlayer",
        "x-amzn-device-id": cfg.get("deviceId") or "",
        "x-amzn-user-agent": UA,
        "x-amzn-session-id": cfg.get("sessionId") or "",
        "x-amzn-device-height": "1080",
        "x-amzn-request-id": uuid.uuid4().hex[:12],
        "x-amzn-device-language": idioma,
        "x-amzn-currency-of-preference": moneda,
        "x-amzn-os-version": "1.0",
        "x-amzn-application-version": cfg.get("version") or "",
        "x-amzn-device-time-zone": "Europe/Madrid",
        "x-amzn-timestamp": str(int(time.time() * 1000)),
        "x-amzn-csrf": json.dumps({
            "interface": "CSRFInterface.v1_0.CSRFHeaderElement",
            "token": csrf.get("token") or "",
            "timestamp": str(csrf.get("ts") or ""),
            "rndNonce": str(csrf.get("rnd") or "")}),
        "x-amzn-music-domain": host,
        "x-amzn-referer": host,
        "x-amzn-affiliate-tags": "",
        "x-amzn-ref-marker": "",
        "x-amzn-page-url": pagina,
        "x-amzn-weblab-id-overrides": "",
        "x-amzn-video-player-token": "",
        "x-amzn-feature-flags": "hd-supported,uhd-supported",
        "x-amzn-has-profile-id": "",
        "x-amzn-age-band": "",
    }


def _amazon_post(host, ruta, ident, segmento):
    cfg = _amazon_config(host)
    region, idioma, moneda = _amazon_parametros(host)
    pagina = f"https://{host}/{segmento}/{ident}"
    cuerpo = {
        "id": ident,
        "userHash": json.dumps({"level": "LIBRARY_MEMBER"}),
        "headers": json.dumps(
            _amazon_cabeceras(cfg, host, pagina, idioma, moneda)),
    }
    req = urllib.request.Request(
        AMAZON_SKILL[region] + ruta,
        data=json.dumps(cuerpo).encode(),
        headers={
            "accept": "*/*",
            "accept-language": "es-ES,es;q=0.9,en;q=0.8",
            "content-type": "text/plain;charset=UTF-8",
            "origin": f"https://{host}",
            "referer": f"https://{host}/",
            "user-agent": UA,
            "x-amzn-device-model": "WEBPLAYER",
            "x-amzn-device-id": cfg.get("deviceId") or "",
            "x-amzn-session-id": cfg.get("sessionId") or "",
        },
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=35) as r:
            datos = json.load(r)
    except urllib.error.HTTPError as e:
        raise ErrorLista(
            f"Amazon Music respondio {e.code}. Puede que el enlace ya no "
            "exista o que el contenido no este disponible en tu region.")
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise ErrorLista(f"No pude leer Amazon Music: {e}")
    if not isinstance(datos, dict):
        raise ErrorLista("Amazon Music devolvio una respuesta inesperada.")
    return datos


def _amazon_texto(valor):
    if isinstance(valor, dict):
        return html.unescape((valor.get("text") or "").strip())
    return html.unescape(str(valor or "")).strip()


def _amazon_duracion(texto):
    """'03:08' o '1:02:03' -> segundos."""
    if not texto:
        return 0
    partes = [int(p) for p in re.split(r"[:.]", str(texto))
              if p.strip().isdigit()]
    if len(partes) >= 3:
        return partes[-3] * 3600 + partes[-2] * 60 + partes[-1]
    if len(partes) == 2:
        return partes[0] * 60 + partes[1]
    return 0


def _amazon_iso(texto):
    """Duracion ISO 8601 de la pagina de una cancion (PT3M8S)."""
    m = re.match(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", texto or "")
    if not m:
        return 0
    h, mi, s = (int(x or 0) for x in m.groups())
    return h * 3600 + mi * 60 + s


def _amazon_ids(item):
    """Devuelve (album_id, track_id) de un elemento de la API."""
    clave = (((item.get("iconButton") or {}).get("observer") or {})
             .get("storageKey") or "")
    album = track = ""
    if ":" in clave:
        album, track = clave.split(":", 1)
    enlace = (((item.get("primaryLink") or {}).get("deeplink")
               or (item.get("primaryTextLink") or {}).get("deeplink") or ""))
    m = re.search(r"trackAsin=([A-Za-z0-9]+)", enlace)
    if m and not track:
        track = m.group(1)
    m = re.search(r"/tracks/([A-Za-z0-9]+)", enlace)
    if m and not track:
        track = m.group(1)
    m = re.search(r"/albums/([A-Za-z0-9]+)", enlace)
    if m and not album:
        album = m.group(1)
    if not track:
        track = str(item.get("id") or "")
    return album, track


def _amazon_items(items, artista="", album="", portada=""):
    pistas = []
    for item in items or []:
        titulo = _amazon_texto(item.get("primaryText"))
        titulo = re.sub(r"^\d+\.\s*", "", titulo).strip()
        if not titulo:
            continue
        nombre_artista = (_amazon_texto(item.get("secondaryText1"))
                          or _amazon_texto(item.get("secondaryText"))
                          or artista)
        nombre_album = _amazon_texto(item.get("secondaryText2")) or album
        album_id, track_id = _amazon_ids(item)
        pistas.append({
            "titulo": titulo,
            "artista": nombre_artista,
            "dur": _amazon_duracion(_amazon_texto(item.get("secondaryText3"))),
            "album": nombre_album,
            "portada": item.get("image") or portada,
            "url": f"https://music.amazon.com/tracks/{track_id}" if track_id else "",
            "_album_id": album_id,
        })
    return pistas


def _amazon_widget_artista(template, nombre):
    """Localiza el carrusel de canciones populares del artista."""
    for widget in template.get("widgets") or []:
        cabecera = (widget.get("header") or "").lower()
        if any(marca in cabecera for marca in AMAZON_TOP):
            return widget.get("items") or []
    # Sin cabecera conocida: el widget con mas pistas del propio artista.
    objetivo = norm(nombre)
    mejor, mejor_n = [], 0
    for widget in template.get("widgets") or []:
        validos = [i for i in (widget.get("items") or [])
                   if ":" in (((i.get("iconButton") or {}).get("observer") or {})
                              .get("storageKey") or "")
                   and objetivo in norm(_amazon_texto(i.get("secondaryText")))]
        if len(validos) > mejor_n:
            mejor, mejor_n = validos, len(validos)
    return mejor


def _pistas_amazon_cancion(url):
    """Ultimo recurso para enlaces /tracks/: la pagina renderizada para bots."""
    bot = ("Mozilla/5.0 (compatible; Googlebot/2.1; "
           "+http://www.google.com/bot.html)")
    pagina = _html(url, ua=bot)
    bloques = re.findall(
        r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>',
        pagina, re.S)
    for bloque in bloques:
        try:
            datos = json.loads(html.unescape(bloque))
        except ValueError:
            continue
        for x in (datos if isinstance(datos, list) else [datos]):
            if not isinstance(x, dict) or x.get("@type") != "MusicRecording":
                continue
            titulo = html.unescape(x.get("name") or "").strip()
            if not titulo:
                continue
            by = x.get("byArtist") or {}
            artista = html.unescape(by.get("name") or "") if isinstance(by, dict) else ""
            dentro = x.get("inAlbum") or {}
            album = html.unescape(dentro.get("name") or "") if isinstance(dentro, dict) else ""
            return {
                "plataforma": "amazon",
                "nombre": album or titulo,
                "portada": x.get("image") or "",
                "pistas": [{
                    "titulo": titulo, "artista": artista,
                    "dur": _amazon_iso(x.get("duration") or ""),
                    "album": album, "portada": x.get("image") or "", "url": url,
                }],
            }
    raise ErrorLista("No pude leer esa cancion de Amazon Music.\n\n"
                     "Prueba con el enlace del album o de la lista.")


def pistas_amazon(url):
    partes = urllib.parse.urlparse(url)
    host = partes.netloc.lower()
    m = re.search(r"/(artists|albums|playlists|user-playlists|tracks)/"
                  r"([A-Za-z0-9]+)", partes.path)
    if not m:
        raise ErrorLista("Enlace de Amazon Music no reconocido.")
    tipo, ident = m.groups()

    if tipo == "tracks":
        return _pistas_amazon_cancion(url)

    datos = _amazon_post(host, AMAZON_RUTAS[tipo], ident, tipo)
    metodos = datos.get("methods") or []
    template = (metodos[0].get("template") or {}) if metodos else {}
    plantilla = template.get("templateData") or {}
    widgets = template.get("widgets") or []
    if (not template or plantilla.get("deeplink") == "/"
            or (tipo != "artists" and not widgets)):
        raise ErrorLista("Amazon Music no encuentra esa lista, album o artista.\n\n"
                         "Puede ser privada, haber cambiado de direccion o no "
                         "estar disponible en tu region.")

    if tipo == "artists":
        nombre = (_amazon_texto(template.get("headerText"))
                  or urllib.parse.unquote(partes.path.rstrip("/").split("/")[-1])
                  .replace("-", " "))
        portada = (template.get("backgroundImage")
                   or template.get("headerImage") or "")
        pistas = _amazon_items(_amazon_widget_artista(template, nombre),
                               artista=nombre, portada=portada)
        if not pistas:
            raise ErrorLista("Ese artista no tiene canciones populares visibles.")
        return {"plataforma": "amazon", "nombre": nombre,
                "portada": portada, "pistas": pistas}

    nombre = (_amazon_texto(template.get("headerText"))
              or urllib.parse.unquote(partes.path.rstrip("/").split("/")[-1])
              .replace("-", " "))
    portada = template.get("headerImage") or ""
    artista = _amazon_texto(template.get("headerPrimaryText"))
    album_defecto = nombre if tipo == "albums" else ""
    items = (widgets[0].get("items") or []) if widgets else []
    pistas = _amazon_items(items, artista=artista, album=album_defecto,
                           portada=portada)
    if not pistas:
        raise ErrorLista("Esa lista de Amazon Music esta vacia.")
    return {"plataforma": "amazon", "nombre": nombre, "portada": portada,
            "pistas": pistas}


# ---------------------------------------------------------------- yt-dlp
def pistas_ytdlp(url, plataforma="otro", impersonar=False):
    if impersonar:
        # Mixcloud y algunas webs detras de Cloudflare necesitan imitar a un
        # navegador; si no esta disponible, se intenta la via normal.
        try:
            datos = _ytdlp_json(
                url, extra=("--extractor-args", "generic:impersonate"))
        except ErrorLista:
            datos = _ytdlp_json(url)
    else:
        datos = _ytdlp_json(url)
    entradas = datos.get("entries") or [datos]
    nombre = datos.get("title") or datos.get("playlist_title") or "Lista"
    pistas = []
    for e in entradas:
        if not e or not e.get("id"):
            continue
        bruto = e.get("title") or e.get("fulltitle") or ""
        if not bruto:
            # SoundCloud devuelve las pistas de un set sin titulo: se saca del
            # slug de la direccion (soundcloud.com/artista/tema).
            ruta = urllib.parse.urlparse(e.get("url") or "").path.strip("/").split("/")
            if len(ruta) >= 2 and ruta[-2] != "sets":
                bruto = (f"{ruta[-2].replace('-', ' ')} - "
                         f"{ruta[-1].replace('-', ' ')}")
        artista_t, titulo = separar_titulo(bruto)
        artista = artista_t or e.get("channel") or e.get("uploader") or ""
        dur = e.get("duration") or 0
        if dur and dur > 3600 * 6:      # directos eternos: fuera
            continue
        pistas.append({
            "titulo": titulo or bruto,
            "artista": artista,
            "dur": dur,
            "album": nombre,
            "portada": "",
            "url": e.get("webpage_url") or e.get("url") or "",
        })
    if not pistas:
        raise ErrorLista("No hay pistas en ese enlace.")
    return {"plataforma": plataforma, "nombre": nombre, "portada": "",
            "pistas": pistas}


# ---------------------------------------------------------------- texto
def pistas_texto(entrada):
    ruta = os.path.expanduser(entrada.strip())
    if os.path.isfile(ruta):
        with open(ruta, encoding="utf-8", errors="replace") as f:
            lineas = f.readlines()
        nombre = os.path.splitext(os.path.basename(ruta))[0]
    else:
        lineas = entrada.splitlines()
        nombre = "Lista pegada"
        if len(lineas) == 1:
            raise ErrorLista("Eso no es un enlace ni una lista de canciones.")

    pistas = []
    for linea in lineas:
        limpia = linea.strip().strip("-•*").strip()
        limpia = re.sub(r"^\d+[.)]\s*", "", limpia)      # "1. ", "2) "
        limpia = re.sub(r"\s{2,}", " ", limpia)
        if not limpia or limpia.startswith("#"):
            continue
        artista, titulo = separar_titulo(limpia)
        pistas.append({"titulo": titulo or limpia, "artista": artista,
                       "dur": 0, "album": nombre, "portada": "", "url": ""})
    if not pistas:
        raise ErrorLista("No encontre canciones en esa lista.")
    return {"plataforma": "texto", "nombre": nombre, "portada": "",
            "pistas": pistas}


# ---------------------------------------------------------------- entrada
def obtener_pistas(entrada):
    """Lee la lista y devuelve {plataforma, nombre, portada, pistas}."""
    plataforma = detectar(entrada)
    if plataforma in SIN_LECTURA:
        raise ErrorLista(SIN_LECTURA[plataforma])
    if plataforma == "texto":
        return pistas_texto(entrada)
    if plataforma == "spotify":
        return pistas_spotify(entrada)
    if plataforma == "deezer":
        return pistas_deezer(entrada)
    if plataforma == "amazon":
        return pistas_amazon(entrada)
    return pistas_ytdlp(entrada, plataforma,
                       impersonar=plataforma in ("mixcloud", "otro"))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Uso: fuentes.py <enlace o lista>")
    try:
        info = obtener_pistas(sys.argv[1])
    except ErrorLista as e:
        sys.exit(f"Error: {e}")
    print(f"{PLATAFORMAS.get(info['plataforma'], info['plataforma'])}: "
          f"{info['nombre']}  ({len(info['pistas'])} pistas)")
    for i, p in enumerate(info["pistas"][:10], 1):
        print(f"  {i:3d}. {p['artista']} - {p['titulo']}  ({p['dur']}s)")
