-- PharmaPlus multi-pharmacy schema. Run the whole file in Supabase SQL Editor.
create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('admin','pharmacist','cashier','storekeeper','manager','staff');
exception when duplicate_object then null; end $$;

create table if not exists public.pharmacies (
  id uuid primary key default gen_random_uuid(), name text not null default 'PharmaPlus Pharmacy',
  location text, contact text, email text, logo_url text, currency text not null default 'USh',
  created_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade, email text, full_name text,
  role public.user_role not null default 'staff', active boolean not null default true,
  pharmacy_id uuid references public.pharmacies(id) on delete cascade, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.profiles add column if not exists pharmacy_id uuid references public.pharmacies(id) on delete cascade;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(), name text not null, category text not null, batch text not null,
  expiry date not null, qty integer not null default 0 check(qty>=0),
  buy numeric(14,2) not null default 0 check(buy>=0), sell numeric(14,2) not null default 0 check(sell>=0),
  created_by uuid references auth.users(id), pharmacy_id uuid references public.pharmacies(id) on delete cascade, created_at timestamptz not null default now()
);
alter table public.products add column if not exists pharmacy_id uuid references public.pharmacies(id) on delete cascade;

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(), receipt text not null default ('R'||substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  sale_type text not null default 'walk_in', business_name text, total numeric(14,2) not null default 0,
  profit numeric(14,2) not null default 0, payment text not null default 'Cash', status text not null default 'completed',
  created_by uuid references auth.users(id), pharmacy_id uuid references public.pharmacies(id) on delete cascade,
  created_at timestamptz not null default now(), paid_at timestamptz
);
alter table public.sales add column if not exists sale_type text default 'walk_in';
alter table public.sales add column if not exists business_name text;
alter table public.sales add column if not exists status text default 'completed';
alter table public.sales add column if not exists paid_at timestamptz;
alter table public.sales add column if not exists pharmacy_id uuid references public.pharmacies(id) on delete cascade;
alter table public.sales add column if not exists total numeric(14,2) default 0;
alter table public.sales add column if not exists profit numeric(14,2) default 0;
alter table public.sales add column if not exists payment text default 'Cash';
-- Legacy columns are kept if they already existed; the new app uses sale_items for multi-drug sales.
alter table public.sales add column if not exists product_id uuid references public.products(id);
alter table public.sales add column if not exists product_name text;
alter table public.sales add column if not exists qty integer;
alter table public.sales alter column product_name drop not null;
alter table public.sales alter column qty drop not null;

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid references public.products(id), product_name text not null, batch text, qty integer not null check(qty>0),
  unit_sell numeric(14,2) not null default 0, unit_buy numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0, line_profit numeric(14,2) not null default 0,
  pharmacy_id uuid references public.pharmacies(id) on delete cascade, created_at timestamptz not null default now()
);

create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(), supplier_name text not null, amount numeric(14,2) not null default 0 check(amount>=0),
  purchase_date date not null default current_date, invoice_url text, invoice_name text,
  created_by uuid references auth.users(id), pharmacy_id uuid references public.pharmacies(id) on delete cascade, created_at timestamptz not null default now()
);
alter table public.purchases add column if not exists supplier_name text;
alter table public.purchases add column if not exists amount numeric(14,2) default 0;
alter table public.purchases add column if not exists purchase_date date default current_date;
alter table public.purchases add column if not exists invoice_url text;
alter table public.purchases add column if not exists invoice_name text;
alter table public.purchases add column if not exists pharmacy_id uuid references public.pharmacies(id) on delete cascade;
alter table public.purchases add column if not exists product_name text;
alter table public.purchases add column if not exists qty integer;
alter table public.purchases add column if not exists unit_cost numeric(14,2);
alter table public.purchases add column if not exists total numeric(14,2);
alter table public.purchases alter column product_name drop not null;
alter table public.purchases alter column qty drop not null;
alter table public.purchases alter column unit_cost drop not null;
alter table public.purchases alter column total drop not null;

-- Existing settings table is retained for backward compatibility; the application now uses pharmacies.
create table if not exists public.settings (id integer primary key default 1, name text not null default 'PharmaPlus Pharmacy', currency text not null default 'USh', updated_at timestamptz not null default now());

