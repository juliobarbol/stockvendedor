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

-- Realtime para avisar a la central al instante (best-effort: si la
-- publication no existe o ya estaba agregada, se ignora el error).
do $$ begin
  alter publication supabase_realtime add table clients;
exception when others then null; end $$;

-- ════════════════════════════════════════════════════════════════════
-- Storage: bucket `backups` (snapshots de la Capa 2 de BACKUPS.JS)
-- Crearlo desde el dashboard (Storage → New bucket → "backups", privado)
-- con policies de insert/select/delete para el rol anon (o el rol que
-- corresponda cuando se active Auth).
-- ════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════
-- RLS — estado actual y endurecimiento pendiente
-- ════════════════════════════════════════════════════════════════════
-- ESTADO ACTUAL (arranque): policies abiertas. Cualquiera con la anon key
-- puede leer/escribir cualquier ns. Aceptado como riesgo de arranque para
-- un negocio chico con la key solo en las apps propias, pero ES EL PRINCIPAL
-- PENDIENTE DE SEGURIDAD (ver AUDITORIA.md, hallazgo C1).
alter table catalog            enable row level security;
alter table orders             enable row level security;
alter table catalog_items      enable row level security;
alter table rubro_multipliers  enable row level security;
alter table settings           enable row level security;
alter table received_orders    enable row level security;
alter table clients            enable row level security;

do $$ begin
  create policy "catalog_read"   on catalog for select using (true);
  create policy "catalog_insert" on catalog for insert with check (true);
  create policy "catalog_update" on catalog for update using (true) with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "orders_read"   on orders for select using (true);
  create policy "orders_insert" on orders for insert with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "catalog_items_all"     on catalog_items     for all using (true) with check (true);
  create policy "rubro_multipliers_all" on rubro_multipliers for all using (true) with check (true);
  create policy "settings_all"          on settings          for all using (true) with check (true);
  create policy "received_orders_all"   on received_orders   for all using (true) with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "clients_all" on clients for all using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ENDURECIMIENTO RECOMENDADO (fase futura, requiere Supabase Auth):
--   1. Crear tabla de membresía: user_stores(user_id uuid, ns text).
--   2. Reemplazar las policies de arriba por filtrado real por ns, p. ej.:
--        create policy "orders_read" on orders for select
--          using (ns in (select ns from user_stores where user_id = auth.uid()));
--   3. Vendedores: solo INSERT en orders + SELECT en catalog de su ns.
--      Central: todo lo demás, solo de su ns.
--   4. Rotar la anon key después del cambio (la actual está distribuida).
