#!/bin/bash
# GorilaPlay - instalador para macOS.
# Instala el motor de Linux/macOS en ~/.local, crea los comandos de terminal
# y una aplicación GorilaPlay.app en ~/Applications.
set -eu

ORIGEN="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(dirname "$ORIGEN")"
MOTOR="$RAIZ/linux"
BIN="$HOME/.local/bin"
DATOS="$HOME/.local/share/gorilaplay"
ESTADO="$HOME/.local/state/gorilaplay"
APPS="$HOME/Applications"
APP="$APPS/GorilaPlay.app"
VERSION="1.2.1"

export PATH="/opt/homebrew/bin:/usr/local/bin:$BIN:$PATH"

echo "GorilaPlay - instalador para macOS"
echo

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Este instalador es solo para macOS."
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    cat <<'MSG'
Falta Homebrew, que se usa para instalar Python y FFmpeg.

Instálalo desde https://brew.sh y vuelve a ejecutar este script:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

MSG
    exit 1
fi

FALTAN=()
command -v python3 >/dev/null 2>&1 || FALTAN+=("python")
command -v ffmpeg >/dev/null 2>&1 || FALTAN+=("ffmpeg")

if [ "${#FALTAN[@]}" -gt 0 ]; then
    echo "Homebrew va a instalar: ${FALTAN[*]}"
    printf '¿Continuar? [s/N] '
    read -r RESPUESTA || exit 1
    case "$RESPUESTA" in
        s|S|si|sí|y|Y) brew install "${FALTAN[@]}" ;;
        *) echo "Instalación cancelada."; exit 1 ;;
    esac
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "No encuentro python3 después de la instalación."
    exit 1
fi

mkdir -p "$BIN" "$DATOS" "$ESTADO" "$APPS"

echo "Preparando las dependencias de Python..."
if [ ! -x "$DATOS/venv/bin/python" ]; then
    python3 -m venv "$DATOS/venv"
fi
"$DATOS/venv/bin/python" -m pip install --upgrade pip >/dev/null
"$DATOS/venv/bin/python" -m pip install --upgrade "yt-dlp[default,curl-cffi]" mutagen

ln -sf "$DATOS/venv/bin/yt-dlp" "$BIN/yt-dlp"

echo "Copiando GorilaPlay..."
for modulo in fuentes.py busqueda.py lista_descargar.py caratulas.py spotify_descargar.py; do
    install -m 755 "$MOTOR/$modulo" "$DATOS/$modulo"
done
install -m 755 "$ORIGEN/gorilaplay" "$BIN/gorilaplay"

cat > "$BIN/gorilaplay-lista" <<EOF
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$BIN:\$PATH"
exec "$DATOS/venv/bin/python" "$DATOS/lista_descargar.py" "\$@"
EOF
chmod +x "$BIN/gorilaplay-lista"

cat > "$BIN/gorilaplay-caratulas" <<EOF
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$BIN:\$PATH"
exec "$DATOS/venv/bin/python" "$DATOS/caratulas.py" "\$@"
EOF
chmod +x "$BIN/gorilaplay-caratulas"

# Aplicación para abrir desde Finder, Launchpad o el Dock.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>CFBundleDisplayName</key><string>GorilaPlay</string>
    <key>CFBundleExecutable</key><string>GorilaPlay</string>
    <key>CFBundleIconFile</key><string>GorilaPlay</string>
    <key>CFBundleIdentifier</key><string>com.gorilaplay.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>GorilaPlay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2.1</string>
    <key>CFBundleVersion</key><string>1.2.1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/GorilaPlay" <<EOF
#!/bin/bash
exec "$BIN/gorilaplay"
EOF
chmod +x "$APP/Contents/MacOS/GorilaPlay"

ICONO="$RAIZ/assets/icono-1024.png"
if [ -f "$ICONO" ] && command -v sips >/dev/null 2>&1 \
        && command -v iconutil >/dev/null 2>&1; then
    ICONSET="$DATOS/GorilaPlay.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for lado in 16 32 128 256 512; do
        sips -z "$lado" "$lado" "$ICONO" \
            --out "$ICONSET/icon_${lado}x${lado}.png" >/dev/null 2>&1 || true
        doble=$((lado * 2))
        sips -z "$doble" "$doble" "$ICONO" \
            --out "$ICONSET/icon_${lado}x${lado}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/GorilaPlay.icns" \
        >/dev/null 2>&1 || true
    rm -rf "$ICONSET"
fi

touch "$APP"

echo
echo "Listo. Abre GorilaPlay desde ~/Applications o desde Launchpad."
echo
echo "Comandos disponibles en $BIN:"
echo "  gorilaplay             interfaz con diálogos"
echo "  gorilaplay-lista       descargar una lista desde la terminal"
echo "  gorilaplay-caratulas   poner carátulas a una carpeta"
echo
echo "Si la terminal no encuentra 'gorilaplay', añade esto a ~/.zshrc:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo
if [ "$VERSION" != "$(sed -n 's/^VERSION=\"\(.*\)\"/\1/p' "$ORIGEN/gorilaplay")" ]; then
    echo "Aviso: la versión del instalador y la del lanzador no coinciden."
fi
