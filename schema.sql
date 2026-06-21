-- schema.sql — Esquema Supabase para StockMerger + StockVendedor
--
-- Este archivo es la FUENTE DE VERDAD del esquema que ambas apps esperan.
-- Correrlo una vez en el SQL Editor del proyecto Supabase. Es idempotente
-- (create … if not exists), se puede re-correr sin romper nada.
--
-- ⚠️ CRÍTICO: la constraint única (ns, order_id) de `orders` es lo que hace
-- idempotente el envío de pedidos (el reintento tras un corte de red devuelve
-- 23505 y NO duplica). Si se redepliega el proyecto sin esa constraint, los
-- pedidos se pueden duplicar EN SILENCIO.

-- ════════════════════════════════════════════════════════════════════
-- catalog — catálogo publicado por la central (1 fila por tienda/ns)
--   escribe: StockMerger (upsert) · lee: StockVendedor
-- ════════════════════════════════════════════════════════════════════
create table if not exists catalog (
  id          text primary key,            -- = ns (namespace de la tienda)
  payload     jsonb not null,              -- vendor_data_v2
  updated_at  timestamptz not null default now()
);

-- ════════════════════════════════════════════════════════════════════
-- orders — pedidos enviados por los vendedores
--   escribe: StockVendedor (insert) · lee: StockMerger (pull incremental)
-- ════════════════════════════════════════════════════════════════════
create table if not exists orders (
  id          uuid primary key default gen_random_uuid(),
  ns          text not null default 'default',
  order_id    text not null,
  vendor      text,
  client      text,
  payload     jsonb not null,
  created_at  timestamptz not null default now()
);

-- Idempotencia de envío (NO BORRAR — ver nota de arriba)
create unique index if not exists orders_ns_order_id_uq on orders (ns, order_id);
-- Pull incremental de la central
create index if not exists orders_ns_created_idx on orders (ns, created_at desc);

