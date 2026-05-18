#!/usr/bin/env bash
# ==============================================================================
# limpiar_correo.sh
# Desinstalador Completo: Servidor de Correo de Laboratorio
# Elimina Postfix, Dovecot, sus configuraciones y reglas de firewall
#
# Uso: sudo bash limpiar_correo.sh
# ==============================================================================

set -uo pipefail
# Nota: No usamos -e (exit on error) aquí, porque varios comandos de limpieza
# pueden devolver códigos de error si el recurso ya no existe, y eso es normal.

IFS=$'\n\t'

# ── Colores ANSI ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Funciones de salida con formato ───────────────────────────────────────────
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "\n${BOLD}${BLUE}━━━  $*${NC}"; }

# ── Verificación: debe ejecutarse como root ────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR ]${NC}  Este script debe ejecutarse como root." >&2
    echo -e "       Usa: sudo bash $0" >&2
    exit 1
fi

# ── Banner ─────────────────────────────────────────────────────────────────────
echo -e "${RED}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║      DESINSTALADOR: SERVIDOR DE CORREO — LABORATORIO       ║
  ║                                                            ║
  ║   Eliminará: Postfix, Dovecot, configuraciones y UFW       ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Confirmación previa ────────────────────────────────────────────────────────
echo -e "${YELLOW}${BOLD}ADVERTENCIA:${NC} Este script realizará las siguientes acciones:"
echo -e "  • Detendrá y deshabilitará los servicios postfix y dovecot"
echo -e "  • Ejecutará ${RED}apt purge${NC} de postfix, dovecot-imapd y dovecot-core"
echo -e "  • Eliminará los directorios ${RED}/etc/postfix${NC} y ${RED}/etc/dovecot${NC}"
echo -e "  • Removerá las reglas de UFW para los puertos 25/tcp y 143/tcp"
echo -e "  • Opcionalmente eliminará los usuarios de correo creados"
echo ""
echo -e "${CYAN}Nota: Samba (puerto 445) y otros servicios NO serán afectados.${NC}"
echo ""

read -r -p "¿Estás seguro de que deseas continuar con la desinstalación? [s/N]: " confirm
if ! [[ "$confirm" =~ ^[sS]$ ]]; then
    echo -e "\n${CYAN}Operación cancelada. No se realizó ningún cambio.${NC}"
    exit 0
fi
echo ""

# ── PASO 1: Detener servicios ──────────────────────────────────────────────────
step "PASO 1/5 — Deteniendo servicios"

if systemctl is-active --quiet postfix 2>/dev/null; then
    info "Deteniendo Postfix..."
    systemctl stop postfix && ok "Postfix detenido." || warn "No se pudo detener Postfix."
else
    warn "Postfix no estaba activo (omitido)."
fi

if systemctl is-active --quiet dovecot 2>/dev/null; then
    info "Deteniendo Dovecot..."
    systemctl stop dovecot && ok "Dovecot detenido." || warn "No se pudo detener Dovecot."
else
    warn "Dovecot no estaba activo (omitido)."
fi

# Deshabilitar arranque automático
systemctl disable postfix --quiet 2>/dev/null && ok "Postfix deshabilitado del arranque." || \
    warn "Postfix ya estaba deshabilitado o no existe."
systemctl disable dovecot --quiet 2>/dev/null && ok "Dovecot deshabilitado del arranque." || \
    warn "Dovecot ya estaba deshabilitado o no existe."

# ── PASO 2: Purgar paquetes ────────────────────────────────────────────────────
step "PASO 2/5 — Eliminando paquetes"

info "Ejecutando apt purge (elimina paquetes y sus archivos de configuración)..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y --autoremove \
    postfix \
    dovecot-imapd \
    dovecot-core \
    2>/dev/null && ok "Paquetes eliminados correctamente." || \
    warn "Algunos paquetes no pudieron eliminarse (puede que ya no estuvieran instalados)."

