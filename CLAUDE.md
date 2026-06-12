# CLAUDE.md — StockVendedor (app de vendedores)

> Mapa de arquitectura de **StockVendedor** y de cómo se conecta con su app
> hermana **StockMerger** (la central). Las dos forman un mismo sistema de
> stock / precios / pedidos para mayoristas.

## Qué es

StockVendedor es la app que usan los **vendedores en la calle**. Permite:

- **Bajar el catálogo** publicado por la central (stock + 3 listas de precios:
  Act/Lista 7, Distribuidor, VIP).
- Ver el catálogo y **armar pedidos** eligiendo la lista de precios por pedido.
- **Enviar el pedido** a la central (a la nube, o exportándolo como Excel).
- Generar una plantilla Excel para clientes.

StockMerger es la **central / back-office**: carga stock, fija precios, publica
el catálogo y recibe/confirma los pedidos descontando stock. Vive en su propio
repo (`juliobarbol/stockmerger`).

## Forma del proyecto

- **PWA de un solo archivo**: toda la app está en `index.html` (~5.2k líneas,
  HTML + CSS + JS inline). No hay build step ni bundler.
- Se sirve como **assets estáticos en Cloudflare** (`wrangler.jsonc`,
  `assets.directory: "."`).
- `sw.js` + `manifest.webmanifest` la hacen instalable y offline-first.
- Dependencias externas por CDN: librería de Supabase (jsdelivr), `xlsx`
  (SheetJS), fuentes de Google.

## ⚠️ Trabajar sin quemar tokens — LEER PRIMERO

`index.html` pesa **~197 KB / ~5.220 líneas** (≈50k tokens). **Leerlo entero
gasta mucho contexto innecesariamente.** Pero está limpio y modularizado:
líneas cortas, sin minificados ni base64, banners `// XXX.JS`. La **lectura por
rangos de línea es exacta y barata**. Reglas:

1. **NUNCA** hagas `Read` del archivo completo (sin `offset`/`limit`). Tampoco
   `cat`/`sed` de todo el archivo.
2. Para localizar algo: `Grep -n` del símbolo/función/string → línea exacta →
   `Read` con `offset`/`limit` solo ese tramo (±30 líneas).
3. Para saltar a un módulo: usá la columna **Líneas** de abajo y `Read` ese
   rango directamente.
4. Para **editar**: `Grep` el `old_string` único → `Read` solo esa franja →
   `Edit`. No vuelvas a leer el archivo después de editar.
5. **CSS (`<style>` 19–1114)** y **HTML/markup (1115–1464)** casi nunca hacen
   falta para lógica — no los leas salvo trabajo de estilos o maquetado.
6. Contrato compartido con StockMerger: `Grep` el símbolo en **ambos** repos en
   vez de abrir los dos `index.html`.

### Mapa de navegación (rangos de línea)

| Región | Líneas |
|---|---|
| `<head>` + scripts CDN | 1–18 |
| **CSS** (`<style>`) | 19–1114 |
| **HTML / markup** (body, pestañas) | 1115–1464 |
| Registro del service worker | 1465–1474 |
| **JS principal** (`<script>`) | 1475–5222 |

### Módulos internos (dentro del JS principal)

Cada módulo arranca con un banner `// XXX.JS — ...`. Saltá directo al rango:

