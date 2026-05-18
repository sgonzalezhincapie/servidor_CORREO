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

# ── Detección dinámica de la subred local ──────────────────────────────────────
# Obtiene la primera ruta de red local (excluye loopback y default gateway)
# Ejemplo de resultado: "192.168.1.0/24"
detect_subnet() {
    local subnet
    subnet=$(ip route 2>/dev/null \
        | grep -v default \
        | grep -v 127 \
        | grep -E '^[0-9]+\.' \
        | awk '{print $1}' \
        | head -n1)

    if [[ -z "$subnet" ]]; then
        warn "No se pudo detectar la subred local automáticamente."
        warn "mynetworks solo incluirá 127.0.0.0/8 (solo loopback)."
        warn "Los clientes de la red local no podrán enviar correo."
        warn "Puedes corregirlo después editando: /etc/postfix/main.cf"
        echo ""
    else
        echo "$subnet"
    fi
}

# ── Instalación silenciosa de paquetes ────────────────────────────────────────
# Usa debconf-set-selections para evitar ventanas emergentes de configuración
install_packages() {
    step "PASO 1/6 — Instalando Postfix y Dovecot"

    info "Preconfigurando respuestas de debconf (instalación silenciosa)..."
    debconf-set-selections << 'DEBCONF'
postfix postfix/mailname string mail.lab.local
postfix postfix/main_mailer_type select Internet Site
DEBCONF

    info "Actualizando índice de paquetes..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq

    info "Instalando postfix y dovecot-imapd..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix dovecot-imapd

    ok "Paquetes instalados correctamente."
    info "Versiones instaladas:"
    postconf mail_version 2>/dev/null | sed 's/^/         Postfix: /' || true
    dovecot --version 2>/dev/null | head -n1 | sed 's/^/         Dovecot: /' || true
}

# ── Configuración de Postfix (/etc/postfix/main.cf) ──────────────────────────
configure_postfix() {
    step "PASO 2/6 — Configurando Postfix (main.cf)"

    local local_subnet="$1"
    local mynetworks="127.0.0.0/8"

    if [[ -n "$local_subnet" ]]; then
        mynetworks="127.0.0.0/8 ${local_subnet}"
        info "Subred local detectada: ${local_subnet}"
        ok "mynetworks = ${mynetworks}"
    else
        warn "mynetworks = ${mynetworks} (solo loopback, subred no detectada)"
    fi

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

# ── Creación interactiva de usuarios de correo ────────────────────────────────
# Los usuarios de correo son cuentas de usuario Linux estándar.
# Se crean SIN shell del sistema (nologin) pero CON directorio home,
# porque Maildir vive dentro del home: ~/Maildir/
create_users() {
    step "PASO 6/6 — Registro de Usuarios de Correo"

    echo -e "${YELLOW}Los usuarios del servidor de correo son cuentas de Linux.${NC}"
    echo -e "${YELLOW}Se crean sin acceso a shell por seguridad, pero con directorio${NC}"
    echo -e "${YELLOW}home para que Postfix pueda crear ~/Maildir/ automáticamente.${NC}"
    echo ""

    local crear_mas="s"
    while [[ "$crear_mas" =~ ^[sS]$ ]]; do

        echo -e "${BOLD}─── Nuevo usuario de correo ───────────────────────────────${NC}"

        # ── Solicitar nombre de usuario ────────────────────────────
        local username=""
        while true; do
            read -r -p "  Nombre de usuario (letras/números, sin espacios): " username || break
            username="${username,,}"  # convertir a minúsculas

            if [[ -z "$username" ]]; then
                warn "  El nombre no puede estar vacío."
                continue
            fi

            if ! [[ "$username" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; then
                warn "  Nombre inválido. Solo letras minúsculas, números, '-' o '_'."
                warn "  Debe comenzar con una letra. Máximo 31 caracteres."
                continue
            fi

            if id "$username" &>/dev/null; then
                warn "  El usuario '${username}' ya existe en el sistema."
                local reset_pass="n"
                read -r -p "  ¿Deseas solo actualizar su contraseña? [s/N]: " reset_pass || true
                if [[ "$reset_pass" =~ ^[sS]$ ]]; then
                    break  # Salir del loop interno, ir a asignar contraseña
                else
                    username=""
                    continue
                fi
            fi

            break
        done

        # Si el usuario salió del loop sin nombre (Ctrl+D), terminamos
        [[ -z "$username" ]] && break

        # ── Solicitar y confirmar contraseña ───────────────────────
        local password="" password_confirm=""
        while true; do
            read -r -s -p "  Contraseña para '${username}': " password || break
            echo ""

            if [[ ${#password} -lt 4 ]]; then
                warn "  La contraseña debe tener al menos 4 caracteres."
                continue
            fi

            read -r -s -p "  Confirmar contraseña: " password_confirm || break
            echo ""

            if [[ "$password" != "$password_confirm" ]]; then
                warn "  Las contraseñas no coinciden. Intenta de nuevo."
                continue
            fi

            break
        done

        [[ -z "$password" ]] && break

        # ── Crear usuario (si no existe) ───────────────────────────
        if ! id "$username" &>/dev/null; then
            # -m: crear directorio home obligatorio (para ~/Maildir/)
            # -s /usr/sbin/nologin: sin acceso a shell del sistema
            useradd -m -s /usr/sbin/nologin "$username"
            ok "  Usuario '${username}' creado con home en /home/${username}/"
        fi

        # ── Asignar contraseña via chpasswd ────────────────────────
        # chpasswd lee "usuario:contraseña" desde stdin
        printf '%s:%s\n' "$username" "$password" | chpasswd
        ok "  Contraseña asignada a '${username}'."
        info "  Buzón de correo: /home/${username}/Maildir/  (se crea al recibir el primer correo)"
        info "  Dirección de correo: ${username}@lab.local"
        echo ""

        read -r -p "  ¿Deseas registrar otro usuario? [s/N]: " crear_mas || break
        echo ""
    done

    ok "Proceso de registro de usuarios completado."
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
