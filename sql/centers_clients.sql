-- العملاء + دفتر المراكز + استيراد بوابة الدفع + رؤية المراكز (12 نوفمبر 2026) — للتجربة أولاً
-- قابل لإعادة التشغيل. لا يمسّ بيانات قائمة: الأعمدة الجديدة لها قيم افتراضية آمنة، وضبط الرصيد مطفأ افتراضياً.

-- ============ الإعدادات الافتراضية للشركة ============
alter table public.companies add column if not exists gateway_company_pct numeric not null default 5;   -- حصة الشركة من الاشتراكات (بعد رسوم البوابة)
alter table public.companies add column if not exists support_company_pct numeric not null default 10;  -- حصة الشركة من الدعم
alter table public.companies add column if not exists import_stale_days int not null default 7;         -- تحوّل تنبيه آخر رفع إلى الأحمر بعد هذا العدد من الأيام
grant select (gateway_company_pct, support_company_pct, import_stale_days) on public.companies to authenticated;

-- ============ العملاء (جمعية ← فرع ← …) ============
create table if not exists public.clients (
  id text primary key default gen_random_uuid()::text,
  company_id text not null,
  parent_id text references public.clients(id) on delete restrict,
  name text not null, name_en text,
  kind text not null default 'association',
  status text not null default 'active',
  address text, email text, website text, tax_no text,
  phones jsonb not null default '[]'::jsonb,      -- [{number, type}]
  contacts jsonb not null default '[]'::jsonb,    -- [{name, title, phone, email}]
  notes text,
  created_by text, created_at timestamptz not null default now());
create index if not exists clients_company on public.clients(company_id);
alter table public.clients enable row level security;
drop policy if exists clients_all on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));
grant select, insert, update, delete on public.clients to authenticated;

-- ============ أعمدة المركز ============
alter table public.centers add column if not exists client_id text references public.clients(id) on delete set null;
alter table public.centers add column if not exists stage text not null default 'operation';          -- creation | finance | operation | closed
alter table public.centers add column if not exists balance_control boolean not null default false;   -- تفعيل ضبط الرصيد والحد السالب
alter table public.centers add column if not exists overdraft_limit numeric not null default 0;       -- مبلغ محدد يسمح بالسالب إلى حدّه
alter table public.centers add column if not exists company_share_pct numeric;                         -- null = افتراضي الشركة
alter table public.centers add column if not exists support_share_pct numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'centers_stage_chk') then
    alter table public.centers add constraint centers_stage_chk check (stage in ('creation','finance','operation','closed'));
  end if;
end $$;
grant select (client_id, stage, balance_control, overdraft_limit, company_share_pct, support_share_pct) on public.centers to authenticated;

-- ============ رؤية المراكز ============
create table if not exists public.center_access (
  center_id text not null references public.centers(id) on delete cascade,
  user_id text not null,
  mode text not null check (mode in ('allow','deny')),
  primary key (center_id, user_id));
alter table public.center_access enable row level security;
drop policy if exists center_access_sel on public.center_access;
drop policy if exists center_access_wrt on public.center_access;
create policy center_access_sel on public.center_access for select to authenticated using (public.is_admin() or user_id = public.qy_me());
create policy center_access_wrt on public.center_access for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.center_access to authenticated;

create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and (u.role in ('accountant','cfo','executive_manager') or u.center_id = p_center))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ============ من يرفع ملفات البوابة ============
create table if not exists public.gateway_import_users (
  company_id text not null, user_id text not null, primary key (company_id, user_id));
alter table public.gateway_import_users enable row level security;
drop policy if exists giu_sel on public.gateway_import_users;
drop policy if exists giu_wrt on public.gateway_import_users;
create policy giu_sel on public.gateway_import_users for select to authenticated using (public.is_admin() or public.is_finance() or user_id = public.qy_me());
create policy giu_wrt on public.gateway_import_users for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.gateway_import_users to authenticated;

