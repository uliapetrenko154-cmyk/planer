-- Планер — доступ по разовой покупке. Выполнить ПОСЛЕ schema.sql в Supabase → SQL Editor → Run. Повторный запуск безопасен.

-- 1. Тариф пользователя: trial (пробный период) или lifetime (куплено навсегда).
alter table public.app_users add column if not exists plan text not null default 'trial';
alter table public.app_users add column if not exists paid_at timestamptz;

-- Пользователь не должен менять себе тариф через API: права на столбцы вместо прав на всю таблицу.
revoke insert, update on public.app_users from authenticated;
grant insert (user_id, created_at, last_active_at, onboarded, quiz_done, lang, platform) on public.app_users to authenticated;
grant update (last_active_at, onboarded, quiz_done, lang, platform) on public.app_users to authenticated;

-- 2. Коды доступа (свои промокоды + ключи Gumroad после проверки). Доступ только через функции ниже.
create table if not exists public.access_codes (
  code text primary key,
  created_at timestamptz not null default now(),
  note text,
  used_by uuid references auth.users(id) on delete set null,
  used_at timestamptz
);
alter table public.access_codes enable row level security;
revoke all on public.access_codes from anon, authenticated;

-- 3. Настройки продаж (ссылка на покупку, цена, пробные дни, Gumroad). Читаются через access_info().
create table if not exists public.app_settings (key text primary key, value text);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;
insert into public.app_settings(key, value) values ('trial_days', '7') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('buy_url', '') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('price_text', '') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('gumroad_product_id', '') on conflict (key) do nothing;

-- Для проверки ключей Gumroad нужен HTTP-вызов из базы.
create extension if not exists http with schema extensions;

-- 4. Что видит приложение о доступе текущего пользователя.
create or replace function public.access_info()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := auth.uid(); r record; s jsonb; created timestamptz;
  admin_email text := 'uliapetrenko154@gmail.com';
begin
  if u is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into s from app_settings;
  select plan, paid_at into r from app_users where user_id = u;
  select created_at into created from auth.users where id = u;
  return jsonb_build_object(
    'plan', case when lower(coalesce(auth.jwt() ->> 'email','')) = lower(admin_email) then 'lifetime' else coalesce(r.plan, 'trial') end,
    'paid_at', r.paid_at,
    'created_at', created,
    'trial_days', coalesce((s ->> 'trial_days')::int, 7),
    'buy_url', coalesce(s ->> 'buy_url', ''),
    'price_text', coalesce(s ->> 'price_text', ''),
    'gumroad', coalesce(s ->> 'gumroad_product_id', '') <> ''
  );
end $$;
revoke all on function public.access_info() from public;
grant execute on function public.access_info() to authenticated;

-- 5. Активация кода. Сначала свои коды, затем (если настроен) ключ Gumroad.
create or replace function public.redeem_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := auth.uid(); c text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g')); rec record;
  pid text; resp extensions.http_response; j jsonb; raw text := trim(coalesce(p_code,''));
begin
  if u is null then raise exception 'not signed in'; end if;
  if c = '' then return jsonb_build_object('ok', false, 'reason', 'empty'); end if;
  -- уже куплено?
  if exists (select 1 from app_users where user_id = u and plan = 'lifetime') then return jsonb_build_object('ok', true, 'already', true); end if;
  -- свой код
  select * into rec from access_codes where upper(regexp_replace(code, '\s', '', 'g')) = c for update;
  if found then
    if rec.used_by is not null and rec.used_by <> u then return jsonb_build_object('ok', false, 'reason', 'used'); end if;
    update access_codes set used_by = u, used_at = coalesce(used_at, now()) where code = rec.code;
    insert into app_users(user_id, plan, paid_at) values (u, 'lifetime', now())
      on conflict (user_id) do update set plan = 'lifetime', paid_at = coalesce(app_users.paid_at, now());
    return jsonb_build_object('ok', true);
  end if;
  -- ключ Gumroad
  select value into pid from app_settings where key = 'gumroad_product_id';
  if coalesce(pid, '') <> '' and raw ~ '^[A-Za-z0-9-]{20,}$' then
    begin
      resp := extensions.http_post('https://api.gumroad.com/v2/licenses/verify',
        'product_id=' || extensions.urlencode(pid) || '&license_key=' || extensions.urlencode(raw) || '&increment_uses_count=false',
        'application/x-www-form-urlencoded');
      j := resp.content::jsonb;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'network');
    end;
    if coalesce((j ->> 'success')::boolean, false)
       and not coalesce((j -> 'purchase' ->> 'refunded')::boolean, false)
       and not coalesce((j -> 'purchase' ->> 'chargebacked')::boolean, false) then
      if exists (select 1 from access_codes where code = raw and used_by is not null and used_by <> u) then
        return jsonb_build_object('ok', false, 'reason', 'used');
      end if;
      insert into access_codes(code, note, used_by, used_at) values (raw, 'gumroad', u, now())
        on conflict (code) do update set used_by = u, used_at = coalesce(access_codes.used_at, now());
      insert into app_users(user_id, plan, paid_at) values (u, 'lifetime', now())
        on conflict (user_id) do update set plan = 'lifetime', paid_at = coalesce(app_users.paid_at, now());
      return jsonb_build_object('ok', true);
    end if;
  end if;
  return jsonb_build_object('ok', false, 'reason', 'invalid');
