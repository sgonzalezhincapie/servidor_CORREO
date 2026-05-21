#!/usr/bin/env bash
# ==============================================================================
# setup_correo.sh
# Instalador Automático: Servidor de Correo de Laboratorio
# Postfix (MTA) + Dovecot IMAP (MDA) en Ubuntu Server 22.04 LTS
#
# ADVERTENCIA: Configuración sin SSL/TLS intencionalmente para redes de
# laboratorio controladas. NO usar en entornos de producción.
#
# Uso: sudo bash setup_correo.sh
# ==============================================================================

set -euo pipefail
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
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}━━━  $*${NC}"; }

# ── Banner de bienvenida ───────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║       INSTALADOR: SERVIDOR DE CORREO — LABORATORIO         ║
  ║                                                            ║
  ║   Postfix  (MTA — Agente de Transporte)  →  puerto 25      ║
  ║   Dovecot  (MDA — Agente de Entrega)     →  puerto 143     ║
  ║                                                            ║
  ║   Ubuntu Server 22.04 LTS  |  Maildir  |  Sin SSL/TLS      ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# ── Verificación: debe ejecutarse como root ────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script debe ejecutarse como root.\n  Usa: sudo bash $0"
    fi
    ok "Ejecutando como root."
}

# ── Verificación: Ubuntu 22.04 ─────────────────────────────────────────────────
check_ubuntu() {
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        local version
        version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        ok "Sistema operativo detectado: Ubuntu ${version}"
    else
        warn "Este script fue diseñado para Ubuntu 22.04. Proceder con precaución."
    fi
}

# ── Detección dinámica de subredes locales ────────────────────────────────────
# Obtiene TODAS las rutas de red directamente conectadas (excluye loopback y
# default gateway). Devuelve las subredes separadas por espacio.
# Ejemplo de resultado: "10.253.62.0/24 10.253.25.0/24"
#
# NOTA: En entornos universitarios o con múltiples VLANs, distintas subredes
# pueden conectarse al servidor a través del mismo router. Si los clientes
# provienen de subredes no directamente conectadas al servidor, agrégalas
# manualmente a mynetworks en /etc/postfix/main.cf después de la instalación:
#   sudo postconf -e "mynetworks = 127.0.0.0/8 10.253.0.0/16"
#   sudo systemctl reload postfix
detect_subnet() {
    local subnets
    subnets=$(ip route 2>/dev/null \
        | grep -v default \
        | grep -v 127 \
        | grep -E '^[0-9]+\.' \
        | awk '{print $1}' \
        | sort -u \
        | tr '\n' ' ' \
        | sed 's/ $//')

    if [[ -z "$subnets" ]]; then
        warn "No se pudo detectar ninguna subred local automáticamente."
        warn "mynetworks solo incluirá 127.0.0.0/8 (solo loopback)."
        warn "Los clientes de la red local no podrán enviar correo."
        warn "Puedes corregirlo después editando: /etc/postfix/main.cf"
        echo ""
    else
        echo "$subnets"
    fi
}