create or replace function public.qy_can_import(p_company text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select public.can_see_company(p_company) and (public.is_admin() or public.is_finance()
     or exists (select 1 from public.gateway_import_users g where g.company_id = p_company and g.user_id = public.qy_me()));
$$;
revoke all on function public.qy_can_import(text) from public, anon;
grant execute on function public.qy_can_import(text) to authenticated;

-- ============ حسابات البوابة وربط منشئ الفاتورة بالمركز ============
create table if not exists public.gateway_accounts (
  id text primary key default gen_random_uuid()::text, company_id text not null,
  name text not null, merchant_id text, active boolean not null default true);
create table if not exists public.gateway_agents (
  id bigserial primary key, company_id text not null, account_id text references public.gateway_accounts(id) on delete cascade,
  agent_name text not null, center_id text references public.centers(id) on delete set null,
  unique (company_id, account_id, agent_name));
alter table public.gateway_accounts enable row level security;
alter table public.gateway_agents enable row level security;
drop policy if exists gwa_all on public.gateway_accounts;
drop policy if exists gwg_all on public.gateway_agents;
create policy gwa_all on public.gateway_accounts for all to authenticated using (public.qy_can_import(company_id)) with check (public.is_admin() or public.is_finance());
create policy gwg_all on public.gateway_agents for all to authenticated using (public.qy_can_import(company_id)) with check (public.qy_can_import(company_id));
grant select, insert, update, delete on public.gateway_accounts, public.gateway_agents to authenticated;
grant usage on sequence public.gateway_agents_id_seq to authenticated;

-- ============ الملفات المرفوعة (تُحفظ كاملة ويمكن تنزيلها) ============
create table if not exists public.gateway_imports (
  id bigserial primary key, company_id text not null, account_id text references public.gateway_accounts(id) on delete set null,
  kind text not null check (kind in ('statement','bills')),
  file_name text, date_from date, date_to date, rows_count int not null default 0,
  content text, uploaded_by text, uploaded_at timestamptz not null default now());
create index if not exists gateway_imports_co on public.gateway_imports(company_id, kind, date_to);
alter table public.gateway_imports enable row level security;
drop policy if exists gwi_sel on public.gateway_imports;
create policy gwi_sel on public.gateway_imports for select to authenticated using (public.qy_can_import(company_id));
grant select on public.gateway_imports to authenticated;

-- ============ دفتر المركز ============
create table if not exists public.center_ledger (
  id bigserial primary key, company_id text not null,
  center_id text references public.centers(id) on delete restrict,       -- null = دفعة معلّقة التصنيف (خارج الرصيد)
  kind text not null check (kind in ('opening','subscription','support','manual','adjust')),
  entry_date date not null default current_date,                            -- تاريخ الدفع الفعلي
  period_from date, period_to date,
  gross numeric not null default 0, gateway_fee numeric not null default 0,
  company_pct numeric, company_share numeric, net numeric,
  method text, purpose text, agent text, receipt text, note text,
  source text not null default 'manual', request_id text, import_id bigint,
  voided boolean not null default false,
  created_by text, created_at timestamptz not null default now());
create unique index if not exists center_ledger_receipt_u on public.center_ledger(company_id, receipt) where receipt is not null;
create index if not exists center_ledger_center on public.center_ledger(center_id, entry_date);
alter table public.center_ledger enable row level security;
drop policy if exists cl_sel on public.center_ledger;
create policy cl_sel on public.center_ledger for select to authenticated
  using (case when center_id is null then public.qy_can_import(company_id) else public.qy_center_can_see(center_id) end);
grant select on public.center_ledger to authenticated;

-- بيانات الدافع (حساسة): للمحاسب ومن يرفع الملفات ومدير النظام فقط
create table if not exists public.center_ledger_payers (
  ledger_id bigint primary key references public.center_ledger(id) on delete cascade,
  company_id text not null, payer_name text, payer_phone text);
create index if not exists clp_company on public.center_ledger_payers(company_id);
alter table public.center_ledger_payers enable row level security;
drop policy if exists clp_sel on public.center_ledger_payers;
create policy clp_sel on public.center_ledger_payers for select to authenticated using (public.qy_can_import(company_id));
grant select on public.center_ledger_payers to authenticated;

-- ============ مسار مبلغ الطلب (دعم) ============
alter table public.requests add column if not exists amount_route text not null default 'normal';
alter table public.requests add column if not exists route_center_id text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'requests_amount_route_chk') then
    alter table public.requests add constraint requests_amount_route_chk check (amount_route in ('normal','center','revenue'));
  end if;
