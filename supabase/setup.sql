-- =====================================================================
-- Diary Apps v2: phone + PIN login, one-device lock, IP log, dropdown status/plan.
-- Run ONCE in Supabase -> SQL Editor. Safe to run again.
-- Works on top of your existing public.subscriptions table (device_id now = login phone number).
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- 1. subscriptions: base table + new columns ----------
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  device_id text unique not null,                -- = the user's login phone number
  plan text not null default 'free',
  status text not null default 'free',
  payment_method text,
  receiving_number text not null default '01756475499',
  sender_phone text,
  trx_id text,
  amount numeric(10,2) default 0,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_subs_on_update on public.subscriptions;
drop trigger if exists trg_subs_after_update on public.subscriptions;
drop function if exists public.subs_on_update();

-- ---------- 2. dropdown (enum) types: pick from a list instead of typing ----------
do $$ begin create type public.sub_plan   as enum ('free','monthly','yearly');                          exception when duplicate_object then null; end $$;
do $$ begin create type public.sub_status as enum ('free','pending','active','rejected','expired');     exception when duplicate_object then null; end $$;

alter table public.subscriptions add column if not exists requested_plan public.sub_plan;
alter table public.subscriptions add column if not exists reference text;
alter table public.subscriptions add column if not exists admin_note text;

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='subscriptions' and column_name='plan' and data_type='text') then
    update public.subscriptions set plan = case
      when lower(coalesce(plan,'')) ~ '(year|annual)' then 'yearly'
      when lower(coalesce(plan,'free')) in ('','free') then 'free' else 'monthly' end;
    alter table public.subscriptions alter column plan drop default;
    alter table public.subscriptions alter column plan type public.sub_plan using plan::public.sub_plan;
    alter table public.subscriptions alter column plan set default 'free';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='subscriptions' and column_name='requested_plan' and data_type='text') then
    update public.subscriptions set requested_plan = case
      when requested_plan is null then null
      when lower(requested_plan) ~ '(year|annual)' then 'yearly'
      when lower(requested_plan) in ('','free') then null else 'monthly' end;
    alter table public.subscriptions alter column requested_plan type public.sub_plan using requested_plan::public.sub_plan;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='subscriptions' and column_name='status' and data_type='text') then
    update public.subscriptions set status = case lower(trim(coalesce(status,'')))
      when 'active' then 'active' when 'pending' then 'pending' when 'rejected' then 'rejected' when 'expired' then 'expired' else 'free' end;
    alter table public.subscriptions alter column status drop default;
    alter table public.subscriptions alter column status type public.sub_status using status::public.sub_status;
    alter table public.subscriptions alter column status set default 'free';
  end if;
end $$;

-- ---------- 3. login / device columns ----------
alter table public.subscriptions add column if not exists pin_hash text;                          -- hashed PIN (never readable)
alter table public.subscriptions add column if not exists fail_count int not null default 0;
alter table public.subscriptions add column if not exists locked_until timestamptz;
alter table public.subscriptions add column if not exists allow_multi_device boolean not null default false;  -- SPECIAL OPTION: tick to allow many devices
alter table public.subscriptions add column if not exists pay_device uuid;                        -- the device that paid
alter table public.subscriptions add column if not exists last_ip text;
alter table public.subscriptions add column if not exists business_name text;
alter table public.subscriptions add column if not exists business_phone text;
alter table public.subscriptions add column if not exists business_address text;
alter table public.subscriptions add column if not exists business_logo text;

-- ---------- 4. device + IP log ----------
create table if not exists public.device_logins (
  id uuid primary key default gen_random_uuid(),
  phone text not null references public.subscriptions(device_id) on delete cascade on update cascade,
  install_id text not null,              -- random id of this app installation
  token_hash text,                       -- hashed session token
  ip_address text,                       -- IP at first login from this device
  last_ip text,                          -- IP at latest activity
  device_model text,
  active boolean not null default true,  -- false = this device is locked out
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  unique (phone, install_id)
);
create index if not exists device_logins_phone on public.device_logins(phone);

create table if not exists public.login_events (
  id bigserial primary key,
  phone text, install_id text, ip_address text, event text,
  created_at timestamptz not null default now()
);