# ── Instalación silenciosa de paquetes ────────────────────────────────────────
# Usa debconf-set-selections para evitar ventanas emergentes de configuración.
# Si existe paquetes/correo/*.deb, instala en modo OFFLINE con dpkg.
# De lo contrario, descarga desde internet con apt-get.
install_packages() {
    step "PASO 1/6 — Instalando Postfix y Dovecot"

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local PAQUETES_DIR="${SCRIPT_DIR}/paquetes/correo"

    info "Preconfigurando respuestas de debconf (instalación silenciosa)..."
    debconf-set-selections << 'DEBCONF'
postfix postfix/mailname string mail.lab.local
postfix postfix/main_mailer_type select Internet Site
DEBCONF

    if ls "$PAQUETES_DIR"/*.deb &>/dev/null 2>&1; then
        local NUM_DEBS
        NUM_DEBS=$(ls "$PAQUETES_DIR"/*.deb | wc -l)
        info "Modo OFFLINE: usando ${NUM_DEBS} paquetes locales desde paquetes/correo/"
        DEBIAN_FRONTEND=noninteractive dpkg -i "$PAQUETES_DIR"/*.deb 2>&1 | tail -5 || true
    else
        info "Actualizando índice de paquetes..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq

        info "Instalando postfix y dovecot-imapd..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix dovecot-imapd
    fi

    ok "Paquetes instalados correctamente."
    info "Versiones instaladas:"
    postconf mail_version 2>/dev/null | sed 's/^/         Postfix: /' || true
    dovecot --version 2>/dev/null | head -n1 | sed 's/^/         Dovecot: /' || true
}

# ── Configuración de Postfix (/etc/postfix/main.cf) ──────────────────────────
configure_postfix() {
    step "PASO 2/6 — Configurando Postfix (main.cf)"

    local local_subnet="$1"

    # Redes fijas que siempre deben estar permitidas:
    #   10.253.0.0/16  → red de la universidad (distintas VLANs/aulas)
    #   172.16.36.0/24 → red local del laboratorio (IP estática 172.16.36.82)
    local fixed_networks="10.253.0.0/16 172.16.36.0/24"
    local mynetworks="127.0.0.0/8 ${fixed_networks}"

    if [[ -n "$local_subnet" ]]; then
        for sn in $local_subnet; do
            [[ "$mynetworks" =~ $sn ]] || mynetworks="${mynetworks} ${sn}"
        done
        info "Subredes locales detectadas: ${local_subnet}"
    else
        warn "No se detectaron subredes adicionales automáticamente."
    fi

    ok "mynetworks = ${mynetworks}"

    info "Aplicando directivas con postconf -e..."

    # Identidad del servidor (solo para cabeceras de correo, no se resuelve por DNS)
    postconf -e "myhostname = mail.lab.local"
    postconf -e "mydomain = lab.local"

    # Dominio de origen que se agrega a correos sin dominio explícito
    postconf -e "myorigin = \$mydomain"

    # Escuchar en todas las interfaces de red del servidor
    postconf -e "inet_interfaces = all"

    # Solo IPv4 (evita complicaciones con IPv6 en laboratorio)
    postconf -e "inet_protocols = ipv4"

    # Dominios para los que este servidor acepta correo (entrega local)
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"

    # Formato de buzón: Maildir en el directorio home del usuario (~/Maildir/)
    postconf -e "home_mailbox = Maildir/"

    # Redes de confianza: pueden enviar correo sin restricciones
    # CORRECCIÓN: la guía original tenía '127.8.0.θ/8' — debe ser '127.0.0.0/8'
    postconf -e "mynetworks = ${mynetworks}"

    # Política de relay: solo se permite desde mynetworks, todo lo demás es rechazado
    # Esto evita que el servidor sea un "open relay" (relay abierto)
    postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject"

    # Sin límite de tamaño de buzón (0 = ilimitado)
    postconf -e "mailbox_size_limit = 0"

    # Tamaño máximo de mensaje: 10 MB
    postconf -e "message_size_limit = 10240000"

    ok "Postfix configurado correctamente."
    info "Configuración guardada en: /etc/postfix/main.cf"
}

# ── Configuración de Dovecot (/etc/dovecot/dovecot.conf) ─────────────────────
# CORRECCIÓN: La guía original usaba sintaxis de Dovecot v2.4 (mail_driver,
# dovecot_config_version). Ubuntu 22.04 trae Dovecot v2.3.x. Se usa la
# sintaxis correcta para v2.3: mail_location = maildir:~/Maildir
configure_dovecot() {
    step "PASO 3/6 — Configurando Dovecot v2.3 (dovecot.conf)"

    if [[ -f /etc/dovecot/dovecot.conf ]]; then
        info "Realizando respaldo de la configuración original..."
        cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak
        ok "Respaldo guardado en: /etc/dovecot/dovecot.conf.bak"
    fi

    info "Escribiendo configuración limpia para Dovecot v2.3..."

    # El heredoc usa comillas simples ('DOVECOT_CONF') para evitar que bash
    # expanda cualquier variable — el contenido llega intacto al archivo.
    cat > /etc/dovecot/dovecot.conf << 'DOVECOT_CONF'
## =============================================================================
## /etc/dovecot/dovecot.conf
## Dovecot v2.3 — Configuración de Laboratorio (Sin SSL/TLS)
## Ubuntu Server 22.04 LTS
##
## ADVERTENCIA: ssl=no y disable_plaintext_auth=no son apropiados ÚNICAMENTE
## para redes de laboratorio controladas. NO usar en producción.
##
## CORRECCIÓN APLICADA: Esta configuración usa sintaxis v2.3.
## La guía original usaba directivas de v2.4 (mail_driver, dovecot_config_version)
## que NO existen en Ubuntu 22.04. El error correcto es mail_location.
## =============================================================================

# Protocolo habilitado: solo IMAP (puerto 143)
protocols = imap

# ─────────────────────────────────────────────────────────────────────────────
# BUZONES: Formato Maildir en el directorio home de cada usuario
# Cada usuario tendrá sus correos en ~/Maildir/
# Ejemplo: /home/juan/Maildir/
# ─────────────────────────────────────────────────────────────────────────────
mail_location = maildir:~/Maildir

# Namespace estándar para el buzón de entrada
namespace inbox {
  inbox = yes
}

# ─────────────────────────────────────────────────────────────────────────────
# SEGURIDAD — DESHABILITADA intencionalmente para laboratorio
# Cambiar estos valores en cualquier entorno con acceso a Internet
# ─────────────────────────────────────────────────────────────────────────────

# Sin cifrado TLS/SSL
ssl = no

# Permitir autenticación con contraseña en texto plano (sin TLS)
disable_plaintext_auth = no

# ─────────────────────────────────────────────────────────────────────────────
# AUTENTICACIÓN: Usuarios del sistema Linux
# passdb pam  → verifica contraseñas usando PAM (igual que el login del sistema)
# userdb passwd → obtiene información del usuario desde /etc/passwd
# ─────────────────────────────────────────────────────────────────────────────
passdb {
  driver = pam
}

userdb {
  driver = passwd
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICIO IMAP: Puerto 143 (sin SSL)
# ─────────────────────────────────────────────────────────────────────────────
service imap-login {
  inet_listener imap {
    port = 143
  }
  # Deshabilitar IMAPS en puerto 993 (SSL) — no lo usamos
  inet_listener imaps {
    port = 0
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# LOGS: Verbose para facilitar aprendizaje y troubleshooting
# Revisa: sudo tail -f /var/log/mail.log
# ─────────────────────────────────────────────────────────────────────────────
auth_verbose = yes
DOVECOT_CONF

    ok "Dovecot configurado con sintaxis v2.3 correcta."
    info "Configuración guardada en: /etc/dovecot/dovecot.conf"
}

# ── Configuración del Firewall (UFW) ──────────────────────────────────────────
configure_firewall() {
    step "PASO 4/6 — Configurando Firewall (UFW)"

    if ! command -v ufw &>/dev/null; then
        warn "UFW no está instalado. Omitiendo configuración de firewall."
        warn "Asegúrate de abrir los puertos 25/tcp y 143/tcp manualmente."
        return 0
    fi

    info "Abriendo puerto 25/tcp (SMTP — Postfix)..."
    ufw allow 25/tcp comment 'SMTP Postfix - Servidor Correo Lab' > /dev/null
    ok "Puerto 25/tcp abierto en UFW."

    info "Abriendo puerto 143/tcp (IMAP — Dovecot)..."
    ufw allow 143/tcp comment 'IMAP Dovecot - Servidor Correo Lab' > /dev/null
    ok "Puerto 143/tcp abierto en UFW."

    info "Nota: El puerto 445/tcp (Samba) no fue modificado."

    # Verificar si UFW está activo
    if ufw status 2>/dev/null | grep -q "Status: inactive"; then
        warn "UFW está instalado pero deshabilitado."
        warn "Las reglas se guardaron pero no tendrán efecto hasta activar UFW."
        warn "Para activar: sudo ufw enable"
    fi
}

# ── Iniciar y habilitar servicios ─────────────────────────────────────────────
start_services() {
    step "PASO 5/6 — Iniciando y habilitando servicios"

    info "Reiniciando Postfix..."
    systemctl restart postfix
    systemctl enable postfix --quiet
    ok "Postfix: activo y habilitado para arranque automático."

    info "Reiniciando Dovecot..."
    systemctl restart dovecot
    systemctl enable dovecot --quiet
    ok "Dovecot: activo y habilitado para arranque automático."
}

# ── Verificación de estado ────────────────────────────────────────────────────
verify_services() {
    step "Verificación de servicios"

    local postfix_status dovecot_status
    postfix_status=$(systemctl is-active postfix 2>/dev/null || echo "unknown")
    dovecot_status=$(systemctl is-active dovecot 2>/dev/null || echo "unknown")

    if [[ "$postfix_status" == "active" ]]; then
        ok "Postfix está ${GREEN}activo${NC}"
    else
        error "Postfix NO está activo (estado: ${postfix_status}).\n  Revisa: sudo journalctl -xe -u postfix"
    fi

    if [[ "$dovecot_status" == "active" ]]; then
        ok "Dovecot está ${GREEN}activo${NC}"
    else
        error "Dovecot NO está activo (estado: ${dovecot_status}).\n  Revisa: sudo journalctl -xe -u dovecot"
    fi

    echo ""
    info "Puertos en escucha (25=SMTP, 143=IMAP):"
    ss -tuln 2>/dev/null | grep -E ':25\b|:143\b' | sed 's/^/         /' || \
        warn "No se pudo verificar los puertos. Usa manualmente: ss -tuln"
}

# ── Habilitación de usuarios NAS existentes para correo ──────────────────────
# Los usuarios se crean en el servidor NAS (setup_servidor.sh).
# Este paso solo necesita asignarles contraseña Linux y pre-crear Maildir.
# La contraseña Samba (tdbsam) NO se ve afectada.
create_users() {
    step "PASO 6/6 — Habilitar usuarios existentes para correo"

    echo -e "${YELLOW}El servidor de correo usa las cuentas Linux creadas por el servidor NAS.${NC}"
    echo -e "${YELLOW}No es necesario crear usuarios nuevos aquí.${NC}"
    echo ""

    # ── Recopilar usuarios del sistema (uid >= 1000, sin nobody) ─────────────
    local -a usuarios=()
    while IFS=: read -r name _ uid _ _ _ _; do
        [[ "$uid" -ge 1000 && "$name" != "nobody" ]] || continue
        usuarios+=("$name")
    done < /etc/passwd

    if [[ ${#usuarios[@]} -eq 0 ]]; then
        warn "No se encontraron usuarios del sistema (uid >= 1000)."
        warn "Despliega primero el servidor NAS (setup_servidor.sh) para crear los usuarios."
        return
    fi

    # ── Tabla de estado ───────────────────────────────────────────────────────
    echo -e "${BOLD}  Estado actual de usuarios:${NC}"
    echo    "  ────────────────────────────────────────────────────────────"
    printf  "  %-20s  %-16s  %-8s  %s\n" "Usuario" "Pass Linux" "Maildir" "Estado"
    echo    "  ────────────────────────────────────────────────────────────"

    local -a pendientes=()
    for u in "${usuarios[@]}"; do
        local home_dir shadow_entry pass_label maildir_label estado_label
        home_dir=$(getent passwd "$u" | cut -d: -f6)
        shadow_entry=$(getent shadow "$u" 2>/dev/null | cut -d: -f2)

        if [[ -n "$shadow_entry" && "$shadow_entry" != "!"* && "$shadow_entry" != "*" ]]; then
            pass_label="si"
        else
            pass_label="no (bloqueada)"
            pendientes+=("$u")
        fi

        if [[ -d "${home_dir}/Maildir" ]]; then
            maildir_label="si"
        else
            maildir_label="no"
        fi

        if [[ "$pass_label" == "si" ]]; then
            estado_label="${GREEN}listo${NC}"
        else
            estado_label="${YELLOW}pendiente${NC}"
        fi

        printf "  %-20s  %-16s  %-8s  " "$u" "$pass_label" "$maildir_label"
        echo -e "$estado_label"
    done
    echo "  ────────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#pendientes[@]} -eq 0 ]]; then
        ok "Todos los usuarios ya están habilitados para correo."
        return
    fi

    info "Usuarios pendientes: ${pendientes[*]}"
    info "La contraseña Linux es independiente de la contraseña Samba (NAS sin cambios)."
    echo ""

    # ── Habilitar los pendientes uno a uno ───────────────────────────────────
    for u in "${pendientes[@]}"; do
        local resp="n"
        read -r -p "  ¿Habilitar '${u}' para correo? [s/N]: " resp || continue
        [[ "$resp" =~ ^[sS]$ ]] || continue

        local password="" password_confirm=""
        while true; do
            read -r -s -p "  Contraseña Linux para '${u}': " password || break
            echo ""
            if [[ ${#password} -lt 4 ]]; then
                warn "  Mínimo 4 caracteres."
                continue
            fi
            read -r -s -p "  Confirmar contraseña: " password_confirm || break
            echo ""
            if [[ "$password" == "$password_confirm" ]]; then
                break
            fi
            warn "  Las contraseñas no coinciden. Intenta de nuevo."
        done

        [[ -z "$password" ]] && continue

        local home_dir
        home_dir=$(getent passwd "$u" | cut -d: -f6)

        # Asegurar home (puede faltar en usuarios Samba creados sin -m)
        if [[ ! -d "$home_dir" ]]; then
            mkdir -p "$home_dir"
            chown "${u}:${u}" "$home_dir"
            chmod 750 "$home_dir"
            ok "  Home creado: ${home_dir}"
        fi

        # Asignar contraseña Linux — no toca tdbsam de Samba
        printf '%s:%s\n' "$u" "$password" | chpasswd
        ok "  Contraseña asignada a '${u}'.  (Samba sin cambios)"

        # Pre-crear estructura Maildir
        su -s /bin/sh "$u" -c "mkdir -p ~/Maildir/{cur,new,tmp}" 2>/dev/null || true
        ok "  Maildir: ${home_dir}/Maildir/"
        info "  Dirección de correo: ${u}@lab.local"
        echo ""
    done

    ok "Habilitación de usuarios completada."
}

# ── Resumen final ─────────────────────────────────────────────────────────────
show_summary() {
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  ✓  INSTALACIÓN COMPLETADA EXITOSAMENTE${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}IP del servidor:${NC}      ${CYAN}${server_ip}${NC}"
    echo -e "  ${BOLD}SMTP (Postfix):${NC}       ${CYAN}${server_ip}:25${NC}   — sin cifrado"
    echo -e "  ${BOLD}IMAP (Dovecot):${NC}       ${CYAN}${server_ip}:143${NC}  — sin cifrado"
    echo -e "  ${BOLD}Formato de buzón:${NC}     ${CYAN}Maildir  (~/Maildir/)${NC}"
    echo -e "  ${BOLD}Dominio de lab:${NC}       ${CYAN}lab.local${NC}"
    echo ""
    echo -e "  ${BOLD}Configuración Thunderbird:${NC}"
    echo -e "    Entrante IMAP → IP: ${CYAN}${server_ip}${NC} | Puerto: ${CYAN}143${NC} | Seguridad: ${CYAN}Ninguna${NC} | Auth: ${CYAN}Contraseña normal${NC}"
    echo -e "    Saliente SMTP → IP: ${CYAN}${server_ip}${NC} | Puerto: ${CYAN}25${NC}  | Seguridad: ${CYAN}Ninguna${NC} | Auth: ${CYAN}Sin autenticación${NC}"
    echo ""
    echo -e "  ${BOLD}Comandos útiles:${NC}"
    echo -e "    Ver logs en tiempo real:    ${YELLOW}sudo tail -f /var/log/mail.log${NC}"
    echo -e "    Estado de Postfix:          ${YELLOW}sudo systemctl status postfix${NC}"
    echo -e "    Estado de Dovecot:          ${YELLOW}sudo systemctl status dovecot${NC}"
    echo -e "    Verificar puertos:          ${YELLOW}ss -tuln | grep -E ':25|:143'${NC}"
    echo -e "    Desinstalar todo:           ${YELLOW}sudo bash limpiar_correo.sh${NC}"
    echo ""
}

# ── Función principal ──────────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_ubuntu

    local subnet
    subnet=$(detect_subnet)

    install_packages
    configure_postfix "$subnet"
    configure_dovecot
    configure_firewall
    start_services
    verify_services
    create_users
    show_summary
}

main "$@"
