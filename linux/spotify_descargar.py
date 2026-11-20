#!/usr/bin/env python3
# GorilaPlay - descarga metadatos de Spotify y audio de YouTube
"""Descarga una playlist/album/cancion de Spotify usando YouTube como fuente.

Lee la lista de pistas de la pagina de Spotify (no necesita cuenta ni API) y
busca cada cancion en YouTube con yt-dlp, eligiendo el resultado con duracion
y titulo mas parecidos.

Uso: spotify_descargar.py <url_spotify> <carpeta_destino> [bitrate] [--limit N]
"""
import sys, os, re, json, subprocess, unicodedata, difflib, urllib.request

YTDLP = os.path.expanduser("~/.local/bin/yt-dlp")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")


def norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^a-z0-9]+", " ", s.lower())
    return " ".join(s.split())


def limpiar(s):
    """Quita sufijos de version/remix entre parentesis para la busqueda."""
    return re.sub(r"\s*\((?:[^()]*)\)", "", s).strip()


def obtener(url):
    """Devuelve (nombre, [(titulo, artista, duracion_segundos)])."""
    m = re.search(r"(playlist|album|track|artist)/([A-Za-z0-9]+)", url)
    if not m:
        raise SystemExit("URL de Spotify no reconocida")
    tipo, sid = m.groups()
    req = urllib.request.Request(f"https://open.spotify.com/embed/{tipo}/{sid}",
                                 headers={"User-Agent": UA,
                                          "Accept-Language": "es-ES,es;q=0.9"})
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    mm = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
                   html, re.S)
    if not mm:
        raise SystemExit("No he podido leer la lista de Spotify")
    data = json.loads(mm.group(1))

    def buscar(o, clave):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == clave:
                    yield v
                yield from buscar(v, clave)
        elif isinstance(o, list):
            for v in o:
                yield from buscar(v, clave)

    ent = next(buscar(data, "entity"), {}) or {}
    nombre = ent.get("name") or ent.get("title") or "Spotify"

    pistas = []
    for lista in buscar(data, "trackList"):
        for t in lista:
            titulo = (t.get("title") or "").strip()
            artista = (t.get("subtitle") or "").replace("\xa0", " ")
            artista = re.sub(r"\s*,\s*", ", ", artista).strip()
            dur = (t.get("duration") or 0) / 1000.0
            if titulo:
                pistas.append((titulo, artista, dur))
    if not pistas and ent.get("title"):
        artistas = ", ".join(a.get("name", "") for a in (ent.get("artists") or []))
        artistas = artistas or (ent.get("subtitle") or "").replace("\xa0", " ").strip()
        pistas.append((ent["title"], artistas,
                       (ent.get("duration") or 0) / 1000.0))
    if not pistas:
        raise SystemExit("La lista de Spotify esta vacia o es privada")
    return nombre, pistas


def yt_search(query, n=10):
    p = subprocess.run([YTDLP, "--flat-playlist", "-J",
                        f"ytsearch{n}:{query}", "--no-warnings"],
                       capture_output=True, text=True)
    try:
        data = json.loads(p.stdout)
    except Exception:
        return []
    return [e for e in data.get("entries") or [] if e.get("id")]


# palabras que indican otra version distinta de la pedida
EXTRAS = ("acustico", "acústico", "en vivo", "live", "cover", "karaoke",
          "instrumental", "letra", "lyric", "sped up", "reverb", "8d",
          "remix", "version", "versión", "tutorial", "reaccion", "reaction")


def elegir(candidatos, dur, titulo, artista):
    t_norm = norm(titulo)
    a_norm = norm(artista)
    mejor, mejor_p = None, -1e9
    for c in candidatos:
        cd = c.get("duration") or 0
        ct = norm(c.get("title") or "")
        sub = norm(c.get("channel") or c.get("uploader") or "")

        # duracion: la senal mas fiable
        if dur and cd:
            d = abs(cd - dur)
            dur_score = 1.0 if d <= 2 else 0.85 if d <= 5 else 0.6 if d <= 12 \
                else 0.25 if d <= 30 else 0.0
        else:
            dur_score = 0.5

        p = 4.5 * dur_score
        p += 2.0 * difflib.SequenceMatcher(None, ct, t_norm).ratio()
        # canal oficial de artista / discografica
        if sub.endswith("topic") or "vevo" in sub:
            p += 0.8
        if a_norm and (a_norm in sub or a_norm in ct):
            p += 0.4
        # penaliza versiones que no se han pedido
        for w in EXTRAS:
            wn = norm(w)
            if wn and wn in ct and wn not in t_norm:
                p -= 1.0
        if p > mejor_p:
            mejor, mejor_p = c, p
    return mejor


def descargar(vid, destino, bitrate):
    url = f"https://www.youtube.com/watch?v={vid}"
    p = subprocess.run([YTDLP, "-x", "--audio-format", "mp3",
                        "--audio-quality", f"{bitrate}K", "--no-overwrites",
                        "--no-warnings", "--retries", "3",
                        "--output", destino, url],
                       capture_output=True, text=True)
    return p.returncode == 0, p.stderr


def etiquetar(ruta, titulo, artista, album):
    tmp = ruta + ".tmp.mp3"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", ruta, "-c", "copy",
                    "-metadata", f"title={titulo}",
                    "-metadata", f"artist={artista}",
                    "-metadata", f"album={album}",
                    tmp], check=True)
    os.replace(tmp, ruta)


def main():
    args = [a for a in sys.argv[1:]]
    limite = None
    if "--limit" in args:
        i = args.index("--limit")
        limite = int(args[i + 1])
        del args[i:i + 2]
    if len(args) < 2:
        raise SystemExit(__doc__)
    url, base = args[0], os.path.expanduser(args[1])
    bitrate = args[2] if len(args) > 2 else "320"

    nombre, pistas = obtener(url)
    if limite:
        pistas = pistas[:limite]
    carpeta = os.path.join(base, re.sub(r'[/\\:*?"<>|]', "_", nombre))
    os.makedirs(carpeta, exist_ok=True)
    print(f"Spotify: {nombre}  ({len(pistas)} pistas)")
    if len(pistas) == 100:
        print("Aviso: la vista publica de Spotify solo muestra 100 pistas.")
        print("Si la playlist tiene mas, se descargan solo las 100 primeras.")
    print(f"Destino: {carpeta}\n")

    fallos = []
    for i, (titulo, artista, dur) in enumerate(pistas, 1):
        archivo = os.path.join(carpeta, re.sub(r'[/\\:*?"<>|]', "_",
                                               f"{artista} - {titulo}") + ".mp3")
        print(f"[{i}/{len(pistas)}] {artista} - {titulo}")
        if os.path.exists(archivo):
            print("   ya existe, se omite")
            continue
        consulta = f"{limpiar(titulo)} {artista}"
        cands = yt_search(consulta, 5)
        if not cands:
            print("   sin resultados en YouTube")
            fallos.append(titulo)
            continue
        c = elegir(cands, dur, titulo, artista.split(",")[0])
        ok, err = descargar(c["id"], archivo, bitrate)
        if not ok:
            print("   error al descargar:", err.strip().splitlines()[-1:] or "")
            fallos.append(titulo)
            continue
        etiquetar(archivo, titulo, artista, nombre)
        cd = c.get("duration")
        print(f"   ok  ({cd}s vs {dur:.0f}s)  {c.get('title')}")

    print(f"\nTerminado. {len(pistas)-len(fallos)}/{len(pistas)} pistas.")
    if fallos:
        print("No encontradas: " + ", ".join(fallos))
        sys.exit(1)


if __name__ == "__main__":
    main()
