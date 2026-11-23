-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٢١ (1.54.0): ملاحق المشروع ومصادر دخله
-- كل ما يدخل المشروع بعد وثيقته الأصلية يُسجَّل «ملحقاً» له نوع:
--   doc       ملحق موثّق (زيادة / تخفيض / تمديد) بملف موقّع، يعتمده العميل، وله فواتيره
--   support   دعم أو تبرع بلا وثيقة ولا فاتورة (اسم الداعم وهاتفه وسند القبض اختياري)
--   transfer  تحويل من مشروع آخر: مباشر من المحاسب، أو بطلب صرف يمر بمسار الاعتماد (إعداد الشركة)
--   gateway   اشتراكات بوابة الدفع: حركات معلّقة في الاستيراد تُضم إلى المشروع
-- لكل ملحق دخلٍ حصة شركة خاصة به: كنسبة البند، أو نسبة، أو مبلغ محدد، أو بلا حصة.
-- اشتراكات البوابة: الحصة تُحسب بعد خصم رسوم البوابة.
-- يُشغَّل بعد بناء-١..٢٠. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ ١) الأعمدة الجديدة في الجداول القائمة ═══
alter table public.companies add column if not exists prj_transfer_mode text not null default 'direct';
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_prj_transfer_mode_chk' and conrelid='public.companies'::regclass) then
  alter table public.companies add constraint companies_prj_transfer_mode_chk check (prj_transfer_mode in ('direct','request')); end if; end $c$;

-- حصة الشركة المحفوظة مع الإيراد نفسه (فارغة = تُحسب بإعداد البند كما كانت)
alter table public.budget_revenues add column if not exists share_amount numeric;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_share_chk' and conrelid='public.budget_revenues'::regclass) then
  alter table public.budget_revenues add constraint budget_revenues_share_chk check (share_amount is null or share_amount >= 0); end if; end $c$;

-- مسار «تحويل لمشروع» في طلب الصرف
alter table public.requests add column if not exists route_project_id uuid;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_route_project_fk' and conrelid='public.requests'::regclass) then
  alter table public.requests add constraint requests_route_project_fk foreign key (route_project_id) references public.projects(id) on delete set null; end if; end $c$;
alter table public.requests drop constraint if exists requests_amount_route_chk;
alter table public.requests add constraint requests_amount_route_chk check (amount_route = any (array['normal','center','revenue','project']));

-- حركة بوابة معلّقة ضُمّت إلى مشروع (تخرج من «المعلّق» ولا تدخل أرصدة المراكز)
alter table public.center_ledger add column if not exists project_id uuid;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_project_fk' and conrelid='public.center_ledger'::regclass) then
  alter table public.center_ledger add constraint center_ledger_project_fk foreign key (project_id) references public.projects(id) on delete set null; end if; end $c$;
create index if not exists center_ledger_project_idx on public.center_ledger(project_id) where project_id is not null;

-- ═══ ٢) جدول الملاحق ═══
create table if not exists public.prj_addenda (
  id              uuid primary key default gen_random_uuid(),
  company_id      text not null references public.companies(id) on delete cascade,
  project_id      uuid not null references public.projects(id) on delete cascade,
  seq             integer not null default 0,
  kind            text not null check (kind in ('doc','support','transfer','gateway')),
  entry_date      date not null default current_date,
  description     text,
  change_type     text check (change_type is null or change_type in ('increase','decrease','extend')),
  amount          numeric not null default 0,         -- الموثّق: التغيّر في قيمة المشروع (موجب أو سالب أو صفر للتمديد) — غيره: المبلغ الداخل
  gateway_fee     numeric not null default 0 check (gateway_fee >= 0),
  share_mode      text not null default 'item' check (share_mode in ('item','none','pct','fixed')),
  share_value     numeric not null default 0 check (share_value >= 0),
  share_amount    numeric not null default 0 check (share_amount >= 0),
  status          text not null default 'posted' check (status in ('pending','approved','rejected','posted','cancelled')),
  file_path       text, file_name text,
  donor_name      text, donor_phone text, method text,
  from_project_id uuid references public.projects(id) on delete set null,
  request_id      text,
  ledger_ids      bigint[] not null default '{}',
  revenue_id      text,
  out_tx_id       uuid,
  decided_by      text, decided_at timestamptz, decision_note text,
  cancelled_by    text, cancelled_at timestamptz, cancel_reason text,
  created_by      text,
  created_at      timestamptz not null default now(),
  constraint prj_add_doc_chk check (kind <> 'doc' or (change_type is not null and status in ('pending','approved','rejected','cancelled'))),
  constraint prj_add_money_chk check (kind = 'doc' or amount > 0)
);
create unique index if not exists prj_addenda_seq_uq on public.prj_addenda(project_id, seq);
create index if not exists prj_addenda_company_idx on public.prj_addenda(company_id, project_id);
create unique index if not exists prj_addenda_request_uq on public.prj_addenda(request_id) where request_id is not null and status = 'posted';

