# Plan: Repositorio GitHub - Servidor de Correo Lab

**TL;DR:** Generar 4 archivos listos para copiar/pegar que formarán un repositorio educativo completo para Postfix+Dovecot en Ubuntu 22.04, con todas las correcciones técnicas aplicadas sobre la guía original.

---

## Archivos a generar

### Fase 1 — Archivos de soporte

**1. `.gitignore`**
Patrones estándar Bash/shell: archivos `*~`, `*.log`, `*.bak`, `.env`, `*.swp`, credenciales cacheadas.

---

### Fase 2 — Scripts de automatización

**2. `setup_correo.sh`** — Script principal con:
- Banner ASCII + colores ANSI para salidas estéticas
- Validación `root` al inicio
- Preseeding con `debconf-set-selections` → instalación 100% silenciosa de `postfix` y `dovecot-imapd`
- Detección dinámica de subred:
  ```bash
  LOCAL_SUBNET=$(ip route | grep -v default | grep -v 127 | awk '{print $1}' | head -n1)
  ```
- Inyección en `/etc/postfix/main.cf`:
  - `myhostname = mail.lab.local`
  - `mydomain = lab.local`
  - `home_mailbox = Maildir/`
  - `mynetworks = 127.0.0.0/8 $LOCAL_SUBNET`
- Sobrescritura limpia de `/etc/dovecot/dovecot.conf` con sintaxis Dovecot **v2.3**:
  - `mail_location = maildir:~/Maildir` (NO `mail_driver`)
  - `ssl = no`
  - `disable_plaintext_auth = no`
  - Bloques `auth-system` con `passdb` y `userdb`
- `ufw allow 25/tcp && ufw allow 143/tcp`
- `systemctl restart && systemctl enable` para `postfix` y `dovecot`
- Bucle interactivo de creación de usuarios:
  ```bash
  useradd -m -s /usr/sbin/nologin <usuario>
  echo "<usuario>:<password>" | chpasswd
  ```

**3. `limpiar_correo.sh`** — Script de desinstalación con:
- Detención de servicios (`systemctl stop`)
- `apt purge --autoremove postfix dovecot-*`
- `rm -rf /etc/postfix /etc/dovecot`
- `ufw delete allow 25/tcp && ufw delete allow 143/tcp`
- Bucle interactivo para eliminar usuarios creados (`userdel -r`)

---

### Fase 3 — Documentación

**4. `README.md`** — Documento extenso con:
- **Introducción conceptual:** Analogía postal MTA/MDA, tabla de puertos coexistentes (Samba 445, SMTP 25, IMAP 143)
- **Estructura del proyecto:** Árbol de archivos
- **Despliegue rápido:** Clone + chmod + run
- **Guía Thunderbird paso a paso:**
  - Configuración manual (no automática)
  - IMAP entrante: puerto `143`, seguridad `Ninguna`, autenticación `Contraseña normal`
  - SMTP saliente: puerto `25`, seguridad `Ninguna`, autenticación `Sin autenticación`
- **Verificación:** `systemctl status`, `ss -tuln | grep -E '25|143'`, `/var/log/mail.log`
- **Troubleshooting:** Tabla de síntomas / causas / soluciones

---

## Correcciones obligatorias aplicadas sobre la guía original

| Error en guía original | Corrección aplicada |
|---|---|
| `127.8.0.θ/8` (typo en mynetworks) | `127.0.0.0/8` |
| `mynetworks` estático sin subred local | Detección dinámica con `ip route` |
| Sintaxis Dovecot v2.4 (`dovecot_config_version`, `mail_driver`) | Sintaxis Dovecot **v2.3.x** (`mail_location = maildir:~/Maildir`) |
| Directorios creados manualmente antes de instalar | Primero `apt install`, luego configurar |
| Sin configuración de firewall | `ufw allow 25/tcp` y `ufw allow 143/tcp` |

## Decisiones de diseño

- **Sin TLS/SSL:** Entorno de laboratorio controlado. Documentado explícitamente como intencional.
- **Sin DNS:** Clientes se conectan por IP. `myhostname` solo es para cabeceras de correo.
- **Usuarios sin shell:** `useradd -m -s /usr/sbin/nologin` — home obligatorio para Maildir, sin acceso SSH por seguridad.
- **Coexistencia con Samba:** Samba usa puerto 445 (SMB). Postfix usa 25 (SMTP). Dovecot usa 143 (IMAP). Sin conflictos.

## Directorio de destino

`/home/saantigh/Universidad/comunicaciones/servidor_CORREO/`
