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

- **PWA de un solo archivo**: toda la app está en `index.html` (~4.5k líneas,
  HTML + CSS + JS inline). No hay build step ni bundler.
- Se sirve como **assets estáticos en Cloudflare** (`wrangler.jsonc`,
  `assets.directory: "."`).
- `sw.js` + `manifest.webmanifest` la hacen instalable y offline-first.
- Dependencias externas por CDN: librería de Supabase (jsdelivr), `xlsx`
  (SheetJS), fuentes de Google.

## ⚠️ Trabajar sin quemar tokens — LEER PRIMERO

`index.html` pesa **~172 KB / ~4.540 líneas** (≈45k tokens). **Leerlo entero
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
5. **CSS (`<style>` 19–1034)** y **HTML/markup (1035–1302)** casi nunca hacen
   falta para lógica — no los leas salvo trabajo de estilos o maquetado.
6. Contrato compartido con StockMerger: `Grep` el símbolo en **ambos** repos en
   vez de abrir los dos `index.html`.

### Mapa de navegación (rangos de línea)

| Región | Líneas |
|---|---|
| `<head>` + scripts CDN | 1–18 |
| **CSS** (`<style>`) | 19–1034 |
| **HTML / markup** (body, pestañas) | 1035–1302 |
| **JS principal** (`<script>`) | 1313–4539 |

### Módulos internos (dentro del JS principal)

Cada módulo arranca con un banner `// XXX.JS — ...`. Saltá directo al rango:

| Módulo | Líneas | Rol |
|---|---|---|
| `STATE.JS` | 1315–1665 | Estado global (`state`) + persistencia en localStorage. |
| `UTILS.JS` | 1666–1758 | Utilidades compartidas (normalización de claves `_key`, etc.). |
| `IMPORT.JS` | 1759–2009 | Importar el catálogo enviado por la central: `applyVendorData()`. |
| `SUPABASE.JS` | 2010–2435 | Sync **opcional** con la nube: bajar catálogo, subir pedidos. |
| `REALTIME.JS` | 2436–2493 | Supabase Realtime: escucha cambios en `catalog`. |
| `TEMPLATE.JS` | 2494–3010 | Plantilla Excel para clientes. |
| `ORDERS.JS` | 3011–3778 | Armado y gestión de pedidos + envío (push) con cola/idempotencia. |
| `UI.JS` | 3779–4538 | Navegación entre pestañas y render de cada vista. |

> Los rangos se mueven al editar. Si algo no cuadra, reubicá con
> `Grep -n "^// NOMBRE.JS"` y leé el banner.

### Pestañas de la UI

`Home`, `Stock` (catálogo), `Order` (armar pedido), `Orders` (pedidos
enviados).

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
    stock:  [ { _key, product, qty, marca, rubro }, ... ],
    prices: { act:{key:{label,marca,rubro,price}}, dist:{...}, vip:{...} } }
  ```
  Lo genera `buildVendorPayload()` (merger) y lo aplica `applyVendorData()`
  (vendedor). `IMPORT.JS` también acepta el formato viejo `vendor_data` (una
  sola lista). **Si cambia el shape, hay que tocar ambos repos.**
- **Pedido (vendedor → central)**: insert en `orders` con
  `{ ns, order_id, vendor, client, payload }`. La central cruza por `_key` los
  productos del `payload` contra su stock y los guarda en `receivedOrders`.
- **`_key`**: clave normalizada de producto. Es el pegamento para cruzar
  catálogo y pedidos. Debe normalizarse igual en ambas apps (`UTILS.JS`).

## Notas de desarrollo

- No hay tests ni linters; es HTML+JS plano servido estático.
- Para cambios de catálogo/pedido, verificá la app hermana
  (`juliobarbol/stockmerger`): comparten formato `vendor_data_v2`, esquema de
  `orders` y la normalización de `_key`.
- Todo lo de Supabase es opt-in: el flujo de archivos Excel/JSON debe seguir
  funcionando aunque no haya nube (ver comentarios "PARA EL PROGRAMADOR QUE
  AGREGUE BACKEND" en `IMPORT.JS`).

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