alter table public.prj_invoices add column if not exists addendum_id uuid;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_addendum_fk' and conrelid='public.prj_invoices'::regclass) then
  alter table public.prj_invoices add constraint prj_invoices_addendum_fk foreign key (addendum_id) references public.prj_addenda(id) on delete set null; end if; end $c$;

-- الرقم التسلسلي للملحق داخل مشروعه (م1، م2…) يضعه الخادم
create or replace function public.qy_prj_add_seq() returns trigger language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  perform pg_advisory_xact_lock(hashtext('prj_add_seq:' || new.project_id::text));
  select coalesce(max(seq),0) + 1 into new.seq from public.prj_addenda where project_id = new.project_id;
  if new.company_id is null then select company_id into new.company_id from public.projects where id = new.project_id; end if;
  new.created_by := coalesce(new.created_by, public.qy_me());
  return new;
end $f$;
drop trigger if exists qy_prj_add_seq_t on public.prj_addenda;
create trigger qy_prj_add_seq_t before insert on public.prj_addenda for each row execute function public.qy_prj_add_seq();

-- حارس: من الواجهة تُكتب الملاحق الموثّقة فقط؛ ملاحق الدخل من دوال الخادم وحدها (لأنها تقيّد في الدفتر)
create or replace function public.qy_prj_add_guard() returns trigger language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if current_setting('qy.prj_add', true) = '1' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.kind <> 'doc' or old.status = 'approved' then raise exception 'لا يُحذف هذا الملحق؛ ألغِه بزر «إلغاء» مع السبب'; end if;
    if exists (select 1 from public.prj_invoices i where i.addendum_id = old.id and i.status <> 'cancelled') then raise exception 'على الملحق فواتير؛ ألغِها أولاً'; end if;
    return old;
  end if;
  if new.kind <> 'doc' then raise exception 'ملاحق الدخل تُسجَّل من أزرارها في صفحة المشروع'; end if;
  if tg_op = 'UPDATE' then
    if new.project_id <> old.project_id or new.kind <> old.kind or new.seq <> old.seq then raise exception 'لا يتغيّر مشروع الملحق ولا نوعه ولا رقمه'; end if;
    if old.status = 'cancelled' then raise exception 'الملحق ملغى'; end if;
    if new.status = 'cancelled' and exists (select 1 from public.prj_invoices i where i.addendum_id = old.id and i.status <> 'cancelled') then
      raise exception 'على الملحق فواتير؛ ألغِها أولاً'; end if;
  end if;
  if new.change_type = 'increase' and new.amount < 0 then new.amount := -new.amount; end if;
  if new.change_type = 'decrease' and new.amount > 0 then new.amount := -new.amount; end if;
  if new.change_type = 'extend' then new.amount := coalesce(new.amount, 0); end if;
  return new;
end $f$;
drop trigger if exists qy_prj_add_guard_t on public.prj_addenda;
create trigger qy_prj_add_guard_t before insert or update or delete on public.prj_addenda for each row execute function public.qy_prj_add_guard();
-- الحارس يعمل بعد الترقيم (الأسماء بالترتيب الأبجدي: guard قبل seq) — فالترقيم مستقل عنه
alter table public.prj_addenda enable row level security;
drop policy if exists prj_add_sel on public.prj_addenda;
create policy prj_add_sel on public.prj_addenda for select using (public.qy_prj_can_read(company_id));
drop policy if exists prj_add_wrt on public.prj_addenda;
create policy prj_add_wrt on public.prj_addenda for all using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));
grant select, insert, update, delete on public.prj_addenda to authenticated;

