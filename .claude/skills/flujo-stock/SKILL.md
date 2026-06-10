---
name: flujo-stock
description: Forma de trabajar con StockMerger y StockVendedor (sistema de stock/precios/pedidos de Julio). Usar SIEMPRE que haya que implementar, arreglar, mejorar o publicar algo en estas apps. Define el flujo completo - implementar de forma autónoma, mergear directo a main, verificar el deploy y reportar en lenguaje simple (Julio no es programador y no tiene entorno de pruebas).
---

# Flujo de trabajo — StockMerger y StockVendedor

## Quién es el usuario

Julio **no es programador** y **no tiene entorno de pruebas**: la única forma
que tiene de probar algo es abrir las apps ya publicadas en su teléfono. Esto
define todo el flujo:

- Vos sos el único control de calidad antes de publicar.
- Las explicaciones tienen que estar en castellano simple.

## Autonomía: hacé todo lo que puedas vos

Tenés autorización permanente de Julio para:

1. Implementar el cambio completo (en uno o ambos repos según haga falta).
2. Commitear con mensajes claros.
3. **Mergear directo a `main` y pushear**, sin preguntar y sin crear PRs
   (PR solo si Julio lo pide explícitamente).
4. Si un push falla por red, reintentar hasta 4 veces con espera creciente
   (2s, 4s, 8s, 16s).

No dejes trabajo sin publicar ni termines con "¿querés que lo suba?": subilo.
Pará a preguntar SOLO si hay que elegir entre opciones que cambian lo que ve
el usuario final, o si el cambio puede afectar datos ya guardados (pedidos,
precios, backups).

## Cómo implementar (calidad sin tests)

No hay tests, linters ni servidor local. El control de calidad sos vos:

1. Seguí las reglas de lectura por rangos del CLAUDE.md de cada repo ANTES
   de tocar `index.html` (son archivos gigantes; nunca leerlos enteros).
2. Si el cambio toca catálogo, pedidos, precios o `_key`: revisá la app
   hermana (`juliobarbol/stockmerger` ↔ `juliobarbol/stockvendedor`).
   Comparten formato y, si divergen, se rompen los pedidos.
3. Antes de mergear, releé el diff completo (`git diff main`) buscando
   errores de sintaxis o llaves sin cerrar — un error de JS deja la app
   entera en blanco para todos los usuarios.
4. Cambios visuales: no podés verlos corriendo la app; sé conservador y no
   reestructures más de lo pedido.

## Después de mergear

1. Verificá que el workflow estampó la versión del cache: `git pull` y
   chequear que `const CACHE` en `sw.js` tenga timestamp nuevo. Si en ~2
   minutos no aparece, corré `python build.py`, commiteá y pusheá.
   **Ahorro de tokens**: si la sesión encadena varios cambios publicados,
   verificá el estampado UNA SOLA VEZ, después del último merge — no tras
   cada uno.
2. Si Julio pide varios cambios en un mensaje, implementalos TODOS y
   publicalos en una sola tanda (un solo ciclo de commit + merge +
   verificación), no un ciclo por cambio.
3. Decile a Julio qué mirar en la app publicada para confirmar que el cambio
   funciona (1 o 2 pasos concretos, ej.: "entrá a la pestaña Pedidos y fijate
   que ahora diga Lista 7"). Es la única prueba real que existe.

## Cómo hablarle a Julio

- **Reportes CORTOS por defecto** (pedido explícito de Julio para ahorrar
  tokens): qué cambió en palabras de usuario + 1 o 2 pasos para probarlo.
  Apuntá a 3–6 líneas en total. Contexto técnico, advertencias largas o
  listas de detalles SOLO si Julio los pide o si hay un riesgo real que
  deba conocer.
- Castellano simple, sin jerga. Nada de "ternario", "refactor", "payload",
  "endpoint", "fast-forward". Si un término técnico es inevitable, explicalo
  con una comparación cotidiana.
- Empezá siempre por el resultado: qué cambió en la app, en palabras de
  usuario ("ahora la etiqueta de los pedidos dice Lista 7").
- Detalles de código solo si los pide.
- Para él, mergear a main = publicar: decí "ya está publicado, en unos
  minutos llega a los teléfonos" en vez de hablar de ramas y merges.
- Nunca le pidas que corra comandos, tests o herramientas de programador.

## Datos que no se tocan sin tocar ambos repos

- Formato `vendor_data_v2` (catálogo central → vendedor).
- Esquema de `orders` (`ns, order_id, vendor, client, payload`).
- Esquema de `clients` (`ns, client_id, name, list, vendor`) — fichas de
  clientes vendedor → central. El esquema completo vive en `schema.sql`
  (idéntico en ambos repos; si se toca, actualizar los dos).
- Normalización de `_key` (UTILS.JS en ambos repos).
- Claves internas de listas `act` / `dist` / `vip`: los nombres visibles son
  "Lista 7", "Distribuidor" y "VIP", pero las claves internas NO se renombran
  (romperían los pedidos guardados y la conexión entre las apps).

## Decisiones de producto

Las reglas de negocio que definió Julio (fichas de clientes, lista bloqueada
por ficha, notas privadas, etc.) están en la sección **"Decisiones de
producto"** del CLAUDE.md de cada repo. Leelas antes de tocar esas áreas, y
si Julio cambia alguna, **editá esa sección en ambos repos en el mismo
cambio** para que no queden reglas viejas que generen confusión.
