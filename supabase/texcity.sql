-- =====================================================================
-- TEX CITY — Tex Coins economy (brief "TEX CITY"), run AFTER schema.sql,
-- kasir_pin.sql and places.sql. Safe to re-run.
--
--  * Seasons (game_seasons): S1, S2, S3. Edit dates in Table Editor.
--  * Wallet per player per season: earned (Season Earned, never goes down)
--    and spent. Available = all earned - all spent.
--  * Missions T1-T7 (in order) + bonus B1-B3 (after T7). Rewards paid once,
--    only by the server, and only after a minimum play time.
--  * Cashier codes: F&B Rupiah + merch items -> Tex Coins + digital items.
--    Code valid 24 hours, one use.
--  * OOT Wardrobe: buy digital items with coins, equip one item per slot.
--  * Milestones per season (first eligible player wins, one prize per account).
--  * Admin = a cashier row with is_admin = true (admin.html).
-- Every value the owner may change lives in game_settings (Table Editor):
--   fnb_rate, merch_rate, mission_rewards, mission_min_secs, milestones, tex_items.
-- Old coins (coins_play / coins_nota / OOT STORE vouchers) are kept as they are,
-- but no longer count for the new leaderboard.
-- =====================================================================

-- ---------- settings ----------
insert into public.game_settings (key, value) values
  ('fnb_rate',   '10'),    -- Tex Coins per Rp15.000 food & beverage (see rescale_koin.sql)
  ('merch_rate', '10'),    -- Tex Coins per Rp15.000 merchandise (same as F&B)
  ('receipt_hours', '24'), -- a cashier code must be redeemed within this many hours
  ('mission_rewards', '{"T1":3000,"T2":5000,"T3":6000,"T4":7000,"T5":8000,"T6":9000,"T7":12000,"B1":3000,"B2":3000,"B3":4000}'),
  ('mission_min_secs', '{"T1":15,"T2":25,"T3":40,"T4":40,"T5":60,"T6":25,"T7":25,"B1":8,"B2":3,"B3":25}'),
  ('milestones', '[{"n":1,"coins":250000,"prize":"Jersey OOT-SS25 \"Pas Presse de Vivre\""},
                   {"n":2,"coins":300000,"prize":"Kaos OOT-SS26 (hitam atau putih)"}]'),
  -- Merch catalogue. rp = official physical price, coins = OOT Wardrobe price.
  -- physical=false hides it from the cashier (sold out); digital=false hides it from the Wardrobe.
  ('tex_items', '[
    {"id":"s1_jersey","season":"S1","slot":"outfit","name":"OOT-SS25 \"Pas Presse de Vivre\" Jersey","rp":125000,"coins":20000,"physical":true,"digital":true},
    {"id":"s1_perfume","season":"S1","slot":"fragrance","name":"OOT-SS25 \"Roche Seche\" Perfume","rp":65000,"coins":15000,"physical":true,"digital":true},
    {"id":"s1_sun_gray","season":"S1","slot":"eyewear","name":"OOT-SS25 \"Vue Seche\" Sunglasses Smoked Gray","rp":17500,"coins":10000,"physical":true,"digital":true},
    {"id":"s1_sun_amber","season":"S1","slot":"eyewear","name":"OOT-SS25 \"Vue Seche\" Sunglasses Burnt Amber","rp":17500,"coins":10000,"physical":true,"digital":true},
    {"id":"s1_ring","season":"S1","slot":"hand","name":"OOT-SS25 \"Pepouze\" Ring","rp":35000,"coins":8000,"physical":true,"digital":true},
    {"id":"s1_key","season":"S1","slot":"keychain","name":"OOT-SS25 \"Accroche Crue\" Keychain","rp":165000,"coins":8000,"physical":false,"digital":true},
    {"id":"s2_tee_black","season":"S2","slot":"outfit","name":"OOT-SS26 \"Piece Noir\" Tshirt Black","rp":110000,"coins":18000,"physical":true,"digital":true},
    {"id":"s2_tee_white","season":"S2","slot":"outfit","name":"OOT-SS26 \"Chronique\" Tshirt White","rp":110000,"coins":18000,"physical":true,"digital":true},
    {"id":"s2_tumbler","season":"S2","slot":"drink","name":"OOT-SS26 \"Achier Recyclee\" Tumbler","rp":75000,"coins":12000,"physical":true,"digital":true},
    {"id":"s2_key","season":"S2","slot":"keychain","name":"OOT-SS26 \"Kit Accroche\" Keychain","rp":55000,"coins":6000,"physical":true,"digital":true}
  ]')