-- ════════════════════════════════════════════════════════════════════
-- Sync fila-por-fila entre dispositivos de la central (SYNC_ROWS.JS, beta)
-- Los upserts usan onConflict — los unique índices son OBLIGATORIOS.
-- ════════════════════════════════════════════════════════════════════
create table if not exists catalog_items (
  ns          text not null default 'default',
  item_key    text not null,
  payload     jsonb,
  deleted     boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create unique index if not exists catalog_items_ns_key_uq on catalog_items (ns, item_key);

create table if not exists rubro_multipliers (
  ns          text not null default 'default',
  rubro       text not null,
  payload     jsonb,
  deleted     boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create unique index if not exists rubro_multipliers_ns_rubro_uq on rubro_multipliers (ns, rubro);

create table if not exists settings (
  ns          text not null default 'default',
  key         text not null,
  payload     jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create unique index if not exists settings_ns_key_uq on settings (ns, key);

create table if not exists received_orders (
  ns          text not null default 'default',
  local_id    text not null,
  payload     jsonb,
  deleted     boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create unique index if not exists received_orders_ns_id_uq on received_orders (ns, local_id);

-- ════════════════════════════════════════════════════════════════════
-- clients — fichas de clientes creadas por los vendedores
--   escribe: StockVendedor (upsert al crear/editar una ficha)
--   lee:     StockMerger (pull + Realtime) para sumarlas a su libreta
--   Las notas privadas del vendedor NO viajan (solo nombre/lista/vendedor).
-- ════════════════════════════════════════════════════════════════════
create table if not exists clients (
  ns          text not null default 'default',
  client_id   text not null,               -- id de la ficha en la app del vendedor
  name        text not null,
  list        text not null default 'act', -- 'act' | 'dist' | 'vip'
  vendor      text,                        -- nombre del vendedor que la cargó
  updated_at  timestamptz not null default now()
);
create unique index if not exists clients_ns_client_uq on clients (ns, client_id);

-- ── Límites de tamaño/forma (F5 de la auditoría 2026-06-18) ──
-- Las policies RLS controlan QUIÉN escribe; estos CHECK controlan QUÉ. Evitan
-- que un vendedor autenticado (o un Excel/payload manipulado) infle la base
-- con un payload enorme o textos absurdos. Topes generosos: un pedido real
-- pesa ~4 KB. Idempotentes (drop+add). octet_length sobre el texto del jsonb.
alter table orders  drop constraint if exists orders_payload_size;
alter table orders  add  constraint orders_payload_size check (octet_length(payload::text) <= 1048576); -- 1 MB
alter table orders  drop constraint if exists orders_vendor_len;
alter table orders  add  constraint orders_vendor_len   check (vendor is null or char_length(vendor) <= 200);
alter table orders  drop constraint if exists orders_client_len;
alter table orders  add  constraint orders_client_len   check (client is null or char_length(client) <= 200);
alter table clients drop constraint if exists clients_name_len;
alter table clients add  constraint clients_name_len    check (char_length(name) <= 200);
alter table clients drop constraint if exists clients_vendor_len;
alter table clients add  constraint clients_vendor_len  check (vendor is null or char_length(vendor) <= 200);
alter table clients drop constraint if exists clients_list_chk;
alter table clients add  constraint clients_list_chk    check (list in ('act','dist','vip'));

-- Realtime para avisar a la central al instante (best-effort: si la
-- publication no existe o ya estaba agregada, se ignora el error).
do $$ begin
  alter publication supabase_realtime add table clients;
exception when others then null; end $$;

-- ════════════════════════════════════════════════════════════════════
-- Storage: bucket `backups` (snapshots de la Capa 2 de BACKUPS.JS)
-- Crearlo desde el dashboard (Storage → New bucket → "backups", privado).
-- Sus policies se definen abajo, junto con el resto del RLS (solo central).
-- ════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════
-- AUTH + RLS — acceso por persona (resuelve el hallazgo C1 de AUDITORIA.md)
-- ════════════════════════════════════════════════════════════════════
-- MODELO: cada persona tiene un usuario de Supabase Auth (email + contraseña)
-- y un rol por tienda ('central' o 'vendor') en `user_stores`. Las policies
-- consultan ese rol con el helper store_role(). Sin sesión iniciada,
-- auth.uid() es null → store_role() devuelve null → NO se ve ni se toca nada
-- (la anon key sola ya no abre la base). Alta/baja de personas = crear/borrar
-- el usuario de Auth y su fila en user_stores.

-- Membresía: qué rol tiene cada usuario en cada tienda (ns).
create table if not exists user_stores (
  user_id uuid not null references auth.users(id) on delete cascade,
  ns      text not null,
  role    text not null check (role = 'central' or role = 'vendor'),
  vendor  text,                              -- nombre visible (auditoría/UI)
  primary key (user_id, ns)
);
alter table user_stores enable row level security;
-- Sin policies para authenticated/anon: solo la lee el helper (security definer).
-- ⚠️ CRÍTICO: esta tabla DECIDE quién es central/vendor → si su RLS queda
-- apagado, cualquiera con la anon key puede leer/editar/borrar los roles
-- (escalar a 'central' o dejar a todos sin acceso). Defensa en profundidad:
-- además de RLS, se revocan TODOS los grants de anon/authenticated. El helper
-- store_role() es SECURITY DEFINER, así que sigue leyéndola igual.
revoke all on user_stores from anon, authenticated;

-- Helper: rol del usuario actual en una tienda. SECURITY DEFINER para poder
-- leer user_stores sin exponerla por RLS.
create or replace function public.store_role(p_ns text)
returns text language sql stable security definer set search_path = public as
$$ select role from user_stores where user_id = auth.uid() and ns = p_ns $$;

alter table catalog            enable row level security;
alter table orders             enable row level security;
alter table catalog_items      enable row level security;
alter table rubro_multipliers  enable row level security;
alter table settings           enable row level security;
alter table received_orders    enable row level security;
alter table clients            enable row level security;

-- catalog (id = ns): vendedor LEE; central todo.
drop policy if exists catalog_read   on catalog;
drop policy if exists catalog_insert on catalog;
drop policy if exists catalog_update on catalog;
drop policy if exists catalog_delete on catalog;
create policy catalog_read   on catalog for select to authenticated using (store_role(id) in ('central','vendor'));
create policy catalog_insert on catalog for insert to authenticated with check (store_role(id) = 'central');
create policy catalog_update on catalog for update to authenticated using (store_role(id) = 'central') with check (store_role(id) = 'central');
create policy catalog_delete on catalog for delete to authenticated using (store_role(id) = 'central');

-- orders (ns): vendedor INSERTA; central LEE/BORRA (el borrado lo usa el gran reset).
drop policy if exists orders_read   on orders;
drop policy if exists orders_insert on orders;
drop policy if exists orders_delete on orders;
create policy orders_read   on orders for select to authenticated using (store_role(ns) = 'central');
create policy orders_insert on orders for insert to authenticated with check (store_role(ns) in ('central','vendor'));
create policy orders_delete on orders for delete to authenticated using (store_role(ns) = 'central');

-- clients (ns): vendedor inserta/actualiza/lee; borra solo central (los borrados no viajan).
drop policy if exists clients_all    on clients;
drop policy if exists clients_read   on clients;
drop policy if exists clients_insert on clients;
drop policy if exists clients_update on clients;
drop policy if exists clients_delete on clients;
create policy clients_read   on clients for select to authenticated using (store_role(ns) in ('central','vendor'));
create policy clients_insert on clients for insert to authenticated with check (store_role(ns) in ('central','vendor'));
create policy clients_update on clients for update to authenticated using (store_role(ns) in ('central','vendor')) with check (store_role(ns) in ('central','vendor'));
create policy clients_delete on clients for delete to authenticated using (store_role(ns) = 'central');

-- Tablas solo-central (sync entre dispositivos de la central + backups).
drop policy if exists catalog_items_all     on catalog_items;
drop policy if exists rubro_multipliers_all on rubro_multipliers;
drop policy if exists settings_all          on settings;
drop policy if exists received_orders_all   on received_orders;
create policy catalog_items_all     on catalog_items     for all to authenticated using (store_role(ns) = 'central') with check (store_role(ns) = 'central');
create policy rubro_multipliers_all on rubro_multipliers for all to authenticated using (store_role(ns) = 'central') with check (store_role(ns) = 'central');
create policy settings_all          on settings          for all to authenticated using (store_role(ns) = 'central') with check (store_role(ns) = 'central');
create policy received_orders_all   on received_orders   for all to authenticated using (store_role(ns) = 'central') with check (store_role(ns) = 'central');

-- backups (tabla): solo central.
drop policy if exists bk_read   on backups;
drop policy if exists bk_insert on backups;
drop policy if exists bk_delete on backups;
drop policy if exists backups_all on backups;
create policy backups_all on backups for all to authenticated using (store_role(ns) = 'central') with check (store_role(ns) = 'central');

-- Storage bucket "backups": solo central. El ns es la primera carpeta del path (<ns>/archivo).
drop policy if exists "backups anon select" on storage.objects;
drop policy if exists "backups anon insert" on storage.objects;
drop policy if exists "backups anon delete" on storage.objects;
drop policy if exists "backups central select" on storage.objects;
drop policy if exists "backups central insert" on storage.objects;
drop policy if exists "backups central delete" on storage.objects;
create policy "backups central select" on storage.objects for select to authenticated
  using (bucket_id = 'backups' and store_role((storage.foldername(name))[1]) = 'central');
create policy "backups central insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'backups' and store_role((storage.foldername(name))[1]) = 'central');
create policy "backups central delete" on storage.objects for delete to authenticated
  using (bucket_id = 'backups' and store_role((storage.foldername(name))[1]) = 'central');

-- ALTA / BAJA DE PERSONAS (operar con la service_role key o la Management API):
--   Alta:  crear el usuario en Auth (Admin API) y luego:
--          insert into user_stores(user_id, ns, role, vendor)
--            values ('<uuid>', 'default', 'vendor', 'Nombre Visible');
--          -- Identidad FIJA del vendedor (la app la autocompleta y bloquea):
--          -- guardar nombre + código corto en app_metadata (el usuario NO los
--          -- puede editar). La app del vendedor los lee de la sesión.
--          update auth.users set raw_app_meta_data = raw_app_meta_data
--            || '{"vendor_name":"Nombre Visible","vendor_code":"NOM"}'::jsonb
--            where id = '<uuid>';
--   Baja:  borrar el usuario de Auth (la fila de user_stores cae sola por el
--          ON DELETE CASCADE). Su teléfono queda sin acceso al instante.

-- ════════════════════════════════════════════════════════════════════
-- event_log — bitácora de diagnóstico (errores + contexto + breadcrumbs)
--   escribe: ambas apps (insert, best-effort) · lee: solo central
-- ════════════════════════════════════════════════════════════════════
-- NO es un log de auditoría observable desde la app: es una bitácora REMOTA
-- para diagnosticar cuando alguien reporta un error. Captura los crashes de
-- JS (window.onerror / unhandledrejection) y los fallos de las operaciones
-- riesgosas, con stack completo, contexto del dispositivo (navegador, versión
-- del cache PWA, online/offline) y "migas de pan" (las últimas acciones antes
-- del error, en meta.breadcrumbs). Cada evento muestra al usuario un `ref`
-- corto (ej. A3F9) que lo cita en la base. Append-only: nadie edita/borra
-- desde la app. Se consulta por la Management API (ver schema/CLAUDE.md).
create table if not exists event_log (
  id          uuid primary key default gen_random_uuid(),
  ref         text,                                  -- código corto mostrado al usuario (ej. A3F9)
  ns          text not null default 'default',
  app         text,                                  -- 'merger' | 'vendor'
  event       text not null,                         -- código del evento (ej. 'error.uncaught', 'sync.fail')
  severity    text not null default 'info' check (severity in ('info','warn','error')),
  summary     text,                                  -- descripción breve legible
  meta        jsonb,                                 -- stack, contexto del dispositivo, breadcrumbs
  user_id     uuid default auth.uid(),               -- quién (se completa solo al insertar)
  actor       text,                                  -- nombre/código visible (de la sesión)
  role        text,                                  -- 'central' | 'vendor'
  occurred_at timestamptz not null default now(),    -- cuándo ocurrió en el dispositivo
  created_at  timestamptz not null default now()     -- cuándo llegó a la base
);

create index if not exists event_log_ns_created_idx on event_log (ns, created_at desc);
create index if not exists event_log_ref_idx        on event_log (ref);
create index if not exists event_log_ns_sev_idx     on event_log (ns, severity, created_at desc);
create index if not exists event_log_ns_event_idx   on event_log (ns, event);

-- Topes de tamaño/forma (igual criterio que orders/clients): evitan inflar la base.
alter table event_log drop constraint if exists event_log_meta_size;
alter table event_log add  constraint event_log_meta_size    check (meta is null or octet_length(meta::text) <= 262144); -- 256 KB
alter table event_log drop constraint if exists event_log_summary_len;
alter table event_log add  constraint event_log_summary_len  check (summary is null or char_length(summary) <= 4000);
alter table event_log drop constraint if exists event_log_event_len;
alter table event_log add  constraint event_log_event_len    check (char_length(event) <= 120);
alter table event_log drop constraint if exists event_log_ref_len;
alter table event_log add  constraint event_log_ref_len      check (ref is null or char_length(ref) <= 32);

-- RLS: cualquiera logueado de la tienda INSERTA su evento; LEE solo central.
-- Sin policies de update/delete → append-only (nadie edita ni borra desde la app).
alter table event_log enable row level security;
drop policy if exists event_log_insert on event_log;
drop policy if exists event_log_read   on event_log;
create policy event_log_insert on event_log for insert to authenticated with check (store_role(ns) in ('central','vendor'));
create policy event_log_read   on event_log for select to authenticated using (store_role(ns) = 'central');
