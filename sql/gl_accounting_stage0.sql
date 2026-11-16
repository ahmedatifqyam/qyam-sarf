-- المحاسبة (المرحلة 0): مستخرجة من قاعدة التجربة في 16 نوفمبر 2026 (أنشأتها جلسة أخرى مباشرة على التجربة دون ملف)
create table if not exists public.gl_accounts (
  company_id text not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null check (kind in ('asset','liability','equity','income','expense')),
  parent_code text,
  is_group boolean not null default false,
  is_active boolean not null default true,
  note text,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (company_id, code));
create table if not exists public.gl_custody_accounts (
  company_id text not null references public.companies(id) on delete cascade,
  holder_id text not null,
  code text not null,
  primary key (company_id, holder_id));
create table if not exists public.gl_exports (
  id bigserial primary key,
  company_id text not null references public.companies(id) on delete cascade,
  month date not null,
  entries integer not null default 0,
  total numeric not null default 0,
  unlinked integer not null default 0,
  exported_by text,
  exported_by_name text,
  exported_at timestamptz not null default now());
alter table public.gl_accounts enable row level security;
alter table public.gl_custody_accounts enable row level security;
alter table public.gl_exports enable row level security;
drop policy if exists gl_acc_sel on public.gl_accounts;
drop policy if exists gl_cust_sel on public.gl_custody_accounts;
drop policy if exists gl_exp_sel on public.gl_exports;
create policy gl_acc_sel on public.gl_accounts for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
create policy gl_cust_sel on public.gl_custody_accounts for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
create policy gl_exp_sel on public.gl_exports for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
grant select, insert, update, delete on public.gl_accounts, public.gl_custody_accounts, public.gl_exports to authenticated;
alter table public.budget_items add column if not exists gl_expense text;
alter table public.budget_items add column if not exists gl_income text;
alter table public.companies add column if not exists gl_cash text default '120101';
alter table public.companies add column if not exists gl_custody_parent text default '120201';
alter table public.companies add column if not exists gl_opening text default '2901';
alter table public.companies add column if not exists gl_share text default '4402';
alter table public.companies add column if not exists gl_unlinked_mode text default 'warn';
alter table public.centers add column if not exists gl_expense text;
alter table public.centers add column if not exists gl_trust text;