-- Create a pharmacy/profile for users that existed before this multi-pharmacy schema.
do $$ declare r record; pid uuid; begin
  for r in select id,email from public.profiles where pharmacy_id is null loop
    insert into public.pharmacies(name,created_by) values ('PharmaPlus Pharmacy',r.id) returning id into pid;
    update public.profiles set pharmacy_id=pid, role=case when role='staff' then 'admin' else role end where id=r.id;
  end loop;
end $$;

-- Users signing up after this migration receive their own pharmacy workspace.
create table if not exists public.staff_invites (id uuid primary key default gen_random_uuid(), pharmacy_id uuid not null references public.pharmacies(id) on delete cascade, code text not null unique, role public.user_role not null, expires_at timestamptz not null, used_at timestamptz, used_by uuid references auth.users(id), created_by uuid references auth.users(id), created_at timestamptz not null default now());
create index if not exists staff_invites_pharmacy_idx on public.staff_invites(pharmacy_id);
alter table public.staff_invites enable row level security;
drop policy if exists staff_invites_select on public.staff_invites;
drop policy if exists staff_invites_insert on public.staff_invites;
create policy staff_invites_select on public.staff_invites for select to authenticated using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin']::public.user_role[]));
create policy staff_invites_insert on public.staff_invites for insert to authenticated with check(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]) and created_by=auth.uid());

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $function$
declare pid uuid; assigned_role public.user_role := 'staff'; inv record; invite_code text;
begin
 invite_code := upper(trim(coalesce(new.raw_user_meta_data->>'invite_code','')));
 if invite_code <> '' then
  select * into inv from public.staff_invites where upper(trim(code))=invite_code and used_at is null and expires_at>now() limit 1 for update;
  if not found then raise exception 'Invalid or expired staff invitation code: %', invite_code; end if;
  pid:=inv.pharmacy_id; assigned_role:=inv.role;
  insert into public.profiles(id,email,full_name,role,pharmacy_id) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),assigned_role,pid)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,role=excluded.role,pharmacy_id=excluded.pharmacy_id,updated_at=now();
  update public.staff_invites set used_at=now(),used_by=new.id where id=inv.id;
 else
  insert into public.pharmacies(name,location,contact,created_by) values(coalesce(nullif(trim(new.raw_user_meta_data->>'pharmacy_name'),''),'PharmaPlus Pharmacy'),nullif(trim(new.raw_user_meta_data->>'pharmacy_location'),''),nullif(trim(new.raw_user_meta_data->>'pharmacy_contact'),''),new.id) returning id into pid;
  assigned_role:='admin';
  insert into public.profiles(id,email,full_name,role,pharmacy_id) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),assigned_role,pid) on conflict(id) do nothing;
 end if;
 return new;
end; $function$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

update public.products x set pharmacy_id=p.pharmacy_id from public.profiles p where x.pharmacy_id is null and x.created_by=p.id;
update public.sales x set pharmacy_id=p.pharmacy_id from public.profiles p where x.pharmacy_id is null and x.created_by=p.id;
update public.purchases x set pharmacy_id=p.pharmacy_id from public.profiles p where x.pharmacy_id is null and x.created_by=p.id;
update public.sale_items x set pharmacy_id=s.pharmacy_id from public.sales s where x.pharmacy_id is null and x.sale_id=s.id;

create or replace function public.current_role() returns public.user_role language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() and active=true limit 1 $$;
create or replace function public.current_pharmacy() returns uuid language sql stable security definer set search_path=public as $$ select pharmacy_id from public.profiles where id=auth.uid() and active=true limit 1 $$;
create or replace function public.has_role(allowed public.user_role[]) returns boolean language sql stable security definer set search_path=public as $$ select coalesce(public.current_role()=any(allowed),false) $$;



-- Role policy update: Cashier is retired; existing Cashier profiles become Pharmacists.
update public.profiles set role='pharmacist' where role='cashier';

drop policy if exists staff_invites_select on public.staff_invites;
drop policy if exists staff_invites_insert on public.staff_invites;
create policy staff_invites_select on public.staff_invites for select to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));
create policy staff_invites_insert on public.staff_invites for insert to authenticated
  with check(
    pharmacy_id=public.current_pharmacy()
    and created_by=auth.uid()
    and (public.has_role(array['admin']::public.user_role[])
      or (public.has_role(array['manager']::public.user_role[]) and role in ('pharmacist','storekeeper','staff')))
  );

