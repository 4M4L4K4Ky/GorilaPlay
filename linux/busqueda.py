#!/usr/bin/env python3
# GorilaPlay - busca el audio de una pista en varias fuentes.
"""Motor de busqueda: prueba YouTube y, si no hay una coincidencia clara,
SoundCloud. Si tampoco, pregunta a Deezer/iTunes por el titulo "oficial" y
vuelve a intentarlo con ese nombre.

Asi una cancion que falta o esta mal subida en una plataforma puede aparecer
en la otra.
"""
import json
import os
import re
import subprocess

import caratulas

AQUI = os.path.dirname(os.path.abspath(__file__))
YTDLP = os.path.expanduser("~/.local/bin/yt-dlp")
FUENTES = ("youtube", "soundcloud")

# Palabras que delatan una version distinta de la pedida.
EXTRAS = ("acustico", "en vivo", "live", "cover", "karaoke", "instrumental",
          "letra", "lyric", "sped up", "reverb", "8d", "remix", "version",
          "tutorial", "reaccion", "reaction", "1 hour", "hour version")


def _exe():
    return YTDLP if os.access(YTDLP, os.X_OK) else "yt-dlp"


# ---------------------------------------------------------------- busqueda
def buscar_candidatos(fuente, consulta, n=6):
    """Busca en la fuente y devuelve candidatos normalizados."""
    prefijo = "ytsearch" if fuente == "youtube" else "scsearch"
    try:
        p = subprocess.run([_exe(), "--flat-playlist", "-J",
                            f"{prefijo}{n}:{consulta}", "--no-warnings"],
                           capture_output=True, text=True, timeout=180)
    except (subprocess.SubprocessError, OSError):
        return []
    try:
        datos = json.loads(p.stdout)
    except ValueError:
        return []

    salida = []
    for e in datos.get("entries") or []:
        if not e or not e.get("id"):
            continue
        if fuente == "youtube":
            url = f"https://www.youtube.com/watch?v={e['id']}"
            artista = e.get("channel") or e.get("uploader") or ""
        else:
            url = e.get("url") or e.get("webpage_url") or ""
            artista = e.get("uploader") or e.get("channel") or ""
            if not url.startswith("http"):
                continue
        salida.append({
            "fuente": fuente,
            "id": str(e["id"]),
            "url": url,
            "titulo": e.get("title") or "",
            "artista": artista,
            "dur": e.get("duration") or 0,
        })
    return salida


def _puntuar(candidatos, titulo, artista, dur, fuente):
    t_limpio = caratulas.norm(caratulas.limpiar_consulta(titulo))
    t_bruto = caratulas.norm(titulo)
    artistas = caratulas.trocear_artistas(artista)
    mejor, mejor_p, mejor_st, mejor_dd = None, -1e9, 0.0, None

    for c in candidatos:
        cd = c.get("dur") or 0
        # descartar directos, albumes completos y "1 hour version"
        if dur and cd:
            if cd > dur * 2.5 and cd - dur > 90:
                continue
            if cd < dur * 0.4 and dur - cd > 45:
                continue
        elif not dur and cd > 60 * 20:
            continue

        ct_bruto = caratulas.norm(c["titulo"])
        ct_limpio = caratulas.norm(caratulas.limpiar_consulta(c["titulo"]))
        st = max(caratulas.similitud(ct_limpio, t_limpio),
                 caratulas.similitud(ct_bruto, t_bruto),
                 caratulas.similitud(ct_bruto, t_limpio))
        sa = max([caratulas.similitud(caratulas.norm(c["artista"]), a)
                  for a in artistas] or [0.0])
        dd = abs(cd - dur) if (cd and dur) else None

        p = 3.0 * st + 1.6 * sa
        if dd is not None:
            p += 2.0 * (1.0 if dd <= 2 else .8 if dd <= 5 else .55 if dd <= 10
                        else .15 if dd <= 20 else 0.0)
        canal = caratulas.norm(c["artista"] + " " + c["titulo"])
        if fuente == "youtube" and (c["artista"].lower().endswith("topic")
                                    or "vevo" in canal):
            p += 0.8
        if fuente == "soundcloud" and artistas:
            if any(a in caratulas.norm(c["artista"]) for a in artistas):
                p += 0.5
        for w in EXTRAS:
            wn = caratulas.norm(w)
            if wn in ct_bruto and wn not in t_bruto:
                p -= 0.9
        if p > mejor_p:
            mejor, mejor_p, mejor_st, mejor_dd = c, p, st, dd

    if mejor is None:
        return None, False
    seguro = mejor_st >= 0.62 and (
        mejor_dd is None or mejor_dd <= 12 or mejor_st >= 0.92)
    return mejor, seguro


