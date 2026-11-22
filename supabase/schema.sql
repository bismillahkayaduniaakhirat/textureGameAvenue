-- =====================================================================
-- OOT Street — game backend (Supabase / Postgres)
-- Every object is prefixed game_ so it stays apart from the future app
-- tables in the same project. Users come from Supabase Auth (auth.users),
-- so the app can reuse the same accounts later.
--
-- Clients never write tables directly: RLS is on with read-own policies
-- only, and every write goes through the SECURITY DEFINER functions below.
-- Safe to re-run (idempotent). Cashier PIN login lives in kasir_pin.sql (run after this file).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- settings (edit values here or in Table Editor) ----------
create table if not exists public.game_settings (
  key   text primary key,
  value jsonb not null
);
insert into public.game_settings (key, value) values
  ('daily_cap',        '20'),                              -- max game coins per player per day (WIB)
  ('play_max_call',    '20'),                              -- max coins one game_add_play call may add
  ('points_per_coin',  '500'),                             -- Texture Points per coin (10.000 = 20 koin)
  ('merch_mult',       '1'),                               -- coin multiplier for merch receipts (not decided yet)
  ('period_end',       '"2026-12-31T23:59:59+07:00"'),     -- leaderboard closes here
  ('voucher_days',     '7'),
  ('prizes', '[{"rank":1,"name":"Kaos OOT","min":600},{"rank":2,"name":"Jersey OOT","min":500}]'),
  ('store', '[
     {"id":"D10","name":"Voucher Diskon 10% semua merch OOT","cost":150},
     {"id":"KEY","name":"Gratis Keychain OOT (min. belanja Rp100rb)","cost":300},
     {"id":"RNG","name":"Diskon 20% Cincin \"Pēpo uze\"","cost":350},
     {"id":"GLS","name":"Diskon 20% Kacamata \"For Life\"","cost":400},
     {"id":"PRF","name":"Diskon 20% Parfum OOT","cost":400},
     {"id":"JRS","name":"Diskon 25% Jersey OOT \"de Vivre\"","cost":500}
   ]')
on conflict (key) do nothing;

create or replace function public.game_setting(p_key text) returns jsonb
language sql stable security definer set search_path = public as
$$ select value from public.game_settings where key = p_key $$;

-- ---------- players ----------
create table if not exists public.game_players (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 2 and 24),
  phone       text not null unique check (phone ~ '^62[0-9]{8,13}$'),   -- normalized 62xxxx
  email       text,
  coins_play  int  not null default 0,   -- lifetime coins from gameplay
  coins_nota  int  not null default 0,   -- lifetime coins from Texture / merch receipts
  spent       int  not null default 0,   -- spent in OOT STORE (does NOT lower rank)
  skin        text not null default 'default',
  last_gain   timestamptz,               -- tie-break: whoever reached the score first ranks higher
  created_at  timestamptz not null default now()
);

create table if not exists public.game_daily (
  player_id uuid not null references public.game_players(id) on delete cascade,
  day       date not null,
  earned    int  not null default 0,
  primary key (player_id, day)
);

-- ---------- receipts (nota) issued by staff ----------
create table if not exists public.game_receipts (
  code         text primary key,
  kind         text not null check (kind in ('food','merch')),
  points       int  not null check (points > 0),
  coins        int  not null check (coins >= 0),
  skin         text,
  note         text,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  redeemed_by  uuid references public.game_players(id),
  redeemed_at  timestamptz
);

create table if not exists public.game_redeem_fails (
  player_id uuid not null references public.game_players(id) on delete cascade,
  at        timestamptz not null default now()
);
create index if not exists game_redeem_fails_idx on public.game_redeem_fails (player_id, at);

-- ---------- store vouchers ----------
create table if not exists public.game_vouchers (
  code        text primary key,
  player_id   uuid not null references public.game_players(id) on delete cascade,
  item_id     text not null,
  item_name   text not null,
  cost        int  not null,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  used_by     uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

-- ---------- audit log + staff ----------
create table if not exists public.game_coin_log (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.game_players(id) on delete cascade,
  source     text not null,     -- play | nota | merch | store
  amount     int  not null,
  ref        text,
  created_at timestamptz not null default now()
);

create table if not exists public.game_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note    text
);