-- ═══ ٣) حصة الشركة ═══
-- حصة إعداد البند لمبلغ (كما في budget_item_balance)
create or replace function public.qy_item_share(p_item text, p_base numeric) returns numeric language sql stable security definer set search_path = public, pg_temp as $f$
  select public.qy_round3(greatest(0, coalesce(case bi.profit_mode
      when 'percent' then p_base * bi.profit_percent / 100.0
      when 'fixed'   then least(p_base, bi.profit_fixed)
      when 'both'    then p_base * bi.profit_percent / 100.0 + bi.profit_fixed
      else 0 end, 0)))
  from public.budget_items bi where bi.id = p_item
$f$;
-- حصة ملحق: item = كإعداد البند، none = بلا، pct = نسبة من الأساس، fixed = مبلغ محدد (لا يتجاوز الأساس)
create or replace function public.qy_prj_share(p_item text, p_base numeric, p_mode text, p_val numeric) returns numeric language sql stable security definer set search_path = public, pg_temp as $f$
  select case coalesce(p_mode,'item')
    when 'none'  then 0::numeric
    when 'pct'   then public.qy_round3(greatest(0, p_base) * least(100, greatest(0, coalesce(p_val,0))) / 100.0)
    when 'fixed' then public.qy_round3(least(greatest(0, p_base), greatest(0, coalesce(p_val,0))))
    else coalesce(public.qy_item_share(p_item, p_base), 0) end
$f$;

-- رصيد البند وربح الشركة: حصة الإيراد المحفوظة معه أولاً، وإلا إعداد البند
create or replace function public.budget_item_company_profit(p_item_id text) returns numeric language sql stable security definer set search_path = public, pg_temp as $f$
  select coalesce(sum(coalesce(br.share_amount, case bi.profit_mode
      when 'percent' then br.amount * bi.profit_percent / 100.0
      when 'fixed'   then least(br.amount, bi.profit_fixed)
      when 'both'    then (br.amount * bi.profit_percent / 100.0) + bi.profit_fixed
      else 0 end)), 0)
  from public.budget_revenues br join public.budget_items bi on bi.id = br.budget_item_id
  where br.budget_item_id = p_item_id
$f$;
create or replace function public.budget_item_balance(p_item_id text) returns numeric language sql stable security definer set search_path = public, pg_temp as $f$
  select coalesce((select sum(br.amount) from public.budget_revenues br where br.budget_item_id = p_item_id), 0)
       - public.budget_item_company_profit(p_item_id)
       - coalesce((select sum(r.total_amount) from public.requests r where r.budget_item_id = p_item_id
                    and r.status in ('approved','pending_decision') and coalesce(r.is_cancelled,false) = false), 0)
$f$;

-- ═══ ٤) قيد الدخل: إيراد على بند المشروع + حركة دخول في الدفتر ═══
create or replace function public.qy_prj_post_income(p_add uuid, p_net numeric, p_desc text, p_method text) returns text
language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.prj_addenda; p public.projects; v_rev text; me text := public.qy_me(); nm text;
begin
  select * into a from public.prj_addenda where id = p_add;
  select * into p from public.projects where id = a.project_id;
  if p.budget_item_id is null then raise exception 'المشروع بلا بند ميزانية'; end if;
  select name into nm from public.users where id = me;
  v_rev := 'rev_add_' || replace(a.id::text, '-', '');
  insert into public.budget_revenues(id, budget_item_id, amount, revenue_date, source_type, description, entered_by_id, share_amount)
  values (v_rev, p.budget_item_id, public.qy_round3(p_net), a.entry_date,
          case when p_method in ('transfer','payment_link','cash','other') then p_method else null end, p_desc, me, a.share_amount);
  insert into public.transactions(company_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, note, created_by_id, created_by)
  values (p.company_id, a.entry_date, 'in', public.qy_round3(p_net), p.budget_item_id, null, p_desc, 'revenue', v_rev, 'ملحق مشروع', me, coalesce(nm,''));
  perform set_config('qy.prj_add', '1', true);
  update public.prj_addenda set revenue_id = v_rev where id = a.id;
  perform set_config('qy.prj_add', '0', true);
  return v_rev;
end $f$;
revoke all on function public.qy_prj_post_income(uuid, numeric, text, text) from public, anon, authenticated;