drop policy if exists profiles_update_admin on public.profiles;
drop policy if exists profiles_update_staff on public.profiles;
create policy profiles_update_staff on public.profiles for update to authenticated
  using(pharmacy_id=public.current_pharmacy() and (public.has_role(array['admin']::public.user_role[]) or (public.has_role(array['manager']::public.user_role[]) and role <> 'admin')))
  with check(pharmacy_id=public.current_pharmacy() and (public.has_role(array['admin']::public.user_role[]) or (public.has_role(array['manager']::public.user_role[]) and role in ('pharmacist','storekeeper','staff'))));

-- Atomic multi-drug sale transaction. This prevents a sale from partially saving or reducing stock incorrectly.
create or replace function public.create_sale(
  p_sale_type text,
  p_business_name text,
  p_payment text,
  p_items jsonb
) returns table(sale_id uuid, receipt text, total numeric, profit numeric)
language plpgsql security definer set search_path=public as $$
declare
  v_pharmacy uuid := public.current_pharmacy();
  v_sale_id uuid := gen_random_uuid();
  v_receipt text := 'R' || substr(replace(gen_random_uuid()::text,'-',''),1,8);
  v_total numeric(14,2) := 0;
  v_profit numeric(14,2) := 0;
  it record; pr record; q integer;
begin
  if auth.uid() is null or v_pharmacy is null then raise exception 'Not authenticated or pharmacy profile missing'; end if;
  if p_sale_type not in ('walk_in','wholesale') then raise exception 'Invalid sale type'; end if;
  if p_sale_type='wholesale' and nullif(trim(p_business_name),'') is null then raise exception 'Business name is required for wholesale sales'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) < 1 then raise exception 'Add at least one drug'; end if;

  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    q := it.qty;
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy for update;
    if not found then raise exception 'Medicine not found'; end if;
    if q is null or q < 1 then raise exception 'Invalid quantity for %',pr.name; end if;
    if pr.qty < q then raise exception 'Insufficient stock for % (available %)',pr.name,pr.qty; end if;
    v_total := v_total + (pr.sell*q);
    v_profit := v_profit + ((pr.sell-pr.buy)*q);
  end loop;

  insert into public.sales(id,receipt,sale_type,business_name,total,profit,payment,status,created_by,pharmacy_id,paid_at)
  values(v_sale_id,v_receipt,p_sale_type,nullif(trim(p_business_name),''),v_total,v_profit,p_payment,'completed',auth.uid(),v_pharmacy,now());

  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy for update;
    insert into public.sale_items(sale_id,product_id,product_name,batch,qty,unit_sell,unit_buy,line_total,line_profit,pharmacy_id)
    values(v_sale_id,pr.id,pr.name,pr.batch,it.qty,pr.sell,pr.buy,pr.sell*it.qty,(pr.sell-pr.buy)*it.qty,v_pharmacy);
    update public.products set qty=qty-it.qty where id=pr.id and pharmacy_id=v_pharmacy;
  end loop;
  return query select v_sale_id,v_receipt,v_total,v_profit;
end; $$;

alter table public.pharmacies enable row level security;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.purchases enable row level security;
alter table public.settings enable row level security;

drop policy if exists pharmacies_select on public.pharmacies;
drop policy if exists pharmacies_update on public.pharmacies;
create policy pharmacies_select on public.pharmacies for select to authenticated using(id=public.current_pharmacy());
create policy pharmacies_update on public.pharmacies for update to authenticated using(id=public.current_pharmacy() and public.has_role(array['admin']::public.user_role[])) with check(id=public.current_pharmacy());

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using(pharmacy_id=public.current_pharmacy());
create policy profiles_update_admin on public.profiles for update to authenticated using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin']::public.user_role[])) with check(pharmacy_id=public.current_pharmacy());

drop policy if exists products_all on public.products;
create policy products_all on public.products for all to authenticated using(pharmacy_id=public.current_pharmacy()) with check(pharmacy_id=public.current_pharmacy());
drop policy if exists sales_all on public.sales;
create policy sales_all on public.sales for all to authenticated using(pharmacy_id=public.current_pharmacy()) with check(pharmacy_id=public.current_pharmacy());
drop policy if exists sale_items_all on public.sale_items;
create policy sale_items_all on public.sale_items for all to authenticated using(pharmacy_id=public.current_pharmacy()) with check(pharmacy_id=public.current_pharmacy());
drop policy if exists purchases_all on public.purchases;
create policy purchases_all on public.purchases for all to authenticated using(pharmacy_id=public.current_pharmacy()) with check(pharmacy_id=public.current_pharmacy());

