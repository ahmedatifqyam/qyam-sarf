-- بنود المركز (نادي، معرض، مشروع…) + حالة الوحدة + ترحيل الرصيد بين البنود (13 نوفمبر 2026) — للتجربة أولاً
-- البند = وحدة تابعة للمركز في الشجرة نفسها (centers.parent_id)، ولها دفترها في center_ledger.
-- قابل لإعادة التشغيل.

alter table public.centers add column if not exists description text;   -- وصف الوحدة (إن لم يُضف سابقاً)

-- ============ الحالة بدل المرحلة ============
-- potential محتمل · open مفتوح · active شغال · closed مغلق
alter table public.centers drop constraint if exists centers_stage_chk;
update public.centers set stage = case stage when 'creation' then 'potential' when 'finance' then 'active' when 'operation' then 'active' else stage end
 where stage in ('creation','finance','operation');
alter table public.centers alter column stage set default 'active';
alter table public.centers add constraint centers_stage_chk check (stage in ('potential','open','active','closed'));

alter table public.centers add column if not exists pre_pay boolean not null default false;      -- يُصرف له قبل الدفع (في حالة «مفتوح»)
alter table public.centers add column if not exists continuous boolean not null default false;   -- مستمر: لا يُقترح إغلاقه بانتهاء المدة
alter table public.centers add column if not exists period_from date;
alter table public.centers add column if not exists period_to date;
alter table public.centers add column if not exists item_budget numeric;                          -- ميزانية البند لمرة واحدة (اختياري)
alter table public.centers add column if not exists transfer_user_ids text[] not null default '{}'; -- من يرحّل الرصيد بين بنود المركز (غير المالية ومدير النظام)
grant select (pre_pay, continuous, period_from, period_to, item_budget, transfer_user_ids) on public.centers to authenticated;

-- ============ الشجرة: أسلاف الوحدة وجذر المركز ============
create or replace function public.qy_unit_up(p_center text) returns table(id text, kind text, depth int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  with recursive up(id, kind, parent_id, depth) as (
    select c.id, c.kind, c.parent_id, 0 from public.centers c where c.id = p_center
    union all
    select c.id, c.kind, c.parent_id, up.depth + 1 from public.centers c join up on c.id = up.parent_id where up.depth < 50)
  select id, kind, depth from up;
$$;
revoke all on function public.qy_unit_up(text) from public, anon, authenticated;

-- الجذر: أعلى وحدة من نوع «مركز» في السلسلة، وإلا الوحدة نفسها
create or replace function public.qy_unit_root(p_center text) returns text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select coalesce((select id from public.qy_unit_up(p_center) where kind = 'center' order by depth desc limit 1), p_center);
$$;
revoke all on function public.qy_unit_root(text) from public, anon, authenticated;

-- الرؤية: من يعمل في المركز يرى بنوده، ومن يعمل في بند يرى بنده فقط
create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and (u.role in ('accountant','cfo','executive_manager')
                          or u.center_id in (select id from public.qy_unit_up(p_center))))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ============ الدفتر: نوع «ترحيل» وربط طرفيه ============
alter table public.center_ledger drop constraint if exists center_ledger_kind_check;
alter table public.center_ledger add constraint center_ledger_kind_check check (kind in ('opening','subscription','support','manual','adjust','transfer'));
alter table public.center_ledger add column if not exists pair_id bigint;

-- هل يرحّل المستخدم بين بنود هذا الجذر؟ المالية ومدير النظام، ومن اختاره مدير النظام للمركز
create or replace function public.qy_can_transfer(p_root text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers r where r.id = p_root and public.can_see_company(r.company_id)
     and (public.is_admin() or public.is_finance() or public.qy_me() = any(coalesce(r.transfer_user_ids,'{}'))));
$$;
revoke all on function public.qy_can_transfer(text) from public, anon;
grant execute on function public.qy_can_transfer(text) to authenticated;