-- ---------- RLS: read-own only; all writes via functions ----------
alter table public.game_settings     enable row level security;
alter table public.game_players      enable row level security;
alter table public.game_daily        enable row level security;
alter table public.game_receipts     enable row level security;
alter table public.game_redeem_fails enable row level security;
alter table public.game_vouchers     enable row level security;
alter table public.game_coin_log     enable row level security;
alter table public.game_staff        enable row level security;

drop policy if exists game_settings_read on public.game_settings;
create policy game_settings_read on public.game_settings for select using (true);
drop policy if exists game_players_own on public.game_players;
create policy game_players_own on public.game_players for select using (id = auth.uid());
drop policy if exists game_vouchers_own on public.game_vouchers;
create policy game_vouchers_own on public.game_vouchers for select using (player_id = auth.uid());
drop policy if exists game_log_own on public.game_coin_log;
create policy game_log_own on public.game_coin_log for select using (player_id = auth.uid());

-- Table grants (new projects no longer grant API access automatically).
-- Read-only; RLS above still limits rows to the caller's own.
grant select on public.game_settings to anon, authenticated;
grant select on public.game_players, public.game_vouchers, public.game_coin_log to authenticated;

-- ---------- helpers ----------
create or replace function public.game_code(p_prefix text, p_len int) returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- no 0/O/1/I
  b bytea := gen_random_bytes(p_len);
  s text := '';
begin
  for i in 0 .. p_len - 1 loop
    s := s || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return p_prefix || '-' || substr(s, 1, p_len / 2) || '-' || substr(s, p_len / 2 + 1);
end $$;

create or replace function public.game_is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.game_staff where user_id = auth.uid()) $$;