| Módulo | Líneas | Rol |
|---|---|---|
| `STATE.JS` | 1475–1856 | Estado global (`state`) + persistencia en localStorage. Incluye `state.clients` (libreta del vendedor). |
| `UTILS.JS` | 1857–1968 | Utilidades compartidas (normalización de claves `_key`, etc.). |
| `IMPORT.JS` | 1969–2222 | Importar el catálogo enviado por la central: `applyVendorData()`. |
| `SUPABASE.JS` | 2223–2661 | Sync **opcional** con la nube: bajar catálogo, subir pedidos (y disparadores de `syncClientsToCloud`). |
| `REALTIME.JS` | 2662–2719 | Supabase Realtime: escucha cambios en `catalog`. |
| `TEMPLATE.JS` | 2720–3267 | Plantilla Excel para clientes (con atajo de libreta y autofiltro). |
| `ORDERS.JS` | 3268–4059 | Armado y gestión de pedidos + envío (push) con cola/idempotencia. `setActiveList` bloquea la lista si el pedido tiene cliente con ficha. |
| `CLIENTS.JS` | 4060–4410 | Libreta de clientes del vendedor (pestaña Clientes, picker del pedido) + `syncClientsToCloud()` (subida a la central). |
| `UI.JS` | 4411–5222 | Navegación entre pestañas y render de cada vista (incl. selector de orden del catálogo). |

> Los rangos se mueven al editar. Si algo no cuadra, reubicá con
> `Grep -n "^// NOMBRE.JS"` y leé el banner.

### Pestañas de la UI

`Home`, `Stock` (catálogo), `Clients` (libreta de clientes), `Order` (armar
pedido), `Orders` (pedidos enviados).

## Persistencia

1. **Local**: `state` (catálogo importado, pedidos, cola de envío) en
   localStorage. Funciona 100% offline.
2. **Nube (opcional)**: Supabase. Si no se configura, la app funciona igual
   usando archivos Excel/JSON para intercambiar con la central.

## Conexión con la nube (Supabase)

Config en `localStorage['sb_config'] = { url, anonKey, ns }`:

- `url` / `anonKey`: del proyecto Supabase.
- **`ns`** = "tienda" / namespace. **Es la clave que une ambas apps**: vendedor
  y central deben usar el mismo `ns` para hablarse.

Cliente creado con `supabase.createClient(url, anonKey)` (ver `scClient()`).

La sección de conexión de la UI (Home) queda **oculta tras la contraseña
`opbayressincnube`** una vez configurada (candado anti-miradas, mismo espíritu
que el gran reset — no es seguridad real). El campo de la key es
`type="password"` y el resumen solo muestra las últimas 4. Igual en la central
(pestaña Archivos). Ver `sbLockRefresh()` en SUPABASE.JS de ambos repos.

### Tablas que toca StockVendedor

| Tabla | Uso desde el vendedor |
|---|---|
| `catalog` | **Lee** la fila de su tienda (`id = ns`): `{ id, payload, updated_at }`. El `payload` es un `vendor_data_v2` (stock + 3 listas). Lo aplica con `applyVendorData()`. |
| `orders` | **Escribe** (insert) un pedido: `{ ns, order_id, vendor, client, payload }`. |
| `clients` | **Escribe** (upsert) la ficha `{ ns, client_id, name, list, vendor }` al crear/editar un cliente de la libreta (las notas privadas NO viajan). La central las baja para su libreta. |

Realtime: se suscribe a `postgres_changes` en `catalog` para refrescar el
catálogo apenas la central publica. (Si el payload supera el límite de 256 KB
de Realtime, solo llega el aviso y se baja con `pullCatalog()`).

Envío de pedidos: `_pushOrderRaw()` es **idempotente** — la constraint única
`(ns, order_id)` hace que un reintento tras corte de red devuelva `23505`
(que tratamos como éxito) y NO duplique. Si falla, el pedido queda en una
**cola local** (`_enqueueOrder`) y se reintenta.

## Cómo se conectan las dos apps

```
            StockMerger (central)                 StockVendedor (vendedores)
            ─────────────────────                 ──────────────────────────
  edita stock + precios
        │
        │ buildVendorPayload()  →  vendor_data_v2 (stock + listas act/dist/vip)
        ▼
   upsert catalog {id: ns, payload}  ───────────►  pullCatalog() / Realtime
                          (Supabase)                 applyVendorData()
                                                          │
                                                     arma pedido
                                                          │
   pullOrders() / Realtime  ◄───────────────────  insert orders {ns, order_id, payload}
        │                       (Supabase)
        ▼
   importa → confirma → descuenta stock → PDF
```