-- عكس قيد ملحق (عند إلغائه أو إبطال طلبه)
create or replace function public.qy_prj_unpost(p_add uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.prj_addenda; t public.transactions; me text := public.qy_me(); nm text;
begin
  select * into a from public.prj_addenda where id = p_add for update;
  select name into nm from public.users where id = me;
  for t in select * from public.transactions x
           where ((x.source_type = 'revenue' and x.source_id = a.revenue_id) or x.id = a.out_tx_id)
             and x.reverses_id is null and not exists (select 1 from public.transactions z where z.reverses_id = x.id)
  loop
    insert into public.transactions(company_id, center_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, reverses_id, note, created_by_id, created_by)
    values (t.company_id, t.center_id, current_date, case when t.direction='out' then 'in' else 'out' end, t.amount, t.budget_item_id, t.beneficiary,
            'عكس: ' || t.description, t.source_type, t.source_id, t.id, 'إلغاء ملحق — ' || coalesce(p_reason,''), me, coalesce(nm,''));
  end loop;
  if a.revenue_id is not null then delete from public.budget_revenues where id = a.revenue_id; end if;
  if a.kind = 'gateway' and coalesce(array_length(a.ledger_ids,1),0) > 0 then
    update public.center_ledger set project_id = null where id = any(a.ledger_ids) and project_id = a.project_id;
  end if;
  perform set_config('qy.prj_add', '1', true);
  update public.prj_addenda set status = 'cancelled', cancelled_by = me, cancelled_at = now(), cancel_reason = p_reason where id = a.id;
  perform set_config('qy.prj_add', '0', true);
end $f$;
revoke all on function public.qy_prj_unpost(uuid, text) from public, anon, authenticated;

-- فحوص مشتركة لملاحق الدخل: المالية فقط، والمشروع نشط
create or replace function public.qy_prj_income_check(p_project uuid) returns public.projects
language plpgsql security definer set search_path = public, pg_temp as $f$
declare p public.projects;
begin
  select * into p from public.projects where id = p_project;
  if p.id is null then raise exception 'المشروع غير موجود'; end if;
  if not (public.is_finance() and public.can_see_company(p.company_id)) then raise exception 'تسجيل دخل المشروع للمالية فقط'; end if;
  if p.status <> 'active' then raise exception 'المشروع مغلق'; end if;
  if p.budget_item_id is null then raise exception 'المشروع بلا بند ميزانية'; end if;
  return p;
end $f$;
revoke all on function public.qy_prj_income_check(uuid) from public, anon, authenticated;

-- ═══ ٥) دعم أو تبرع ═══
create or replace function public.qy_prj_support_add(p_project uuid, p_date date, p_amount numeric, p_donor text, p_phone text, p_method text,
  p_file_path text, p_file_name text, p_desc text, p_share_mode text, p_share_value numeric) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $f$
declare p public.projects := public.qy_prj_income_check(p_project); v_id uuid; v_amt numeric := public.qy_round3(p_amount); v_share numeric;
begin
  if v_amt is null or v_amt <= 0 then raise exception 'اكتب المبلغ'; end if;
  if coalesce(trim(p_donor),'') = '' then raise exception 'اكتب اسم الداعم'; end if;
  v_share := public.qy_prj_share(p.budget_item_id, v_amt, p_share_mode, p_share_value);
  perform set_config('qy.prj_add', '1', true);
  insert into public.prj_addenda(company_id, project_id, kind, entry_date, description, amount, share_mode, share_value, share_amount, status,
                                 donor_name, donor_phone, method, file_path, file_name)
  values (p.company_id, p.id, 'support', coalesce(p_date, current_date), nullif(trim(coalesce(p_desc,'')),''), v_amt, coalesce(p_share_mode,'item'), coalesce(p_share_value,0), v_share, 'posted',
          trim(p_donor), nullif(trim(coalesce(p_phone,'')),''), p_method, p_file_path, p_file_name)
  returning id into v_id;
  perform set_config('qy.prj_add', '0', true);
  perform public.qy_prj_post_income(v_id, v_amt, 'دعم للمشروع «' || p.name || '» من ' || trim(p_donor) || coalesce(' — ' || nullif(trim(coalesce(p_desc,'')),''), ''), p_method);
  return v_id;
end $f$;
grant execute on function public.qy_prj_support_add(uuid, date, numeric, text, text, text, text, text, text, text, numeric) to authenticated;