on conflict (key) do nothing;

-- ---------- seasons ----------
create table if not exists public.game_seasons (
  id        text primary key,
  name      text not null,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,
  note      text
);
comment on table public.game_seasons is 'Season TEX CITY. Season aktif = yang sedang berjalan menurut starts_at / ends_at. Data season lama tetap tersimpan.';
insert into public.game_seasons (id, name, starts_at, ends_at, note) values
  ('S1', 'Season 1', '2026-11-01 00:00+07', '2027-03-01 00:00+07', 'Nov 2026 - Feb 2027'),
  ('S2', 'Season 2', '2027-03-01 00:00+07', '2027-05-20 00:00+07', 'Mar - Mei 2027'),
  ('S3', 'Season 3', '2027-05-20 00:00+07', '2027-09-01 00:00+07', 'Rilis 20 Mei 2027 (OOT SS27)')
on conflict (id) do nothing;

-- Season running now (null between seasons).
create or replace function public.game_season_now() returns text
language sql stable security definer set search_path = public as
$$ select id from public.game_seasons where now() >= starts_at and now() < ends_at order by starts_at desc limit 1 $$;

-- Season to book spending on: the running one, else the latest that has started.
create or replace function public.game_season_book() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(public.game_season_now(),
    (select id from public.game_seasons where starts_at <= now() order by starts_at desc limit 1),
    (select id from public.game_seasons order by starts_at limit 1))
$$;

-- ---------- wallet ----------
create table if not exists public.game_wallet (
  player_id  uuid not null references public.game_players(id) on delete cascade,
  season_id  text not null references public.game_seasons(id),
  earned     int  not null default 0 check (earned >= 0),
  spent      int  not null default 0 check (spent >= 0),
  last_gain  timestamptz,
  primary key (player_id, season_id)
);

alter table public.game_coin_log add column if not exists season_id text;
alter table public.game_players  add column if not exists equip jsonb not null default '{}';

-- ---------- missions ----------
create table if not exists public.game_missions_done (
  player_id  uuid not null references public.game_players(id) on delete cascade,
  mission_id text not null,
  season_id  text,
  reward     int  not null,
  done_at    timestamptz not null default now(),
  primary key (player_id, mission_id)
);
create table if not exists public.game_mission_runs (
  player_id  uuid primary key references public.game_players(id) on delete cascade,
  mission_id text not null,
  started_at timestamptz not null default now()
);

-- ---------- items ----------
create table if not exists public.game_items (
  player_id  uuid not null references public.game_players(id) on delete cascade,
  item_id    text not null,
  source     text not null,          -- coins | nota
  ref        text,
  created_at timestamptz not null default now(),
  primary key (player_id, item_id)
);

-- ---------- receipts: F&B Rupiah + merch items ----------
alter table public.game_receipts add column if not exists fnb_rp    int;
alter table public.game_receipts add column if not exists merch_rp  int;
alter table public.game_receipts add column if not exists items     jsonb;
alter table public.game_receipts add column if not exists season_id text;
alter table public.game_receipts add column if not exists expires_at timestamptz;
alter table public.game_receipts drop constraint if exists game_receipts_kind_check;
alter table public.game_receipts add constraint game_receipts_kind_check check (kind in ('food', 'merch', 'mix'));

