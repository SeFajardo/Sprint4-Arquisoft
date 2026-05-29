# BITE.co — Sprint 4: Validación ASR Seguridad + Latencia

Experimento académico para validar dos ASRs sobre el endpoint de registro de cuentas cloud AWS de BITE.co. Usa Kong como API Gateway con plugins de seguridad, Flask/Gunicorn como microservicio, y PostgreSQL como base de datos — todo en AWS Academy con Terraform.

---

## Arquitectura

```
[JMeter local] ──HTTP:8000──▶ [bite-kong EC2] ──HTTP:8080──▶ [bite-api EC2] ──TCP:5432──▶ [bite-db EC2]
                               Kong 3.6 (Docker)              Flask + Gunicorn              PostgreSQL 14
                               Plugins:                                │                   (fuente de verdad ACID)
                               • key-auth        → 401                │
                               • rate-limiting   → 429 >2000/min      │──TCP:27017──▶ [bite-mongo EC2]
                               • request-size-limiting → 413 >2KB                     MongoDB 7.0
                               • file-log        → /tmp/kong-audit.log                • audit_events (ASR-SEG)
                                                                                       • account_cache (ASR-LAT)
```

**Táctica no-relacional aplicada — Polyglot Persistence:**
| Rol de MongoDB | Colección | Táctica | ASR que soporta |
|---------------|-----------|---------|-----------------|
| Audit Event Store | `audit_events` | Documento JSON append-only, schema flexible | ASR-SEG: registro de cada evento de seguridad (401, 429, 400, SUCCESS) |
| Account Cache | `account_cache` | Cache-aside + Write-through | ASR-LAT: check de duplicado vía índice MongoDB antes de ir a PostgreSQL |

| EC2 | Nombre | Qué corre | Puerto |
|-----|--------|-----------|--------|
| bite-db | PostgreSQL 14 | `apt install postgresql` nativo | 5432 |
| bite-mongo | MongoDB 7.0 | `apt install mongodb-org` nativo | 27017 |
| bite-api | Flask + Gunicorn 4 workers | `gunicorn app:app` | 8080 |
| bite-kong | Kong 3.6 | Docker (`kong:3.6`) | 8000 |

---

## Pre-requisitos

