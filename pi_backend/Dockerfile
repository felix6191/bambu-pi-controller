FROM ubuntu:24.04

# Ubuntu 24.04 ist Absicht: Nur damit läuft das offizielle OrcaSlicer-ARM64-
# AppImage (benötigt neueres glibc) direkt im Container mit — kein Slicer
# mehr separat am Pi installieren.
ARG TARGETARCH=arm64
ARG ORCA_VERSION=2.4.2

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# System-Python + Laufzeitbibliotheken für OrcaSlicer (headless).
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip curl ca-certificates \
        libgl1 libglib2.0-0 libnss3 libx11-6 libx11-xcb1 libxcb1 libxext6 \
        libxrender1 libxtst6 libxi6 libasound2t64 libfontconfig1 libdbus-1-3 \
        libsm6 libice6 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 \
        libxcursor1 libgtk-3-0t64 libwebkit2gtk-4.1-0 xdg-utils \
        libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 \
        libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 \
        libxcb-xinerama0 libxcb-xkb1 libegl1 libopengl0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml .
COPY app ./app
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install .
ENV PATH="/opt/venv/bin:${PATH}"

# OrcaSlicer passend zur Architektur herunterladen und entpacken.
# AppImage braucht kein FUSE: einmal mit --appimage-extract auspacken.
RUN set -eux; \
    case "${TARGETARCH}" in \
        arm64) url="https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${ORCA_VERSION}/OrcaSlicer_Linux_AppImage_Ubuntu2404_aarch64_V${ORCA_VERSION}.AppImage" ;; \
        amd64) url="https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${ORCA_VERSION}/OrcaSlicer_Linux_AppImage_Ubuntu2404_V${ORCA_VERSION}.AppImage" ;; \
        *) url="" ;; \
    esac; \
    if [ -n "$url" ]; then \
        curl -fsSL "$url" -o /tmp/orca.AppImage; \
        chmod +x /tmp/orca.AppImage; \
        /tmp/orca.AppImage --appimage-extract >/dev/null; \
        mv squashfs-root /opt/orcaslicer; \
        rm -f /tmp/orca.AppImage; \
        ln -sf /opt/orcaslicer/AppRun /usr/local/bin/orcaslicer; \
    fi

# /data muss dem Container-User gehören — sonst kann er pairing.json/jobs
# nicht schreiben und die App bekommt HTTP 500 (genau der Pairing-Fehler).
# Keine feste UID 1000: Im Ubuntu-24.04-Image belegt der User "ubuntu" bereits
# UID 1000, sonst bricht useradd mit "UID 1000 is not unique" ab.
RUN useradd -m -s /bin/bash appuser \
    && mkdir -p /data /home/appuser/.config \
    && chown -R appuser:appuser /app /data /home/appuser
USER appuser
ENV HOME=/home/appuser

ENV SLICER_MODE=orca \
    SLICER_CMD=orcaslicer \
    ORCA_PROFILES=/opt/orcaslicer/resources/profiles/BBL \
    QT_QPA_PLATFORM=offscreen

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD curl -f http://localhost:8000/health || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
