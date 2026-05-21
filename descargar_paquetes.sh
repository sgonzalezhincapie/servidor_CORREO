#!/usr/bin/env bash
# ==============================================================================
# descargar_paquetes.sh
# Descarga de Paquetes para Instalación Offline — Servidor de Correo
#
# Uso       : sudo bash descargar_paquetes.sh
# Requisito : Ejecutar UNA VEZ con conexión a internet.
#
# DESCRIPCIÓN:
#   Descarga todos los paquetes .deb (con sus dependencias transitivas)
#   necesarios para setup_correo.sh, en la carpeta:
#
#     paquetes/correo/   → postfix, dovecot-imapd
#
#   Una vez descargados, setup_correo.sh los detecta automáticamente
#   y los instala con dpkg sin necesitar internet.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}━━━  $*${NC}"; }

if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root.\n  Usa: sudo bash $0"
fi

# Verificar conexión a internet
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
    error "No hay conexión a internet.\nEjecuta este script en una máquina con acceso a internet."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║   DESCARGA DE PAQUETES OFFLINE — SERVIDOR DE CORREO        ║
  ║                                                            ║
  ║   Postfix  +  Dovecot (+ dependencias transitivas)         ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Actualizar índice ──────────────────────────────────────────────────────────
step "Actualizando índice de paquetes"
apt-get update -qq
ok "Índice actualizado."

# ── Función: descargar paquetes apt con dependencias transitivas ───────────────
# Usa apt-cache depends --recurse para obtener el árbol completo de dependencias
# y apt-get download para guardar cada .deb en el directorio indicado.
descargar_apt() {
    local DESTINO="$1"
    shift
    local PAQUETES=("$@")

    mkdir -p "$DESTINO"

    info "Resolviendo dependencias de: ${PAQUETES[*]}"
    local LISTA
    LISTA=$(apt-cache depends --recurse \
        --no-recommends --no-suggests \
        --no-conflicts --no-breaks \
        --no-replaces --no-enhances \
        "${PAQUETES[@]}" 2>/dev/null \
        | grep "^\w" | sort -u)

    if [[ -z "$LISTA" ]]; then
        error "No se pudieron resolver las dependencias. Verifica los nombres de los paquetes."
    fi

    local TOTAL
    TOTAL=$(echo "$LISTA" | wc -l)
    info "Total de paquetes a descargar (incluye dependencias): ${TOTAL}"
    echo ""

    local DESCARGADOS=0
    local OMITIDOS=0

    pushd "$DESTINO" > /dev/null

    while IFS= read -r PKG; do
        [[ -z "$PKG" ]] && continue
        if ls "${PKG}_"*.deb &>/dev/null 2>&1; then
            (( OMITIDOS++ )) || true
            continue
        fi
        if apt-get download "$PKG" &>/dev/null 2>&1; then
            (( DESCARGADOS++ )) || true
        else
            warn "No se pudo descargar: $PKG (puede ser virtual o de arquitectura diferente)"
        fi
    done <<< "$LISTA"

    popd > /dev/null

    ok "Descargados: ${DESCARGADOS} | Ya existían: ${OMITIDOS}"
    local NUM_DEBS
    NUM_DEBS=$(ls "$DESTINO"/*.deb 2>/dev/null | wc -l)
    ok "Total .deb en ${DESTINO}: ${NUM_DEBS}"
}

# ── Descargar paquetes del servidor de correo ──────────────────────────────────
step "Descargando paquetes: postfix, dovecot-imapd (+ dependencias)"
DEST="${SCRIPT_DIR}/paquetes/correo"
descargar_apt "$DEST" postfix dovecot-imapd
echo ""
info "Guardados en: ${DEST}/"

# ── Resumen ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Descarga completada.                                       ║${NC}"
echo -e "${GREEN}${BOLD}║                                                             ║${NC}"
echo -e "${GREEN}${BOLD}║  setup_correo.sh detectará automáticamente estos paquetes   ║${NC}"
echo -e "${GREEN}${BOLD}║  e instalará Postfix y Dovecot sin necesitar internet.      ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Estructura generada:"
echo "    paquetes/"
echo "    └── correo/   → para setup_correo.sh"
echo ""
