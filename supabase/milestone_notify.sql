-- =====================================================================
-- TEX CITY — Automatic email / webhook notification when a player wins a Milestone
-- Run in Supabase SQL Editor after texcity.sql & rescale_koin.sql. Safe to re-run.
--
-- How to set the destination email or webhook in Supabase Table Editor -> game_settings:
--   1. Key: 'notify_email'   -> Value: '"emailtexture@gmail.com"' (JSON string)
--      (First time a milestone triggers, FormSubmit sends a 1-click activation email to that inbox).
--   2. Key: 'notify_webhook' -> Value: '"https://script.google.com/macros/s/.../exec"' (optional Google Apps Script / Discord / Resend webhook)
--   3. Optional Resend API directly from PostgreSQL trigger (via pg_net):
--      Key: 'resend_api_key' -> Value: '"re_xxxxxxxxx"'
-- =====================================================================

create extension if not exists pg_net with schema extensions;

insert into public.game_settings (key, value) values
  ('notify_email',   '"hello.texturecoffee@gmail.com"'),
  ('notify_webhook', '""')
on conflict (key) do update set value = case when public.game_settings.value = '""'::jsonb then excluded.value else public.game_settings.value end;

create or replace function public.game_notify_milestone_winner()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p public.game_players;
  em text := coalesce(nullif(trim(public.game_setting('notify_email') #>> '{}'), ''), 'hello.texturecoffee@gmail.com');
  wh text := coalesce(public.game_setting('notify_webhook') #>> '{}', '');
  rk text := coalesce(public.game_setting('resend_api_key') #>> '{}', '');
  subj text;
  body jsonb;
begin
  select * into p from public.game_players where id = new.player_id;
  subj := format('[TEX CITY] Pemenang Milestone #%s (%s): %s', new.n, new.season_id, coalesce(p.name, 'Pemain'));
  body := jsonb_build_object(
    '_subject', subj,
    'season', new.season_id,
    'milestone_n', new.n,
    'prize', new.prize,
    'player_name', coalesce(p.name, '-'),
    'player_phone', coalesce(p.phone, '-'),
    'player_email', coalesce(p.email, '-'),
    'earned_coins', new.earned,
    'reached_at', new.reached_at
  );

  -- 1. If a custom webhook (e.g. Google Apps Script / Discord / Make / n8n) is configured:
  if length(trim(wh)) > 8 then
    begin
      perform net.http_post(url := trim(wh), body := body, headers := '{"Content-Type":"application/json"}'::jsonb);
    exception when others then null;
    end;
  end if;

  -- 2. If Resend API key + notify_email are configured in game_settings:
  if length(trim(rk)) > 8 and length(trim(em)) > 3 then
    begin
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || trim(rk), 'Content-Type', 'application/json'),
        body := jsonb_build_object(
          'from', 'Tex City <onboarding@resend.dev>',
          'to', jsonb_build_array(trim(em)),
          'subject', subj,
          'html', format(
            '<h2>Pemenang Milestone #%s (%s)</h2><p><b>Hadiah:</b> %s</p><p><b>Nama Pemain:</b> %s</p><p><b>No. HP / WA:</b> %s</p><p><b>Email:</b> %s</p><p><b>Tex Coins Earned:</b> %s</p><p><b>Waktu Tercapai:</b> %s</p>',
            new.n, new.season_id, new.prize, coalesce(p.name, '-'), coalesce(p.phone, '-'), coalesce(p.email, '-'), new.earned, new.reached_at
          )
        )
      );
    exception when others then null;
    end;
  end if;

  return new;
end $$;

drop trigger if exists trg_notify_milestone_winner on public.game_milestone_winners;
create trigger trg_notify_milestone_winner
  after insert on public.game_milestone_winners
  for each row execute function public.game_notify_milestone_winner();
