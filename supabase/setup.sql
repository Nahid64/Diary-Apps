-- Diary Apps: secure manual subscription approval.
-- Works with your existing public.subscriptions table (one row per device). Safe to run more than once.
-- Run in Supabase -> SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  device_id text unique not null,
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

-- extra columns the app flow needs
alter table public.subscriptions add column if not exists requested_plan text;  -- plan the user is asking for (while pending)
alter table public.subscriptions add column if not exists reference text;
alter table public.subscriptions add column if not exists admin_note text;

-- 1) CLOSE THE HOLE: remove the public read/insert/update policies.
--    With them, anyone holding the app's key could set their own row to 'active'.
alter table public.subscriptions enable row level security;
drop policy if exists "Allow public read"   on public.subscriptions;
drop policy if exists "Allow public insert" on public.subscriptions;
drop policy if exists "Allow public update" on public.subscriptions;
revoke all on public.subscriptions from anon, authenticated;

-- 2) When YOU change a pending row to status = 'active', plan + expiry are set automatically
--    (monthly = 30 days, yearly = 365 days; renewals add on top of the remaining time).
create or replace function public.subs_on_update() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'active' and old.status = 'pending' then
    new.plan := coalesce(new.requested_plan, new.plan);
    new.expires_at := greatest(now(), coalesce(old.expires_at, now()))
                      + case new.plan when 'yearly' then interval '365 days' else interval '30 days' end;
    new.requested_plan := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_subs_on_update on public.subscriptions;
create trigger trg_subs_on_update before update on public.subscriptions
  for each row execute function public.subs_on_update();

-- 3) The only two things the app is allowed to do
drop function if exists public.submit_subscription_request(uuid,text,numeric,text,text,text,text);
drop function if exists public.get_subscription_status(uuid);

create or replace function public.submit_subscription_request(
  p_device_id text, p_plan text, p_amount numeric, p_method text,
  p_sender text, p_trx text, p_reference text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur public.subscriptions; t text := upper(trim(p_trx));
begin
  if p_plan not in ('monthly','yearly') then raise exception 'invalid_plan'; end if;
  if length(coalesce(p_device_id,'')) < 8 then raise exception 'invalid_device'; end if;
  if p_sender !~ '^01[3-9][0-9]{8}$' then raise exception 'invalid_sender'; end if;
  if length(t) < 6 or length(t) > 40 then raise exception 'invalid_trx'; end if;

  select * into cur from subscriptions where device_id = p_device_id;
  if found and cur.status = 'pending' then raise exception 'pending_exists'; end if;
  if exists (select 1 from subscriptions
              where upper(trx_id) = t and device_id <> p_device_id and status <> 'rejected')
     or (found and upper(cur.trx_id) = t and cur.status = 'active') then
    raise exception 'trx_used';
  end if;

  insert into subscriptions(device_id, status, requested_plan, payment_method, sender_phone, trx_id, amount, reference)
  values (p_device_id, 'pending', p_plan, lower(left(p_method, 20)), p_sender, t, p_amount, left(coalesce(p_reference,''), 80))
  on conflict (device_id) do update
    set status = 'pending', requested_plan = excluded.requested_plan, payment_method = excluded.payment_method,
        sender_phone = excluded.sender_phone, trx_id = excluded.trx_id, amount = excluded.amount,
        reference = excluded.reference, admin_note = null, updated_at = now();

  return jsonb_build_object('status', 'pending');
end $$;

create or replace function public.get_subscription_status(p_device_id text) returns jsonb
language sql security definer stable set search_path = public as $$
  select to_jsonb(x) from (
    select plan, status, requested_plan, expires_at, admin_note, trx_id, updated_at
      from subscriptions where device_id = p_device_id) x;
$$;

revoke all on function public.submit_subscription_request(text,text,numeric,text,text,text,text) from public;
revoke all on function public.get_subscription_status(text) from public;
grant execute on function public.submit_subscription_request(text,text,numeric,text,text,text,text) to anon;
grant execute on function public.get_subscription_status(text) to anon;

-- HOW TO APPROVE: Table Editor -> subscriptions -> find the row with status = 'pending'
-- (check sender_phone + trx_id in your bKash/Nagad app) -> set status to 'active'.
-- To decline: set status = 'rejected' and optionally write admin_note.