Dos canales equivalentes, según haya nube o no:

- **Con Supabase**: catálogo y pedidos viajan por las tablas `catalog` y
  `orders`, en tiempo real. Misma `ns` en ambos lados.
- **Sin nube (manual)**: la central exporta un `.json`/Excel `vendor_data_v2`;
  el vendedor lo importa (`applyVendorData`). El vendedor exporta el pedido como
  Excel (con hoja oculta `_meta`) y la central lo importa. **Mismo formato y
  mismas funciones** que el camino de nube, para no divergir.

### Contrato de datos compartido

- **Catálogo (central → vendedor)** = `vendor_data_v2`:
  ```
  { _app:"StockMerger", _type:"vendor_data_v2", _version:2, _exportedAt,
    stock:  [ { _key, product, qty, marca, rubro }, ... ],   // en orden catálogo
    prices: { act:{key:{label,marca,rubro,price}}, dist:{...}, vip:{...} },
    order:  { rubros:[...], marcas:[...] } }   // ADITIVO: prioridad del catálogo
  ```
  Lo genera `buildVendorPayload()` (merger) y lo aplica `applyVendorData()`
  (vendedor). `IMPORT.JS` también acepta el formato viejo `vendor_data` (una
  sola lista). **Si cambia el shape, hay que tocar ambos repos.**
- **Pedido (vendedor → central)**: insert en `orders` con
  `{ ns, order_id, vendor, client, payload }`. La central cruza por `_key` los
  productos del `payload` contra su stock y los guarda en `receivedOrders`.
- **`_key`**: clave normalizada de producto. Es el pegamento para cruzar
  catálogo y pedidos. Debe normalizarse igual en ambas apps (`UTILS.JS`).

## Decisiones de producto (de Julio) — fuente de verdad

> ⚠️ **Mantener al día**: si Julio cambia alguna de estas reglas, hay que
> EDITAR esta sección en los CLAUDE.md de **ambos repos** en el mismo cambio.
> Una regla desactualizada acá genera implementaciones contradictorias.

- **Listas de precios**: claves internas `act` / `dist` / `vip` — los nombres
  visibles son "Lista 7", "Distribuidor" y "VIP". Las claves internas NO se
  renombran (romperían pedidos guardados y la conexión entre apps).
- **Fichas de clientes**: cada vendedor tiene SU libreta local (StockVendedor,
  pestaña Clientes); la central tiene la suya con TODOS los clientes
  (StockMerger, overlay 👥 Clientes en la pestaña Pedidos).
- **La lista del pedido la define la ficha del cliente**: al elegir cliente en
  el pedido, su lista se aplica y los chips quedan bloqueados. Para un pedido
  puntual con otra lista se EDITA LA FICHA (no se puede pisar desde el pedido).
- **Notas privadas por lado**: las notas del vendedor no viajan a la central y
  viceversa. Entre apps solo viajan nombre / lista / vendedor (tabla `clients`).
- **Sync de fichas vendedor → central** (tabla `clients`): los borrados NO
  viajan (la libreta de la central es de la central), y si la central editó
  una ficha (`source: 'central'`), lo que mande un vendedor no la pisa.
- **Excel exportados**: siempre con autofiltro en la fila de cabecera. El
  Excel de Stock de la central incluye las 3 listas + precio China.
- **Orden catálogo** (jerarquía rubro → marca → modelo correlativo, con
  números comparados como números: A01 < A01 Core < A02 < A02s < A10): la
  prioridad de rubros y marcas la define la central (botón 📑 en Stock,
  `state.catalogOrder`) y viaja en `vendor_data_v2.order` (campo aditivo).
  Es el orden de los Excel de la central, el orden por defecto del catálogo
  del vendedor y de la plantilla Excel para clientes. Valores no listados van
  después (alfabéticos); sin rubro/marca, al final.
