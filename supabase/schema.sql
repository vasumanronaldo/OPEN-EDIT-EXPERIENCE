-- ════════════════════════════════════════════════════════════════
--  EDIT EXPERIENCE — Private Inventory Platform
--  Supabase schema · v1 backbone
--  Run in the Supabase SQL editor. Test RLS before going live.
-- ════════════════════════════════════════════════════════════════

-- ───────── enums ─────────
create type user_role        as enum ('admin','reseller','client');
create type piece_status     as enum ('available','reserved','sold','returned');
create type consigner_type   as enum ('store','reseller_own','external');
create type movement_type    as enum ('added','removed','sold','returned','price_change','reserved','settled');
create type movement_status  as enum ('pending','approved','denied');
create type access_scope     as enum ('full','curated');

-- ───────── profiles (extends auth.users) ─────────
create table profiles (
  id          uuid primary key references auth.users on delete cascade,
  role        user_role not null default 'client',
  display_name text not null,
  handle      text unique,
  created_by  uuid references profiles(id),
  created_at  timestamptz default now()
);

-- account-level rules the ADMIN sets when issuing a reseller account
create table reseller_settings (
  reseller_id         uuid primary key references profiles(id) on delete cascade,
  client_cap          int  not null default 10,      -- max B2B clients
  min_margin_pct      numeric default 0,             -- price-floor enforcement
  approval_threshold  numeric,                        -- pieces above this need admin OK to expose
  can_expose_store_stock boolean default false,
  created_at          timestamptz default now()
);

-- ───────── client access (many-to-many: a client can be keyed to many resellers) ─────────
create table client_access (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references profiles(id) on delete cascade,
  reseller_id uuid not null references profiles(id) on delete cascade,
  access_key  text not null unique,        -- issued key (e.g. EX-7741-K)
  link_slug   text not null unique,        -- private storefront link
  scope       access_scope not null default 'full',
  status      text not null default 'active',  -- active | revoked
  granted_by  uuid references profiles(id),    -- the reseller
  expires_at  timestamptz,
  created_at  timestamptz default now(),
  unique(client_id, reseller_id)
);

