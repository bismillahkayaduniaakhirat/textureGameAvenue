-- =========================================================
-- OOT Street: partner coffee shops ("tempat kopi") shown in the game.
-- Each active row gets a teal marker in front of the shop; walking into it
-- shows the shop name, address, an Instagram button and a Maps button.
--
-- Admin: Table Editor -> game_places.
--   name / instagram (without @) / address / lat / lon (Google Maps: right-click
--   the pin -> copy the coordinates) / active = true to show it.
--   sponsor_until: last day the ad is shown (empty = no end date).
--   note: internal only (deal, price, contact); players never see it.
-- Only pins inside the game map (central Kota Kediri, about 1.5 x 1.5 km around
-- Texture Coffee) can be shown; pins outside it are skipped by the game.
--
-- Stats for selling ads: select * from game_place_stats;
-- Run this whole file once in the SQL Editor. Safe to re-run.
-- =========================================================

create table if not exists public.game_places (
  id            bigint generated always as identity primary key,
  name          text not null,
  instagram     text,
  address       text,
  lat           double precision not null,
  lon           double precision not null,
  active        boolean not null default false,
  sponsor_until date,
  note          text,
  created_at    timestamptz not null default now()
);

create table if not exists public.game_place_hits (
  id        bigint generated always as identity primary key,
  place_id  bigint not null references public.game_places(id) on delete cascade,
  kind      text not null check (kind in ('view', 'ig', 'maps')),
  player_id uuid,
  day       date not null default (now() at time zone 'Asia/Jakarta')::date,
  at        timestamptz not null default now()
);
-- one count per player per place per kind per day (guests are not deduplicated)
create unique index if not exists game_place_hits_once on public.game_place_hits (place_id, kind, player_id, day);

alter table public.game_places     enable row level security;
alter table public.game_place_hits enable row level security;
-- no policies: players read through game_places_list() only, so note stays private

create or replace function public.game_places_list()
returns table (id bigint, name text, instagram text, address text, lat double precision, lon double precision)
language sql stable security definer set search_path = public as $$
  select id, name, nullif(trim(both '@ ' from coalesce(instagram, '')), ''), address, lat, lon
    from public.game_places
   where active and (sponsor_until is null or sponsor_until >= (now() at time zone 'Asia/Jakarta')::date)
   order by id
$$;

create or replace function public.game_place_hit(p_place bigint, p_kind text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('view', 'ig', 'maps') then return; end if;
  if not exists (select 1 from public.game_places where id = p_place and active) then return; end if;
  insert into public.game_place_hits (place_id, kind, player_id) values (p_place, p_kind, auth.uid())
  on conflict do nothing;
end $$;

-- Admin report (SQL Editor / Table Editor only; not exposed to the API)
create or replace view public.game_place_stats as
select p.id, p.name, p.active, p.sponsor_until,
       count(*) filter (where h.kind = 'view')                    as mampir,
       count(distinct h.player_id) filter (where h.kind = 'view') as pemain_unik,
       count(*) filter (where h.kind = 'ig')                      as klik_ig,
       count(*) filter (where h.kind = 'maps')                    as klik_maps,
       max(h.at)                                                  as terakhir
  from public.game_places p
  left join public.game_place_hits h on h.place_id = p.id
 group by p.id
 order by mampir desc;

revoke all on public.game_places, public.game_place_hits, public.game_place_stats from anon, authenticated;
revoke all on function public.game_places_list(), public.game_place_hit(bigint, text) from public;
grant execute on function public.game_places_list(), public.game_place_hit(bigint, text) to anon, authenticated;

-- ---------- seed ----------
-- Texture Coffee: active (test partner). Others: coffee shops found in OpenStreetMap,
-- inactive prospects; the admin fills instagram/address and ticks active once they pay.
insert into public.game_places (name, instagram, address, lat, lon, active, note)
select * from (values
  ('Texture Coffee', 'texturecoffee_', 'Jl. Dr. Wahidin Sudirohusodo No.01, Pakelan, Kota Kediri', -7.8198536, 112.0120063, true, 'Mitra uji coba'),
  ('Kopi Berontoseno', null, null, -7.8195413, 112.0126151, false, 'Prospek dari OpenStreetMap, di dalam peta game'),
  ('Kedai Kopi',       null, null, -7.8172616, 112.0115774, false, 'Prospek dari OpenStreetMap, di dalam peta game (nama perlu dicek)'),
  ('Cozy Cafe',        null, null, -7.8143240, 112.0108163, false, 'Prospek dari OpenStreetMap, di dalam peta game'),
  ('TOMORO Coffee',    null, null, -7.8100431, 112.0044670, false, 'Prospek dari OpenStreetMap, DI LUAR peta game'),
  ('Talk Kopi Kediri', null, null, -7.8199830, 112.0204914, false, 'Prospek dari OpenStreetMap, DI LUAR peta game'),
  ('Warung Kopi Merdeka', null, null, -7.8309257, 112.0196191, false, 'Prospek dari OpenStreetMap, DI LUAR peta game'),
  ('Cafe Water Torn',  null, null, -7.8194425, 112.0293280, false, 'Prospek dari OpenStreetMap, DI LUAR peta game'),
  ('Tautan Coffee',    null, null, -7.8276819, 112.0337199, false, 'Prospek dari OpenStreetMap, DI LUAR peta game'),
  ('Kedai Kopi Moe Kediri', 'kedai.kopimoe', 'Jl. Soekarno Hatta No.22, Katang, Sukorejo, Ngasem', -7.8076997, 112.0397898, false, 'Prospek dari OpenStreetMap, DI LUAR peta game')
) v(name, instagram, address, lat, lon, active, note)
where not exists (select 1 from public.game_places g where g.name = v.name);