end $$;
grant select (amount_route, route_center_id) on public.requests to authenticated;
grant insert (amount_route, route_center_id), update (amount_route, route_center_id) on public.requests to authenticated;

-- ============ حسابات ============
create or replace function public.qy_round3(x numeric) returns numeric language sql immutable as $$ select round(coalesce(x,0), 3) $$;

-- نسبة الشركة لحركة: دعم أو اشتراك
create or replace function public.qy_center_pct(p_center text, p_support boolean) returns numeric
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select case when p_support then coalesce(ce.support_share_pct, co.support_company_pct, 10)
              else coalesce(ce.company_share_pct, co.gateway_company_pct, 5) end
  from public.centers ce join public.companies co on co.id = ce.company_id where ce.id = p_center;
$$;
revoke all on function public.qy_center_pct(text, boolean) from public, anon, authenticated;

-- الرصيد: صافي الدخل المقيّد ناقص المصروف المكتمل (الطلبات العادية فقط)
create or replace function public.qy_center_balance(p_center text) returns numeric
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select qy_round3(coalesce((select sum(net) from public.center_ledger where center_id = p_center and not voided), 0)
        - coalesce((select sum(total_amount) from public.requests where center_id = p_center and status = 'completed' and not coalesce(is_cancelled,false) and amount_route = 'normal'), 0));
$$;
revoke all on function public.qy_center_balance(text) from public, anon, authenticated;

create or replace function public.qy_center_balances(p_company text) returns table(center_id text, income numeric, expense numeric, balance numeric, pending_requests numeric, pending_payments int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select ce.id,
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided),0)),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status = 'completed' and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    public.qy_center_balance(ce.id),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    0
  from public.centers ce where ce.company_id = p_company and public.qy_center_can_see(ce.id);
$$;
revoke all on function public.qy_center_balances(text) from public, anon;
grant execute on function public.qy_center_balances(text) to authenticated;

-- ============ إدخال يدوي (رصيد افتتاحي / اشتراك / إيراد) ============
create or replace function public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric,
   p_share_pct numeric, p_purpose text, p_note text) returns bigint
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_pct numeric; v_share numeric; v_net numeric; v_id bigint; v_me text := public.qy_me();
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_kind not in ('opening','subscription','support','manual','adjust') then raise exception 'نوع غير صالح'; end if;
  if ce.stage = 'closed' and p_kind <> 'adjust' then raise exception 'المركز مغلق'; end if;
  if p_kind = 'opening' then
    if exists (select 1 from public.center_ledger where center_id = p_center and kind = 'opening' and not voided) then raise exception 'للمركز رصيد افتتاحي مسجّل، ألغِه أولاً ثم أدخل الجديد'; end if;
    v_pct := 0;
  elsif p_kind = 'manual' or p_kind = 'adjust' then v_pct := coalesce(p_share_pct, 0);
  else v_pct := coalesce(p_share_pct, public.qy_center_pct(p_center, p_kind = 'support')); end if;
  v_share := public.qy_round3((coalesce(p_gross,0) - coalesce(p_fee,0)) * v_pct / 100);
  v_net := public.qy_round3(coalesce(p_gross,0) - coalesce(p_fee,0) - v_share);
  insert into public.center_ledger(company_id, center_id, kind, entry_date, period_from, period_to, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by)
  values (ce.company_id, p_center, p_kind, coalesce(p_date, current_date), p_from, p_to, coalesce(p_gross,0), coalesce(p_fee,0), v_pct, v_share, v_net, p_purpose, p_note, 'manual', v_me)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.qy_ledger_add(text,text,date,date,date,numeric,numeric,numeric,text,text) from public, anon;
grant execute on function public.qy_ledger_add(text,text,date,date,date,numeric,numeric,numeric,text,text) to authenticated;

