-- Physical vouchers: 1 voucher per Rp15.000 purchase = 10 Tex Coins.
-- Redeemed in the game (TEX WALLET > Tukar Kode) through game_redeem, once per code.
-- Code: TEX-XXXXX-XXXXX, 10 random chars from 32 symbols (no 0/O/1/I), always
-- letters AND digits. 32^10 ~ 1.1e15 combinations + max 8 wrong tries/hour per player.
-- Valid until the end of the running season (game_redeem checks season + expires_at).

alter table public.game_receipts drop constraint if exists game_receipts_kind_check;
alter table public.game_receipts add constraint game_receipts_kind_check check (kind in ('food', 'merch', 'mix', 'voucher'));

do $$
declare
  s text := public.game_season_now();
  ends timestamptz;
  c text;
  made int := 0;
  k int;
begin
  if s is null then raise exception 'SEASON_TUTUP'; end if;
  select ends_at into ends from public.game_seasons where id = s;
  while made < 100 loop
    c := public.game_code('TEX', 10);
    continue when substr(c, 5) !~ '[A-Z]' or substr(c, 5) !~ '[0-9]';
    insert into public.game_receipts (code, kind, points, coins, note, fnb_rp, merch_rp, items, season_id, expires_at)
    values (c, 'voucher', 15000, 10, 'Voucher fisik batch 1', 15000, 0, '[]', s, ends)
    on conflict (code) do nothing;
    get diagnostics k = row_count;
    made := made + k;
  end loop;
end $$;

select code from public.game_receipts where kind = 'voucher' and note = 'Voucher fisik batch 1' order by code;