-- الرصيد: صافي الدخل والترحيلات ناقص المصروف المكتمل (الدالة السابقة تجمع net لكل الأنواع فتشمل الترحيل)
drop function if exists public.qy_center_balances(text);
create or replace function public.qy_center_balances(p_company text) returns table(center_id text, income numeric, transfers numeric, expense numeric, balance numeric, pending_requests numeric, pending_payments int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select ce.id,
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind <> 'transfer'),0)),
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind = 'transfer'),0)),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status = 'completed' and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    public.qy_center_balance(ce.id),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    0
  from public.centers ce where ce.company_id = p_company and public.qy_center_can_see(ce.id);
$$;
revoke all on function public.qy_center_balances(text) from public, anon;
grant execute on function public.qy_center_balances(text) to authenticated;

-- ============ ترحيل رصيد بين بندين من المركز نفسه ============
create or replace function public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text) returns bigint
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare a public.centers%rowtype; b public.centers%rowtype; v_root text; v_amt numeric := public.qy_round3(p_amount); v_out bigint; v_in bigint; v_avail numeric; v_me text := public.qy_me();
begin
  select * into a from public.centers where id = p_from;
  select * into b from public.centers where id = p_to;
  if a.id is null or b.id is null then raise exception 'البند غير موجود'; end if;
  if a.id = b.id then raise exception 'اختر بندين مختلفين'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'أدخل مبلغاً أكبر من صفر'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'اكتب سبب الترحيل'; end if;
  v_root := public.qy_unit_root(a.id);
  if v_root <> public.qy_unit_root(b.id) or a.company_id <> b.company_id then raise exception 'الترحيل بين بنود المركز نفسه فقط'; end if;
  if not public.qy_can_transfer(v_root) then raise exception 'ليست لديك صلاحية ترحيل الرصيد في هذا المركز'; end if;
  if b.stage = 'closed' then raise exception 'البند «%» مغلق ولا يُرحَّل إليه', b.name; end if;
  if a.balance_control then
    v_avail := public.qy_center_balance(a.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = a.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if v_amt > v_avail + coalesce(a.overdraft_limit,0) then raise exception 'المبلغ يتجاوز الرصيد المتاح في «%» (%)', a.name, v_avail; end if;
  end if;
  insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by)
  values (a.company_id, a.id, 'transfer', coalesce(p_date, current_date), -v_amt, 0, 0, 0, -v_amt, 'ترحيل إلى «'||b.name||'»', trim(p_reason), 'transfer', v_me) returning id into v_out;
  insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by, pair_id)
  values (b.company_id, b.id, 'transfer', coalesce(p_date, current_date), v_amt, 0, 0, 0, v_amt, 'ترحيل من «'||a.name||'»', trim(p_reason), 'transfer', v_me, v_out) returning id into v_in;
  update public.center_ledger set pair_id = v_in where id = v_out;
  return v_out;
end $$;
revoke all on function public.qy_ledger_transfer(text,text,numeric,date,text) from public, anon;
grant execute on function public.qy_ledger_transfer(text,text,numeric,date,text) to authenticated;