CREATE OR REPLACE FUNCTION public.qy_gl_block_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare m text; r public.requests; holder text; acct text;
begin
  if new.source_type <> 'request' or new.direction <> 'out' or new.reverses_id is not null then return new; end if;
  select gl_unlinked_mode into m from public.companies where id = new.company_id;
  if coalesce(m,'warn') <> 'block' then return new; end if;
  select * into r from public.requests where id = new.source_id;
  if coalesce(r.amount_route,'normal') <> 'normal' then return new; end if;
  select holder_id into holder from public.custodies where request_id = new.source_id limit 1;
  if r.request_type = 'custody' or holder is not null then
    select code into acct from public.gl_custody_accounts where company_id = new.company_id and holder_id = holder;
    if acct is null then raise exception 'لا يُصرف قبل ربط صاحب العهدة بحساب عهدة في «المحاسبة ← ربط الحسابات»'; end if;
    return new;
  end if;
  acct := coalesce(public.qy_gl_trust_of(coalesce(new.center_id, r.center_id)), public.qy_gl_exp_of(new.budget_item_id, coalesce(new.center_id, r.center_id)));
  if acct is null then raise exception 'لا يُصرف قبل ربط بند الطلب أو وحدته بحساب في «المحاسبة ← ربط الحسابات» (إعداد الشركة: منع الصرف حتى الربط)'; end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_can(p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.is_admin() or (public.is_finance() and public.can_see_company(p_company));
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_copy_chart(p_from text, p_to text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n int;
begin
  if not (public.qy_gl_can(p_from) and public.qy_gl_can(p_to)) then raise exception 'للمالية ومدير النظام'; end if;
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, is_active, note, updated_by)
  select p_to, code, name, kind, parent_code, is_group, is_active, note, public.qy_me() from public.gl_accounts where company_id=p_from
  on conflict do nothing;
  get diagnostics n = row_count; return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_delete_account(p_company text, p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.qy_gl_can(p_company) then raise exception 'دليل الحسابات للمالية ومدير النظام'; end if;
  if exists (select 1 from public.gl_accounts where company_id=p_company and parent_code=p_code) then raise exception 'للحساب حسابات تتبعه، انقلها أولاً'; end if;
  if exists (select 1 from public.budget_items where company_id=p_company and (gl_expense=p_code or gl_income=p_code))
     or exists (select 1 from public.centers where company_id=p_company and (gl_trust=p_code or gl_expense=p_code))
     or exists (select 1 from public.gl_custody_accounts where company_id=p_company and code=p_code)
     or exists (select 1 from public.companies where id=p_company and p_code in (gl_cash, gl_share, gl_opening, gl_custody_parent)) then
    raise exception 'الحساب مربوط ببند أو مركز أو إعداد؛ أوقفه بدل حذفه'; end if;
  delete from public.gl_accounts where company_id=p_company and code=p_code;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_exp_of(p_item text, p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select gl_expense from public.budget_items where id=p_item),
                  (select gl_expense from public.centers where id=p_center),
                  (select c.gl_expense from public.qy_unit_up(p_center) u join public.centers c on c.id=u.id where c.gl_expense is not null order by u.depth limit 1));
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_inc_of(p_item text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select gl_income from public.budget_items where id=p_item;
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_journal(p_company text, p_from date, p_to date)
 RETURNS TABLE(entry_key text, entry_date date, ref text, source text, description text, account_code text, account_name text, debit numeric, credit numeric, flag text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare co public.companies;
begin
  if not public.qy_gl_can(p_company) then raise exception 'كشف الحركات للمالية ومدير النظام'; end if;
  select * into co from public.companies where id=p_company;
  return query
  with
  tx as (
    select t.*, r.request_type, coalesce(r.amount_route,'normal') as route, r.number as req_no,
           coalesce(t.center_id, r.center_id) as ctr,
           k.holder_id as c_holder, k.remaining_action as c_action
    from public.transactions t
    left join public.requests r on r.id = t.source_id and t.source_type in ('request','refund')
    left join public.custodies k on (t.source_type='custody' and k.id::text = t.source_id) or (t.source_type='request' and k.request_id = t.source_id)
    where t.company_id=p_company and t.tx_date between p_from and p_to
  ),
  lines as (
    select 'tx:'||t.id::text k, t.tx_date d, coalesce(t.req_no, t.source_id) rf, 'صرف طلب'::text src, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,'') ds,
      case when t.direction='out' then
        case when t.request_type='custody' or t.c_holder is not null then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder)
             when public.qy_gl_trust_of(t.ctr) is not null then public.qy_gl_trust_of(t.ctr)
             else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end
      else co.gl_cash end ac,
      t.amount dr, 0::numeric cr, case when t.request_type='custody' or t.c_holder is not null then 'عهدة' else null end fl
    from tx t where t.source_type='request' and t.route='normal'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'صرف طلب', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='out' then co.gl_cash
        else case when t.request_type='custody' or t.c_holder is not null then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder)
             when public.qy_gl_trust_of(t.ctr) is not null then public.qy_gl_trust_of(t.ctr)
             else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end end,
      0, t.amount, null
    from tx t where t.source_type='request' and t.route='normal'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'استرداد', coalesce(t.description,''),
      case when t.direction='in' then co.gl_cash else coalesce(public.qy_gl_trust_of(t.ctr), public.qy_gl_exp_of(t.budget_item_id, t.ctr)) end, t.amount, 0, null
    from tx t where t.source_type='refund'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'استرداد', coalesce(t.description,''),
      case when t.direction='in' then coalesce(public.qy_gl_trust_of(t.ctr), public.qy_gl_exp_of(t.budget_item_id, t.ctr)) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type='refund'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.source_id,''), case t.source_type when 'revenue' then 'إيراد' when 'recurring' then 'قيد دوري' else 'قيد يدوي' end, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then co.gl_cash else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end, t.amount, 0, null
    from tx t where t.source_type not in ('request','refund','custody')
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.source_id,''), case t.source_type when 'revenue' then 'إيراد' when 'recurring' then 'قيد دوري' else 'قيد يدوي' end, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then coalesce(public.qy_gl_inc_of(t.budget_item_id), public.qy_gl_trust_of(t.ctr)) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type not in ('request','refund','custody')
    union all
    select 'tx:'||t.id::text, t.tx_date, 'عهدة '||t.source_id, 'إقفال عهدة', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then co.gl_cash else (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder) end, t.amount, 0, null
    from tx t where t.source_type='custody' and coalesce(t.c_action,'') not in ('carry','carry_debt')
    union all
    select 'tx:'||t.id::text, t.tx_date, 'عهدة '||t.source_id, 'إقفال عهدة', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type='custody' and coalesce(t.c_action,'') not in ('carry','carry_debt')
    union all
    select 'cl:'||l.id::text, k.closed_at::date, 'عهدة '||k.id::text, 'مصروف عهدة', coalesce(l.description,'')||coalesce(' — فاتورة '||nullif(l.invoice_no,''),''),
      case when l.kind='expense' then public.qy_gl_exp_of(k.budget_item_id, null) else (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=k.holder_id) end,
      l.amount, 0, case when l.no_doc then 'بلا مستند' else null end
    from public.custody_lines l join public.custodies k on k.id=l.custody_id
    where k.company_id=p_company and k.status='closed' and l.status='accepted' and k.closed_at::date between p_from and p_to
    union all
    select 'cl:'||l.id::text, k.closed_at::date, 'عهدة '||k.id::text, 'مصروف عهدة', coalesce(l.description,'')||coalesce(' — فاتورة '||nullif(l.invoice_no,''),''),
      case when l.kind='expense' then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=k.holder_id) else coalesce(public.qy_gl_inc_of(k.budget_item_id), public.qy_gl_exp_of(k.budget_item_id, null)) end,
      0, l.amount, null
    from public.custody_lines l join public.custodies k on k.id=l.custody_id
    where k.company_id=p_company and k.status='closed' and l.status='accepted' and k.closed_at::date between p_from and p_to
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'opening' then 'رصيد افتتاحي لمركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      case when e.kind='opening' then co.gl_opening
           when e.request_id is not null then (select public.qy_gl_exp_of(r.budget_item_id, r.center_id) from public.requests r where r.id=e.request_id)
           else co.gl_cash end,
      case when e.gross - coalesce(e.gateway_fee,0) >= 0 then e.gross - coalesce(e.gateway_fee,0) else 0 end,
      case when e.gross - coalesce(e.gateway_fee,0) < 0 then -(e.gross - coalesce(e.gateway_fee,0)) else 0 end,
      case when e.kind='opening' then 'افتتاحي' else null end
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind <> 'transfer' and e.entry_date between p_from and p_to
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'opening' then 'رصيد افتتاحي لمركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      public.qy_gl_trust_of(e.center_id),
      case when e.net < 0 then -e.net else 0 end, case when e.net >= 0 then e.net else 0 end, null
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind <> 'transfer' and e.entry_date between p_from and p_to and e.net <> 0
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||' — حصة الشركة', co.gl_share,
      case when e.company_share < 0 then -e.company_share else 0 end, case when e.company_share >= 0 then e.company_share else 0 end, null
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind not in ('transfer','opening') and e.entry_date between p_from and p_to and coalesce(e.company_share,0) <> 0
    union all
    select 'cb:'||least(e.id, coalesce(e.pair_id, e.id))::text, e.entry_date, '', 'ترحيل بين مراكز', coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      public.qy_gl_trust_of(e.center_id), case when e.net < 0 then -e.net else 0 end, case when e.net > 0 then e.net else 0 end, null
    from public.center_ledger e left join public.center_ledger p on p.id = e.pair_id
    where e.company_id=p_company and not e.voided and e.kind='transfer' and e.entry_date between p_from and p_to
      and public.qy_gl_trust_of(e.center_id) is distinct from public.qy_gl_trust_of(p.center_id)
  )
  select l.k, l.d, l.rf, l.src, l.ds, l.ac, a.name,
         round(l.dr, 3), round(l.cr, 3),
         nullif(concat_ws(' · ', case when l.ac is null then 'بلا حساب' end, l.fl), '')
  from lines l left join public.gl_accounts a on a.company_id=p_company and a.code=l.ac
  where coalesce(l.dr,0) <> 0 or coalesce(l.cr,0) <> 0
  order by l.d, l.k, (l.dr = 0), l.ac;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_link(p_company text, p_target text, p_id text, p_field text, p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c text := nullif(btrim(coalesce(p_code,'')),'');
begin
  if not public.qy_gl_can(p_company) then raise exception 'الربط للمالية ومدير النظام'; end if;
  if p_target = 'company' and p_field = 'unlinked_mode' then
    if p_code not in ('warn','block') then raise exception 'قيمة غير صالحة'; end if;
    update public.companies set gl_unlinked_mode=p_code where id=p_company; return;
  end if;
  if c is not null and not exists (select 1 from public.gl_accounts where company_id=p_company and code=c) then raise exception 'الحساب % غير موجود في الدليل', c; end if;
  if p_target = 'item' then
    if p_field = 'expense' then update public.budget_items set gl_expense=c where id=p_id and company_id=p_company;
    elsif p_field = 'income' then update public.budget_items set gl_income=c where id=p_id and company_id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  elsif p_target = 'unit' then
    if p_field = 'trust' then update public.centers set gl_trust=c where id=p_id and company_id=p_company;
    elsif p_field = 'expense' then update public.centers set gl_expense=c where id=p_id and company_id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  elsif p_target = 'holder' then
    if c is null then delete from public.gl_custody_accounts where company_id=p_company and holder_id=p_id;
    else insert into public.gl_custody_accounts(company_id, holder_id, code) values (p_company, p_id, c)
         on conflict (company_id, holder_id) do update set code=excluded.code; end if;
  elsif p_target = 'company' then
    if p_field = 'cash' then update public.companies set gl_cash=c where id=p_company;
    elsif p_field = 'share' then update public.companies set gl_share=c where id=p_company;
    elsif p_field = 'opening' then update public.companies set gl_opening=c where id=p_company;
    elsif p_field = 'custody_parent' then update public.companies set gl_custody_parent=c where id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  else raise exception 'هدف غير صالح'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_mark_exported(p_company text, p_month date, p_entries integer, p_total numeric, p_unlinked integer)
 RETURNS gl_exports
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare x public.gl_exports;
begin
  if not public.qy_gl_can(p_company) then raise exception 'للمالية ومدير النظام'; end if;
  insert into public.gl_exports(company_id, month, entries, total, unlinked, exported_by, exported_by_name)
  values (p_company, date_trunc('month', p_month)::date, coalesce(p_entries,0), coalesce(p_total,0), coalesce(p_unlinked,0), public.qy_me(), (select name from public.users where id=public.qy_me()))
  returning * into x;
  return x;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_new_custody_account(p_company text, p_holder text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare par text; nm text; nxt text; n int;
begin
  if not public.qy_gl_can(p_company) then raise exception 'للمالية ومدير النظام'; end if;
  select gl_custody_parent into par from public.companies where id=p_company;
  if par is null or not exists (select 1 from public.gl_accounts where company_id=p_company and code=par) then raise exception 'حدد مجموعة حسابات العهد في الإعدادات أولاً'; end if;
  select name into nm from public.users where id=p_holder;
  if nm is null then raise exception 'صاحب العهدة غير موجود'; end if;
  select coalesce(max(substr(code, length(par)+1)::int), 0) + 1 into n from public.gl_accounts
   where company_id=p_company and parent_code=par and code ~ ('^'||par||'[0-9]{3}$');
  nxt := par || lpad(n::text, 3, '0');
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, updated_by) values (p_company, nxt, 'عهدة '||nm, 'asset', par, false, public.qy_me());
  insert into public.gl_custody_accounts(company_id, holder_id, code) values (p_company, p_holder, nxt)
    on conflict (company_id, holder_id) do update set code=excluded.code;
  return nxt;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_save_account(p_company text, p_old_code text, p_code text, p_name text, p_kind text, p_parent text, p_is_group boolean, p_active boolean, p_note text)
 RETURNS gl_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.gl_accounts;
begin
  if not public.qy_gl_can(p_company) then raise exception 'دليل الحسابات للمالية ومدير النظام'; end if;
  p_code := btrim(coalesce(p_code,'')); p_name := btrim(coalesce(p_name,''));
  if p_code = '' or p_name = '' then raise exception 'رقم الحساب واسمه مطلوبان'; end if;
  if p_code !~ '^[0-9]+$' then raise exception 'رقم الحساب أرقام فقط'; end if;
  if p_kind not in ('asset','liability','equity','income','expense') then raise exception 'نوع الحساب غير صالح'; end if;
  if nullif(btrim(coalesce(p_parent,'')),'') is not null and not exists (select 1 from public.gl_accounts where company_id=p_company and code=btrim(p_parent)) then
    raise exception 'الحساب الأب % غير موجود', p_parent; end if;
  if btrim(coalesce(p_parent,'')) = p_code then raise exception 'الحساب لا يتبع نفسه'; end if;
  if coalesce(p_old_code,'') <> '' and p_old_code <> p_code then
    if exists (select 1 from public.gl_accounts where company_id=p_company and code=p_code) then raise exception 'الرقم % مستخدم لحساب آخر', p_code; end if;
    update public.gl_accounts set code=p_code where company_id=p_company and code=p_old_code;
    update public.gl_accounts set parent_code=p_code where company_id=p_company and parent_code=p_old_code;
    update public.budget_items set gl_expense=p_code where company_id=p_company and gl_expense=p_old_code;
    update public.budget_items set gl_income=p_code where company_id=p_company and gl_income=p_old_code;
    update public.centers set gl_trust=p_code where company_id=p_company and gl_trust=p_old_code;
    update public.centers set gl_expense=p_code where company_id=p_company and gl_expense=p_old_code;
    update public.gl_custody_accounts set code=p_code where company_id=p_company and code=p_old_code;
    update public.companies set gl_cash = case when gl_cash=p_old_code then p_code else gl_cash end,
      gl_share = case when gl_share=p_old_code then p_code else gl_share end,
      gl_opening = case when gl_opening=p_old_code then p_code else gl_opening end,
      gl_custody_parent = case when gl_custody_parent=p_old_code then p_code else gl_custody_parent end
      where id=p_company;
  end if;
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, is_active, note, updated_by, updated_at)
  values (p_company, p_code, p_name, p_kind, nullif(btrim(coalesce(p_parent,'')),''), coalesce(p_is_group,false), coalesce(p_active,true), nullif(btrim(coalesce(p_note,'')),''), public.qy_me(), now())
  on conflict (company_id, code) do update set name=excluded.name, kind=excluded.kind, parent_code=excluded.parent_code,
    is_group=excluded.is_group, is_active=excluded.is_active, note=excluded.note, updated_by=excluded.updated_by, updated_at=now()
  returning * into a;
  return a;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_trust_of(p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select gl_trust from public.centers where id=p_center),
                  (select gl_trust from public.centers where id=public.qy_unit_root(p_center)));
$function$
;

drop trigger if exists trg_qy_gl_block on public.transactions;
create trigger trg_qy_gl_block before insert on public.transactions for each row execute function public.qy_gl_block_guard();