-- Purchase invoices and pharmacy logos.
insert into storage.buckets(id,name,public) values('pharmaplus-files','pharmaplus-files',true) on conflict(id) do nothing;
drop policy if exists pharmaplus_files_select on storage.objects;
drop policy if exists pharmaplus_files_insert on storage.objects;
drop policy if exists pharmaplus_files_update on storage.objects;
drop policy if exists pharmaplus_files_delete on storage.objects;
create policy pharmaplus_files_select on storage.objects for select to authenticated using(bucket_id='pharmaplus-files');
create policy pharmaplus_files_insert on storage.objects for insert to authenticated with check(bucket_id='pharmaplus-files' and (storage.foldername(name))[1]=public.current_pharmacy()::text);
create policy pharmaplus_files_update on storage.objects for update to authenticated using(bucket_id='pharmaplus-files' and (storage.foldername(name))[1]=public.current_pharmacy()::text);
create policy pharmaplus_files_delete on storage.objects for delete to authenticated using(bucket_id='pharmaplus-files' and (storage.foldername(name))[1]=public.current_pharmacy()::text);

create index if not exists products_pharmacy_idx on public.products(pharmacy_id);
create index if not exists sales_pharmacy_date_idx on public.sales(pharmacy_id,created_at);
create index if not exists sale_items_sale_idx on public.sale_items(sale_id);
create index if not exists purchases_pharmacy_date_idx on public.purchases(pharmacy_id,purchase_date);

-- Legacy customers/suppliers are no longer used by the application. They are left intact so existing data is not deleted.

-- =========================================================
-- PharmaPlus adjustments: brands, dates, archive, stock history, expenses
-- =========================================================
alter table public.products add column if not exists brand_name text not null default '';
alter table public.products add column if not exists entered_date date not null default current_date;
alter table public.products add column if not exists archived boolean not null default false;
alter table public.sale_items add column if not exists brand_name text;

create table if not exists public.product_stock_history (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  previous_qty integer not null default 0,
  new_qty integer not null default 0,
  change_qty integer not null default 0,
  reason text,
  created_by uuid references auth.users(id),
  pharmacy_id uuid references public.pharmacies(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  category text not null check(category in ('Rent','Bills','Wages','Tax','Subscriptions','Others')),
  other_description text,
  amount numeric(14,2) not null check(amount>=0),
  expense_date date not null default current_date,
  notes text,
  document_url text,
  document_name text,
  created_by uuid references auth.users(id),
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.product_stock_history enable row level security;
alter table public.expenses enable row level security;

drop policy if exists product_stock_history_select on public.product_stock_history;
create policy product_stock_history_select on public.product_stock_history for select to authenticated
  using(pharmacy_id=public.current_pharmacy());
drop policy if exists product_stock_history_insert on public.product_stock_history;
create policy product_stock_history_insert on public.product_stock_history for insert to authenticated
  with check(pharmacy_id=public.current_pharmacy() and (created_by=auth.uid() or created_by is null));

drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check(pharmacy_id=public.current_pharmacy() and created_by=auth.uid() and public.has_role(array['admin','manager']::public.user_role[]));
drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]))
  with check(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));
drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));

-- Only Admin/Manager may change price or quantity. Other roles may edit descriptive fields.
create or replace function public.enforce_product_edit_permissions()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not public.has_role(array['admin','manager']::public.user_role[]) then
    if new.qty is distinct from old.qty or new.buy is distinct from old.buy or new.sell is distinct from old.sell then
      raise exception 'Only Admin and Manager can change medicine price or quantity';
    end if;
    if new.archived is distinct from old.archived then
      raise exception 'Only Admin and Manager can archive or restore medicines';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists products_edit_permissions on public.products;
create trigger products_edit_permissions before update on public.products
for each row execute function public.enforce_product_edit_permissions();

-- Log stock changes automatically for an audit trail.
create or replace function public.log_product_stock_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    insert into public.product_stock_history(product_id,previous_qty,new_qty,change_qty,reason,created_by,pharmacy_id)
    values(new.id,0,new.qty,new.qty,'Initial stock',coalesce(new.created_by,auth.uid()),new.pharmacy_id);
  elsif new.qty is distinct from old.qty then
    insert into public.product_stock_history(product_id,previous_qty,new_qty,change_qty,reason,created_by,pharmacy_id)
    values(new.id,old.qty,new.qty,new.qty-old.qty,'Stock adjustment',auth.uid(),new.pharmacy_id);
  end if;
  return new;
