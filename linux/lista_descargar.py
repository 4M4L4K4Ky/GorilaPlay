#!/usr/bin/env python3
# GorilaPlay - descarga una lista de cualquier plataforma compatible.
"""Descarga una lista de musica buscando el audio en YouTube y SoundCloud.

La entrada puede ser:
  - Un enlace de Spotify, Deezer, Amazon Music, YouTube, YouTube Music,
    SoundCloud o Mixcloud.
  - La ruta de un archivo .txt con una cancion por linea ("Artista - Titulo"),
    util para Nonoki o cualquier lista copiada a mano.

Cada pista se busca primero en YouTube; si no hay una coincidencia clara se
prueba SoundCloud y, como ultimo recurso, se reintenta con el titulo canonico
que da Deezer. El archivo se queda etiquetado y con caratula.

Uso:
    lista_descargar.py <enlace o .txt> <carpeta> [kbps] [opciones]

Opciones:
    --limit N        descarga solo las primeras N pistas
    --desde N        empieza por la pista N (para reanudar)
    --fuente A,B     fuentes de audio en orden (youtube,soundcloud)
    --sin-caratula   no busca ni incrusta portada
    --nombre NOMBRE  nombre de la carpeta (por defecto, el de la lista)
    --solo-probar    muestra que encontraria sin descargar nada
"""
import argparse
import os
import re
import sys

import busqueda
import caratulas
import fuentes

MALO = re.compile(r'[/\\:*?"<>|]')


def limpiar_nombre(texto, limite=150):
    nombre = MALO.sub("_", texto or "").strip(" .")
    nombre = re.sub(r"\s{2,}", " ", nombre)
    return nombre[:limite] or "sin titulo"


def main():
    ap = argparse.ArgumentParser(
        description="Descarga una lista de musica de cualquier plataforma.")
    ap.add_argument("entrada", help="enlace de la lista o archivo .txt")
    ap.add_argument("carpeta", help="carpeta donde guardar")
    ap.add_argument("kbps", nargs="?", default="320", help="calidad MP3 (320)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--desde", type=int, default=1)
    ap.add_argument("--fuente", default="youtube,soundcloud")
    ap.add_argument("--nombre", default="")
    ap.add_argument("--sin-caratula", action="store_true")
    ap.add_argument("--solo-probar", action="store_true")
    a = ap.parse_args()

    fuentes_audio = tuple(f.strip() for f in a.fuente.split(",")
                          if f.strip() in busqueda.FUENTES) or busqueda.FUENTES

    try:
        info = fuentes.obtener_pistas(a.entrada)
    except fuentes.ErrorLista as e:
        print(f"Error: {e}")
        sys.exit(2)

    pistas = info["pistas"]
    if a.limit:
        pistas = pistas[:a.limit]
    inicio = max(1, a.desde)
    pistas = pistas[inicio - 1:]
    if not pistas:
        print("No hay pistas que descargar.")
        sys.exit(2)

    plataforma = fuentes.PLATAFORMAS.get(info["plataforma"], info["plataforma"])
    base = os.path.expanduser(a.carpeta)
    nombre_lista = a.nombre.strip() or info["nombre"]
    carpeta = os.path.join(base, limpiar_nombre(nombre_lista, 120))
    os.makedirs(carpeta, exist_ok=True)

    print(f"{plataforma}: {nombre_lista}  ({len(pistas)} pistas)")
    print(f"Fuentes de audio: {' > '.join(fuentes_audio)}")
    print(f"Destino: {carpeta}\n")

    ok, saltadas, fallos = 0, 0, []
    for i, pista in enumerate(pistas, inicio):
        titulo = (pista.get("titulo") or "").strip()
        artista = (pista.get("artista") or "").strip()
        etiqueta = f"{artista} - {titulo}" if artista else titulo
        archivo = os.path.join(carpeta, limpiar_nombre(
            f"{artista} - {titulo}" if artista else titulo) + ".mp3")
        print(f"[{i}/{inicio + len(pistas) - 1}] {etiqueta}")

        if os.path.exists(archivo):
            print("   ya existe, se omite")
            saltadas += 1
            continue

        candidato = busqueda.buscar_audio(pista, fuentes_audio)
        if not candidato:
            print("   sin resultados en ninguna fuente")
            fallos.append(etiqueta)
            continue

        origen = candidato["fuente"].capitalize()
        if candidato.get("dudoso"):
            origen += " (poco fiable)"
        print(f"   {origen}: {candidato['titulo']}" +
              (f" [{candidato['dur']}s]" if candidato.get("dur") else ""))

        if a.solo_probar:
            ok += 1
            continue

        bien, error = busqueda.descargar(candidato, archivo, a.kbps)
        if not bien:
            print(f"   error al descargar: {error}")
            fallos.append(etiqueta)
            continue

        artista_final = artista or candidato.get("artista") or ""
        if not a.sin_caratula:
            try:
                estado, detalle = caratulas.poner(
                    archivo, titulo=titulo, artista=artista_final,
                    album=nombre_lista, dur=pista.get("dur") or 0,
                    reemplazar=True, portada_respaldo=info.get("portada"))
                print("   ok" + (f"  ·  caratula: {detalle}" if estado == "ok"
                                 else "  ·  sin caratula"))
            except Exception as e:
                print(f"   ok  ·  caratula fallida: {str(e)[:90]}")
        else:
            print("   ok")
        ok += 1

    print()
    if a.solo_probar:
        print(f"Simulacion: {ok} se descargarian, {saltadas} ya estan, "
              f"{len(fallos)} sin resultados.")
    else:
        print(f"Terminado: {ok} descargadas, {saltadas} ya estaban, "
              f"{len(fallos)} fallidas.")
    if fallos:
        print("Fallidas: " + ", ".join(fallos[:10]) +
              ("..." if len(fallos) > 10 else ""))
        sys.exit(1)


if __name__ == "__main__":
    main()