# ── PASO 3: Eliminar archivos de configuración residuales ─────────────────────
step "PASO 3/5 — Eliminando configuraciones residuales"

if [[ -d /etc/postfix ]]; then
    rm -rf /etc/postfix
    ok "Directorio /etc/postfix eliminado."
else
    warn "/etc/postfix no existe (ya fue eliminado por apt purge)."
fi

if [[ -d /etc/dovecot ]]; then
    rm -rf /etc/dovecot
    ok "Directorio /etc/dovecot eliminado."
else
    warn "/etc/dovecot no existe (ya fue eliminado por apt purge)."
fi

# Limpiar mailname si fue configurado por el instalador
if [[ -f /etc/mailname ]]; then
    local_mailname=$(cat /etc/mailname 2>/dev/null || echo "")
    if [[ "$local_mailname" == "mail.lab.local" ]]; then
        rm -f /etc/mailname
        ok "Archivo /etc/mailname eliminado."
    fi
fi

# ── PASO 4: Remover reglas del Firewall (UFW) ──────────────────────────────────
step "PASO 4/5 — Removiendo reglas del Firewall (UFW)"

if command -v ufw &>/dev/null; then
    ufw delete allow 25/tcp 2>/dev/null && \
        ok "Regla UFW eliminada: 25/tcp (SMTP)" || \
        warn "La regla para el puerto 25/tcp no existía en UFW."

    ufw delete allow 143/tcp 2>/dev/null && \
        ok "Regla UFW eliminada: 143/tcp (IMAP)" || \
        warn "La regla para el puerto 143/tcp no existía en UFW."
else
    warn "UFW no está instalado. No hay reglas que limpiar."
fi

# ── PASO 5: Eliminar usuarios de correo (interactivo) ─────────────────────────
step "PASO 5/5 — Eliminar usuarios de correo del sistema"

echo -e "${YELLOW}¿Deseas eliminar las cuentas de usuario Linux creadas para el correo?${NC}"
echo -e "${RED}${BOLD}ADVERTENCIA:${NC}${RED} Esto eliminará también el directorio home del usuario${NC}"
echo -e "${RED}y todos sus correos almacenados en ~/Maildir/. Esta acción es irreversible.${NC}"
echo ""
read -r -p "¿Proceder con la eliminación de usuarios? [s/N]: " del_users

if [[ "$del_users" =~ ^[sS]$ ]]; then
    echo ""
    info "Ingresa los usuarios a eliminar. Deja vacío y presiona Enter para terminar."
    echo ""

    while true; do
        local del_user=""
        read -r -p "  Nombre del usuario a eliminar (Enter vacío = terminar): " del_user || break

        if [[ -z "$del_user" ]]; then
            break
        fi

        if id "$del_user" &>/dev/null; then
            local confirm_del="n"
            read -r -p "  ¿Confirmas eliminar '${del_user}' y su directorio /home/${del_user}/? [s/N]: " confirm_del || true

            if [[ "$confirm_del" =~ ^[sS]$ ]]; then
                userdel -r "$del_user" 2>/dev/null && \
                    ok "  Usuario '${del_user}' eliminado (home y correos borrados)." || \
                    warn "  No se pudo eliminar completamente a '${del_user}'."
            else
                info "  Usuario '${del_user}' conservado."
            fi
        else
            warn "  El usuario '${del_user}' no existe en el sistema."
        fi
    done
else
    info "Los usuarios del sistema no fueron modificados."
fi

# ── Resumen final ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  ✓  DESINSTALACIÓN COMPLETADA${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
ok "Postfix y Dovecot han sido eliminados del sistema."
info "Los puertos 25/tcp y 143/tcp han sido cerrados en UFW."
info "Samba (puerto 445) y otros servicios no fueron afectados."
echo ""
info "Para reinstalar el servidor de correo, ejecuta:"
echo -e "  ${YELLOW}sudo bash setup_correo.sh${NC}"
echo ""