end; $$;
drop trigger if exists products_stock_history on public.products;
create trigger products_stock_history after insert or update of qty on public.products
for each row execute function public.log_product_stock_change();

-- Ensure sale history keeps the brand used at the time of sale.
create or replace function public.create_sale(
  p_sale_type text,
  p_business_name text,
  p_payment text,
  p_items jsonb
) returns table(sale_id uuid, receipt text, total numeric, profit numeric)
language plpgsql security definer set search_path=public as $$
declare
  v_pharmacy uuid := public.current_pharmacy();
  v_sale_id uuid := gen_random_uuid();
  v_receipt text := 'R' || substr(replace(gen_random_uuid()::text,'-',''),1,8);
  v_total numeric(14,2) := 0;
  v_profit numeric(14,2) := 0;
  it record; pr record; q integer;
begin
  if auth.uid() is null or v_pharmacy is null then raise exception 'Not authenticated or pharmacy profile missing'; end if;
  if p_sale_type not in ('walk_in','wholesale') then raise exception 'Invalid sale type'; end if;
  if p_sale_type='wholesale' and nullif(trim(p_business_name),'') is null then raise exception 'Business name is required for wholesale sales'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) < 1 then raise exception 'Add at least one drug'; end if;
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    q:=it.qty;
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived for update;
    if not found then raise exception 'Medicine not found or archived'; end if;
    if q is null or q<1 then raise exception 'Invalid quantity for %',pr.name; end if;
    if pr.qty<q then raise exception 'Insufficient stock for % (available %)',pr.name,pr.qty; end if;
    v_total:=v_total+(pr.sell*q); v_profit:=v_profit+((pr.sell-pr.buy)*q);
  end loop;
  insert into public.sales(id,receipt,sale_type,business_name,total,profit,payment,status,created_by,pharmacy_id,paid_at)
  values(v_sale_id,v_receipt,p_sale_type,nullif(trim(p_business_name),''),v_total,v_profit,p_payment,'completed',auth.uid(),v_pharmacy,now());
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived for update;
    insert into public.sale_items(sale_id,product_id,product_name,brand_name,batch,qty,unit_sell,unit_buy,line_total,line_profit,pharmacy_id)
    values(v_sale_id,pr.id,pr.name,pr.brand_name,pr.batch,it.qty,pr.sell,pr.buy,pr.sell*it.qty,(pr.sell-pr.buy)*it.qty,v_pharmacy);
    update public.products set qty=qty-it.qty where id=pr.id and pharmacy_id=v_pharmacy;
  end loop;
  return query select v_sale_id,v_receipt,v_total,v_profit;
end; $$;

create index if not exists product_stock_history_product_idx on public.product_stock_history(product_id,created_at);
create index if not exists product_stock_history_pharmacy_idx on public.product_stock_history(pharmacy_id,created_at);
create index if not exists expenses_pharmacy_date_idx on public.expenses(pharmacy_id,expense_date);

-- Tighten product deletion: the UI uses Archive, and only Admin/Manager may permanently delete rows.
drop policy if exists products_all on public.products;
drop policy if exists products_select on public.products;
drop policy if exists products_insert on public.products;
drop policy if exists products_update on public.products;
drop policy if exists products_delete on public.products;
create policy products_select on public.products for select to authenticated
  using(pharmacy_id=public.current_pharmacy());
create policy products_insert on public.products for insert to authenticated
  with check(pharmacy_id=public.current_pharmacy());
create policy products_update on public.products for update to authenticated
  using(pharmacy_id=public.current_pharmacy())
  with check(pharmacy_id=public.current_pharmacy());
create policy products_delete on public.products for delete to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));

-- Reorder level is retired; low-stock display uses a simple fixed 10-unit warning.
alter table public.products drop column if exists reorder;

-- =========================================================
-- PharmaPlus V7: wholesale/retail pricing + pending sales
-- =========================================================
alter table public.products add column if not exists wholesale_price numeric(14,2) not null default 0 check(wholesale_price>=0);
alter table public.products add column if not exists retail_price numeric(14,2) not null default 0 check(retail_price>=0);
update public.products set retail_price=sell where retail_price=0 and sell>0;
update public.products set wholesale_price=sell where wholesale_price=0 and sell>0;