create or replace function public.qy_ledger_void(p_id bigint, p_void boolean) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare l public.center_ledger%rowtype;
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(l.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  update public.center_ledger set voided = coalesce(p_void, true) where id = p_id;
end $$;
revoke all on function public.qy_ledger_void(bigint, boolean) from public, anon;
grant execute on function public.qy_ledger_void(bigint, boolean) to authenticated;

-- إسناد دفعات معلّقة إلى مركز
create or replace function public.qy_ledger_assign(p_ids bigint[], p_center text) returns int
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; n int := 0; l public.center_ledger%rowtype; v_pct numeric; v_share numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not public.qy_can_import(ce.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  v_pct := public.qy_center_pct(p_center, false);
  for l in select * from public.center_ledger where id = any(p_ids) and center_id is null and company_id = ce.company_id loop
    v_share := public.qy_round3((l.gross - l.gateway_fee) * v_pct / 100);
    update public.center_ledger set center_id = p_center, company_pct = v_pct, company_share = v_share, net = public.qy_round3(l.gross - l.gateway_fee - v_share) where id = l.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.qy_ledger_assign(bigint[], text) from public, anon;
grant execute on function public.qy_ledger_assign(bigint[], text) to authenticated;

-- ============ اعتماد استيراد البوابة ============
-- p_rows: [{receipt, txn_date 'YYYY-MM-DD', gross, fee, method, center_id|null, purpose, agent, payer_name, payer_phone}]
-- p_files: [{kind, file_name, date_from, date_to, rows_count, content}]
create or replace function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r jsonb; f jsonb; v_imp bigint; v_first bigint; v_ins int := 0; v_dup int := 0; v_pend int := 0; v_id bigint;
  v_center text; v_pct numeric; v_gross numeric; v_fee numeric; v_share numeric; v_me text := public.qy_me();
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية رفع ملفات البوابة'; end if;
  for f in select * from jsonb_array_elements(coalesce(p_files,'[]'::jsonb)) loop
    insert into public.gateway_imports(company_id, account_id, kind, file_name, date_from, date_to, rows_count, content, uploaded_by)
    values (p_company, nullif(p_account,''), f->>'kind', f->>'file_name', nullif(f->>'date_from','')::date, nullif(f->>'date_to','')::date, coalesce((f->>'rows_count')::int,0), f->>'content', v_me)
    returning id into v_imp;
    if v_first is null then v_first := v_imp; end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_center := nullif(r->>'center_id','');
    if v_center is not null and not exists (select 1 from public.centers where id = v_center and company_id = p_company) then v_center := null; end if;
    v_gross := coalesce((r->>'gross')::numeric,0); v_fee := coalesce((r->>'fee')::numeric,0);
    if exists (select 1 from public.center_ledger where company_id = p_company and receipt = r->>'receipt') then v_dup := v_dup + 1; continue; end if;
    if v_center is not null then
      v_pct := public.qy_center_pct(v_center, false); v_share := public.qy_round3((v_gross - v_fee) * v_pct / 100);
    else v_pct := null; v_share := null; v_pend := v_pend + 1; end if;
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, method, purpose, agent, receipt, source, import_id, created_by)
    values (p_company, v_center, 'subscription', (r->>'txn_date')::date, v_gross, v_fee, v_pct, v_share,
            case when v_center is null then null else public.qy_round3(v_gross - v_fee - v_share) end,
            r->>'method', r->>'purpose', r->>'agent', r->>'receipt', 'import', v_first, v_me)
    returning id into v_id;
    if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
      insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone');
    end if;
    v_ins := v_ins + 1;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'pending', v_pend);
end $$;
revoke all on function public.qy_gateway_commit(text,text,jsonb,jsonb) from public, anon;
grant execute on function public.qy_gateway_commit(text,text,jsonb,jsonb) to authenticated;

