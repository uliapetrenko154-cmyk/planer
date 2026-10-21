-- Планер — оплата через WayForPay. Выполнить ПОСЛЕ schema_v2.sql в Supabase → SQL Editor → Run. Повторный запуск безопасен.
-- Секретный ключ WayForPay хранится только в базе и используется только внутри функций ниже.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists http with schema extensions;

-- 1. Настройки WayForPay (вводятся в панели владельца).
insert into public.app_settings(key, value) values ('wfp_merchant', '') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('wfp_secret', '') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('wfp_domain', 'planer.co.ua') on conflict (key) do nothing;
insert into public.app_settings(key, value) values ('price_uah', '499') on conflict (key) do nothing;

-- 2. Заказы: один ряд на попытку оплаты.
create table if not exists public.orders (
  ref text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric not null,
  currency text not null default 'UAH',
  status text not null default 'created',   -- created | approved | declined | refunded | expired
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  raw jsonb
);
alter table public.orders enable row level security;
revoke all on public.orders from anon, authenticated;

create or replace function public.wfp_sign(p_secret text, p_data text)
returns text language sql immutable as $$
  select encode(extensions.hmac(convert_to(p_data, 'UTF8'), convert_to(p_secret, 'UTF8'), 'md5'), 'hex');
$$;
revoke all on function public.wfp_sign(text, text) from public;

create or replace function public.wfp_grant(p_user uuid)
returns void language sql as $$
  insert into app_users(user_id, plan, paid_at) values (p_user, 'lifetime', now())
    on conflict (user_id) do update set plan = 'lifetime', paid_at = coalesce(app_users.paid_at, now());
$$;
revoke all on function public.wfp_grant(uuid) from public;

-- 3. Создать заказ и подписанные параметры для платёжного виджета WayForPay.
create or replace function public.wfp_order(p_lang text default 'UA')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := auth.uid(); s jsonb; v_merchant text; v_secret text; v_domain text; v_price numeric;
  v_ref text; v_ts bigint := extract(epoch from now())::bigint; v_email text; v_amount text; v_sig text; v_lang text;
  v_name text := 'Планер: доступ навсегда';
begin
  if u is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into s from app_settings;
  v_merchant := s ->> 'wfp_merchant'; v_secret := s ->> 'wfp_secret'; v_domain := coalesce(nullif(s ->> 'wfp_domain', ''), 'planer.co.ua');
  if coalesce(v_merchant, '') = '' or coalesce(v_secret, '') = '' then return jsonb_build_object('ok', false, 'reason', 'not_configured'); end if;
  begin v_price := coalesce(nullif(s ->> 'price_uah', '')::numeric, 0); exception when others then v_price := 0; end;
  if v_price <= 0 then return jsonb_build_object('ok', false, 'reason', 'no_price'); end if;
  if exists (select 1 from app_users where user_id = u and plan = 'lifetime') then return jsonb_build_object('ok', true, 'already', true); end if;
  v_amount := v_price::text;
  if position('.' in v_amount) > 0 then v_amount := rtrim(rtrim(v_amount, '0'), '.'); end if;
  v_ref := 'pl-' || replace(u::text, '-', '') || '-' || v_ts::text;
  select au.email into v_email from auth.users au where au.id = u;
  v_lang := case lower(coalesce(p_lang, 'ua')) when 'ru' then 'RU' when 'en' then 'EN' else 'UA' end;
  insert into orders(ref, user_id, amount, currency, status) values (v_ref, u, v_amount::numeric, 'UAH', 'created');
  v_sig := wfp_sign(v_secret, v_merchant || ';' || v_domain || ';' || v_ref || ';' || v_ts::text || ';' || v_amount || ';UAH;' || v_name || ';1;' || v_amount);
  return jsonb_build_object('ok', true, 'ref', v_ref, 'widget', jsonb_build_object(
    'merchantAccount', v_merchant, 'merchantDomainName', v_domain, 'authorizationType', 'SimpleSignature', 'merchantSignature', v_sig,
    'orderReference', v_ref, 'orderDate', v_ts, 'amount', v_amount::numeric, 'currency', 'UAH',
    'productName', jsonb_build_array(v_name), 'productPrice', jsonb_build_array(v_amount::numeric), 'productCount', jsonb_build_array(1),
    'clientEmail', coalesce(v_email, ''), 'language', v_lang, 'straightWidget', true,
    'serviceUrl', 'https://iyzszbcwknoqsrrvftzl.supabase.co/rest/v1/rpc/wfp_callback?apikey=sb_publishable__YKy17HlTUc0ci9vW5jTZg_1baKXyqF'
  ));