create or replace function public.game_period_open() returns boolean
language sql stable security definer set search_path = public as
$$ select now() < (public.game_setting('period_end') #>> '{}')::timestamptz $$;

-- ---------- player API ----------
-- Create or update own profile. Phone accepts 08xx / +62xx / 62xx.
-- Players sign in anonymously (no email verification), so the email is
-- contact data typed by the player; a verified login email wins if present.
drop function if exists public.game_save_profile(text, text);
create or replace function public.game_save_profile(p_name text, p_phone text, p_email text default null)
returns public.game_players
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  ph  text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  em  text := coalesce(nullif(auth.jwt() ->> 'email', ''), nullif(lower(btrim(p_email)), ''));
  row public.game_players;
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if ph like '0%' then ph := '62' || substr(ph, 2); end if;
  if ph !~ '^62[0-9]{8,13}$' then raise exception 'NOMOR_HP_SALAH'; end if;
  if em is not null and (length(em) > 120 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'EMAIL_SALAH'; end if;
  if exists (select 1 from public.game_players where phone = ph and id <> uid) then
    raise exception 'NOMOR_HP_DIPAKAI';
  end if;
  insert into public.game_players (id, name, phone, email)
  values (uid, btrim(p_name), ph, em)
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, email = excluded.email
  returning * into row;
  return row;
end $$;

-- Own status: profile + balance + rank + today.
create or replace function public.game_me()
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  p public.game_players;
  rnk int;
  today_earned int;
begin
  if uid is null then return null; end if;
  select * into p from public.game_players where id = uid;
  if not found then return json_build_object('profile', false); end if;
  select count(*) + 1 into rnk from public.game_players q
   where (q.coins_play + q.coins_nota) > (p.coins_play + p.coins_nota)
      or ((q.coins_play + q.coins_nota) = (p.coins_play + p.coins_nota) and q.last_gain < p.last_gain);
  select coalesce(earned, 0) into today_earned from public.game_daily
   where player_id = uid and day = (now() at time zone 'Asia/Jakarta')::date;
  return json_build_object(
    'profile', true, 'name', p.name, 'phone', p.phone, 'email', p.email, 'skin', p.skin,
    'total', p.coins_play + p.coins_nota, 'balance', p.coins_play + p.coins_nota - p.spent,
    'coins_play', p.coins_play, 'coins_nota', p.coins_nota,
    'rank', rnk, 'today', coalesce(today_earned, 0),
    'daily_cap', (public.game_setting('daily_cap') #>> '{}')::int,
    'period_end', public.game_setting('period_end') #>> '{}');
end $$;

-- Gameplay coins (coin pickups, missions). Server enforces the daily cap.
create or replace function public.game_add_play(p_amount int, p_ref text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  cap int := (public.game_setting('daily_cap') #>> '{}')::int;
  per_call int := (public.game_setting('play_max_call') #>> '{}')::int;
  d date := (now() at time zone 'Asia/Jakarta')::date;
  cur int;
  got int;
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  if not exists (select 1 from public.game_players where id = uid) then raise exception 'PROFIL_KOSONG'; end if;
  if not public.game_period_open() then return json_build_object('got', 0, 'closed', true); end if;
  insert into public.game_daily (player_id, day) values (uid, d) on conflict do nothing;
  select earned into cur from public.game_daily where player_id = uid and day = d for update;
  got := greatest(0, least(coalesce(p_amount, 0), per_call, cap - cur));
  if got > 0 then
    update public.game_daily set earned = earned + got where player_id = uid and day = d;
    update public.game_players set coins_play = coins_play + got, last_gain = now() where id = uid;
    insert into public.game_coin_log (player_id, source, amount, ref) values (uid, 'play', got, left(p_ref, 40));
  end if;
  return json_build_object('got', got, 'today', cur + got, 'cap', cap);
end $$;

-- Redeem a receipt code from Texture (food/drink) or a merch purchase.
create or replace function public.game_redeem(p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9-]', '', 'g'));
  r public.game_receipts;
  fails int;
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
  if not public.game_period_open() then raise exception 'PERIODE_SELESAI'; end if;
  update public.game_receipts set redeemed_by = uid, redeemed_at = now() where code = c;
  update public.game_players
     set coins_nota = coins_nota + r.coins, last_gain = now(),
         skin = coalesce(r.skin, skin)
   where id = uid;
  insert into public.game_coin_log (player_id, source, amount, ref) values (uid, r.kind, r.coins, c);
  return json_build_object('coins', r.coins, 'kind', r.kind, 'points', r.points, 'skin', r.skin);
end $$;

-- Buy a store voucher. Cost comes from settings, never from the client.
create or replace function public.game_buy(p_item text)
returns public.game_vouchers
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  it jsonb;
  p public.game_players;
  v public.game_vouchers;
begin
  if uid is null then raise exception 'BELUM_LOGIN'; end if;
  select e.value into it from jsonb_array_elements(public.game_setting('store')) as e(value) where e.value ->> 'id' = p_item;
  if it is null then raise exception 'ITEM_TIDAK_ADA'; end if;
  select * into p from public.game_players where id = uid for update;
  if not found then raise exception 'PROFIL_KOSONG'; end if;
  if p.coins_play + p.coins_nota - p.spent < (it ->> 'cost')::int then raise exception 'KOIN_KURANG'; end if;
  update public.game_players set spent = spent + (it ->> 'cost')::int where id = uid;
  insert into public.game_vouchers (code, player_id, item_id, item_name, cost, expires_at)
  values (public.game_code('OOT', 8), uid, it ->> 'id', it ->> 'name', (it ->> 'cost')::int,
          now() + make_interval(days => (public.game_setting('voucher_days') #>> '{}')::int))
  returning * into v;
  insert into public.game_coin_log (player_id, source, amount, ref) values (uid, 'store', -(it ->> 'cost')::int, v.code);
  return v;
end $$;

-- Public leaderboard. Names only; phone and email never leave the DB.
create or replace function public.game_leaderboard(p_limit int default 50)
returns table (rank bigint, name text, total int, is_me boolean)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by (coins_play + coins_nota) desc, last_gain asc nulls last, created_at asc),
         name, coins_play + coins_nota, id = auth.uid()
    from public.game_players
   where coins_play + coins_nota > 0
   order by 1
   limit least(greatest(coalesce(p_limit, 50), 1), 100)
$$;

-- ---------- staff API (cashier page) ----------
create or replace function public.game_create_receipt(p_kind text, p_points int, p_note text default null)
returns public.game_receipts
language plpgsql security definer set search_path = public as $$
declare
  ppc int := (public.game_setting('points_per_coin') #>> '{}')::int;
  mult numeric := (public.game_setting('merch_mult') #>> '{}')::numeric;
  c int;
  r public.game_receipts;
begin
  if not public.game_is_staff() then raise exception 'BUKAN_STAFF'; end if;
  if p_kind not in ('food', 'merch') then raise exception 'JENIS_SALAH'; end if;
  if coalesce(p_points, 0) <= 0 or p_points > 50000000 then raise exception 'POIN_SALAH'; end if;
  c := floor(p_points::numeric / ppc * (case when p_kind = 'merch' then mult else 1 end));
  insert into public.game_receipts (code, kind, points, coins, skin, note, created_by)
  values (public.game_code(case when p_kind = 'merch' then 'MRC' else 'TXR' end, 8),
          p_kind, p_points, c, case when p_kind = 'merch' then 'merch' end, left(p_note, 80), auth.uid())
  returning * into r;
  return r;
end $$;

-- Cashier checks / marks a store voucher as used.
create or replace function public.game_use_voucher(p_code text, p_commit boolean default false)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v public.game_vouchers;
  pname text;
begin
  if not public.game_is_staff() then raise exception 'BUKAN_STAFF'; end if;
  select * into v from public.game_vouchers where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'VOUCHER_TIDAK_ADA'; end if;
  select name into pname from public.game_players where id = v.player_id;
  if p_commit then
    if v.used_at is not null then raise exception 'VOUCHER_SUDAH_DIPAKAI'; end if;
    if v.expires_at < now() then raise exception 'VOUCHER_KADALUARSA'; end if;
    update public.game_vouchers set used_at = now(), used_by = auth.uid() where code = v.code;
    v.used_at := now();
  end if;
  return json_build_object('code', v.code, 'item', v.item_name, 'player', pname,
    'expires_at', v.expires_at, 'used_at', v.used_at, 'expired', v.expires_at < now());
end $$;

-- Staff view of the leaderboard with contact details (for prize handover).
create or replace function public.game_leaderboard_staff(p_limit int default 20)
returns table (rank bigint, name text, phone text, email text, total int, coins_play int, coins_nota int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.game_is_staff() then raise exception 'BUKAN_STAFF'; end if;
  return query
  select row_number() over (order by (p.coins_play + p.coins_nota) desc, p.last_gain asc nulls last, p.created_at asc),
         p.name, p.phone, p.email, p.coins_play + p.coins_nota, p.coins_play, p.coins_nota
    from public.game_players p
   order by 1 limit least(greatest(coalesce(p_limit, 20), 1), 200);
end $$;

-- ---------- grants ----------
-- Only game_ functions are touched; other functions in public stay as they are.
revoke all on function
  public.game_code(text, int), public.game_setting(text), public.game_is_staff(), public.game_period_open(),
  public.game_me(), public.game_save_profile(text, text, text), public.game_add_play(int, text),
  public.game_redeem(text), public.game_buy(text), public.game_leaderboard(int),
  public.game_create_receipt(text, int, text), public.game_use_voucher(text, boolean),
  public.game_leaderboard_staff(int)
from public, anon, authenticated;
grant execute on function public.game_leaderboard(int)  to anon, authenticated;
grant execute on function public.game_setting(text)     to anon, authenticated;
grant execute on function
  public.game_me(), public.game_save_profile(text, text, text), public.game_add_play(int, text),
  public.game_redeem(text), public.game_buy(text),
  public.game_create_receipt(text, int, text), public.game_use_voucher(text, boolean),
  public.game_leaderboard_staff(int), public.game_is_staff()
to authenticated;

-- After creating your own login once, make yourself staff:
--   insert into public.game_staff (user_id, note)
--   select id, 'owner' from auth.users where email = 'YOUR_EMAIL';
-- Staff log in on kasir.html with email + password: create the user in
-- Dashboard > Authentication > Users > Add user (Auto Confirm), then run the insert above.