-- ═══ ٦) تحويل مباشر من مشروع إلى مشروع (إعداد الشركة «مباشر») ═══
create or replace function public.qy_prj_transfer_direct(p_from uuid, p_to uuid, p_amount numeric, p_date date, p_reason text, p_share_mode text, p_share_value numeric) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $f$
declare t public.projects := public.qy_prj_income_check(p_to); f public.projects; v_id uuid; v_amt numeric := public.qy_round3(p_amount); v_share numeric; v_out uuid; me text := public.qy_me(); nm text; v_mode text;
begin
  select * into f from public.projects where id = p_from;
  if f.id is null then raise exception 'اختر المشروع المحوِّل'; end if;
  if f.id = t.id then raise exception 'اختر مشروعاً آخر'; end if;
  if f.company_id <> t.company_id then raise exception 'التحويل بين مشاريع الشركة نفسها فقط'; end if;
  if f.budget_item_id is null then raise exception 'المشروع المحوِّل بلا بند ميزانية'; end if;
  select prj_transfer_mode into v_mode from public.companies where id = t.company_id;
  if coalesce(v_mode,'direct') <> 'direct' then raise exception 'إعداد الشركة: التحويل بين المشاريع بطلب صرف يمر بمسار الاعتماد'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'اكتب المبلغ'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'اكتب سبب التحويل'; end if;
  select name into nm from public.users where id = me;
  v_share := public.qy_prj_share(t.budget_item_id, v_amt, p_share_mode, p_share_value);
  perform set_config('qy.prj_add', '1', true);
  insert into public.prj_addenda(company_id, project_id, kind, entry_date, description, amount, share_mode, share_value, share_amount, status, from_project_id)
  values (t.company_id, t.id, 'transfer', coalesce(p_date, current_date), trim(p_reason), v_amt, coalesce(p_share_mode,'item'), coalesce(p_share_value,0), v_share, 'posted', f.id)
  returning id into v_id;
  insert into public.transactions(company_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, note, created_by_id, created_by)
  values (f.company_id, coalesce(p_date, current_date), 'out', v_amt, f.budget_item_id, t.name, 'تحويل إلى المشروع «' || t.name || '» — ' || trim(p_reason), 'manual', v_id::text, 'تحويل بين مشاريع', me, coalesce(nm,''))
  returning id into v_out;
  update public.prj_addenda set out_tx_id = v_out where id = v_id;
  perform set_config('qy.prj_add', '0', true);
  perform public.qy_prj_post_income(v_id, v_amt, 'تحويل من المشروع «' || f.name || '» — ' || trim(p_reason), 'transfer');
  return v_id;
end $f$;
grant execute on function public.qy_prj_transfer_direct(uuid, uuid, numeric, date, text, text, numeric) to authenticated;

-- ═══ ٧) ضمّ حركات بوابة الدفع المعلّقة إلى المشروع ═══
create or replace function public.qy_prj_gateway_attach(p_project uuid, p_ids bigint[], p_desc text, p_share_mode text, p_share_value numeric) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $f$
declare p public.projects := public.qy_prj_income_check(p_project); v_id uuid; v_n int; v_gross numeric; v_fee numeric; v_net numeric; v_share numeric; v_from date; v_to date;
begin
  if coalesce(array_length(p_ids,1),0) = 0 then raise exception 'اختر الحركات'; end if;
  perform 1 from public.center_ledger where id = any(p_ids) for update;
  select count(*), coalesce(sum(gross),0), coalesce(sum(gateway_fee),0), min(entry_date), max(entry_date) into v_n, v_gross, v_fee, v_from, v_to
    from public.center_ledger where id = any(p_ids) and company_id = p.company_id and center_id is null and project_id is null and not voided;
  if v_n <> array_length(p_ids,1) then raise exception 'بعض الحركات لم تعد معلّقة (صُنّفت أو حُذفت أو ضُمّت). حدّث الصفحة'; end if;
  v_net := public.qy_round3(v_gross - v_fee);
  if v_net <= 0 then raise exception 'صافي الحركات بعد الرسوم صفر'; end if;
  v_share := public.qy_prj_share(p.budget_item_id, v_net, p_share_mode, p_share_value);
  perform set_config('qy.prj_add', '1', true);
  insert into public.prj_addenda(company_id, project_id, kind, entry_date, description, amount, gateway_fee, share_mode, share_value, share_amount, status, ledger_ids, method)
  values (p.company_id, p.id, 'gateway', v_to, coalesce(nullif(trim(coalesce(p_desc,'')),''), 'اشتراكات بوابة الدفع ' || to_char(v_from,'DD-MM-YYYY') || ' إلى ' || to_char(v_to,'DD-MM-YYYY') || ' (' || v_n || ' حركة)'),
          public.qy_round3(v_gross), public.qy_round3(v_fee), coalesce(p_share_mode,'item'), coalesce(p_share_value,0), v_share, 'posted', p_ids, 'payment_link')
  returning id into v_id;
  perform set_config('qy.prj_add', '0', true);
  update public.center_ledger set project_id = p.id where id = any(p_ids);
  perform public.qy_prj_post_income(v_id, v_net, 'اشتراكات بوابة الدفع للمشروع «' || p.name || '» (' || v_n || ' حركة، بعد رسوم ' || to_char(v_fee,'FM999999990.000') || ')', 'payment_link');
  return v_id;