-- Keep historical sale/product links usable when a medicine is permanently deleted.
alter table public.sale_items drop constraint if exists sale_items_product_id_fkey;
alter table public.sale_items add constraint sale_items_product_id_fkey foreign key(product_id) references public.products(id) on delete set null;
alter table public.sales drop constraint if exists sales_product_id_fkey;
alter table public.sales add constraint sales_product_id_fkey foreign key(product_id) references public.products(id) on delete set null;

-- Admin/Manager only for permanent medicine deletion.
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete to authenticated
  using(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]));

-- Completed sale RPC uses the correct price category and deducts stock atomically.
create or replace function public.create_sale(
  p_sale_type text,
  p_business_name text,
  p_payment text,
  p_items jsonb
) returns table(sale_id uuid, receipt text, total numeric, profit numeric)
language plpgsql security definer set search_path=public as $$
declare
  v_pharmacy uuid := public.current_pharmacy();
  v_sale_id uuid := gen_random_uuid();
  v_receipt text := 'R' || substr(replace(gen_random_uuid()::text,'-',''),1,8);
  v_total numeric(14,2) := 0;
  v_profit numeric(14,2) := 0;
  it record; pr record; q integer; v_price numeric(14,2);
begin
  if auth.uid() is null or v_pharmacy is null then raise exception 'Not authenticated or pharmacy profile missing'; end if;
  if p_sale_type not in ('walk_in','wholesale') then raise exception 'Invalid sale type'; end if;
  if p_sale_type='wholesale' and nullif(trim(p_business_name),'') is null then raise exception 'Business name is required for wholesale sales'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) < 1 then raise exception 'Add at least one drug'; end if;
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    q:=it.qty;
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived for update;
    if not found then raise exception 'Medicine not found or archived'; end if;
    if q is null or q<1 then raise exception 'Invalid quantity for %',pr.name; end if;
    if pr.qty<q then raise exception 'Insufficient stock for % (available %)',pr.name,pr.qty; end if;
    v_price:=case when p_sale_type='wholesale' then pr.wholesale_price else pr.retail_price end;
    v_total:=v_total+(v_price*q); v_profit:=v_profit+((v_price-pr.buy)*q);
  end loop;
  insert into public.sales(id,receipt,sale_type,business_name,total,profit,payment,status,created_by,pharmacy_id,paid_at)
  values(v_sale_id,v_receipt,p_sale_type,nullif(trim(p_business_name),''),v_total,v_profit,coalesce(p_payment,'Cash'),'completed',auth.uid(),v_pharmacy,now());
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived for update;
    v_price:=case when p_sale_type='wholesale' then pr.wholesale_price else pr.retail_price end;
    insert into public.sale_items(sale_id,product_id,product_name,brand_name,batch,qty,unit_sell,unit_buy,line_total,line_profit,pharmacy_id)
    values(v_sale_id,pr.id,pr.name,pr.brand_name,pr.batch,it.qty,v_price,pr.buy,v_price*it.qty,(v_price-pr.buy)*it.qty,v_pharmacy);
    update public.products set qty=qty-it.qty where id=pr.id and pharmacy_id=v_pharmacy;
  end loop;
  return query select v_sale_id,v_receipt,v_total,v_profit;
end; $$;

-- Create a pending sale. It records the basket and prices but NEVER deducts stock.
create or replace function public.create_pending_sale(
  p_sale_type text,
  p_business_name text,
  p_payment text,
  p_items jsonb
) returns table(sale_id uuid, receipt text, total numeric, profit numeric)
language plpgsql security definer set search_path=public as $$
declare
  v_pharmacy uuid := public.current_pharmacy();
  v_sale_id uuid := gen_random_uuid();
  v_receipt text := 'R' || substr(replace(gen_random_uuid()::text,'-',''),1,8);
  v_total numeric(14,2) := 0; v_profit numeric(14,2) := 0;
  it record; pr record; q integer; v_price numeric(14,2);