end $$;
revoke all on function public.wfp_order(text) from public;
grant execute on function public.wfp_order(text) to authenticated;

-- 4. Проверить статус заказа у WayForPay (приложение вызывает после оплаты и при запуске, пока заказ не подтверждён).
create or replace function public.wfp_check(p_ref text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := auth.uid(); o record; v_merchant text; v_secret text; resp extensions.http_response; j jsonb; v_st text; v_amt numeric; v_sig text;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into o from orders where orders.ref = p_ref and orders.user_id = u;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_order'); end if;
  if o.status = 'approved' then perform wfp_grant(u); return jsonb_build_object('ok', true, 'status', 'approved'); end if;
  select value into v_merchant from app_settings where key = 'wfp_merchant';
  select value into v_secret from app_settings where key = 'wfp_secret';
  begin
    resp := extensions.http_post('https://api.wayforpay.com/api',
      jsonb_build_object('transactionType', 'CHECK_STATUS', 'merchantAccount', v_merchant, 'orderReference', p_ref,
                         'merchantSignature', wfp_sign(v_secret, v_merchant || ';' || p_ref), 'apiVersion', 1)::text,
      'application/json');
    j := resp.content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'network');
  end;
  v_st := lower(coalesce(j ->> 'transactionStatus', ''));
  begin v_amt := coalesce((j ->> 'amount')::numeric, 0); exception when others then v_amt := 0; end;
  -- подпись ответа (если WayForPay её прислал) должна сходиться
  if coalesce(j ->> 'merchantSignature', '') <> '' then
    v_sig := wfp_sign(v_secret, coalesce(j ->> 'merchantAccount','') || ';' || coalesce(j ->> 'orderReference','') || ';' || coalesce(j ->> 'amount','') || ';' || coalesce(j ->> 'currency','') || ';' ||
                               coalesce(j ->> 'authCode','') || ';' || coalesce(j ->> 'cardPan','') || ';' || coalesce(j ->> 'transactionStatus','') || ';' || coalesce(j ->> 'reasonCode',''));
    if v_sig <> (j ->> 'merchantSignature') then return jsonb_build_object('ok', false, 'reason', 'bad_signature'); end if;
  end if;
  update orders set raw = j where orders.ref = p_ref;
  if v_st = 'approved' and v_amt >= o.amount then
    update orders set status = 'approved', paid_at = coalesce(paid_at, now()) where orders.ref = p_ref;
    perform wfp_grant(u);
    return jsonb_build_object('ok', true, 'status', 'approved');
  end if;
  if v_st in ('declined', 'expired', 'refunded', 'voided') then update orders set status = v_st where orders.ref = p_ref; end if;
  return jsonb_build_object('ok', false, 'status', v_st, 'reason', coalesce(j ->> 'reason', ''), 'code', coalesce(j ->> 'reasonCode', ''));
end $$;
revoke all on function public.wfp_check(text) from public;
grant execute on function public.wfp_check(text) to authenticated;