-- تنزيل ملف مرفوع
create or replace function public.qy_gateway_file(p_id bigint) returns table(file_name text, content text)
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare g public.gateway_imports%rowtype;
begin
  select * into g from public.gateway_imports where id = p_id;
  if not found or not public.qy_can_import(g.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  return query select g.file_name, g.content;
end $$;
revoke all on function public.qy_gateway_file(bigint) from public, anon;
grant execute on function public.qy_gateway_file(bigint) to authenticated;

-- ============ مراحل المركز ============
create or replace function public.qy_center_set_stage(p_center text, p_stage text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('creation','finance','operation','closed') then raise exception 'مرحلة غير صالحة'; end if;
  if p_stage = 'closed' then
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'للمركز طلبات مفتوحة، أنجزها أو ألغها قبل الإغلاق'; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'رصيد المركز غير مسوّى (%). سوِّ الرصيد بحركة تسوية قبل الإغلاق', v_bal; end if;
  end if;
  update public.centers set stage = p_stage where id = p_center;
end $$;
revoke all on function public.qy_center_set_stage(text, text) from public, anon;
grant execute on function public.qy_center_set_stage(text, text) to authenticated;

-- ============ منع طلب جديد يتجاوز الحد، أو لمركز مغلق ============
create or replace function public.qy_center_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_avail numeric;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception 'المركز مغلق ولا تُنشأ له طلبات جديدة'; end if;
  if ce.balance_control then
    v_avail := public.qy_center_balance(ce.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if coalesce(new.total_amount,0) > v_avail + coalesce(ce.overdraft_limit,0) then
      raise exception 'يتجاوز الطلب الرصيد المتاح للمركز (%) مع حد السالب (%)', v_avail, coalesce(ce.overdraft_limit,0);
    end if;
  end if;
  return new;
end $$;
create or replace trigger qy_center_guard_t before insert on public.requests for each row execute function public.qy_center_guard();

-- ============ تحويل مبلغ الدعم إلى دخل مركز عند اكتمال الصرف ============
create or replace function public.qy_route_income() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_pct numeric; v_share numeric;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.amount_route in ('center','revenue') and new.route_center_id is not null
     and not exists (select 1 from public.center_ledger where request_id = new.id and not voided) then
    v_pct := case when new.amount_route = 'center' then public.qy_center_pct(new.route_center_id, true) else 0 end;
    v_share := public.qy_round3(coalesce(new.total_amount,0) * v_pct / 100);
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, company_pct, company_share, net, purpose, note, source, request_id, created_by)
    values (new.company_id, new.route_center_id, case when new.amount_route = 'center' then 'support' else 'manual' end, current_date,
            coalesce(new.total_amount,0), v_pct, v_share, public.qy_round3(coalesce(new.total_amount,0) - v_share),
            'من الطلب '||coalesce(new.number,new.id), case when new.amount_route = 'revenue' then 'إيراد يدوي عبر الطلب' else 'دعم' end, 'request', new.id, public.qy_me());
  end if;
  return new;
end $$;
create or replace trigger qy_route_income_t after update of status on public.requests for each row execute function public.qy_route_income();

-- ============ تنبيه تأخر رفع الملفات: إشعار المدير يومياً ============
create or replace function public.qy_gateway_stale() returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare c record; v_last date; v_days int;
begin
  for c in select id, import_stale_days from public.companies loop
    select max(date_to) into v_last from public.gateway_imports where company_id = c.id and kind = 'statement';
    if v_last is null then continue; end if;
    v_days := current_date - v_last;
    if v_days > coalesce(c.import_stale_days, 7) then
      perform public.qy_push_enqueue(public.qy_push_admins('import_stale'), 'ملفات بوابة الدفع متأخرة', 'آخر كشف مرفوع حتى '||to_char(v_last,'DD/MM/YYYY')||' ('||v_days||' يوماً)', 'import_stale', null, c.id||':'||to_char(current_date,'YYYYMMDD'), now());
    end if;
  end loop;
end $$;
revoke all on function public.qy_gateway_stale() from public, anon, authenticated;

create or replace function public.qy_push_set_events(p_endpoint text, p_events text[]) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error','note','late','review','self','import_stale'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_events(text,text[]) from public, anon;
grant execute on function public.qy_push_set_events(text,text[]) to authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'qy_gateway_stale';
    perform cron.schedule('qy_gateway_stale', '0 6 * * *', 'select public.qy_gateway_stale()');
  end if;
end $$;

-- 13 نوفمبر: منع ربط جهة بمركز من شركة أخرى، وحذف ما رُبط خطأً
delete from public.gateway_agents g using public.centers c where c.id = g.center_id and c.company_id <> g.company_id;
create or replace function public.qy_gateway_agent_guard() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.center_id is not null and not exists(select 1 from public.centers where id = new.center_id and company_id = new.company_id) then
    raise exception 'المركز المختار لا يتبع هذه الشركة';
  end if;
  return new;
end $$;
drop trigger if exists trg_gateway_agent_guard on public.gateway_agents;
create trigger trg_gateway_agent_guard before insert or update on public.gateway_agents for each row execute function public.qy_gateway_agent_guard();
