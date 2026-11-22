-- =====================================================================
-- OOT Street — cashier login by name + PIN (no Supabase Auth account).
-- The owner manages cashiers in Table Editor > game_cashiers, like a
-- spreadsheet: one row per cashier (name, pin, active). The PIN is
-- bcrypt-hashed by a trigger the moment the row is saved.
-- kasir.html logs in with game_cashier_login() and gets a session token;
-- every game_k_* function takes that token. Safe to re-run.
-- Run after schema.sql.
-- =====================================================================

create table if not exists public.game_cashiers (
  id         serial primary key,
  name       text not null unique check (char_length(btrim(name)) between 2 and 30),
  pin        text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.game_cashiers is
  'Akun kasir OOT Street. Isi name + pin (4-8 angka). PIN otomatis diacak (hash) saat disimpan. Hapus centang active untuk menonaktifkan kasir.';

create table if not exists public.game_cashier_sessions (
  token      text primary key,
  cashier_id int  not null references public.game_cashiers(id) on delete cascade,
  expires_at timestamptz not null
);

create table if not exists public.game_cashier_fails (
  name text not null,
  at   timestamptz not null default now()
);
create index if not exists game_cashier_fails_idx on public.game_cashier_fails (name, at);

-- No policies: these tables are reachable only through the functions below.
alter table public.game_cashiers         enable row level security;
alter table public.game_cashier_sessions enable row level security;
alter table public.game_cashier_fails    enable row level security;

-- Which cashier made a receipt / handed over a voucher.
alter table public.game_receipts add column if not exists cashier_id int references public.game_cashiers(id) on delete set null;
alter table public.game_vouchers add column if not exists used_by_cashier int references public.game_cashiers(id) on delete set null;

-- Hash the PIN whenever a plain PIN is typed into the table.
create or replace function public.game_cashier_hash_pin() returns trigger
language plpgsql set search_path = public, extensions as $$
begin
  new.name := btrim(new.name);
  if new.pin !~ '^\$2[aby]\$' then
    if new.pin !~ '^[0-9]{4,8}$' then raise exception 'PIN harus 4-8 angka'; end if;
    new.pin := crypt(new.pin, gen_salt('bf', 8));
  end if;
  return new;
end $$;
drop trigger if exists game_cashier_hash_pin on public.game_cashiers;
create trigger game_cashier_hash_pin before insert or update on public.game_cashiers
  for each row execute function public.game_cashier_hash_pin();

-- ---------- cashier API ----------
-- Names for the login dropdown (active cashiers only, no PINs).
create or replace function public.game_cashier_names()
returns table (name text)
language sql stable security definer set search_path = public as
$$ select c.name from public.game_cashiers c where c.active order by c.name $$;

-- Name + PIN -> session token (14 hours). 5 wrong PINs per name lock it for 15 minutes.
-- Failures return {"error": ...} instead of raising, so the failure row is kept
-- (an exception would roll it back and the lock would never trigger).
create or replace function public.game_cashier_login(p_name text, p_pin text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.game_cashiers;
  tok text;
  exp timestamptz := now() + interval '14 hours';
begin
  if (select count(*) from public.game_cashier_fails
       where name = btrim(p_name) and at > now() - interval '15 minutes') >= 5 then
    return json_build_object('error', 'KASIR_TERKUNCI');
  end if;
  select * into c from public.game_cashiers where name = btrim(p_name) and active;
  if not found or c.pin <> crypt(coalesce(p_pin, ''), c.pin) then
    insert into public.game_cashier_fails (name) values (left(btrim(coalesce(p_name, '')), 30));
    return json_build_object('error', 'PIN_SALAH');
  end if;
  delete from public.game_cashier_fails where name = c.name;
  delete from public.game_cashier_sessions where expires_at < now();
  tok := encode(gen_random_bytes(24), 'hex');
  insert into public.game_cashier_sessions (token, cashier_id, expires_at) values (tok, c.id, exp);
  return json_build_object('token', tok, 'name', c.name, 'expires_at', exp);
end $$;

create or replace function public.game_cashier_logout(p_token text) returns void
language sql security definer set search_path = public as
$$ delete from public.game_cashier_sessions where token = p_token $$;

-- Internal: token -> active cashier id, or SESI_KASIR_HABIS.
create or replace function public.game_cashier_id(p_token text) returns int
language plpgsql stable security definer set search_path = public as $$
declare cid int;
begin
  select s.cashier_id into cid
    from public.game_cashier_sessions s join public.game_cashiers c on c.id = s.cashier_id
   where s.token = p_token and s.expires_at > now() and c.active;
  if cid is null then raise exception 'SESI_KASIR_HABIS'; end if;
  return cid;
end $$;

-- Create a receipt code (same rules as game_create_receipt).
create or replace function public.game_k_receipt(p_token text, p_kind text, p_points int, p_note text default null)
returns public.game_receipts
language plpgsql security definer set search_path = public as $$
declare
  cid int := public.game_cashier_id(p_token);
  ppc int := (public.game_setting('points_per_coin') #>> '{}')::int;
  mult numeric := (public.game_setting('merch_mult') #>> '{}')::numeric;
  c int;
  r public.game_receipts;
begin
  if p_kind not in ('food', 'merch') then raise exception 'JENIS_SALAH'; end if;
  if coalesce(p_points, 0) <= 0 or p_points > 50000000 then raise exception 'POIN_SALAH'; end if;
  c := floor(p_points::numeric / ppc * (case when p_kind = 'merch' then mult else 1 end));
  insert into public.game_receipts (code, kind, points, coins, skin, note, cashier_id)
  values (public.game_code(case when p_kind = 'merch' then 'MRC' else 'TXR' end, 8),
          p_kind, p_points, c, case when p_kind = 'merch' then 'merch' end, left(p_note, 80), cid)
  returning * into r;
  return r;
end $$;

-- Check / mark a store voucher as used.
create or replace function public.game_k_voucher(p_token text, p_code text, p_commit boolean default false)
returns json
language plpgsql security definer set search_path = public as $$
declare
  cid int := public.game_cashier_id(p_token);
  v public.game_vouchers;
  pname text;
begin
  select * into v from public.game_vouchers where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'VOUCHER_TIDAK_ADA'; end if;
  select name into pname from public.game_players where id = v.player_id;
  if p_commit then
    if v.used_at is not null then raise exception 'VOUCHER_SUDAH_DIPAKAI'; end if;
    if v.expires_at < now() then raise exception 'VOUCHER_KADALUARSA'; end if;
    update public.game_vouchers set used_at = now(), used_by_cashier = cid where code = v.code;
    v.used_at := now();
  end if;
  return json_build_object('code', v.code, 'item', v.item_name, 'player', pname,
    'expires_at', v.expires_at, 'used_at', v.used_at, 'expired', v.expires_at < now());
end $$;

-- Leaderboard with contact details (prize handover).
create or replace function public.game_k_board(p_token text, p_limit int default 50)
returns table (rank bigint, name text, phone text, email text, total int, coins_play int, coins_nota int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.game_cashier_id(p_token);
  return query
  select row_number() over (order by (p.coins_play + p.coins_nota) desc, p.last_gain asc nulls last, p.created_at asc),
         p.name, p.phone, p.email, p.coins_play + p.coins_nota, p.coins_play, p.coins_nota
    from public.game_players p
   order by 1 limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

-- ---------- grants ----------
revoke all on function
  public.game_cashier_hash_pin(), public.game_cashier_names(), public.game_cashier_login(text, text),
  public.game_cashier_logout(text), public.game_cashier_id(text),
  public.game_k_receipt(text, text, int, text), public.game_k_voucher(text, text, boolean), public.game_k_board(text, int)
from public, anon, authenticated;
grant execute on function
  public.game_cashier_names(), public.game_cashier_login(text, text), public.game_cashier_logout(text),
  public.game_k_receipt(text, text, int, text), public.game_k_voucher(text, text, boolean), public.game_k_board(text, int)
to anon, authenticated;