# ---------------------------------------------------------------- canonico
def canonizar(pista):
    """Pregunta a Deezer por la version "oficial" de la pista.

    Devuelve una pista con titulo/artista/album/portada normalizados o None.
    """
    titulo = pista.get("titulo") or ""
    artista = pista.get("artista") or ""
    dur = pista.get("dur") or 0
    consulta = f"{artista} {caratulas.limpiar_consulta(titulo)}".strip()
    try:
        cands = caratulas.buscar_deezer(consulta)
    except Exception:
        return None
    if not cands:
        return None
    mejor, seguro = caratulas.elegir(cands, titulo, artista, dur)
    if not mejor or not seguro:
        return None
    return {"titulo": mejor["titulo"], "artista": mejor["artista"],
            "album": mejor.get("album") or "", "dur": mejor.get("dur") or 0,
            "portada": mejor.get("portada") or ""}


def consultas(pista):
    titulo = pista.get("titulo") or ""
    artista = pista.get("artista") or ""
    salida = []
    if artista:
        salida.append(f"{artista} {caratulas.limpiar_consulta(titulo)}".strip())
    salida.append(caratulas.limpiar_consulta(titulo) or titulo)
    vistas, final = set(), []
    for q in salida:
        q = " ".join(q.split())
        if q and q not in vistas:
            vistas.add(q)
            final.append(q)
    return final


def buscar_audio(pista, fuentes=FUENTES):
    """Devuelve el mejor candidato descargable o None.

    Orden: YouTube -> SoundCloud; si nada convence, reintenta con el titulo
    canonico que da Deezer.
    """
    titulo = pista.get("titulo") or ""
    artista = pista.get("artista") or ""
    dur = pista.get("dur") or 0

    for fuente in fuentes:
        for consulta in consultas(pista):
            cands = buscar_candidatos(fuente, consulta)
            if not cands:
                continue
            mejor, seguro = _puntuar(cands, titulo, artista, dur, fuente)
            if mejor and seguro:
                return mejor

    canon = canonizar(pista)
    if canon and (caratulas.norm(canon["titulo"]) != caratulas.norm(titulo)
                  or caratulas.norm(canon["artista"]) != caratulas.norm(artista)):
        for fuente in fuentes:
            consulta = f"{canon['artista']} {canon['titulo']}".strip()
            cands = buscar_candidatos(fuente, consulta)
            if not cands:
                continue
            mejor, seguro = _puntuar(cands, canon["titulo"], canon["artista"],
                                     canon["dur"] or dur, fuente)
            if mejor and seguro:
                mejor["canonico"] = canon
                return mejor

    # ultimo recurso: la mejor coincidencia aunque no sea perfecta
    for fuente in fuentes:
        consulta = consultas(pista)[0]
        cands = buscar_candidatos(fuente, consulta, n=10)
        if not cands:
            continue
        mejor, _ = _puntuar(cands, titulo, artista, dur, fuente)
        if mejor:
            mejor["dudoso"] = True
            return mejor
    return None


# ---------------------------------------------------------------- descarga
def descargar(candidato, destino, bitrate="320"):
    """Descarga el candidato en MP3. Devuelve (ok, mensaje)."""
    args = [_exe(), "-x", "--audio-format", "mp3",
            "--audio-quality", f"{bitrate}K", "--no-overwrites",
            "--no-warnings", "--newline", "--retries", "3",
            "--socket-timeout", "30", "-o", destino, candidato["url"]]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return False, "la descarga tardo demasiado"
    except (subprocess.SubprocessError, OSError) as e:
        return False, str(e)
    if p.returncode != 0:
        lineas = (p.stderr or "").strip().splitlines()
        return False, lineas[-1] if lineas else f"codigo {p.returncode}"
    return os.path.isfile(destino), "" if os.path.isfile(destino) else "no se creo el archivo"


# ---------------------------------------------------------------- prueba
if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        sys.exit("Uso: busqueda.py 'Artista - Titulo' [duracion]")
    texto = sys.argv[1]
    artista, titulo = (texto.split(" - ", 1) if " - " in texto else ("", texto))
    pista = {"titulo": titulo.strip(), "artista": artista.strip(),
             "dur": float(sys.argv[2]) if len(sys.argv) > 2 else 0}
    c = buscar_audio(pista)
    if not c:
        sys.exit("sin resultados")
    print(f"{c['fuente']}: {c['artista']} - {c['titulo']} ({c['dur']}s)")
    print(c["url"])
