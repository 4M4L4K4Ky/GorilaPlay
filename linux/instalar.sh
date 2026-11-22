#!/usr/bin/env bash
# GorilaPlay - instalador para Linux (escritorio KDE/GNOME)
set -eu

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$ORIGEN")"
BIN="$HOME/.local/bin"
DATOS="$HOME/.local/share/gorilaplay"
ICONOS="$HOME/.local/share/icons/hicolor"
APPS="$HOME/.local/share/applications"

echo "Instalando GorilaPlay..."

mkdir -p "$BIN" "$DATOS" "$APPS" "$ICONOS/512x512/apps" "$ICONOS/256x256/apps"

install -m 755 "$ORIGEN/descargar-playlist" "$BIN/descargar-playlist"
install -m 755 "$ORIGEN/spotify_descargar.py" "$DATOS/spotify_descargar.py"
install -m 755 "$ORIGEN/caratulas.py" "$DATOS/caratulas.py"
install -m 755 "$ORIGEN/caratulas.py" "$BIN/gorilaplay-caratulas"

if [ -f "$RAIZ/assets/icono-512.png" ]; then
    install -m 644 "$RAIZ/assets/icono-512.png" "$ICONOS/512x512/apps/gorilaplay.png"
    install -m 644 "$RAIZ/assets/icono-256.png" "$ICONOS/256x256/apps/gorilaplay.png"
    gtk-update-icon-cache -f -t "$ICONOS" >/dev/null 2>&1 || true
fi

cat > "$APPS/gorilaplay.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GorilaPlay
Comment=Descarga playlists de YouTube y Spotify
Exec=$BIN/descargar-playlist
Icon=gorilaplay
Terminal=false
Categories=AudioVideo;Audio;Network;
Keywords=yt-dlp;youtube;spotify;playlist;mp3;musica;
StartupNotify=true
EOF

chmod +x "$APPS/gorilaplay.desktop"
update-desktop-database "$APPS" >/dev/null 2>&1 || true

echo
echo "Listo. Busca 'GorilaPlay' en el menú de aplicaciones."
echo
echo "Dependencias que deben estar instaladas:"
echo "  yt-dlp   ->  pipx install yt-dlp   (o pip install --user yt-dlp)"
echo "  ffmpeg   ->  sudo dnf install ffmpeg  (o apt install ffmpeg)"
echo "  mutagen  ->  sudo dnf install python3-mutagen  (o pip install --user mutagen)"
echo "  python3, kdialog, konsole"