-- ---------- 5. lock everything: the app can only use the functions below ----------
alter table public.subscriptions enable row level security;
alter table public.device_logins enable row level security;
alter table public.login_events  enable row level security;
drop policy if exists "Allow public read"   on public.subscriptions;
drop policy if exists "Allow public insert" on public.subscriptions;
drop policy if exists "Allow public update" on public.subscriptions;
revoke all on public.subscriptions, public.device_logins, public.login_events from anon, authenticated;
revoke all on sequence public.login_events_id_seq from anon, authenticated;

-- ---------- 6. helpers ----------
create or replace function public.client_ip() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip',
    split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1),
    '')
$$;

create or replace function public.plan_period(p public.sub_plan) returns interval language sql immutable as $$
  select case p when 'yearly' then interval '365 days' else interval '30 days' end
$$;

create or replace function public._session(p_phone text, p_token text) returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select id from public.device_logins
   where phone = p_phone and active and token_hash is not null
     and token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex')
   limit 1
$$;

create or replace function public._status_json(p_phone text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', plan,
    'status', case when status = 'active' and expires_at is not null and expires_at <= now() then 'expired' else status::text end,
    'requested_plan', requested_plan,
    'expires_at', expires_at,
    'admin_note', admin_note,
    'trx_id', trx_id,
    'allow_multi', allow_multi_device,
    'updated_at', updated_at)
  from public.subscriptions where device_id = p_phone
$$;

-- ---------- 7. approval triggers (you only pick the dropdown values) ----------
create or replace function public.subs_before_update() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'active' and old.status is distinct from 'active' then
    if new.requested_plan is not null then new.plan := new.requested_plan; end if;
    if new.plan = 'free' then new.plan := 'monthly'; end if;         -- an active plan is always paid
    if old.status = 'pending' then                                   -- approving a payment (renewals stack)
      new.expires_at := greatest(now(), coalesce(old.expires_at, now())) + public.plan_period(new.plan);
    elsif new.expires_at is null or new.expires_at <= now() then      -- manual grant
      new.expires_at := now() + public.plan_period(new.plan);
    end if;
    new.requested_plan := null;
  end if;
  return new;
end $$;

create or replace function public.subs_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare keep uuid;
begin
  -- plan just became active: only the paying device may keep using it (unless multi-device is ticked)
  if new.status = 'active' and old.status is distinct from 'active' and not new.allow_multi_device then
    keep := coalesce(new.pay_device, (select id from public.device_logins where phone = new.device_id order by last_seen desc limit 1));
    update public.device_logins set active = (id = keep) where phone = new.device_id;
  -- multi-device switched OFF while a plan is running: keep only the most recent device
  elsif old.allow_multi_device and not new.allow_multi_device and new.plan <> 'free' and new.expires_at > now() then
    keep := (select id from public.device_logins where phone = new.device_id order by last_seen desc limit 1);
    update public.device_logins set active = (id = keep) where phone = new.device_id;
  end if;
  return null;
end $$;

create trigger trg_subs_on_update before update on public.subscriptions
  for each row execute function public.subs_before_update();
create trigger trg_subs_after_update after update on public.subscriptions
  for each row execute function public.subs_after_update();

-- ---------- 8. app functions ----------
drop function if exists public.submit_subscription_request(text,text,numeric,text,text,text,text);
drop function if exists public.get_subscription_status(text);

