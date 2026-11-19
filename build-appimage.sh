#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/rizzy/Documents/RookieIDE/RookieIDE"
WORK_DIR="/tmp/appimage-work"
APPDIR="${WORK_DIR}/AppDir"

cd "${PROJECT_DIR}"
sudo chown -R "$USER":"$USER" _build 2>/dev/null || true

ninja -C _build
sudo meson install -C _build --no-rebuild

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/local/share/icons/hicolor/scalable/apps"
mkdir -p "${APPDIR}/usr/local/share/metainfo"
DESTDIR="${APPDIR}" meson install -C _build --no-rebuild

cat << 'EOF' > "${APPDIR}/AppRun"
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="${HERE}/usr/local/bin:${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/local/lib:${HERE}/usr/lib:${HERE}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="${HERE}/usr/local/share:${HERE}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GSETTINGS_SCHEMA_DIR="${HERE}/usr/local/share/glib-2.0/schemas:${HERE}/usr/share/glib-2.0/schemas"
exec rookieide "$@"
EOF
chmod +x "${APPDIR}/AppRun"

cat << 'EOF' > "${APPDIR}/io.github.rookieide.App.desktop"
[Desktop Entry]
Name=RookieIDE
Comment=Lightweight GTK4 and Libadwaita code editor and IDE
Exec=rookieide %F
Icon=io.github.rookieide.App
Terminal=false
Type=Application
Categories=Development;IDE;
StartupNotify=true
StartupWMClass=io.github.rookieide.App
EOF

if [ -f "${PROJECT_DIR}/data/io.github.rookieide.App.metainfo.xml" ]; then
    cp "${PROJECT_DIR}/data/io.github.rookieide.App.metainfo.xml" "${APPDIR}/usr/local/share/metainfo/"
fi

ICON_SRC=""
for candidate in \
    "${PROJECT_DIR}/data/icons/hicolor/scalable/apps/io.github.rookieide.App.svg" \
    "/usr/local/share/icons/hicolor/scalable/apps/io.github.rookieide.App.svg" \
    "/usr/local/share/icons/hicolor/scalable/apps/org.gnome.RookieIDE.svg"
do
    if [ -f "$candidate" ]; then
        ICON_SRC="$candidate"
        break
    fi
done

if [ -n "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${APPDIR}/io.github.rookieide.App.svg"
    cp "$ICON_SRC" "${APPDIR}/usr/local/share/icons/hicolor/scalable/apps/io.github.rookieide.App.svg"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w 256 -h 256 "$ICON_SRC" -o "${APPDIR}/io.github.rookieide.App.png"
    fi
fi

gtk4-update-icon-cache -q -t -f "${APPDIR}/usr/local/share/icons/hicolor" 2>/dev/null || true

cd "${WORK_DIR}"
ARCH=x86_64 ./appimagetool AppDir RookieIDE-x86_64.AppImage || ARCH=x86_64 ./appimagetool --appimage-extract-and-run AppDir RookieIDE-x86_64.AppImage
chmod +x "${WORK_DIR}/RookieIDE-x86_64.AppImage"
echo "Done: ${WORK_DIR}/RookieIDE-x86_64.AppImage"