end $$;
revoke all on function public.redeem_code(text) from public;
grant execute on function public.redeem_code(text) to authenticated;

-- 6. Для владельца: коды, настройки, продажи.
create or replace function public.admin_generate_codes(n int, p_note text default null)
returns setof text language plpgsql security definer set search_path = public as $$
declare i int; c text; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then raise exception 'not allowed'; end if;
  n := least(greatest(coalesce(n, 1), 1), 200);
  for i in 1..n loop
    loop
      c := 'PL-' || (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 4))
         || '-' || (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 4))
         || '-' || (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 4));
      exit when not exists (select 1 from access_codes where code = c);
    end loop;
    insert into access_codes(code, note) values (c, p_note);
    return next c;
  end loop;
end $$;
revoke all on function public.admin_generate_codes(int, text) from public;
grant execute on function public.admin_generate_codes(int, text) to authenticated;

create or replace function public.admin_codes()
returns jsonb language sql security definer set search_path = public as $$
  select case when lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then null
    else coalesce((select jsonb_agg(jsonb_build_object('code', code, 'note', note, 'created_at', created_at, 'used', used_by is not null, 'used_at', used_at) order by created_at desc)
                   from (select * from access_codes order by created_at desc limit 300) t), '[]'::jsonb) end;
$$;
revoke all on function public.admin_codes() from public;
grant execute on function public.admin_codes() to authenticated;

create or replace function public.admin_set_setting(k text, v text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then raise exception 'not allowed'; end if;
  if k not in ('trial_days', 'buy_url', 'price_text', 'gumroad_product_id') then raise exception 'unknown setting'; end if;
  insert into app_settings(key, value) values (k, coalesce(v, '')) on conflict (key) do update set value = excluded.value;
end $$;
revoke all on function public.admin_set_setting(text, text) from public;
grant execute on function public.admin_set_setting(text, text) to authenticated;

create or replace function public.admin_settings()
returns jsonb language sql security definer set search_path = public as $$
  select case when lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then null
    else coalesce((select jsonb_object_agg(key, value) from app_settings), '{}'::jsonb) end;
$$;
revoke all on function public.admin_settings() from public;
grant execute on function public.admin_settings() to authenticated;

-- Статистика: добавляем продажи.
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
    'paid',        (select count(*) from app_users where plan = 'lifetime'),
    'paid_30d',    (select count(*) from app_users where plan = 'lifetime' and paid_at > now() - interval '30 days'),
    'codes_free',  (select count(*) from access_codes where used_by is null and coalesce(note,'') <> 'gumroad'),
    'by_platform', (select coalesce(jsonb_object_agg(platform, c), '{}'::jsonb)
                      from (select coalesce(platform, 'unknown') platform, count(*) c from app_users group by 1) t),
    'by_day',      (select coalesce(jsonb_agg(jsonb_build_object('day', (d::date)::text, 'active', coalesce(a.c, 0), 'new_users', coalesce(n.c, 0)) order by d), '[]'::jsonb)
                      from generate_series(current_date - 29, current_date, interval '1 day') as d
                      left join (select activity.day as act_day, count(*) as c from activity group by activity.day) a on a.act_day = d::date
                      left join (select created_at::date as reg_day, count(*) as c from app_users group by 1) n on n.reg_day = d::date)
  ) into res;
  return res;
end
$$;

-- 7. Удаление аккаунта самим пользователем (данные удаляются каскадно).
create or replace function public.delete_me()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_me() from public;
grant execute on function public.delete_me() to authenticated;