-- 5. Серверное уведомление от WayForPay (serviceUrl). PostgREST передаёт тело запроса целиком в единственный json-параметр.
create or replace function public.wfp_callback(json)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  b jsonb := $1::jsonb; v_secret text; v_sig text; v_ref text; v_st text; o record; v_t bigint := extract(epoch from now())::bigint; v_amt numeric;
begin
  select value into v_secret from app_settings where key = 'wfp_secret';
  v_ref := b ->> 'orderReference';
  if v_ref is null or coalesce(v_secret, '') = '' then return jsonb_build_object('ok', false); end if;
  v_sig := wfp_sign(v_secret, coalesce(b ->> 'merchantAccount','') || ';' || v_ref || ';' || coalesce(b ->> 'amount','') || ';' || coalesce(b ->> 'currency','') || ';' ||
                             coalesce(b ->> 'authCode','') || ';' || coalesce(b ->> 'cardPan','') || ';' || coalesce(b ->> 'transactionStatus','') || ';' || coalesce(b ->> 'reasonCode',''));
  if v_sig <> coalesce(b ->> 'merchantSignature', '') then return jsonb_build_object('ok', false, 'reason', 'bad_signature'); end if;
  select * into o from orders where orders.ref = v_ref;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_order'); end if;
  v_st := lower(coalesce(b ->> 'transactionStatus', ''));
  begin v_amt := coalesce((b ->> 'amount')::numeric, 0); exception when others then v_amt := 0; end;
  update orders set raw = b where orders.ref = v_ref;
  if v_st = 'approved' and v_amt >= o.amount then
    update orders set status = 'approved', paid_at = coalesce(paid_at, now()) where orders.ref = v_ref;
    perform wfp_grant(o.user_id);
  elsif v_st in ('declined', 'expired', 'refunded', 'voided') then
    update orders set status = v_st where orders.ref = v_ref;
  end if;
  return jsonb_build_object('orderReference', v_ref, 'status', 'accept', 'time', v_t, 'signature', wfp_sign(v_secret, v_ref || ';accept;' || v_t::text));
end $$;
revoke all on function public.wfp_callback(json) from public;
grant execute on function public.wfp_callback(json) to anon, authenticated;

-- 6. access_info: сообщаем приложению, что оплата настроена, и цену.
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
    'trial_days', coalesce((s ->> 'trial_days')::int, 1),
    'buy_url', coalesce(s ->> 'buy_url', ''),
    'price_text', coalesce(s ->> 'price_text', ''),
    'price_uah', coalesce(nullif(regexp_replace(coalesce(s ->> 'price_uah',''), '[^0-9.]', '', 'g'), '')::numeric, 0),
    'wfp', coalesce(s ->> 'wfp_merchant', '') <> '' and coalesce(s ->> 'wfp_secret', '') <> '',
    'gumroad', coalesce(s ->> 'gumroad_product_id', '') <> ''
  );
end $$;

-- 7. Настройки владельца: новые ключи, секрет наружу не отдаём целиком.
create or replace function public.admin_set_setting(k text, v text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then raise exception 'not allowed'; end if;
  if k not in ('trial_days', 'buy_url', 'price_text', 'gumroad_product_id', 'wfp_merchant', 'wfp_secret', 'wfp_domain', 'price_uah') then raise exception 'unknown setting'; end if;
  if k = 'wfp_secret' and v like '****%' then return; end if;   -- маска из панели: ключ не менялся
  if k = 'price_uah' then v := regexp_replace(replace(coalesce(v, ''), ',', '.'), '[^0-9.]', '', 'g'); end if;
  if k = 'wfp_domain' then v := lower(regexp_replace(regexp_replace(coalesce(v, ''), '^https?://', ''), '/.*$', '')); end if;
  insert into app_settings(key, value) values (k, trim(coalesce(v, ''))) on conflict (key) do update set value = excluded.value;
end $$;

create or replace function public.admin_settings()
returns jsonb language sql security definer set search_path = public as $$
  select case when lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then null
    else coalesce((select jsonb_object_agg(key, case when key = 'wfp_secret' and value <> '' then '****' || right(value, 4) else value end) from app_settings), '{}'::jsonb) end;
$$;

-- 8. Статистика: заказы.
create or replace function public.admin_orders()
returns jsonb language sql security definer set search_path = public as $$
  select case when lower(coalesce(auth.jwt() ->> 'email','')) <> 'uliapetrenko154@gmail.com' then null
    else coalesce((select jsonb_agg(jsonb_build_object('ref', ref, 'amount', amount, 'status', status, 'created_at', created_at, 'paid_at', paid_at) order by created_at desc)
                   from (select * from orders order by created_at desc limit 100) t), '[]'::jsonb) end;
$$;
revoke all on function public.admin_orders() from public;
grant execute on function public.admin_orders() to authenticated;