-- Login / create account. Failures return {ok:false,error:'...'} (so wrong-PIN counting is saved).
create or replace function public.app_login(p_phone text, p_pin text, p_install text, p_model text, p_create boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.subscriptions; d public.device_logins; ip text := public.client_ip(); tok text; plan_live boolean;
begin
  if p_phone !~ '^01[3-9][0-9]{8}$' then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if p_pin !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok', false, 'error', 'bad_pin_format'); end if;
  if coalesce(length(p_install), 0) < 8 then return jsonb_build_object('ok', false, 'error', 'bad_install'); end if;

  select * into a from public.subscriptions where device_id = p_phone for update;

  if p_create then
    if found and a.pin_hash is not null then
      insert into public.login_events(phone, install_id, ip_address, event) values (p_phone, p_install, ip, 'register_exists');
      return jsonb_build_object('ok', false, 'error', 'phone_exists');
    end if;
    if not found then
      insert into public.subscriptions(device_id, pin_hash, last_ip) values (p_phone, crypt(p_pin, gen_salt('bf')), ip) returning * into a;
    else  -- admin reset the PIN (pin_hash is empty): set a new one
      update public.subscriptions set pin_hash = crypt(p_pin, gen_salt('bf')), fail_count = 0, locked_until = null
       where device_id = p_phone returning * into a;
    end if;
  else
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    if a.pin_hash is null then return jsonb_build_object('ok', false, 'error', 'pin_not_set'); end if;
    if a.locked_until is not null and a.locked_until > now() then
      insert into public.login_events(phone, install_id, ip_address, event) values (p_phone, p_install, ip, 'locked');
      return jsonb_build_object('ok', false, 'error', 'too_many');
    end if;
    if crypt(p_pin, a.pin_hash) <> a.pin_hash then
      update public.subscriptions
         set fail_count   = case when fail_count + 1 >= 5 then 0 else fail_count + 1 end,
             locked_until = case when fail_count + 1 >= 5 then now() + interval '15 minutes' else locked_until end
       where device_id = p_phone;
      insert into public.login_events(phone, install_id, ip_address, event) values (p_phone, p_install, ip, 'bad_pin');
      return jsonb_build_object('ok', false, 'error', 'bad_pin');
    end if;
  end if;

  -- one-device lock: while a paid plan is running, only already-bound devices may log in
  plan_live := a.plan <> 'free' and a.expires_at is not null and a.expires_at > now();
  select * into d from public.device_logins where phone = p_phone and install_id = p_install;
  if not (found and d.active) and plan_live and not a.allow_multi_device then
    insert into public.login_events(phone, install_id, ip_address, event) values (p_phone, p_install, ip, 'device_locked');
    return jsonb_build_object('ok', false, 'error', 'device_locked');
  end if;

  tok := gen_random_uuid()::text;
  insert into public.device_logins(phone, install_id, token_hash, ip_address, last_ip, device_model, active)
  values (p_phone, p_install, encode(digest(tok, 'sha256'), 'hex'), ip, ip, left(coalesce(p_model, ''), 60), true)
  on conflict (phone, install_id) do update
    set token_hash = excluded.token_hash, last_ip = excluded.last_ip, last_seen = now(),
        active = true, device_model = excluded.device_model;

  update public.subscriptions set fail_count = 0, locked_until = null, last_ip = ip where device_id = p_phone;
  insert into public.login_events(phone, install_id, ip_address, event) values (p_phone, p_install, ip, case when p_create then 'register' else 'login' end);

  return jsonb_build_object('ok', true, 'token', tok,
    'profile', jsonb_build_object('name', a.business_name, 'phone', a.business_phone, 'address', a.business_address, 'logo', a.business_logo),
    'status', public._status_json(p_phone));
end $$;

-- Poll: current plan + checks that this device is still allowed
create or replace function public.app_status(p_phone text, p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare did uuid := public._session(p_phone, p_token);
begin
  if did is null then return jsonb_build_object('ok', false, 'error', 'session_invalid'); end if;
  update public.device_logins set last_seen = now(), last_ip = public.client_ip() where id = did;
  return jsonb_build_object('ok', true) || public._status_json(p_phone);
end $$;

-- Payment request: always created as 'pending'; the plan stays as it was
create or replace function public.app_submit_payment(
  p_phone text, p_token text, p_plan text, p_amount numeric, p_method text, p_sender text, p_trx text, p_reference text
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare did uuid := public._session(p_phone, p_token); a public.subscriptions; t text := upper(trim(p_trx));
begin
  if did is null then raise exception 'session_invalid'; end if;
  if p_plan not in ('monthly','yearly') then raise exception 'invalid_plan'; end if;
  if p_sender !~ '^01[3-9][0-9]{8}$' then raise exception 'invalid_sender'; end if;
  if length(t) < 6 or length(t) > 40 then raise exception 'invalid_trx'; end if;
  select * into a from public.subscriptions where device_id = p_phone for update;
  if a.status = 'pending' then raise exception 'pending_exists'; end if;
  if exists (select 1 from public.subscriptions where upper(trx_id) = t and device_id <> p_phone and status <> 'rejected')
     or (upper(coalesce(a.trx_id, '')) = t and a.status = 'active') then
    raise exception 'trx_used';
  end if;
  update public.subscriptions
     set status = 'pending', requested_plan = p_plan::public.sub_plan, payment_method = lower(left(p_method, 20)),
         sender_phone = p_sender, trx_id = t, amount = p_amount, reference = left(coalesce(p_reference, ''), 80),
         admin_note = null, pay_device = did
   where device_id = p_phone;
  return jsonb_build_object('ok', true, 'status', 'pending');
end $$;

create or replace function public.app_save_profile(p_phone text, p_token text, p_name text, p_bphone text, p_addr text, p_logo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if public._session(p_phone, p_token) is null then return jsonb_build_object('ok', false, 'error', 'session_invalid'); end if;
  if length(coalesce(p_logo, '')) > 80000 then return jsonb_build_object('ok', false, 'error', 'logo_too_big'); end if;
  update public.subscriptions
     set business_name = left(p_name, 80), business_phone = left(p_bphone, 20), business_address = left(p_addr, 160),
         business_logo = nullif(p_logo, '')
   where device_id = p_phone;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_logout(p_phone text, p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare did uuid := public._session(p_phone, p_token);
begin
  if did is not null then update public.device_logins set token_hash = null where id = did; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 9. permissions: the app may call only these five ----------
revoke all on function public.client_ip(), public.plan_period(public.sub_plan), public._session(text,text), public._status_json(text) from public, anon, authenticated;
revoke all on function public.app_login(text,text,text,text,boolean), public.app_status(text,text),
  public.app_submit_payment(text,text,text,numeric,text,text,text,text),
  public.app_save_profile(text,text,text,text,text,text), public.app_logout(text,text) from public;
grant execute on function public.app_login(text,text,text,text,boolean) to anon;
grant execute on function public.app_status(text,text) to anon;
grant execute on function public.app_submit_payment(text,text,text,numeric,text,text,text,text) to anon;
grant execute on function public.app_save_profile(text,text,text,text,text,text) to anon;
grant execute on function public.app_logout(text,text) to anon;

-- ---------- 10. cloud backup + change PIN ----------
create table if not exists public.cloud_backups (
  phone text primary key references public.subscriptions(device_id) on delete cascade on update cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.cloud_backups enable row level security;
revoke all on public.cloud_backups from anon, authenticated;

create or replace function public.app_cloud_save(p_phone text, p_token text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if public._session(p_phone, p_token) is null then return jsonb_build_object('ok', false, 'error', 'session_invalid'); end if;
  if length(p_data::text) > 6000000 then return jsonb_build_object('ok', false, 'error', 'too_big'); end if;
  insert into public.cloud_backups(phone, data, updated_at) values (p_phone, p_data, now())
  on conflict (phone) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_cloud_load(p_phone text, p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b public.cloud_backups;
begin
  if public._session(p_phone, p_token) is null then return jsonb_build_object('ok', false, 'error', 'session_invalid'); end if;
  select * into b from public.cloud_backups where phone = p_phone;
  if not found then return jsonb_build_object('ok', false, 'error', 'none'); end if;
  return jsonb_build_object('ok', true, 'data', b.data, 'updated_at', b.updated_at);
end $$;

create or replace function public.app_change_pin(p_phone text, p_token text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a public.subscriptions;
begin
  if public._session(p_phone, p_token) is null then return jsonb_build_object('ok', false, 'error', 'session_invalid'); end if;
  if p_new !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok', false, 'error', 'bad_pin_format'); end if;
  select * into a from public.subscriptions where device_id = p_phone for update;
  if a.pin_hash is null or crypt(coalesce(p_old, ''), a.pin_hash) <> a.pin_hash then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;
  update public.subscriptions set pin_hash = crypt(p_new, gen_salt('bf')) where device_id = p_phone;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.app_cloud_save(text,text,jsonb), public.app_cloud_load(text,text), public.app_change_pin(text,text,text,text) from public;
grant execute on function public.app_cloud_save(text,text,jsonb) to anon;
grant execute on function public.app_cloud_load(text,text) to anon;
grant execute on function public.app_change_pin(text,text,text,text) to anon;

-- =====================================================================
-- ADMIN GUIDE (Table Editor -> subscriptions)
--  * Approve payment : open the row with status = pending -> status dropdown = active -> Save
--                      (plan + expiry are filled automatically; the paying device becomes the only allowed device)
--  * Reject          : status dropdown = rejected (optional admin_note) -> Save
--  * Manual grant    : set plan dropdown (monthly/yearly) + status dropdown = active -> Save
--  * Many devices    : tick allow_multi_device -> Save (untick to go back to one device)
--  * Forgot PIN      : set pin_hash to NULL -> the user taps "Create account" and chooses a new PIN
--  * Cloud backups   : Table Editor -> cloud_backups (one row per phone number)
--  * Device / IP log : Table Editor -> device_logins (ip_address, last_ip, device_model, active) and login_events
-- =====================================================================
