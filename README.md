# Internal DNS (dnsmasq en Docker)

Servicio DNS interno para clientes VPN, basado en `dnsmasq`, orientado a resolver dominios privados de ejemplo como `*.internal.example`.

## Objetivo

- Resolver nombres internos desde la red VPN.
- Mantener configuración sensible fuera del repositorio.
- Operar de forma simple con `docker compose`.

## Estructura

```text
Internal-DNS/
├─ docker-compose.yml
├─ README.md
├─ .gitignore
├─ client-windows-scripts/
│  ├─ Fix-DNS-VPN.ps1
│  └─ Host-Entry.ps1
└─ config/
	├─ dnsmasq.conf.example
	└─ dnsmasq.conf        # local, ignorado por git
```

## Configuración inicial

1. Entrar al proyecto:

```bash
cd Internal-DNS
```

2. Crear configuración local a partir del ejemplo:

```bash
cp config/dnsmasq.conf.example config/dnsmasq.conf
```

3. Editar `config/dnsmasq.conf` y ajustar IP/hosts:

```properties
address=/app1.internal.example/192.0.2.10
address=/app2.internal.example/192.0.2.20
address=/router-site.internal.example/10.0.10.1
```

## Levantar / detener servicio

Levantar:

```bash
docker compose up -d
```

Ver estado/logs:

```bash
docker compose ps
docker compose logs -f
```

Detener:

```bash
docker compose down
```

## Scripts de cliente Windows

Carpeta: `client-windows-scripts/`

- `Fix-DNS-VPN.ps1`: diagnostica y corrige el comportamiento DNS en Windows cuando la VPN está conectada (métricas, DNS en interfaz VPN activa DCO/TAP, flush y verificación).
- `Host-Entry.ps1`: gestor interactivo para agregar, listar y eliminar entradas del archivo `hosts` con compatibilidad PS5/PS7.

### Configurar dominios para Host-Entry.ps1

El script carga dominios desde `client-windows-scripts/domains.json`.

1. Crear archivo local a partir del ejemplo anonimizado:

```powershell
Copy-Item client-windows-scripts/domains.example.json client-windows-scripts/domains.json
```

2. Editar `client-windows-scripts/domains.json` con tus hostnames/IPs reales.

Notas:

- `domains.example.json` está versionado y usa datos de ejemplo.
- `domains.json` es local y está ignorado por git.
- `Host-Entry.ps1` requiere `domains.json`; si falta o es inválido, el script termina con error.

### Configurar Fix-DNS-VPN.ps1 desde el mismo JSON

`Fix-DNS-VPN.ps1` reutiliza `client-windows-scripts/domains.json` en la sección `vpnFix`.

Ejemplo de bloque:

```json
"vpnFix": {
	"vpnDns": "10.8.0.1",
	"testName": "router-site-a.vpn.internal.example",
	"vpnDcoAliasPattern": "OpenVPN*Offload*",
	"vpnTapAliasPattern": "OpenVPN*TAP*",
	"preferredMetric": 5,
	"nonVpnMetric": 50,
	"logPath": "%TEMP%\\fix-vpn-dns.log"
}
```

Notas:

- Los parámetros CLI siguen funcionando y tienen prioridad sobre `vpnFix`.
- Si falta `vpnFix`, el script usa valores por defecto para `vpnDns`, patrones y métricas.
- `testName` es obligatorio: debe venir en `vpnFix.testName` o por CLI con `-TestName`.
- El panel ahora aplica DNS sobre adaptadores VPN activos detectados (DCO/TAP), no solo TAP por nombre fijo.

### Uso rápido de Fix-DNS-VPN.ps1

- Ejecutar panel interactivo:

```powershell
.\Fix-DNS-VPN.ps1
```

- Aplicar fix recomendado sin panel:

```powershell
.\Fix-DNS-VPN.ps1 -ApplyMetrics -ApplyVpnDns
```

## Pruebas de resolución

Desde el host:

```bash
dig @10.8.0.1 app1.internal.example +short
dig @10.8.0.1 app2.internal.example +short
```

Desde cliente Windows VPN:

```powershell
nslookup app1.internal.example 10.8.0.1
```

## Integración con OpenVPN

En la configuración del servidor OpenVPN (`openvpn.conf`) usar:

```conf
push "dhcp-option DNS 10.8.0.1"
push "dhcp-option DOMAIN internal"
push "dhcp-option DOMAIN-SEARCH internal.example"
```

Luego reiniciar el servicio OpenVPN según tu stack.

## Git y archivos sensibles

El repositorio incluye `.gitignore` para evitar versionar la configuración local:

- `config/dnsmasq.conf` (local)
- logs y temporales

Archivo versionado de referencia:

- `config/dnsmasq.conf.example`

## Inicializar repositorio (si aplica)

```bash
cd Internal-DNS
git init
git add .
git commit -m "chore: initial internal dns setup"
```

Si ya existe remoto:

```bash
git remote add origin <URL_DEL_REPO>
git push -u origin main
```

## Troubleshooting rápido

- Si `53/tcp` o `53/udp` está ocupado, detén el servicio DNS local que colisiona.
- Si no resuelve desde cliente VPN, validar rutas VPN y push de DNS en OpenVPN.
- Si resuelve con `dig @10.8.0.1` pero no sin servidor, revisar cliente DNS del SO.

## Personalización recomendada antes de producción

- Reemplazar `internal.example` por tu dominio interno real.
- Ajustar IPs privadas según tu red (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
- Evitar publicar datos sensibles (hostnames reales, IPs de infraestructura, rutas internas).
