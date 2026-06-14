# aeontech-tenant-db

Estructura completa de la base de datos tenant de AeonTech — sistema de facturación electrónica FE 4.4 Costa Rica.

## Propósito

Este repositorio mantiene el esquema SQL de `tenant_template`, la base de datos maestra que se clona al crear un nuevo tenant en el sistema AeonTech. Cada commit representa un estado consistente del esquema listo para instalar.

## Contenido

| Archivo | Descripción |
|---------|-------------|
| `tenant_template_schema.sql` | Dump completo: tablas, funciones (SPs), índices, constraints, triggers |

## Uso

### Instalación en servidor nuevo

```bash
# 1. Crear la base de datos
createdb -U postgres tenant_template

# 2. Aplicar el esquema
psql -U postgres -d tenant_template -f tenant_template_schema.sql
```

### Clonar para un nuevo tenant

```sql
-- En PostgreSQL, desde psql como superuser
CREATE DATABASE tenant_nuevo TEMPLATE tenant_template;
```

## Stack

- **Motor**: PostgreSQL 16
- **Patrón**: Multi-tenant por base de datos (una BD por empresa)
- **Lógica**: Stored Procedures / Funciones PL/pgSQL (sin queries directas desde el backend)
- **Normativa**: FE 4.4 Hacienda Costa Rica (ATV)

## Módulos incluidos en el esquema

- Empresas, Sucursales, Cajas, Usuarios, Roles, Permisos
- Clientes, Funcionarios, Proveedores
- Productos, Servicios, Categorías, Bodegas (inventario)
- Medios de Pago
- Documentos Electrónicos (FE, TE, NC, ND) + consecutivos
- Facturas Recibidas (Mensaje Receptor)
- Auditoría

## Flujo de actualización

Cada vez que se modifica `tenant_template` localmente:

```bash
pg_dump -U postgres -d tenant_template --schema-only --no-owner --no-acl -f tenant_template_schema.sql
git add tenant_template_schema.sql
git commit -m "feat/fix: descripción del cambio"
git push origin main
```
