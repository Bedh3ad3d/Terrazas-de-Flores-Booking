-- Supabase SQL Editor. Safe to re-run after dropping the tables. pg_cron is no longer needed.
do $$ begin perform cron.unschedule('expire-holds'); exception when others then null; end $$;
drop function if exists create_booking(text,timestamptz,text,text);
drop function if exists create_booking(text,int,timestamptz,text,text,text);
drop function if exists create_booking(text,int,timestamptz,text,text,text,text);
drop function if exists taken_slots(timestamptz,timestamptz);
drop policy if exists "customers upload receipts" on storage.objects;
drop policy if exists "admin views receipts" on storage.objects;
-- If you ran the earlier version, drop its tables first: drop table bookings, services cascade;
create table reservation_types(
  name text primary key, min_pax int, max_pax int, per_pax int,
  exclusive bool, buffet bool, hours int, area text, online bool default true);
insert into reservation_types values
 ('Regular table',1,14,0,false,false,2,'Main cafe'),
 ('Intimate event',15,20,850,true,false,3,'Veranda'),
 ('Group event',21,35,800,true,true,3,'Main cafe'),
 ('Wedding',21,35,1000,true,true,3,'Main cafe'),
 ('Debut',21,35,1000,true,true,3,'Main cafe');
update reservation_types set online=false where name='Wedding';  -- weddings are planned by message

create table areas(name text primary key, capacity int);
insert into areas values('Veranda',20),('Main cafe',40),('Outdoor',30);  -- Outdoor is a placeholder: set your real number
alter table areas enable row level security;

create table bookings(
  id uuid primary key default gen_random_uuid(),
  type text references reservation_types(name), pax int,
  slot timestamptz not null, ends_at timestamptz not null, exclusive bool, area text,
  min_spend int, due int, decor text, preorder text, name text, contact text,
  status text not null default 'pending'
    check (status in ('pending','awaiting_verification','confirmed','rejected','expired')),
  receipt_path text, hold_expires timestamptz, created_at timestamptz default now());

alter table reservation_types enable row level security;
alter table bookings enable row level security;
create policy "public reads types" on reservation_types for select using (true);
create policy "admin reads" on bookings for select to authenticated using (true);
create policy "admin updates" on bookings for update to authenticated using (true);

insert into storage.buckets(id,name,public) values('receipts','receipts',false) on conflict do nothing;
create policy "customers upload receipts" on storage.objects for insert to anon with check (bucket_id='receipts');
create policy "admin views receipts" on storage.objects for select to authenticated using (bucket_id='receipts');

create or replace function expire_holds() returns void language sql security definer as $$
  update bookings set status='expired'
  where status in ('pending','awaiting_verification') and hold_expires < now(); $$;

create or replace function create_booking(p_type text,p_pax int,p_slot timestamptz,p_name text,p_contact text,p_decor text,p_area text,p_preorder text)
returns jsonb language plpgsql security definer as $$
declare t reservation_types; v_end timestamptz; v_due int; v_id uuid; v_cap int;
begin
  perform pg_advisory_xact_lock(42);
  perform expire_holds();
  select * into t from reservation_types where name=p_type;
  if t.name is null or p_pax<t.min_pax or p_pax>t.max_pax then
    raise exception 'Party size does not fit this reservation type'; end if;
  if not t.online then raise exception 'WEDDING_MESSAGE'; end if;
  if p_area not in ('Veranda','Outdoor','Main cafe') then raise exception 'Choose a seating area'; end if;
  if t.exclusive and length(coalesce(trim(p_preorder),''))<3 then raise exception 'PREORDER_REQUIRED'; end if;
  v_end := p_slot + t.hours*interval '1 hour';
  if p_slot<now() or (p_slot at time zone 'Asia/Manila')::time<'07:00'
     or (v_end at time zone 'Asia/Manila')::time>'20:00' then
    raise exception 'Outside opening hours (7:00 AM to 8:00 PM)'; end if;
  -- Regular bookings may overlap each other. Exclusive use may not overlap anything in the same chosen area.
  if exists(select 1 from bookings b where b.slot<v_end and b.ends_at>p_slot
     and b.area=p_area and b.status in ('pending','awaiting_verification','confirmed') and (t.exclusive or b.exclusive)) then
    raise exception 'PRIOR_RESERVATION'; end if;
  select capacity into v_cap from areas where name=p_area;
  if coalesce((select sum(b.pax) from bookings b where b.area=p_area and b.slot<v_end and b.ends_at>p_slot
     and b.status in ('pending','awaiting_verification','confirmed')),0)+p_pax>v_cap then raise exception 'AREA_FULL'; end if;
  -- Events: 30% of the minimum spend. Regular tables: flat 1,500 above 8 guests (no per-guest bill).
  v_due := case when t.per_pax>0 then ceil(t.per_pax*p_pax*0.3)::int when p_pax>8 then 1500 else 0 end;
  insert into bookings(type,pax,slot,ends_at,exclusive,area,min_spend,due,decor,name,contact,status,hold_expires,preorder)
  values(t.name,p_pax,p_slot,v_end,t.exclusive,p_area,t.per_pax*p_pax,v_due,p_decor,trim(p_name),trim(p_contact),
    case when v_due=0 then 'confirmed' else 'pending' end,
    null,trim(p_preorder))
  returning id into v_id;
  return jsonb_build_object('id',v_id,'due',v_due,'min_spend',t.per_pax*p_pax);
end $$;

create or replace function submit_payment(p_id uuid,p_path text) returns boolean language plpgsql security definer as $$
begin
  update bookings set receipt_path=p_path,status='awaiting_verification'
  where id=p_id and status='pending' and p_path is not null;
  return found;
end $$;
grant execute on function create_booking, submit_payment to anon, authenticated;
-- No payment deadline: unpaid bookings stay held until you cancel them in admin.html.
