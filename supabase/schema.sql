-- Планер — схема базы. Вставить целиком в Supabase → SQL Editor → Run. Выполняется один раз (повторный запуск безопасен).

-- 1. Документы пользователя (недели, профиль, мечты, фон). Каждый видит только своё.
create table if not exists public.docs (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.docs enable row level security;
drop policy if exists "docs select own" on public.docs; create policy "docs select own" on public.docs for select using (auth.uid() = user_id);
drop policy if exists "docs insert own" on public.docs; create policy "docs insert own" on public.docs for insert with check (auth.uid() = user_id);
drop policy if exists "docs update own" on public.docs; create policy "docs update own" on public.docs for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "docs delete own" on public.docs; create policy "docs delete own" on public.docs for delete using (auth.uid() = user_id);

-- 2. Обезличенная статистика: одна строка на аккаунт, без имён и содержимого.
create table if not exists public.app_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  onboarded boolean not null default false,
  quiz_done boolean not null default false,
  lang text,
  platform text
);
alter table public.app_users enable row level security;
drop policy if exists "app_users select own" on public.app_users; create policy "app_users select own" on public.app_users for select using (auth.uid() = user_id);
drop policy if exists "app_users insert own" on public.app_users; create policy "app_users insert own" on public.app_users for insert with check (auth.uid() = user_id);
drop policy if exists "app_users update own" on public.app_users; create policy "app_users update own" on public.app_users for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 3. Активность по дням: только факт «пользователь был активен в этот день».
create table if not exists public.activity (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);
alter table public.activity enable row level security;
drop policy if exists "activity select own" on public.activity; create policy "activity select own" on public.activity for select using (auth.uid() = user_id);
drop policy if exists "activity insert own" on public.activity; create policy "activity insert own" on public.activity for insert with check (auth.uid() = user_id);
drop policy if exists "activity update own" on public.activity; create policy "activity update own" on public.activity for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 4. Статистика для владельца: только счётчики. Доступна одному e-mail (замени при необходимости).
create or replace function public.admin_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  res jsonb;
  admin_email text := 'uliapetrenko154@gmail.com';
begin
  if lower(coalesce(auth.jwt() ->> 'email', '')) <> lower(admin_email) then
    raise exception 'not allowed';
  end if;
  select jsonb_build_object(
    'total_users', (select count(*) from app_users),
    'new_7d',      (select count(*) from app_users where created_at > now() - interval '7 days'),
    'new_30d',     (select count(*) from app_users where created_at > now() - interval '30 days'),
    'active_today',(select count(distinct user_id) from activity where day = current_date),
    'active_7d',   (select count(distinct user_id) from activity where day > current_date - 7),
    'active_30d',  (select count(distinct user_id) from activity where day > current_date - 30),
    'onboarded',   (select count(*) from app_users where onboarded),
    'quiz_done',   (select count(*) from app_users where quiz_done),
    'by_platform', (select coalesce(jsonb_object_agg(platform, c), '{}'::jsonb)
                      from (select coalesce(platform, 'unknown') platform, count(*) c from app_users group by 1) t),
    'by_day',      (select coalesce(jsonb_agg(jsonb_build_object('day', d::text, 'active', coalesce(a.c, 0), 'new_users', coalesce(n.c, 0)) order by d), '[]'::jsonb)
                      from generate_series(current_date - 29, current_date, interval '1 day') d
                      left join (select day, count(*) c from activity group by day) a on a.day = d::date
                      left join (select created_at::date day, count(*) c from app_users group by 1) n on n.day = d::date)
  ) into res;
  return res;
end
$$;
revoke all on function public.admin_stats() from public;
grant execute on function public.admin_stats() to authenticated;
