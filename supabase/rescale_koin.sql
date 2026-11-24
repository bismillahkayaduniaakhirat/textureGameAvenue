-- =====================================================================
-- TEX CITY: one coin scale for everything (2026-11-24, owner's decision)
--   * Rp15.000 belanja = 10 Tex Coins: physical voucher, cashier F&B code AND
--     cashier merch code (merch uses the same rate as F&B).
--   * Missions pay at most 5 coins.
--   * Milestones: Jersey 450, Kaos 550.
--   * OOT Wardrobe prices scaled by 550/300.000 (old kaos milestone).
-- Then every existing wallet is recomputed from game_coin_log with the new
-- values, so nobody keeps thousands of old-scale coins.
-- Safe to run more than once.
-- =====================================================================

-- ---------- settings ----------
insert into public.game_settings (key, value) values ('coin_unit_rp', '15000')
on conflict (key) do update set value = excluded.value;
comment on table public.game_settings is 'TEX CITY settings. Coins per receipt = floor(Rp / coin_unit_rp) * fnb_rate (or merch_rate).';
update public.game_settings set value = '10' where key = 'fnb_rate';   -- per coin_unit_rp (Rp15.000)
update public.game_settings set value = '10' where key = 'merch_rate'; -- same as F&B
update public.game_settings set value =
  '{"T1":1,"T2":2,"T3":2,"T4":3,"T5":3,"T6":4,"T7":5,"B1":1,"B2":1,"B3":2}'
where key = 'mission_rewards';
update public.game_settings set value =
  '[{"n":1,"coins":450,"prize":"Jersey OOT-SS25 \"Pas Presse de Vivre\""},
    {"n":2,"coins":550,"prize":"Kaos OOT-SS26 (hitam atau putih)"}]'
where key = 'milestones';
update public.game_settings set value = (
  select jsonb_agg(case e.value ->> 'id'
    when 's1_jersey'    then jsonb_set(e.value, '{coins}', '37')
    when 's1_perfume'   then jsonb_set(e.value, '{coins}', '28')
    when 's1_sun_gray'  then jsonb_set(e.value, '{coins}', '18')
    when 's1_sun_amber' then jsonb_set(e.value, '{coins}', '18')
    when 's1_ring'      then jsonb_set(e.value, '{coins}', '15')
    when 's1_key'       then jsonb_set(e.value, '{coins}', '15')
    when 's2_tee_black' then jsonb_set(e.value, '{coins}', '33')
    when 's2_tee_white' then jsonb_set(e.value, '{coins}', '33')
    when 's2_tumbler'   then jsonb_set(e.value, '{coins}', '22')
    when 's2_key'       then jsonb_set(e.value, '{coins}', '11')
    else e.value end order by e.ord)
  from jsonb_array_elements(public.game_setting('tex_items')) with ordinality e(value, ord))
where key = 'tex_items';

-- ---------- cashier code: coins per Rp15.000 ----------
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
  unit numeric := coalesce((public.game_setting('coin_unit_rp') #>> '{}')::numeric, 15000);
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
  coins_f := floor(fnb / unit) * (public.game_setting('fnb_rate') #>> '{}')::int;
  coins_m := floor(merch / unit) * (public.game_setting('merch_rate') #>> '{}')::int;
  if coins_f + coins_m <= 0 and jsonb_array_length(clean) = 0 then raise exception 'NOMINAL_KECIL'; end if;
  insert into public.game_receipts (code, kind, points, coins, note, cashier_id, fnb_rp, merch_rp, items, season_id, expires_at)
  values (public.game_code('TEX', 8),
          case when merch = 0 then 'food' when fnb = 0 then 'merch' else 'mix' end,
          fnb + merch, coins_f + coins_m, left(p_note, 80), cid, fnb, merch, clean, s,
          now() + make_interval(hours => (public.game_setting('receipt_hours') #>> '{}')::int))
  returning * into r;
  return json_build_object('code', r.code, 'coins', r.coins, 'coins_fnb', coins_f, 'coins_merch', coins_m,
    'fnb_rp', fnb, 'merch_rp', merch, 'items', clean, 'expires_at', r.expires_at);
end $$;

-- ---------- recompute existing data on the new scale ----------
do $$
declare
  unit numeric := 15000;
  rw jsonb := public.game_setting('mission_rewards');
begin
  -- cashier codes (not the physical vouchers, which are already 10 per Rp15.000)
  update public.game_receipts
     set coins = (floor(coalesce(fnb_rp, 0) / unit) + floor(coalesce(merch_rp, 0) / unit))::int * 10
   where kind in ('food', 'merch', 'mix') and season_id is not null;

  update public.game_missions_done d set reward = (rw ->> d.mission_id)::int where rw ? d.mission_id;

  -- the log is the source of truth for every wallet
  update public.game_coin_log l set amount = (rw ->> l.ref)::int where l.source = 'mission' and rw ? l.ref;
  update public.game_coin_log l set amount = r.coins
    from public.game_receipts r where l.source = 'nota' and r.code = l.ref;
  update public.game_coin_log l set amount = -((public.game_item(l.ref) ->> 'coins')::int)
   where l.source = 'wardrobe' and public.game_item(l.ref) is not null;

  update public.game_wallet w set
    earned = coalesce((select sum(amount) from public.game_coin_log l where l.player_id = w.player_id and l.season_id = w.season_id and l.amount > 0), 0),
    spent  = coalesce((select -sum(amount) from public.game_coin_log l where l.player_id = w.player_id and l.season_id = w.season_id and l.amount < 0), 0);
  -- skins bought on the old scale stay owned; the wallet never goes below zero
  update public.game_wallet set spent = earned where spent > earned;

  -- milestone wins only count on the new scale
  delete from public.game_milestone_winners m
   where m.handed_at is null
     and not exists (select 1 from public.game_wallet w where w.player_id = m.player_id and w.season_id = m.season_id
                     and w.earned >= (select (x.value ->> 'coins')::int from jsonb_array_elements(public.game_setting('milestones')) x(value) where (x.value ->> 'n')::int = m.n));
end $$;

-- check: what each wallet looks like now
select p.name, w.season_id, w.earned, w.spent, w.earned - w.spent as available
from public.game_wallet w join public.game_players p on p.id = w.player_id
order by w.earned desc limit 30;