1. **AWS Academy activo**: sesión de laboratorio iniciada en [awsacademy.instructure.com](https://awsacademy.instructure.com)
2. **AWS CLI configurado** con las credenciales de sesión de AWS Academy:
   ```bash
   # En AWS Academy → Vocareum → AWS Details → AWS CLI
   # Copiar y pegar las credenciales en ~/.aws/credentials
   aws sts get-caller-identity  # debe mostrar LabRole
   ```
3. **Terraform ≥ 1.5**:
   ```bash
   terraform --version
   ```
4. **JMeter 5.6+** descargado desde [jmeter.apache.org](https://jmeter.apache.org)

---

## Paso 1 — Crear key pair `vockey`

AWS Academy provee un key pair llamado `vockey` por defecto.

1. Ir a **AWS Console → EC2 → Key Pairs**
2. Si existe `vockey`, hacer clic en él y **descargar** el archivo `.pem`
3. Si NO existe: **Create key pair** → nombre: `vockey` → tipo: RSA → formato: `.pem` → guardar
4. Mover el `.pem` a un lugar seguro y ajustar permisos:
   ```bash
   chmod 400 ~/vockey.pem   # Linux/Mac
   # En Windows: click derecho → Propiedades → Seguridad → dar acceso solo a tu usuario
   ```

> **Importante**: el `key_name = "vockey"` está hardcodeado en `main.tf`. Si tu key pair tiene otro nombre, edita esa línea.

---

## Paso 2 — Deploy con Terraform

```bash
# Desde la raiz del repositorio:
terraform init
terraform apply -auto-approve
```

Terraform creará en orden: 4 security groups + 4 EC2 (`bite-db` y `bite-mongo` en paralelo → `bite-api` → `bite-kong`).

`apply` termina en ~2 minutos. Pero los **user_data siguen corriendo** en background (instalan PostgreSQL, Python, Docker, etc.).

**Esperar 8 minutos** antes de continuar. Puedes monitorear el progreso con:

```bash
# Ver log de la DB
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw db_public_ip) 'tail -f /tmp/user-data-db.log'

# Ver log de MongoDB
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw mongo_public_ip) 'tail -f /tmp/user-data-mongo.log'

# Ver log de la API (en otra terminal)
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw api_public_ip) 'tail -f /tmp/user-data-api.log'

# Ver log de Kong
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw kong_public_ip) 'tail -f /tmp/user-data-kong.log'
```

Cuando la API esté lista verás `[bite-api] Setup completo` en su log.

---

## Paso 3 — Smoke Test (verificar que todo funciona)

```bash
# Guardar la IP de Kong en una variable
KONG=$(terraform output -raw kong_public_ip)
echo "Kong IP: $KONG"

# ── Test 1: Request valido → debe retornar HTTP 201 con {"id": N} ──
curl -s -w "\nHTTP %{http_code}\n" -X POST http://$KONG:8000/cloud-accounts/ \
  -H "Content-Type: application/json" \
  -H "apikey: bite-key-prod-001" \
  -d '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","account_id":"100000009999","account_name":"My AWS Account","region":"us-east-1","role_arn":"arn:aws:iam::100000009999:role/BiteCoAccess"}'

# ── Test 2: Sin API key → debe retornar HTTP 401 ──
curl -s -w "\nHTTP %{http_code}\n" -X POST http://$KONG:8000/cloud-accounts/ \
  -H "Content-Type: application/json" \
  -d '{"company_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","account_id":"200000009999","account_name":"NoAuth","region":"us-east-1","role_arn":"arn:aws:iam::200000009999:role/Test"}'

# ── Test 3: Payload invalido → debe retornar HTTP 400 con array de errores ──
curl -s -w "\nHTTP %{http_code}\n" -X POST http://$KONG:8000/cloud-accounts/ \
  -H "Content-Type: application/json" \
  -H "apikey: bite-key-prod-001" \
  -d '{"company_id":"not-a-uuid","account_id":"123","account_name":"X","region":"mars","role_arn":"invalid"}'
```

Si los tres tests retornan los códigos esperados (201, 401, 400), el sistema está funcionando correctamente.

---

## Paso 4 — Preparar JMeter

### 4.1 Obtener IP de Kong y configurar el plan de prueba

```bash
terraform output -raw kong_public_ip
```

Abrir `jmeter/test_plan.jmx` en JMeter GUI (File → Open) y en el nodo raíz **BITE.co ASR - Seguridad y Latencia**:

1. Ir a **"Variables de Usuario"**
2. Cambiar el valor de `KONG_HOST` de `REPLACE_WITH_KONG_IP` por la IP de Kong

### 4.2 Verificar el CSV de account_ids

El archivo `jmeter/account_ids.csv` ya está generado (2000 IDs únicos de 12 dígitos).

Si necesitas regenerarlo:
```bash
python3 -c "
ids = ['account_id']
for i in range(1, 2001):
    ids.append(str(100000000000 + i))
with open('jmeter/account_ids.csv', 'w') as f:
    f.write('\n'.join(ids) + '\n')
print('Generados 2000 account_ids')
"
```

---

## Paso 5 — Correr el experimento

### Opción A: Modo CLI (recomendado para el experimento)

```bash
# Desde la raiz del repo:
mkdir -p report
jmeter -n \
  -t jmeter/test_plan.jmx \
  -l results.jtl \
  -e -o report/ \
  -JKONG_HOST=$(terraform output -raw kong_public_ip)
```

> **Nota**: la bandera `-JKONG_HOST=...` sobreescribe la variable del plan de prueba. Si ya editaste el .jmx con la IP, puedes omitirla.

El test corre **5 minutos** (300 segundos). Al terminar, abre `report/index.html` en el navegador.

### Opción B: Modo GUI (para observar en tiempo real)

1. Abrir JMeter
2. File → Open → seleccionar `jmeter/test_plan.jmx`
3. Verificar que `KONG_HOST` tiene la IP correcta
4. Clic en ▶ (Run)
5. Ver los listeners: Summary Report y Aggregate Report en tiempo real

---

## Paso 6 — Verificar cumplimiento de los ASR

Abrir `report/index.html` y verificar en el **Aggregate Report**:

### ASR Latencia (cumplido si ✓)
| Métrica | Thread Group | Criterio | Resultado esperado |
|---------|-------------|----------|--------------------|
| p95 (95th percentile) | `1 - Legitimo (ASR Latencia)` | **< 3000 ms** | ✓ con controles activos |

### ASR Seguridad (cumplido si ✓)
| Thread Group | Código esperado | Criterio | Resultado esperado |
|-------------|----------------|----------|--------------------|
| `2 - SinAuth (ASR Seguridad)` | **100% HTTP 401** | Kong rechaza sin apikey | ✓ |
| `3 - Malformado (ASR Seguridad)` | **100% HTTP 400** | Flask valida y rechaza | ✓ |
| `4 - SobreCuota (ASR Seguridad)` | **Aparecen HTTP 429** | Kong limita a 2000 req/min (TG4 genera ~5000+/min) | ✓ |

> En el **Summary Report** de JMeter puedes filtrar por thread group para ver los códigos de respuesta.

---

## Paso 7 — Inspeccionar auditoría y logs

### Audit log de PostgreSQL (fuente de verdad relacional)
```bash
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw db_public_ip) \
  "PGPASSWORD=bite_app_pass_123 psql -U bite_app -d bite -c 'SELECT timestamp, source_ip, status, reason FROM audit_log ORDER BY timestamp DESC LIMIT 20;'"
```

### Audit events de MongoDB (Audit Event Store — ASR-SEG)
```bash
# Ver ultimos 20 eventos de seguridad en MongoDB
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw mongo_public_ip) \
  'mongosh "mongodb://localhost:27017/bite_mongo" --eval "db.audit_events.find({},{_id:0,timestamp:1,source_ip:1,status:1,reason:1}).sort({timestamp:-1}).limit(20).forEach(printjson)"'

# Contar eventos por status (401, 429, VALIDATION_FAILED, SUCCESS)
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw mongo_public_ip) \
  'mongosh "mongodb://localhost:27017/bite_mongo" --eval "db.audit_events.aggregate([{\$group:{_id:\"\$status\",count:{\$sum:1}}}]).forEach(printjson)"'

# Ver cuentas en cache (Account Cache — ASR-LAT)
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw mongo_public_ip) \
  'mongosh "mongodb://localhost:27017/bite_mongo" --eval "db.account_cache.countDocuments()"'
```

### Log de auditoría de Kong (file-log plugin)
```bash
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw kong_public_ip) \
  'docker exec kong tail -50 /tmp/kong-audit.log'
```

### Log de la aplicación Flask
```bash
ssh -i ~/vockey.pem ubuntu@$(terraform output -raw api_public_ip) \
  'tail -50 /tmp/app.log'
```

---

## Paso 8 — Destruir la infraestructura

```bash
terraform destroy -auto-approve
```

Esto elimina las 3 EC2 y los 3 security groups. **No hay costos recurrentes** una vez destruido.

---

## Troubleshooting

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `curl: Connection refused` al endpoint | user_data no terminó | Esperar 2-3 minutos más y reintentar |
| Todos los requests dan `502 Bad Gateway` | Kong no puede alcanzar la API | SSH a bite-kong → `docker logs kong` → verificar la IP del upstream en `/etc/kong/kong.yaml` |
| Todos los requests dan `401` aunque la apikey sea válida | Header mal configurado en JMeter | Verificar que el header se llama exactamente `apikey` (minúsculas) |
| La API no responde en el puerto 8080 | Gunicorn no arrancó | SSH a bite-api → `cat /tmp/app.log` → `ps aux | grep gunicorn` |
| PostgreSQL rechaza conexiones | pg_hba.conf no se aplicó | SSH a bite-db → `sudo -u postgres psql -c "SHOW hba_file;"` → revisar el archivo |
| `terraform apply` falla con "InvalidAMIID" | AMI no disponible en us-east-1 | Buscar el AMI ID actual de Ubuntu 22.04 LTS en la consola de AWS y actualizar `main.tf` |
| JMeter no encuentra `account_ids.csv` | Ruta incorrecta | El CSV debe estar en `jmeter/account_ids.csv` (mismo directorio que el .jmx) |
| `rate-limiting` no genera 429 | Test muy corto o pocas threads | El límite es 2000 req/min; TG4 (5 threads sin timer) genera ~5000+ req/min y lo supera en segundos |
| MongoDB no arranca en bite-api | user_data de bite-mongo aún corriendo | El log `/tmp/user-data-api.log` muestra "MongoDB no lista aun" — esperar hasta ver "MongoDB lista!" |
| `mongosh` falla con "command not found" | MongoDB no instaló correctamente | SSH a bite-mongo → `cat /tmp/user-data-mongo.log` → verificar que terminó con "[bite-mongo] Setup completo" |

---

## Estructura del proyecto

```
.
├── main.tf                  # Infraestructura Terraform: 4 SGs + 4 EC2 con user_data embebido
├── outputs.tf               # IPs públicas, SSH commands, URL del endpoint
├── README.md                # Este archivo
└── jmeter/
    ├── test_plan.jmx        # Plan de prueba JMeter (4 thread groups, 5 min cada uno)
    └── account_ids.csv      # 2000 account_ids únicos de 12 dígitos
```

---

## Detalles técnicos del experimento

### Endpoint
```
POST http://<KONG_IP>:8000/cloud-accounts/
```

### Payload válido de ejemplo
```json
{
  "company_id": "11111111-1111-1111-1111-111111111111",
  "account_id": "100000000001",
  "account_name": "Production AWS",
  "region": "us-east-1",
  "role_arn": "arn:aws:iam::123456789012:role/BiteCoAccess"
}
```

### Validaciones aplicadas (Flask)
| Campo | Regla |
|-------|-------|
| `company_id` | UUID válido |
| `account_id` | Exactamente 12 dígitos numéricos |
| `account_name` | 3-50 caracteres |
| `region` | `us-east-1`, `us-east-2`, `us-west-1`, `us-west-2`, `eu-west-1`, `sa-east-1` |
| `role_arn` | Regex: `^arn:aws:iam::\d{12}:role/[A-Za-z0-9_+=,.@-]+$` |

### Plugins de Kong activos
| Plugin | Configuración | Efecto |
|--------|--------------|--------|
| `key-auth` | header `apikey` | 401 si falta o es inválida |
| `rate-limiting` | 2000 req/min, policy local | 429 cuando supera cuota (TG4 a ~5000+/min lo supera; TG1 a ~1200/min no) |
| `request-size-limiting` | 2 KB máximo | 413 si body es muy grande |
| `file-log` | `/tmp/kong-audit.log` | Registra todas las requests |

### Códigos de respuesta esperados por thread group
| Thread Group | Código | Quién lo genera |
|-------------|--------|----------------|
| Legítimo | 201 (creado) / 409 (duplicado) | Flask |
| SinAuth | 401 | Kong (key-auth) |
| Malformado | 400 | Flask (validaciones) |
| SobreCuota | 201/409 primero, luego 429 | Kong (rate-limiting) |