-- الحذف/الاسترجاع: الترحيل يُحذف بطرفيه معاً
create or replace function public.qy_ledger_void(p_id bigint, p_void boolean) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare l public.center_ledger%rowtype;
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if l.kind = 'transfer' then
    if not public.qy_can_transfer(public.qy_unit_root(l.center_id)) then raise exception 'ليست لديك صلاحية'; end if;
    update public.center_ledger set voided = coalesce(p_void, true) where id = p_id or (l.pair_id is not null and id = l.pair_id);
    return;
  end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(l.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  update public.center_ledger set voided = coalesce(p_void, true) where id = p_id;
end $$;
revoke all on function public.qy_ledger_void(bigint, boolean) from public, anon;
grant execute on function public.qy_ledger_void(bigint, boolean) to authenticated;

-- ============ تغيير الحالة ============
drop function if exists public.qy_center_set_stage(text, text);
create or replace function public.qy_center_set_stage(p_center text, p_stage text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('potential','open','active','closed') then raise exception 'حالة غير صالحة'; end if;
  if p_stage = 'closed' then
    if exists (select 1 from public.centers x where x.parent_id = p_center and x.stage <> 'closed') then raise exception 'تحته بنود غير مغلقة، أغلقها أولاً'; end if;
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'له طلبات مفتوحة، أنجزها أو ألغها قبل الإغلاق'; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'الرصيد غير مسوّى (%). رحّله لبند آخر أو سوِّه بحركة تسوية قبل الإغلاق', v_bal; end if;
  end if;
  update public.centers set stage = p_stage where id = p_center;
end $$;
revoke all on function public.qy_center_set_stage(text, text) from public, anon;
grant execute on function public.qy_center_set_stage(text, text) to authenticated;

-- ============ خصائص البند (المالية ومدير النظام) ============
create or replace function public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric,
   p_monthly numeric, p_annual numeric) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'نهاية المدة قبل بدايتها'; end if;
  update public.centers set pre_pay = coalesce(p_pre_pay,false), continuous = coalesce(p_continuous,false), period_from = p_from, period_to = p_to,
    item_budget = p_budget, monthly_budget = p_monthly, annual_budget = p_annual where id = p_center;
end $$;
revoke all on function public.qy_unit_item_set(text,boolean,boolean,date,date,numeric,numeric,numeric) from public, anon;
grant execute on function public.qy_unit_item_set(text,boolean,boolean,date,date,numeric,numeric,numeric) to authenticated;

-- ============ إضافة بند تحت مركز (المالية ومدير النظام) ============
create or replace function public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean,
   p_from date, p_to date, p_budget numeric, p_desc text) returns text
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare pa public.centers%rowtype; v_id text := 'c_' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text;
begin
  select * into pa from public.centers where id = p_parent;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(pa.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'اكتب اسم البند'; end if;
  if coalesce(p_stage,'active') not in ('potential','open','active') then raise exception 'حالة غير صالحة'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'نهاية المدة قبل بدايتها'; end if;
  insert into public.centers(id, name, code, company_id, kind, scope, parent_id, stage, pre_pay, continuous, period_from, period_to, item_budget, description)
  values (v_id, trim(p_name), '', pa.company_id, coalesce(nullif(p_kind,''),'section'), coalesce(pa.scope,'company'), p_parent, coalesce(p_stage,'active'),
          coalesce(p_pre_pay,false), coalesce(p_continuous,false), p_from, p_to, p_budget, nullif(trim(coalesce(p_desc,'')),''));
  return v_id;
end $$;
revoke all on function public.qy_unit_item_add(text,text,text,text,boolean,boolean,date,date,numeric,text) from public, anon;
grant execute on function public.qy_unit_item_add(text,text,text,text,boolean,boolean,date,date,numeric,text) to authenticated;

-- ============ منع الطلب حسب الحالة والرصيد ============
create or replace function public.qy_center_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_avail numeric;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception '«%» مغلق ولا تُنشأ له طلبات جديدة', ce.name; end if;
  if ce.stage = 'potential' then raise exception '«%» محتمل ولم يُعتمد بعد، فلا تُنشأ له طلبات', ce.name; end if;
  if ce.stage = 'open' and not coalesce(ce.pre_pay,false) then raise exception '«%» مفتوح ولم يُدفع بعد، ولا يُصرف له قبل الدفع', ce.name; end if;
  if ce.balance_control then
    v_avail := public.qy_center_balance(ce.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if coalesce(new.total_amount,0) > v_avail + coalesce(ce.overdraft_limit,0) then
      raise exception 'يتجاوز الطلب الرصيد المتاح (%) مع حد السالب (%)', v_avail, coalesce(ce.overdraft_limit,0);
    end if;
  end if;
  return new;
end $$;