end $f$;
grant execute on function public.qy_prj_gateway_attach(uuid, bigint[], text, text, numeric) to authenticated;

-- ═══ ٨) إلغاء ملحق دخل (يعكس قيده) ═══
create or replace function public.qy_prj_addendum_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.prj_addenda;
begin
  select * into a from public.prj_addenda where id = p_id;
  if a.id is null then raise exception 'الملحق غير موجود'; end if;
  if not (public.is_finance() and public.can_see_company(a.company_id)) then raise exception 'إلغاء ملاحق الدخل للمالية فقط'; end if;
  if a.kind = 'doc' then raise exception 'الملحق الموثّق يُلغى من زره'; end if;
  if a.status <> 'posted' then raise exception 'الملحق ملغى من قبل'; end if;
  if a.request_id is not null then raise exception 'هذا التحويل جاء بطلب صرف؛ أبطل الطلب نفسه فيُعكس الملحق تلقائياً'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'اكتب سبب الإلغاء'; end if;
  perform public.qy_prj_unpost(a.id, trim(p_reason));
end $f$;
grant execute on function public.qy_prj_addendum_cancel(uuid, text) to authenticated;

-- ═══ ٩) التحويل بطلب صرف: عند اكتمال صرف طلب «تحويل لمشروع» يُسجَّل ملحق دخل في المشروع المستلم ═══
create or replace function public.qy_route_income() returns trigger language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_pct numeric; v_share numeric; t public.projects; f public.projects; v_id uuid; v_amt numeric;
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
  if new.status = 'completed' and old.status is distinct from 'completed' and new.amount_route = 'project' and new.route_project_id is not null
     and not exists (select 1 from public.prj_addenda where request_id = new.id and status = 'posted') then
    select * into t from public.projects where id = new.route_project_id;
    select * into f from public.projects where budget_item_id = new.budget_item_id order by created_at limit 1;
    v_amt := public.qy_round3(coalesce(new.total_amount,0));
    if t.id is not null and t.budget_item_id is not null and v_amt > 0 then
      v_share := public.qy_prj_share(t.budget_item_id, v_amt, 'item', 0);
      perform set_config('qy.prj_add', '1', true);
      insert into public.prj_addenda(company_id, project_id, kind, entry_date, description, amount, share_mode, share_value, share_amount, status, from_project_id, request_id)
      values (t.company_id, t.id, 'transfer', current_date, coalesce(new.reason, 'تحويل بطلب صرف'), v_amt, 'item', 0, v_share, 'posted', f.id, new.id)
      returning id into v_id;
      perform set_config('qy.prj_add', '0', true);
      perform public.qy_prj_post_income(v_id, v_amt, 'تحويل من ' || coalesce('المشروع «' || f.name || '»', 'بند آخر') || ' بالطلب ' || coalesce(new.number, new.id), 'transfer');
    end if;
  end if;
  return new;
end $f$;

-- إبطال طلب «تحويل لمشروع» بعد صرفه يعكس ملحقه في المشروع المستلم
create or replace function public.qy_route_project_void() returns trigger language plpgsql security definer set search_path = public, pg_temp as $f$
declare a uuid;
begin
  if coalesce(new.is_cancelled,false) and not coalesce(old.is_cancelled,false) and new.amount_route = 'project' then
    for a in select id from public.prj_addenda where request_id = new.id and status = 'posted' loop
      perform public.qy_prj_unpost(a, 'إبطال الطلب ' || coalesce(new.number, new.id) || coalesce(' — ' || new.cancel_reason, ''));
    end loop;
  end if;
  return new;
end $f$;
drop trigger if exists qy_route_project_void_t on public.requests;
create trigger qy_route_project_void_t after update of is_cancelled on public.requests for each row execute function public.qy_route_project_void();

-- ═══ ١٠) تحقق سريع ═══
-- select count(*) from information_schema.tables where table_schema='public' and table_name='prj_addenda';  -- 1
