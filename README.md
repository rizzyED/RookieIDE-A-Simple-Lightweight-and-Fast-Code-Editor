# RookieIDE

**RookieIDE** (`org.gnome.RookieIDE`) is a lightweight, fast, and clean code editor designed for Linux desktops. Built natively with Vala, GTK4, and Libadwaita, it focuses on speed, low memory usage, and an intuitive, distraction-free workflow.

## ✨ Key Features

- **Native & Lightweight:** Built with GTK4, Libadwaita, and GtkSourceView 5 for snappy startup times and minimal RAM footprint.
- **Clean Workspace:** Responsive layout featuring a collapsible file manager sidebar and syntax-highlighted editor.
- **Integrated Bottom Panel:** Built-in Status, Compiler output, and VTE Terminal tabs so you can write, build, and run code in one window.
- **Smart Templates & Sessions:** Multi-language file templates with auto-generated headers, persistent sessions, and inline compile-error highlighting.
- **Custom Themes:** Clean, modern color schemes inspired by popular dark and VS Code-style palettes.
- **Portable Packaging:** Designed to build cleanly via Meson and package as a standalone Flatpak or AppImage.

## 🛠️ Tech Stack

- **Language:** Vala
- **UI Toolkit:** GTK4 & Libadwaita
- **Editor & Terminal:** GtkSourceView 5 & VTE
- **Build System:** Meson & Ninja

## 🚀 Building from Source

```bash
meson setup _build
ninja -C _build
./_build/src/rookieide
```

## 🚀 Installation

### 1. Clone the Repository
Clone the project from GitHub and enter the project directory:

```bash
git clone [https://github.com/rizzyED/RookieIDE-A-Simple-Lightweight-and-Fast-Code-Editor.git](https://github.com/rizzyED/RookieIDE-A-Simple-Lightweight-and-Fast-Code-Editor.git)
cd RookieIDE-A-Simple-Lightweight-and-Fast-Code-Editor
```
### 2. Configure and Build with Meson
Set up a build directory (_build) and compile the project using ninja:
```bash
meson setup _build
ninja -C _build
```
### 3. Run or Install System-Wide
Run directly from the build directory to test:
```bash
./_build/src/rookieide
```
Or install it onto your system:
```bash
sudo ninja -C _build install
```
Also available with AppImage. Windows Platform port? maybe next month lol