-- ---------- milestones ----------
create table if not exists public.game_milestone_winners (
  season_id  text not null references public.game_seasons(id),
  n          int  not null,
  player_id  uuid not null references public.game_players(id) on delete cascade,
  earned     int  not null,
  prize      text not null,
  reached_at timestamptz not null default now(),
  handed_at  timestamptz,            -- owner fills this when the prize is handed over
  primary key (season_id, n),
  unique (season_id, player_id)
);

-- ---------- admin flag on cashiers ----------
alter table public.game_cashiers add column if not exists is_admin boolean not null default false;

-- ---------- RLS (read-own; writes only through functions) ----------
alter table public.game_seasons           enable row level security;
alter table public.game_wallet            enable row level security;
alter table public.game_missions_done     enable row level security;
alter table public.game_mission_runs      enable row level security;
alter table public.game_items             enable row level security;
alter table public.game_milestone_winners enable row level security;
drop policy if exists game_seasons_read on public.game_seasons;
create policy game_seasons_read on public.game_seasons for select using (true);
grant select on public.game_seasons to anon, authenticated;

-- ---------- helpers ----------
create or replace function public.game_item(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select e.value from jsonb_array_elements(public.game_setting('tex_items')) e(value) where e.value ->> 'id' = p_id
$$;

create or replace function public.game_available(p_uid uuid) returns int
language sql stable security definer set search_path = public as
$$ select coalesce(sum(earned - spent), 0)::int from public.game_wallet where player_id = p_uid $$;

create or replace function public.game_main_done(p_uid uuid) returns int
language sql stable security definer set search_path = public as
$$ select count(*)::int from public.game_missions_done where player_id = p_uid and mission_id like 'T%' $$;

-- Award milestones for the running season. First eligible player wins each one;
-- one prize per account per season; all 7 main missions required.
create or replace function public.game_check_milestones(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  s text := public.game_season_now();
  e int;
  m jsonb;
begin
  if s is null or public.game_main_done(p_uid) < 7 then return; end if;
  select earned into e from public.game_wallet where player_id = p_uid and season_id = s;
  if coalesce(e, 0) = 0 then return; end if;
  for m in select x.value from jsonb_array_elements(public.game_setting('milestones')) x(value) order by (x.value ->> 'n')::int loop
    exit when exists (select 1 from public.game_milestone_winners where season_id = s and player_id = p_uid);
    if e >= (m ->> 'coins')::int then
      insert into public.game_milestone_winners (season_id, n, player_id, earned, prize)
      values (s, (m ->> 'n')::int, p_uid, e, m ->> 'prize')
      on conflict do nothing;
    end if;
  end loop;
end $$;

-- Credit coins to the running season (internal).
create or replace function public.game_credit(p_uid uuid, p_amount int, p_source text, p_ref text) returns text
language plpgsql security definer set search_path = public as $$
declare s text := public.game_season_now();
begin
  if s is null then raise exception 'SEASON_TUTUP'; end if;
  if p_amount > 0 then
    insert into public.game_wallet (player_id, season_id, earned, last_gain) values (p_uid, s, p_amount, now())
    on conflict (player_id, season_id) do update set earned = game_wallet.earned + p_amount, last_gain = now();
    insert into public.game_coin_log (player_id, source, amount, ref, season_id) values (p_uid, p_source, p_amount, left(p_ref, 40), s);
  end if;
  return s;
end $$;

-- ---------- player API ----------
create or replace function public.game_me()
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  p public.game_players;
  s text := public.game_season_now();
  w public.game_wallet;
  rnk int;
begin
  if uid is null then return null; end if;
  select * into p from public.game_players where id = uid;
  if not found then return json_build_object('profile', false); end if;
  select * into w from public.game_wallet where player_id = uid and season_id = s;
  select count(*) + 1 into rnk from public.game_wallet q
   where q.season_id = s and (q.earned > coalesce(w.earned, 0) or (q.earned = coalesce(w.earned, 0) and q.last_gain < w.last_gain));
  return json_build_object(
    'profile', true, 'name', p.name, 'phone', p.phone, 'email', p.email,
    'season', (select json_build_object('id', id, 'name', name, 'starts_at', starts_at, 'ends_at', ends_at) from public.game_seasons where id = s),
    'available', public.game_available(uid),
    'earned', coalesce(w.earned, 0),
    'spent', (select coalesce(sum(spent), 0) from public.game_wallet where player_id = uid),
    'rank', case when coalesce(w.earned, 0) > 0 then rnk end,
    'missions', coalesce((select json_agg(mission_id order by done_at) from public.game_missions_done where player_id = uid), '[]'),
    'items', coalesce((select json_agg(item_id order by created_at) from public.game_items where player_id = uid), '[]'),
    'equip', p.equip,
    'milestone', (select json_build_object('n', n, 'prize', prize, 'reached_at', reached_at) from public.game_milestone_winners where player_id = uid and season_id = s),
    'milestones_taken', coalesce((select json_agg(n) from public.game_milestone_winners where season_id = s), '[]'),
    'legacy_total', p.coins_play + p.coins_nota);
end $$;

-- Start a mission (the server notes the time; rewards need a minimum play time).
create or replace function public.game_mission_start(p_mission text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  m text := upper(btrim(coalesce(p_mission, '')));
  k int;
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if not exists (select 1 from public.game_players where id = uid) then raise exception 'PROFIL_KOSONG'; end if;
  if public.game_setting('mission_rewards') -> m is null then raise exception 'MISI_TIDAK_ADA'; end if;
  if exists (select 1 from public.game_missions_done where player_id = uid and mission_id = m) then raise exception 'MISI_SUDAH_SELESAI'; end if;
  if m like 'T%' then
    k := substr(m, 2)::int;
    if k > 1 and not exists (select 1 from public.game_missions_done where player_id = uid and mission_id = 'T' || (k - 1)) then
      raise exception 'MISI_BELUM_TERBUKA';
    end if;
  elsif public.game_main_done(uid) < 7 then
    raise exception 'MISI_BELUM_TERBUKA';
  end if;
  insert into public.game_mission_runs (player_id, mission_id, started_at) values (uid, m, now())
  on conflict (player_id) do update set mission_id = excluded.mission_id, started_at = now();
  return json_build_object('mission', m, 'started', true);
end $$;

-- Finish a mission: pays the reward once.
create or replace function public.game_mission_done(p_mission text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  m text := upper(btrim(coalesce(p_mission, '')));
  r public.game_mission_runs;
  reward int := (public.game_setting('mission_rewards') ->> m)::int;
  mins int := coalesce((public.game_setting('mission_min_secs') ->> m)::int, 10);
  s text;
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if reward is null then raise exception 'MISI_TIDAK_ADA'; end if;
  select * into r from public.game_mission_runs where player_id = uid for update;
  if not found or r.mission_id <> m then raise exception 'MISI_BELUM_DIMULAI'; end if;
  if now() - r.started_at < make_interval(secs => mins) then raise exception 'MISI_TERLALU_CEPAT'; end if;
  if exists (select 1 from public.game_missions_done where player_id = uid and mission_id = m) then raise exception 'MISI_SUDAH_SELESAI'; end if;
  s := public.game_credit(uid, reward, 'mission', m);
  insert into public.game_missions_done (player_id, mission_id, season_id, reward) values (uid, m, s, reward);
  delete from public.game_mission_runs where player_id = uid;
  perform public.game_check_milestones(uid);
  return json_build_object('mission', m, 'reward', reward, 'available', public.game_available(uid));
end $$;

-- Redeem a cashier code: coins to the wallet + digital items unlocked.
create or replace function public.game_redeem(p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9-]', '', 'g'));
  r public.game_receipts;
  fails int;
  it jsonb;
  unlocked text[] := '{}';
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if not exists (select 1 from public.game_players where id = uid) then raise exception 'PROFIL_KOSONG'; end if;
  select count(*) into fails from public.game_redeem_fails where player_id = uid and at > now() - interval '1 hour';
  if fails >= 8 then raise exception 'TERLALU_BANYAK_COBA'; end if;
  select * into r from public.game_receipts where code = c for update;
  if not found then
    insert into public.game_redeem_fails (player_id) values (uid);
    raise exception 'KODE_TIDAK_ADA';
  end if;
  if r.redeemed_at is not null then raise exception 'KODE_SUDAH_DIPAKAI'; end if;
  if r.season_id is null or r.expires_at is null or r.expires_at < now() then raise exception 'KODE_KADALUARSA'; end if;
  if r.season_id is distinct from public.game_season_now() then raise exception 'KODE_KADALUARSA'; end if;
  update public.game_receipts set redeemed_by = uid, redeemed_at = now() where code = c;
  perform public.game_credit(uid, r.coins, 'nota', c);
  for it in select x.value from jsonb_array_elements(coalesce(r.items, '[]')) x(value) loop
    insert into public.game_items (player_id, item_id, source, ref) values (uid, it ->> 'id', 'nota', c) on conflict do nothing;
    unlocked := unlocked || (it ->> 'id');
  end loop;
  perform public.game_check_milestones(uid);
  return json_build_object('coins', r.coins, 'kind', r.kind, 'items', to_json(unlocked), 'available', public.game_available(uid));
end $$;

-- OOT Wardrobe: buy a digital item with coins (permanent).
create or replace function public.game_wardrobe_buy(p_item text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  it jsonb := public.game_item(p_item);
  cost int;
  s text := public.game_season_book();
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if it is null or not coalesce((it ->> 'digital')::boolean, false) then raise exception 'ITEM_TIDAK_ADA'; end if;
  perform 1 from public.game_players where id = uid for update;
  if not found then raise exception 'PROFIL_KOSONG'; end if;
  if exists (select 1 from public.game_items where player_id = uid and item_id = p_item) then raise exception 'ITEM_SUDAH_ADA'; end if;
  cost := (it ->> 'coins')::int;
  if public.game_available(uid) < cost then raise exception 'KOIN_KURANG'; end if;
  insert into public.game_wallet (player_id, season_id, spent) values (uid, s, cost)
  on conflict (player_id, season_id) do update set spent = game_wallet.spent + cost;
  insert into public.game_items (player_id, item_id, source) values (uid, p_item, 'coins');
  insert into public.game_coin_log (player_id, source, amount, ref, season_id) values (uid, 'wardrobe', -cost, p_item, s);
  return json_build_object('item', p_item, 'cost', cost, 'available', public.game_available(uid));
end $$;

-- Equip owned items: {"outfit": "s1_jersey", "eyewear": null, ...}. Free.
create or replace function public.game_equip(p_equip jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  slot text;
  v jsonb;
  res jsonb := '{}';
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  for slot, v in select * from jsonb_each(coalesce(p_equip, '{}')) loop
    continue when slot not in ('outfit', 'eyewear', 'fragrance', 'hand', 'keychain', 'drink') or jsonb_typeof(v) <> 'string';
    continue when public.game_item(v #>> '{}') ->> 'slot' is distinct from slot;
    continue when not exists (select 1 from public.game_items where player_id = uid and item_id = v #>> '{}');
    res := res || jsonb_build_object(slot, v);
  end loop;
  update public.game_players set equip = res where id = uid;
  if not found then raise exception 'PROFIL_KOSONG'; end if;
  return res;
end $$;

-- Public leaderboard: Season Earned of the running season. Names only.
create or replace function public.game_leaderboard(p_limit int default 50)
returns table (rank bigint, name text, total int, is_me boolean)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by w.earned desc, w.last_gain asc nulls last), p.name, w.earned, p.id = auth.uid()
    from public.game_wallet w join public.game_players p on p.id = w.player_id
   where w.season_id = public.game_season_now() and w.earned > 0
   order by 1
   limit least(greatest(coalesce(p_limit, 50), 1), 100)
$$;

-- ---------- cashier API ----------
-- New receipt: F&B Rupiah (after discount) + merch items with quantity.
-- p_items = [{"id":"s1_jersey","qty":1}, ...]. Prices come from tex_items, never from the page.
create or replace function public.game_k_receipt2(p_token text, p_fnb_rp int, p_items jsonb, p_note text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  cid int := public.game_cashier_id(p_token);
  s text := public.game_season_now();
  fnb int := greatest(coalesce(p_fnb_rp, 0), 0);
  merch int := 0;
  q int;
  e jsonb;
  it jsonb;
  clean jsonb := '[]';
  coins_f int;
  coins_m int;
  r public.game_receipts;
begin
  if s is null then raise exception 'SEASON_TUTUP'; end if;
  if fnb > 50000000 then raise exception 'POIN_SALAH'; end if;
  for e in select x.value from jsonb_array_elements(coalesce(p_items, '[]')) x(value) loop
    it := public.game_item(e ->> 'id');
    if it is null or not coalesce((it ->> 'physical')::boolean, false) then raise exception 'ITEM_TIDAK_ADA'; end if;
    q := coalesce((e ->> 'qty')::int, 1);
    if q < 1 or q > 20 then raise exception 'JUMLAH_SALAH'; end if;
    merch := merch + (it ->> 'rp')::int * q;
    clean := clean || jsonb_build_array(jsonb_build_object('id', it ->> 'id', 'qty', q, 'name', it ->> 'name'));
  end loop;
  -- superseded by supabase/rescale_koin.sql (Rp15.000 = 10 coins); keep that file last when re-running
  coins_f := floor(fnb / 15000.0) * (public.game_setting('fnb_rate') #>> '{}')::int;
  coins_m := floor(merch / 15000.0) * (public.game_setting('merch_rate') #>> '{}')::int;
  if coins_f + coins_m <= 0 then raise exception 'NOMINAL_KECIL'; end if;
  insert into public.game_receipts (code, kind, points, coins, note, cashier_id, fnb_rp, merch_rp, items, season_id, expires_at)
  values (public.game_code('TEX', 8),
          case when merch = 0 then 'food' when fnb = 0 then 'merch' else 'mix' end,
          fnb + merch, coins_f + coins_m, left(p_note, 80), cid, fnb, merch, clean, s,
          now() + make_interval(hours => (public.game_setting('receipt_hours') #>> '{}')::int))
  returning * into r;
  return json_build_object('code', r.code, 'coins', r.coins, 'coins_fnb', coins_f, 'coins_merch', coins_m,
    'fnb_rp', fnb, 'merch_rp', merch, 'items', clean, 'expires_at', r.expires_at);
end $$;

-- Players with contact data, Season Earned and progress (prize handover).
create or replace function public.game_k_players(p_token text, p_limit int default 50)
returns json
language plpgsql stable security definer set search_path = public as $$
declare s text := public.game_season_now();
begin
  perform public.game_cashier_id(p_token);
  return coalesce((select json_agg(t) from (
    select row_number() over (order by coalesce(w.earned, 0) desc, w.last_gain asc nulls last, p.created_at) as rank,
           p.name, p.phone, p.email, coalesce(w.earned, 0) as earned, public.game_available(p.id) as available,
           (select coalesce(sum(spent), 0) from public.game_wallet x where x.player_id = p.id) as spent,
           public.game_main_done(p.id) as main_done,
           (select count(*) from public.game_items i where i.player_id = p.id) as items,
           (select m.prize from public.game_milestone_winners m where m.player_id = p.id and m.season_id = s) as prize
      from public.game_players p left join public.game_wallet w on w.player_id = p.id and w.season_id = s
     order by 1 limit least(greatest(coalesce(p_limit, 50), 1), 300)) t), '[]');
end $$;

-- Admin dashboard (cashier with is_admin = true).
create or replace function public.game_k_admin(p_token text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  cid int := public.game_cashier_id(p_token);
  s text := public.game_season_now();
begin
  if not exists (select 1 from public.game_cashiers where id = cid and is_admin) then raise exception 'BUKAN_ADMIN'; end if;
  return json_build_object(
    'season', (select row_to_json(x) from public.game_seasons x where id = s),
    'seasons', (select json_agg(x order by starts_at) from public.game_seasons x),
    'players', (select count(*) from public.game_players),
    'players_season', (select count(*) from public.game_wallet where season_id = s and earned > 0),
    'earned', (select coalesce(sum(earned), 0) from public.game_wallet where season_id = s),
    'spent', (select coalesce(sum(spent), 0) from public.game_wallet where season_id = s),
    'receipts_made', (select count(*) from public.game_receipts where season_id = s),
    'receipts_redeemed', (select count(*) from public.game_receipts where season_id = s and redeemed_at is not null),
    'receipt_coins', (select coalesce(sum(coins), 0) from public.game_receipts where season_id = s and redeemed_at is not null),
    'missions', (select json_object_agg(mission_id, n) from (select mission_id, count(*) n from public.game_missions_done group by 1) m),
    'milestones', (select json_agg(json_build_object('season', w.season_id, 'n', w.n, 'prize', w.prize, 'name', p.name, 'phone', p.phone,
                     'earned', w.earned, 'reached_at', w.reached_at, 'handed_at', w.handed_at) order by w.season_id, w.n)
                     from public.game_milestone_winners w join public.game_players p on p.id = w.player_id),
    'receipts', (select json_agg(t) from (
        select r.code, r.kind, r.fnb_rp, r.merch_rp, r.coins, r.items, r.note, r.created_at, r.expires_at, r.redeemed_at,
               c.name as cashier, p.name as player
          from public.game_receipts r
          left join public.game_cashiers c on c.id = r.cashier_id
          left join public.game_players p on p.id = r.redeemed_by
         where r.season_id is not null
         order by r.created_at desc limit 60) t),
    'settings', (select json_object_agg(key, value) from public.game_settings
                  where key in ('fnb_rate', 'merch_rate', 'receipt_hours', 'mission_rewards', 'milestones', 'tex_items')));
end $$;

-- ---------- grants ----------
revoke all on function
  public.game_season_now(), public.game_season_book(), public.game_item(text), public.game_available(uuid),
  public.game_main_done(uuid), public.game_check_milestones(uuid), public.game_credit(uuid, int, text, text),
  public.game_me(), public.game_mission_start(text), public.game_mission_done(text), public.game_redeem(text),
  public.game_wardrobe_buy(text), public.game_equip(jsonb), public.game_leaderboard(int),
  public.game_k_receipt2(text, int, jsonb, text), public.game_k_players(text, int), public.game_k_admin(text)
from public, anon, authenticated;
grant execute on function public.game_season_now(), public.game_leaderboard(int) to anon, authenticated;
grant execute on function
  public.game_me(), public.game_mission_start(text), public.game_mission_done(text), public.game_redeem(text),
  public.game_wardrobe_buy(text), public.game_equip(jsonb)
to authenticated;
grant execute on function
  public.game_k_receipt2(text, int, jsonb, text), public.game_k_players(text, int), public.game_k_admin(text)
to anon, authenticated;

-- Make the owner an admin (admin.html logs in with the same name + PIN as kasir.html):
--   update public.game_cashiers set is_admin = true where name = 'NAMA_OWNER';