-- ───────── pieces (the vault / master inventory) ─────────
create table pieces (
  id            uuid primary key default gen_random_uuid(),
  brand         text not null,
  model         text not null,
  ref           text,
  category      text,
  condition     text,
  year          text,
  accessories   text,
  cost          numeric not null default 0,   -- ADMIN ONLY. never exposed to clients.
  consigner     consigner_type not null default 'store',
  owner_reseller_id uuid references profiles(id),  -- set when consigner = reseller_own
  status        piece_status not null default 'available',
  created_by    uuid references profiles(id),
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- ───────── consignments (store stock placed with a reseller) ─────────
create table consignments (
  id           uuid primary key default gen_random_uuid(),
  piece_id     uuid not null references pieces(id) on delete cascade,
  reseller_id  uuid not null references profiles(id) on delete cascade,
  agreed_price numeric not null,                -- what reseller owes store when sold
  status       text not null default 'held',    -- held | sold | returned | settled
  created_at   timestamptz default now(),
  unique(piece_id, reseller_id)
);

-- ───────── listings (a piece surfaced by a reseller at a price) ─────────
create table listings (
  id           uuid primary key default gen_random_uuid(),
  piece_id     uuid not null references pieces(id) on delete cascade,
  reseller_id  uuid not null references profiles(id) on delete cascade,
  basis        numeric not null default 0,   -- reseller cost basis. RESELLER + ADMIN only.
  client_price numeric not null,             -- what clients see
  visible      boolean not null default true,
  created_at   timestamptz default now(),
  unique(piece_id, reseller_id)
);

-- per-client curation, used only when client_access.scope = 'curated'
create table listing_visibility (
  listing_id uuid not null references listings(id) on delete cascade,
  client_id  uuid not null references profiles(id) on delete cascade,
  visible    boolean not null default true,
  primary key (listing_id, client_id)
);

-- ───────── movements (the ledger AND the approval queue) ─────────
create table movements (
  id              uuid primary key default gen_random_uuid(),
  piece_id        uuid references pieces(id) on delete set null,
  reseller_id     uuid not null references profiles(id) on delete cascade,
  type            movement_type not null,
  proposed_by     uuid not null references profiles(id),  -- admin (store) or reseller
  counterparty_id uuid not null references profiles(id),  -- the side that must approve
  owed_delta      numeric not null default 0,  -- effect on "owed to store"
  value_delta     numeric not null default 0,  -- effect on consignment value
  consign_delta   int     not null default 0,  -- effect on consignment count
  note            text,
  status          movement_status not null default 'pending',
  resolved_by     uuid references profiles(id),
  resolved_at     timestamptz,
  created_at      timestamptz default now()
);

-- ───────── reservations (client requests a piece) ─────────
create table reservations (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  client_id  uuid not null references profiles(id) on delete cascade,
  status     text not null default 'requested',  -- requested | confirmed | cancelled
  created_at timestamptz default now()
);

-- ════════════════════════════════════════════════════════════════
--  helpers
-- ════════════════════════════════════════════════════════════════
create or replace function app_role() returns user_role
  language sql stable security definer set search_path=public as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function is_admin() returns boolean
  language sql stable security definer set search_path=public as $$
  select coalesce((select role='admin' from profiles where id=auth.uid()), false);
$$;

-- ════════════════════════════════════════════════════════════════
--  RLS — the walls
--  Rule of thumb: admin sees all. Reseller sees only own rows.
--  Clients NEVER touch base tables; they read the catalog function only.
-- ════════════════════════════════════════════════════════════════
alter table profiles            enable row level security;
alter table reseller_settings   enable row level security;
alter table client_access       enable row level security;
alter table pieces              enable row level security;
alter table consignments        enable row level security;
alter table listings            enable row level security;
alter table listing_visibility  enable row level security;
alter table movements           enable row level security;
alter table reservations        enable row level security;

-- profiles: see self; admin sees all; reseller sees their own clients; client sees their resellers
create policy p_self      on profiles for select using (id = auth.uid());
create policy p_admin     on profiles for all    using (is_admin()) with check (is_admin());
create policy p_res_cli   on profiles for select using (
  exists (select 1 from client_access ca where ca.reseller_id = auth.uid() and ca.client_id = profiles.id));
create policy p_cli_res   on profiles for select using (
  exists (select 1 from client_access ca where ca.client_id = auth.uid() and ca.reseller_id = profiles.id));

-- reseller_settings: admin manages; reseller reads own
create policy rs_admin on reseller_settings for all    using (is_admin()) with check (is_admin());
create policy rs_own   on reseller_settings for select using (reseller_id = auth.uid());

-- client_access: admin all; reseller manages own; client reads own
create policy ca_admin on client_access for all    using (is_admin()) with check (is_admin());
create policy ca_res   on client_access for all    using (reseller_id = auth.uid()) with check (reseller_id = auth.uid());
create policy ca_cli   on client_access for select using (client_id = auth.uid());

-- pieces: admin all; reseller sees own + consigned-to-them (no client access)
create policy pc_admin on pieces for all using (is_admin()) with check (is_admin());
create policy pc_res   on pieces for select using (
  app_role()='reseller' and (
    owner_reseller_id = auth.uid()
    or exists (select 1 from consignments c where c.piece_id = pieces.id and c.reseller_id = auth.uid())
  ));

-- consignments / listings / listing_visibility / movements: admin all; reseller own
create policy cg_admin on consignments for all using (is_admin()) with check (is_admin());
create policy cg_res   on consignments for all using (reseller_id = auth.uid()) with check (reseller_id = auth.uid());

create policy ls_admin on listings for all using (is_admin()) with check (is_admin());
create policy ls_res   on listings for all using (reseller_id = auth.uid()) with check (reseller_id = auth.uid());

create policy lv_admin on listing_visibility for all using (is_admin()) with check (is_admin());
create policy lv_res   on listing_visibility for all using (
  exists (select 1 from listings l where l.id = listing_visibility.listing_id and l.reseller_id = auth.uid()))
  with check (
  exists (select 1 from listings l where l.id = listing_visibility.listing_id and l.reseller_id = auth.uid()));

create policy mv_admin on movements for all    using (is_admin()) with check (is_admin());
create policy mv_res   on movements for select using (reseller_id = auth.uid() or counterparty_id = auth.uid() or proposed_by = auth.uid());

-- reservations: client own; reseller sees reservations on their listings; admin all
create policy rv_admin on reservations for all    using (is_admin()) with check (is_admin());
create policy rv_cli   on reservations for all    using (client_id = auth.uid()) with check (client_id = auth.uid());
create policy rv_res   on reservations for select using (
  exists (select 1 from listings l where l.id = reservations.listing_id and l.reseller_id = auth.uid()));

-- ════════════════════════════════════════════════════════════════
--  CLIENT CATALOG — the only way a client reads inventory.
--  Returns safe columns only. cost / basis / consigner never selected.
-- ════════════════════════════════════════════════════════════════
create or replace function get_my_catalog(p_slug text)
returns table (
  listing_id uuid, brand text, model text, ref text, category text,
  condition text, year text, accessories text, client_price numeric, status piece_status
) language sql stable security definer set search_path=public as $$
  select l.id, pc.brand, pc.model, pc.ref, pc.category, pc.condition,
         pc.year, pc.accessories, l.client_price, pc.status
  from client_access ca
  join listings l  on l.reseller_id = ca.reseller_id and l.visible
  join pieces  pc  on pc.id = l.piece_id
  left join listing_visibility lv on lv.listing_id = l.id and lv.client_id = ca.client_id
  where ca.link_slug = p_slug
    and ca.client_id = auth.uid()
    and ca.status = 'active'
    and (ca.expires_at is null or ca.expires_at > now())
    and (ca.scope = 'full' or coalesce(lv.visible, false));
$$;

-- ════════════════════════════════════════════════════════════════
--  TWO-WAY APPROVAL — no stock change commits without both sides.
--  All stock movement goes through these. Never write `movements`
--  or flip `pieces.status` directly from the app.
-- ════════════════════════════════════════════════════════════════

-- propose: caller's role decides who must approve (the other side)
create or replace function propose_movement(
  p_piece uuid, p_reseller uuid, p_type movement_type,
  p_owed numeric default 0, p_value numeric default 0,
  p_consign int default 0, p_note text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_role user_role := app_role(); v_counterparty uuid; v_id uuid;
begin
  if v_role = 'reseller' then
    p_reseller := auth.uid();
    select id into v_counterparty from profiles where role='admin' order by created_at limit 1;
  elsif v_role = 'admin' then
    v_counterparty := p_reseller;            -- the reseller approves
  else
    raise exception 'only admin or reseller may propose movements';
  end if;

  insert into movements(piece_id,reseller_id,type,proposed_by,counterparty_id,
                        owed_delta,value_delta,consign_delta,note)
  values (p_piece,p_reseller,p_type,auth.uid(),v_counterparty,p_owed,p_value,p_consign,p_note)
  returning id into v_id;
  return v_id;
end; $$;

-- resolve: only the counterparty may approve/deny. effects apply atomically on approve.
create or replace function resolve_movement(p_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare m movements%rowtype;
begin
  select * into m from movements where id = p_id;
  if not found then raise exception 'movement not found'; end if;
  if m.status <> 'pending' then raise exception 'already resolved'; end if;
  if auth.uid() <> m.counterparty_id then raise exception 'only the counterparty may resolve'; end if;

  if p_approve then
    if m.type = 'sold' and m.piece_id is not null then
      update pieces set status='sold', updated_at=now() where id = m.piece_id;
      update consignments set status='sold'   where piece_id=m.piece_id and reseller_id=m.reseller_id;
    elsif m.type = 'returned' and m.piece_id is not null then
      update pieces set status='returned', updated_at=now() where id = m.piece_id;
      update consignments set status='returned' where piece_id=m.piece_id and reseller_id=m.reseller_id;
    elsif m.type = 'settled' then
      update consignments set status='settled' where piece_id=m.piece_id and reseller_id=m.reseller_id;
    end if;
    update movements set status='approved', resolved_by=auth.uid(), resolved_at=now() where id = p_id;
  else
    update movements set status='denied',   resolved_by=auth.uid(), resolved_at=now() where id = p_id;
  end if;
end; $$;

-- ───────── live balances (the Splitwise numbers) ─────────
create or replace view reseller_balances as
select reseller_id,
  coalesce(sum(consign_delta) filter (where status='approved'),0) as pieces_on_consignment,
  coalesce(sum(value_delta)   filter (where status='approved'),0) as value_on_consignment,
  coalesce(sum(owed_delta)    filter (where status='approved'),0) as owed_to_store
from movements
group by reseller_id;

-- Enable Realtime on these for the live Airtable feel:
--   movements, pieces, listings, reservations, consignments
-- (Supabase dashboard → Database → Replication, or alter publication supabase_realtime add table ...)
