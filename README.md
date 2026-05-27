# Servidor de Correo Electrónico — Laboratorio

> Postfix (envío SMTP) + Dovecot IMAP (lectura) en Ubuntu Server 22.04 LTS · Sin SSL/TLS · Formato Maildir · Coexiste con Samba en puerto 445

[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Postfix](https://img.shields.io/badge/MTA-Postfix-005FAD)](http://www.postfix.org/)
[![Dovecot](https://img.shields.io/badge/MDA-Dovecot_v2.3-2B6CB0)](https://dovecot.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Estructura del proyecto

```
servidor_CORREO/
├── .gitignore           # Archivos a ignorar en Git
├── README.md            # Esta guía
├── setup_correo.sh      # Instalador automático
└── limpiar_correo.sh    # Desinstalador completo
```

---

## Parte 1 — En el servidor Ubuntu

### Paso 1 · Clonar el repositorio y preparar los scripts

```bash
git clone https://github.com/TU_USUARIO/servidor_CORREO.git
cd servidor_CORREO
chmod +x setup_correo.sh limpiar_correo.sh descargar_paquetes.sh
```

### Paso 2 - Descargar los paquetes necesarios
```bash
sudo bash descargar_paquetes.sh
```

### Paso 3 · Ejecutar el instalador

```bash
sudo bash setup_correo.sh
```

El script hace todo automáticamente:
- Instala `postfix` y `dovecot-imapd` de forma silenciosa
- Configura Postfix (detecta tu subred local y la agrega a `mynetworks`)
- Configura Dovecot v2.3 (IMAP en puerto 143, sin SSL)
- Abre los puertos 25 y 143 en el firewall UFW
- Al terminar, te pregunta si quieres crear usuarios de correo de prueba

Cuando te pida usuarios, crea al menos dos para poder hacer pruebas de envío entre ellos (por ejemplo `juan` y `bob`).

### Paso 3 · Obtener la IP del servidor

Anota esta IP, la necesitarás para configurar el cliente de correo:

```bash
hostname -I | awk '{print $1}'
# Ejemplo: 192.168.1.105
```

### Paso 4 · Verificar que todo funciona

```bash
# Los dos servicios deben aparecer como "active (running)"
sudo systemctl status postfix dovecot

# Los puertos 25 (SMTP) y 143 (IMAP) deben estar escuchando
sudo ss -tuln | grep -E ':25\b|:143\b'
```

Salida esperada:
```
tcp  LISTEN  0  100  0.0.0.0:25   0.0.0.0:*
tcp  LISTEN  0  100  0.0.0.0:143  0.0.0.0:*
```

### Gestión de usuarios (después de la instalación)

**Agregar un usuario nuevo:**
```bash
sudo useradd -m -s /usr/sbin/nologin maria
echo "maria:micontraseña" | sudo chpasswd
```

> **¿Ya tienes un servidor NAS con Samba?** Los usuarios de Samba no tienen contraseña Linux ni directorio home por defecto. El script `setup_correo.sh` los detecta automáticamente y te ofrece habilitarlos para correo (crea el home y asigna contraseña Linux **sin tocar la contraseña de Samba**). También puedes hacerlo a mano para usuarios ya existentes:
>
> ```bash
> # Habilitar usuario Samba existente (ej: santi) para correo
> sudo mkdir -p /home/santi && sudo chown santi:santi /home/santi && sudo chmod 750 /home/santi
> echo "santi:contraseña_correo" | sudo chpasswd
> # La contraseña de Samba de santi NO cambia
> ```

**Cambiar la contraseña de un usuario:**
```bash
echo "juan:nuevacontraseña" | sudo chpasswd
```

**Eliminar un usuario y sus correos:**
```bash
sudo userdel -r juan
```

**Ver correos recibidos de un usuario directamente en el servidor:**
```bash
ls /home/juan/Maildir/new/    # correos sin leer
ls /home/juan/Maildir/cur/    # correos ya vistos
```

---

## Parte 2 — Desde el cliente (cualquier PC)

### Datos de conexión

Reemplaza `192.168.1.105` con la IP real de tu servidor.

| | Servidor entrante (IMAP) | Servidor saliente (SMTP) |
|:---|:---|:---|
| **Protocolo** | IMAP | SMTP |
| **Servidor** | `192.168.1.105` | `192.168.1.105` |
| **Puerto** | `143` | `25` |
| **Seguridad** | Ninguna (None) | Ninguna (None) |
| **Autenticación** | Contraseña normal | **Sin autenticación** |
| **Usuario** | `juan` (sin @lab.local) | — |

> **¿Por qué "Sin autenticación" en SMTP?** El servidor acepta correos de cualquier máquina dentro de la misma red local. No hace falta usuario ni contraseña para enviar.

---

### Opción A — Thunderbird (Windows / Linux / macOS)

Thunderbird es gratuito, funciona igual en los tres sistemas operativos y es el cliente recomendado para este laboratorio.

**Descarga:** [https://www.thunderbird.net](https://www.thunderbird.net)

**Pasos:**

1. Abre Thunderbird y ve a **≡ → Nuevo → Cuenta de correo existente…**

2. Rellena el formulario inicial:
   - Nombre: `Juan García` (o el que quieras)
   - Correo: `juan@lab.local`
   - Contraseña: la que asignaste al crear el usuario

3. Haz clic en **"Configurar manualmente"**
   > No hagas clic en "Continuar" — sin DNS la detección automática fallará.

4. En **Servidor entrante**, completa con los valores de la tabla de arriba (IMAP, puerto 143, Ninguna, Contraseña normal).

5. En **Servidor saliente**, completa con los valores de la tabla (puerto 25, Ninguna, Sin autenticación).

6. Haz clic en **"Hecho"**. Si aparece una advertencia sobre conexión sin cifrar, haz clic en **"Confirmar"** o **"Aceptar"**.

7. La cuenta aparecerá en el panel izquierdo. Repite estos pasos para el usuario `bob` si quieres probar el envío entre dos cuentas.

**Prueba de envío:** desde la cuenta de `juan`, envía un correo a `bob@lab.local`. Luego en la cuenta de `bob` haz clic en el botón de sincronizar/recibir correo.

---

### Opción B — Prueba rápida desde terminal (sin instalar nada)

Funciona en Linux, macOS y Windows con WSL. Solo necesitas `telnet` (o `nc`).

**Verificar que Dovecot responde (IMAP):**
```bash
telnet 192.168.1.105 143
```
Debes ver algo como: `* OK Dovecot (Ubuntu) ready.`  
Para salir: escribe `a LOGOUT` y presiona Enter.

**Leer correos de un usuario por IMAP manual:**
```bash
telnet 192.168.1.105 143
# Una vez conectado, escribe estos comandos uno a uno:
a LOGIN juan micontraseña
a SELECT INBOX
a FETCH 1 BODY[]
a LOGOUT
```

**Enviar un correo por SMTP manual (sin autenticación):**
```bash
telnet 192.168.1.105 25
# Una vez conectado, escribe estos comandos uno a uno:
HELO cliente
MAIL FROM:<juan@lab.local>
RCPT TO:<bob@lab.local>
DATA
Subject: Correo de prueba

Hola bob, esto es una prueba desde la terminal.
.
QUIT
```
> La línea con solo un punto (`.`) indica el fin del cuerpo del mensaje.

---

## Ver los logs del servidor

Mientras realizas pruebas desde el cliente, observa en tiempo real qué pasa en el servidor:

```bash
sudo tail -f /var/log/mail.log
```

Cuando llegue un correo verás líneas similares a:
```
postfix/smtpd: connect from cliente[192.168.1.50]
postfix/local: to=<bob@lab.local>, status=sent (delivered to maildir)
dovecot: imap-login: Login: user=<bob>, rip=192.168.1.50
```

---

## Desinstalar

```bash
sudo bash limpiar_correo.sh
```

El script te preguntará si también quieres eliminar los usuarios de correo creados.

---

## Troubleshooting

| Síntoma | Causa probable | Solución |
|:--------|:---------------|:---------|
| `Connection refused` en puerto 143 | Dovecot no está activo | `sudo systemctl restart dovecot` |
| `Connection refused` en puerto 25 | Postfix no está activo | `sudo systemctl restart postfix` |
| Error de autenticación en Thunderbird | Contraseña incorrecta o usuario no existe | `id juan` para verificar, `echo "juan:pass" \| sudo chpasswd` para corregir |
| Correo enviado desde Thunderbird no llega | El PC no está en `mynetworks` | `postconf mynetworks` para ver las redes autorizadas |
| Thunderbird exige cifrado y no conecta | Seguridad configurada como SSL/TLS en vez de Ninguna | Cambiar a "Ninguna" en ambos servidores y aceptar advertencia |
| Dovecot no arranca — "Unknown setting" | Archivo de config con sintaxis de v2.4 | Confirmar que `/etc/dovecot/dovecot.conf` usa `mail_location`, no `mail_driver` |
| `NOQUEUE: reject` en los logs de Postfix | Remitente no autorizado por `mynetworks` | Ejecutar `postconf mynetworks` y verificar que la subred del cliente esté incluida |

---

<details>
<summary>📚 Conceptos: ¿Cómo funciona un servidor de correo? (expandir)</summary>

### El problema que resuelve este sistema

Cuando envías un correo electrónico intervienen dos piezas de software con roles distintos, igual que en el servicio postal físico.

### Postfix — El camión de correos (MTA)

**MTA = Mail Transfer Agent.** Su trabajo es:
- Recibir correos del cliente remitente en el puerto **25** (protocolo SMTP)
- Decidir si el destinatario es local o hay que reenviar a otro servidor
- Depositar el mensaje en el buzón local del destinatario

### Dovecot — El cartero del edificio (MDA/IMAP)

**MDA = Mail Delivery Agent.** Su trabajo es:
- Custodiar los buzones de los usuarios
- Atender a los clientes de correo (Thunderbird, Outlook, etc.) que quieran leer su bandeja
- Servir los mensajes a través del protocolo **IMAP** en el puerto **143**

### El flujo completo

```
[Thunderbird en el PC]              [Ubuntu Server]

  Enviar correo ──── SMTP :25 ────▶ Postfix (MTA)
                                         │
                                         ▼ entrega local
                                    ~/Maildir/bob/
                                         │
  Leer correo  ◀─── IMAP :143 ────  Dovecot (MDA)
```

### El formato Maildir

Cada correo es un archivo individual dentro del directorio home del usuario:

```
/home/bob/Maildir/
├── new/    ← correos recién llegados, sin leer
├── cur/    ← correos ya abiertos
└── tmp/    ← correos en tránsito (entrega en curso)
```

### Coexistencia con Samba

No hay conflicto porque cada servicio usa un puerto diferente:

| Servicio | Puerto | Protocolo |
|:---------|:------:|:----------|
| Samba NAS | 445 | SMB (compartición de archivos) |
| Postfix | 25 | SMTP (envío de correo) |
| Dovecot | 143 | IMAP (lectura de correo) |

### ¿Por qué sin autenticación en SMTP?

Postfix solo acepta correos de máquinas dentro de `mynetworks` (la subred local). Como todos los clientes están en la misma LAN que el servidor, la red en sí actúa como control de acceso. Este es el modelo clásico de servidores de correo corporativos internos.

### ¿Por qué sin SSL/TLS?

En un laboratorio con red local controlada y sin acceso a Internet, el cifrado no es necesario y añade complejidad (certificados, configuración extra). Esta configuración es **solo válida para entornos de laboratorio**. En producción siempre se usa TLS con certificados válidos.

### Correcciones sobre la guía de implementación original

| Error en guía original | Corrección aplicada |
|:----------------------|:--------------------|
| `mynetworks = 127.8.0.θ/8` (typo con carácter θ) | `127.0.0.0/8` + subred local detectada con `ip route` |
| `mynetworks` sin incluir la subred local | Detección automática para que los clientes de LAN puedan enviar |
| Directiva Dovecot v2.4: `dovecot_config_version` | Eliminada — no existe en Dovecot v2.3.x (Ubuntu 22.04) |
| Directiva Dovecot v2.4: `mail_driver = maildir` | Reemplazada por `mail_location = maildir:~/Maildir` (v2.3) |
| Directorios creados manualmente antes de instalar | Primero `apt install`, luego modificar configuraciones |

</details>

> ⚠️ **Solo para laboratorio.** Las contraseñas viajan en texto plano y no hay autenticación SMTP. No uses esta configuración en redes con acceso a Internet ni con datos sensibles.

---

*Proyecto académico — Asignatura: Comunicaciones · Universidad*