begin
  if auth.uid() is null or v_pharmacy is null then raise exception 'Not authenticated or pharmacy profile missing'; end if;
  if p_sale_type not in ('walk_in','wholesale') then raise exception 'Invalid sale type'; end if;
  if p_sale_type='wholesale' and nullif(trim(p_business_name),'') is null then raise exception 'Business name is required for wholesale sales'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) < 1 then raise exception 'Add at least one drug'; end if;
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    q:=it.qty;
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived;
    if not found then raise exception 'Medicine not found or archived'; end if;
    if q is null or q<1 then raise exception 'Invalid quantity for %',pr.name; end if;
    if pr.qty<q then raise exception 'Insufficient stock for % (available %)',pr.name,pr.qty; end if;
    v_price:=case when p_sale_type='wholesale' then pr.wholesale_price else pr.retail_price end;
    v_total:=v_total+(v_price*q); v_profit:=v_profit+((v_price-pr.buy)*q);
  end loop;
  insert into public.sales(id,receipt,sale_type,business_name,total,profit,payment,status,created_by,pharmacy_id)
  values(v_sale_id,v_receipt,p_sale_type,nullif(trim(p_business_name),''),v_total,v_profit,coalesce(p_payment,'Cash'),'pending',auth.uid(),v_pharmacy);
  for it in select * from jsonb_to_recordset(p_items) as x(product_id uuid, qty integer) loop
    select * into pr from public.products where id=it.product_id and pharmacy_id=v_pharmacy and not archived;
    v_price:=case when p_sale_type='wholesale' then pr.wholesale_price else pr.retail_price end;
    insert into public.sale_items(sale_id,product_id,product_name,brand_name,batch,qty,unit_sell,unit_buy,line_total,line_profit,pharmacy_id)
    values(v_sale_id,pr.id,pr.name,pr.brand_name,pr.batch,it.qty,v_price,pr.buy,v_price*it.qty,(v_price-pr.buy)*it.qty,v_pharmacy);
  end loop;
  return query select v_sale_id,v_receipt,v_total,v_profit;
end; $$;

-- Complete an existing pending sale and deduct stock only at this moment.
create or replace function public.complete_pending_sale(p_sale_id uuid)
returns table(sale_id uuid, receipt text, total numeric, profit numeric)
language plpgsql security definer set search_path=public as $$
declare
  v_pharmacy uuid := public.current_pharmacy(); s record; i record; pr record;
begin
  if auth.uid() is null or v_pharmacy is null then raise exception 'Not authenticated or pharmacy profile missing'; end if;
  select * into s from public.sales where id=p_sale_id and pharmacy_id=v_pharmacy for update;
  if not found then raise exception 'Sale not found'; end if;
  if s.status='rejected' then raise exception 'Rejected sales cannot be completed'; end if;
  if s.status='completed' then return query select s.id,s.receipt,s.total,s.profit; return; end if;
  if s.status<>'pending' then raise exception 'Sale is not pending'; end if;
  for i in select * from public.sale_items where sale_id=s.id order by created_at for update loop
    select * into pr from public.products where id=i.product_id and pharmacy_id=v_pharmacy and not archived for update;
    if not found then raise exception 'Medicine for sale item no longer exists'; end if;
    if pr.qty < i.qty then raise exception 'Insufficient stock for % (available %)',pr.name,pr.qty; end if;
  end loop;
  for i in select * from public.sale_items where sale_id=s.id order by created_at loop
    update public.products set qty=qty-i.qty where id=i.product_id and pharmacy_id=v_pharmacy;
  end loop;
  update public.sales set status='completed',paid_at=now() where id=s.id;
  return query select s.id,s.receipt,s.total,s.profit;
end; $$;

-- Rejecting a pending sale does not touch stock.
create or replace function public.reject_pending_sale(p_sale_id uuid)
returns boolean
language plpgsql security definer set search_path=public as $$
declare v_pharmacy uuid := public.current_pharmacy(); v_status text;
begin
  select status into v_status from public.sales where id=p_sale_id and pharmacy_id=v_pharmacy for update;
  if v_status is null then raise exception 'Sale not found'; end if;
  if v_status='completed' then raise exception 'Completed sales cannot be rejected'; end if;
  if v_status='rejected' then return true; end if;
  update public.sales set status='rejected' where id=p_sale_id and pharmacy_id=v_pharmacy and status='pending';
  return true;
end; $$;

create index if not exists sales_status_idx on public.sales(pharmacy_id,status,created_at);


-- V7: Managers may also create invitations for operational roles.
drop policy if exists staff_invites_insert on public.staff_invites;
create policy staff_invites_insert on public.staff_invites for insert to authenticated
  with check(pharmacy_id=public.current_pharmacy() and public.has_role(array['admin','manager']::public.user_role[]) and created_by=auth.uid());
