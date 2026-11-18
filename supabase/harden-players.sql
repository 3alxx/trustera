-- Trustera Challenge: harden public.players (run once in Supabase → SQL Editor by the project owner).
-- Safe to re-run. Deletes NO rows. All 8 rows that existed on 2026-11-19 satisfy these rules (checked).
--
-- Scoring in index.html: 3 rounds, all-or-nothing per round. A correct round gives 100 + 3 × (seconds left),
-- seconds left is 0..30. So for c correct rounds: score = 100·c + 3·k with 0 ≤ k ≤ 30·c.
-- Maximum legitimate score = 3 × (100 + 3 × 30) = 570.

begin;

-- 1) Shape of a valid result -------------------------------------------------------------------------
alter table public.players alter column name set not null;
alter table public.players alter column score set not null;
alter table public.players alter column correct_rounds set not null;
alter table public.players alter column created_at set default now();

alter table public.players drop constraint if exists players_name_valid;
alter table public.players add constraint players_name_valid check (
  name = btrim(name)                                  -- no leading/trailing spaces
  and char_length(name) between 2 and 24              -- same limits as the game
  and name !~ '[<>[:cntrl:]]'                          -- no HTML brackets or control characters
  and name !~ E'[\u202A-\u202E\u2066-\u2069]'       -- no hidden text-direction overrides (name spoofing)
) not valid;

alter table public.players drop constraint if exists players_score_valid;
alter table public.players add constraint players_score_valid check (
  correct_rounds between 0 and 3
  and score between 100 * correct_rounds and 190 * correct_rounds   -- 0 when no round is correct; max 570
  and (score - 100 * correct_rounds) % 3 = 0                         -- speed bonus comes in steps of 3
) not valid;

alter table public.players validate constraint players_name_valid;
alter table public.players validate constraint players_score_valid;

-- 2) The server decides id and time; the browser can only send name, score, correct_rounds ---------------
create or replace function public.players_before_insert() returns trigger
language plpgsql set search_path = public as $$
begin
  new.name := regexp_replace(btrim(new.name), '\s+', ' ', 'g');
  new.created_at := now();
  return new;
end $$;
drop trigger if exists players_before_insert on public.players;
create trigger players_before_insert before insert on public.players
  for each row execute function public.players_before_insert();

-- 3) Least privilege for visitors (anon) and signed-in users -------------------------------------------
alter table public.players enable row level security;

do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'players' loop
    execute format('drop policy %I on public.players', p.policyname);
  end loop;
end $$;

create policy players_insert_public on public.players for insert to anon, authenticated with check (true);
create policy players_read_public  on public.players for select to anon, authenticated using (true);
-- No update or delete policy: nobody can change or remove a saved result through the public API.

revoke all on table public.players from anon, authenticated;
grant insert (name, score, correct_rounds) on public.players to anon, authenticated;  -- only these columns
grant select (score) on public.players to anon, authenticated;                       -- the game only needs scores for the rank

commit;

-- Check afterwards (expect: 2 policies, 2 constraints, the trigger):
-- select policyname, cmd, roles from pg_policies where tablename = 'players';
-- select conname from pg_constraint where conrelid = 'public.players'::regclass and contype = 'c';
-- select tgname from pg_trigger where tgrelid = 'public.players'::regclass and not tgisinternal;