- **Tesorería / Caja (solo central, pestaña 💰 Caja en StockMerger)**: 4
  cuentas fijas — Caja Pesos (ARS), Caja Dólares (USD), Mercado Pago (ARS),
  Lemon (ARS). La **cotización del día** (1 USD = ARS) es un campo editable a
  mano; cada movimiento guarda la cotización con la que se registró, así los
  reportes históricos no cambian al actualizarla. Nada de esto viaja a
  StockVendedor ni a la nube (vive en `state.treasury`, local + backups).
- **Cuenta corriente de clientes (en USD)**: la deuda nace al CONFIRMAR un
  pedido (flag `ctaCte` que se setea desde v26 — los confirmados antes se
  asumen ya cobrados). Los pagos se registran como "cobranza" en Caja (en
  cualquier cuenta; si es en pesos se convierte a USD con la cotización) y
  bajan el saldo automáticamente. Deudas previas a la app → campo
  `saldoInicial` (USD) en la ficha del cliente. El cruce es POR NOMBRE
  normalizado (`_cliKey`), igual que fichas↔pedidos.
- **Comisiones por vendedor**: % editable por vendedor (se guarda en
  `state.treasury.commissions`), aplicado sobre las ventas confirmadas de su
  cartera en el mes (pestaña Caja → Reportes de StockMerger).

## Notas de desarrollo

- **PENDIENTE ACORDADO CON JULIO (2026-06-12): acceso por persona a la nube**
  (Supabase Auth + RLS por `ns`). El plan de ejecución completo vive en
  **`PLAN-ACCESOS.md` del repo de StockMerger** — toca ambas apps (login en
  la sección de conexión, manejo de sesión, gran reset).
- No hay tests ni linters; es HTML+JS plano servido estático.
- Para cambios de catálogo/pedido, verificá la app hermana
  (`juliobarbol/stockmerger`): comparten formato `vendor_data_v2`, esquema de
  `orders` y la normalización de `_key`.
- Todo lo de Supabase es opt-in: el flujo de archivos Excel/JSON debe seguir
  funcionando aunque no haya nube (ver comentarios "PARA EL PROGRAMADOR QUE
  AGREGUE BACKEND" en `IMPORT.JS`).
- **Gran reset** (pasaje de pruebas a uso real): botón al final de Home,
  protegido por la contraseña `opbayresgranreset` (hardcodeada — es un guard
  anti-toque-accidental, no seguridad). Borra TODO lo local de este teléfono
  salvo `sb_config`. Los datos de prueba de la NUBE los borra el gran reset
  de la central (StockMerger, pestaña Archivos), que necesita las policies
  de DELETE de `orders`/`catalog` agregadas a schema.sql desde esta versión.

## Deploy y versión del cache (PWA)

- Se sirve como assets estáticos en Cloudflare desde el repo. `.assetsignore`
  excluye `wrangler.jsonc`, `.assetsignore` y `README.md` (ojo: el readme real
  se llama `READE.md`, así que hoy no queda excluido — detalle menor).
- El service worker (`sw.js`) sirve el HTML **network-first** (las
  actualizaciones del `index.html` llegan solas) y el resto **cache-first**.
- La versión del cache (`const CACHE` en `sw.js`) **debe cambiar en cada
  release** para que el SW se actualice y los usuarios reciban lo nuevo. Lo
  estampa **`build.py`** (`CACHE = '<name>-<timestamp UTC>'`, name de
  `wrangler.jsonc`).
- `build.py` lo corre solo el workflow **`.github/workflows/stamp-sw.yml`** en
  cada push a `main`; si el `sw.js` no venía estampado, lo commitea de vuelta.
  Es la red de seguridad: **no hace falta bump manual**. Igual podés correrlo a
  mano con `python build.py`.
- Si algún día se parte el `index.html` en archivos `.js` externos, ojo: caen
  en la rama cache-first del SW → hay que cache-bustear (`?v=`) o pasarlos a
  network-first para no servir versiones viejas.
