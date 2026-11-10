-- ترقية الإنتاج إلى حالة قاعدة الاختبار (١٠ نوفمبر ٢٠٢٦) — ملف واحد يحل محل ملفات العهد السابقة
-- مُستخرج آلياً من قاعدة الاختبار: جداول العهد، الأعمدة الجديدة، القيود، الدوال الجديدة والمحدّثة، الصلاحيات، السياسات، المشغّلات.
-- يشمل الصرف بلا سند وتوقيع الإدارة الاختياري.
begin;
set local check_function_bodies = off;
-- (١) الجداول الجديدة
create table if not exists public.custodies (id bigint generated always as identity not null, request_id text not null, company_id text not null, holder_id text not null, budget_item_id text, amount numeric(14,3) not null, purpose text, carried_in numeric(14,3) default 0 not null, carried_from_id bigint, status text default 'requested'::text not null, due_close_at date, received_at timestamp with time zone, remaining_action text, remaining_amount numeric(14,3), settlement_no text, reviewed_by_id text, signed_by_id text, closed_at timestamp with time zone, created_by_id text default qy_me() not null, created_at timestamp with time zone default now() not null, reviewer_id text, close_requested_at timestamp with time zone, over_mode text, over_value numeric(14,3));
create table if not exists public.custody_balances (id bigint generated always as identity not null, holder_id text not null, company_id text not null, amount numeric(14,3) not null, source_custody_id bigint, status text default 'open'::text not null, applied_custody_id bigint, settled_by_id text, settled_at timestamp with time zone, note text, created_at timestamp with time zone default now() not null);
create table if not exists public.custody_lines (id bigint generated always as identity not null, custody_id bigint not null, kind text not null, amount numeric(14,3) not null, description text not null, invoice_no text, line_date date default CURRENT_DATE not null, image_data text, has_image boolean generated always as ((image_data IS NOT NULL)) stored, status text default 'draft'::text not null, review_note text, created_by_id text, created_at timestamp with time zone default now() not null, updated_at timestamp with time zone default now() not null, reviewed_by_id text, reviewed_at timestamp with time zone, reopened boolean default false not null, no_doc boolean default false not null, no_doc_reason text);
-- (٢) أعمدة جديدة على جداول قائمة
alter table public.centers add column if not exists min_single_approver text default 'exec'::text not null;
alter table public.companies add column if not exists custody_alert_user_id text;
alter table public.companies add column if not exists custody_default_days integer default 30 not null;
alter table public.companies add column if not exists custody_img_min numeric(14,3) default 0 not null;
alter table public.companies add column if not exists custody_max_amount numeric(14,3);
alter table public.companies add column if not exists custody_max_open integer default 1 not null;
alter table public.companies add column if not exists custody_max_total numeric(14,3);
alter table public.companies add column if not exists custody_over_mode text default 'none'::text not null;
alter table public.companies add column if not exists custody_over_value numeric(14,3) default 0 not null;
alter table public.companies add column if not exists custody_path_mode text default 'exec'::text not null;
alter table public.companies add column if not exists custody_receipt_days integer default 3 not null;
alter table public.companies add column if not exists custody_review_mode text default 'line'::text not null;
alter table public.requests add column if not exists request_type text default 'normal'::text not null;
alter table public.users add column if not exists avatar_data text;
alter table public.companies add column if not exists custody_nodoc_on boolean default false not null;
alter table public.companies add column if not exists custody_nodoc_mode text;
alter table public.companies add column if not exists custody_nodoc_value numeric(14,3);
alter table public.companies add column if not exists custody_sign_on boolean default true not null;
alter table public.companies add column if not exists custody_signers text default 'any'::text not null;
-- (٣) القيود (الجداول الجديدة والأعمدة الجديدة)
alter table custodies drop constraint if exists custodies_pkey; alter table custodies add constraint custodies_pkey PRIMARY KEY (id);
alter table custody_lines drop constraint if exists custody_lines_pkey; alter table custody_lines add constraint custody_lines_pkey PRIMARY KEY (id);
alter table custody_balances drop constraint if exists custody_balances_pkey; alter table custody_balances add constraint custody_balances_pkey PRIMARY KEY (id);
alter table custodies drop constraint if exists custodies_request_id_key; alter table custodies add constraint custodies_request_id_key UNIQUE (request_id);
alter table qy_client_events drop constraint if exists qy_client_events_kind_chk; alter table qy_client_events add constraint qy_client_events_kind_chk CHECK ((kind = ANY (ARRAY['js_error'::text, 'promise_error'::text, 'db_error'::text, 'login_failed'::text, 'login_suspended'::text, 'login_ok'::text, 'logout'::text])));
alter table requests drop constraint if exists requests_request_type_chk; alter table requests add constraint requests_request_type_chk CHECK ((request_type = ANY (ARRAY['normal'::text, 'custody'::text])));
alter table companies drop constraint if exists companies_custody_limits_chk; alter table companies add constraint companies_custody_limits_chk CHECK ((((custody_max_open >= 1) AND (custody_max_open <= 20)) AND ((custody_default_days >= 1) AND (custody_default_days <= 365)) AND ((custody_receipt_days >= 1) AND (custody_receipt_days <= 60))));
alter table custodies drop constraint if exists custodies_amount_check; alter table custodies add constraint custodies_amount_check CHECK ((amount > (0)::numeric));
alter table companies drop constraint if exists companies_custody_amounts_chk; alter table companies add constraint companies_custody_amounts_chk CHECK ((((custody_max_amount IS NULL) OR (custody_max_amount > (0)::numeric)) AND ((custody_max_total IS NULL) OR (custody_max_total > (0)::numeric))));
alter table custody_balances drop constraint if exists custody_balances_amount_check; alter table custody_balances add constraint custody_balances_amount_check CHECK ((amount <> (0)::numeric));
alter table users drop constraint if exists users_avatar_size_chk; alter table users add constraint users_avatar_size_chk CHECK (((avatar_data IS NULL) OR (length(avatar_data) <= 200000)));
alter table centers drop constraint if exists centers_min_single_approver_chk; alter table centers add constraint centers_min_single_approver_chk CHECK ((min_single_approver = ANY (ARRAY['exec'::text, 'direct'::text, 'senior'::text])));
alter table companies drop constraint if exists companies_custody_path_mode_chk; alter table companies add constraint companies_custody_path_mode_chk CHECK ((custody_path_mode = ANY (ARRAY['exec'::text, 'direct'::text, 'full'::text])));
alter table companies drop constraint if exists companies_custody_review_mode_chk; alter table companies add constraint companies_custody_review_mode_chk CHECK (((custody_review_mode = ANY (ARRAY['line'::text, 'whole'::text])) AND (custody_img_min >= (0)::numeric)));
alter table custody_lines drop constraint if exists custody_lines_kind_check; alter table custody_lines add constraint custody_lines_kind_check CHECK ((kind = ANY (ARRAY['expense'::text, 'receipt'::text])));
alter table custody_lines drop constraint if exists custody_lines_amount_check; alter table custody_lines add constraint custody_lines_amount_check CHECK ((amount > (0)::numeric));
alter table custody_lines drop constraint if exists custody_lines_description_check; alter table custody_lines add constraint custody_lines_description_check CHECK (((length(btrim(description)) >= 1) AND (length(btrim(description)) <= 300)));
alter table custody_lines drop constraint if exists custody_lines_invoice_no_check; alter table custody_lines add constraint custody_lines_invoice_no_check CHECK (((invoice_no IS NULL) OR (length(invoice_no) <= 60)));
alter table custody_lines drop constraint if exists custody_lines_image_data_check; alter table custody_lines add constraint custody_lines_image_data_check CHECK (((image_data IS NULL) OR (length(image_data) <= 3000000)));
alter table custody_lines drop constraint if exists custody_lines_status_check; alter table custody_lines add constraint custody_lines_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'accepted'::text, 'rejected'::text])));
alter table custodies drop constraint if exists custodies_status_check; alter table custodies add constraint custodies_status_check CHECK ((status = ANY (ARRAY['requested'::text, 'awaiting_receipt'::text, 'open'::text, 'close_requested'::text, 'acct_review'::text, 'returned'::text, 'pending_sign'::text, 'closed'::text, 'cancelled'::text])));
alter table transactions drop constraint if exists transactions_source_type_check; alter table transactions add constraint transactions_source_type_check CHECK ((source_type = ANY (ARRAY['request'::text, 'recurring'::text, 'manual'::text, 'revenue'::text, 'opening'::text, 'refund'::text, 'custody'::text])));
alter table custody_balances drop constraint if exists custody_balances_status_check; alter table custody_balances add constraint custody_balances_status_check CHECK ((status = ANY (ARRAY['open'::text, 'applied'::text, 'settled'::text])));
alter table companies drop constraint if exists companies_custody_over_mode_chk; alter table companies add constraint companies_custody_over_mode_chk CHECK ((custody_over_mode = ANY (ARRAY['none'::text, 'percent'::text, 'amount'::text])));
alter table companies drop constraint if exists companies_custody_over_value_chk; alter table companies add constraint companies_custody_over_value_chk CHECK ((custody_over_value >= (0)::numeric));
alter table custodies drop constraint if exists custodies_over_mode_chk; alter table custodies add constraint custodies_over_mode_chk CHECK (((over_mode IS NULL) OR (over_mode = ANY (ARRAY['none'::text, 'percent'::text, 'amount'::text]))));
alter table companies drop constraint if exists companies_custody_nodoc_chk; alter table companies add constraint companies_custody_nodoc_chk CHECK ((((custody_nodoc_mode IS NULL) OR (custody_nodoc_mode = ANY (ARRAY['amount'::text, 'percent'::text]))) AND ((custody_nodoc_value IS NULL) OR (custody_nodoc_value >= (0)::numeric)) AND ((custody_nodoc_mode <> 'percent'::text) OR (custody_nodoc_value <= (100)::numeric))));
alter table companies drop constraint if exists companies_custody_signers_chk; alter table companies add constraint companies_custody_signers_chk CHECK ((custody_signers = ANY (ARRAY['any'::text, 'cfo'::text, 'acct'::text])));
alter table custodies drop constraint if exists custodies_request_id_fkey; alter table custodies add constraint custodies_request_id_fkey FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE;
alter table custodies drop constraint if exists custodies_company_id_fkey; alter table custodies add constraint custodies_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id);
alter table custodies drop constraint if exists custodies_holder_id_fkey; alter table custodies add constraint custodies_holder_id_fkey FOREIGN KEY (holder_id) REFERENCES users(id);
alter table custodies drop constraint if exists custodies_carried_from_id_fkey; alter table custodies add constraint custodies_carried_from_id_fkey FOREIGN KEY (carried_from_id) REFERENCES custodies(id);
alter table custodies drop constraint if exists custodies_reviewer_id_fkey; alter table custodies add constraint custodies_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES users(id);
alter table custody_lines drop constraint if exists custody_lines_custody_id_fkey; alter table custody_lines add constraint custody_lines_custody_id_fkey FOREIGN KEY (custody_id) REFERENCES custodies(id) ON DELETE CASCADE;
alter table custody_balances drop constraint if exists custody_balances_holder_id_fkey; alter table custody_balances add constraint custody_balances_holder_id_fkey FOREIGN KEY (holder_id) REFERENCES users(id);
alter table custody_balances drop constraint if exists custody_balances_source_custody_id_fkey; alter table custody_balances add constraint custody_balances_source_custody_id_fkey FOREIGN KEY (source_custody_id) REFERENCES custodies(id);
alter table custody_balances drop constraint if exists custody_balances_applied_custody_id_fkey; alter table custody_balances add constraint custody_balances_applied_custody_id_fkey FOREIGN KEY (applied_custody_id) REFERENCES custodies(id);
-- (٤) الفهارس
CREATE INDEX IF NOT EXISTS custodies_holder_idx ON public.custodies USING btree (holder_id, company_id, status);
CREATE INDEX IF NOT EXISTS custody_lines_custody_idx ON public.custody_lines USING btree (custody_id);
-- (٥) الدوال (الجديدة والمحدَّثة) — check_function_bodies مُعطّل حتى لا يهم الترتيب
CREATE OR REPLACE FUNCTION public.can_see_request(p_request_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.requests r
    where r.id = p_request_id and (
         r.created_by_id = public.qy_me()
      or (public.is_finance() and public.can_see_company(r.company_id))
      or exists (select 1 from public.request_approval_steps s where s.request_id = r.id and public.qy_step_actor_ok(s.approver_id, r.id, public.qy_me()))
      or exists (select 1 from public.request_history h where h.request_id = r.id and h.user_id = public.qy_me())
      or exists (select 1 from public.custodies k where k.request_id = r.id and k.holder_id = public.qy_me())
      or exists (select 1 from public.companies c where c.id = r.company_id and public.can_see_company(r.company_id) and (
             (c.cfo_delegation_mode = 'delegate_user' and c.cfo_delegate_user_id = public.qy_me())
          or (c.cfo_delegation_mode = 'delegate_manager' and exists (select 1 from public.users u where u.manager_id = public.qy_me() and u.role = 'accountant'))))
    ));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_ben_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype; v_me text; rid text; s numeric;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  rid := case when tg_op = 'DELETE' then old.request_id else new.request_id end;
  select * into r from public.requests where id = rid;
  if not found then return case when tg_op = 'DELETE' then old else new end; end if;
  v_me := public.qy_me();
  if r.is_cancelled then
    perform public.qy_deny('ben_cancelled', rid, 'لا يُعدَّل مستفيدو طلب ملغى');
  elsif not (public.qy_content_open(r.id, r.status)
             or (r.status = 'pending_transfer_request' and r.number is null and coalesce(r.created_by_id = v_me, false))) then
    perform public.qy_deny('ben_locked', rid, 'مستفيدو الطلب مقفلون بعد أول اعتماد');
  elsif not coalesce(r.created_by_id = v_me, false) then
    perform public.qy_deny('ben_stranger', rid, 'تعديل مستفيدي الطلب لصاحبه فقط؛ المالية ترفض الطلب بملاحظة');
  elsif public.qy_content_open(r.id, r.status) and public.qy_page_blocked(r.company_id, 'editreq')
        and public.qy_ben_is_edit(rid, tg_op) then
    perform public.qy_deny('ben_edit_page', rid, 'ليست لديك صلاحية «تعديل طلباتي» في هذه الشركة');
  end if;
  if tg_op <> 'DELETE' and r.status = 'pending_transfer_request' and not public.is_finance() then
    select coalesce(sum(greatest(coalesce(b.amount,0) - coalesce(b.deduction,0) + coalesce(b.extra,0), 0)), 0) into s
      from public.request_beneficiaries b where b.request_id = rid and (tg_op = 'INSERT' or b.id <> old.id);
    s := s + greatest(coalesce(new.amount,0) - coalesce(new.deduction,0) + coalesce(new.extra,0), 0);
    if s > coalesce(r.total_amount,0) + 0.001 then
      perform public.qy_deny('ben_over_total', rid, 'مجموع المستفيدين يتجاوز مبلغ الطلب');
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_ben_is_edit(p_req text, p_op text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k text := 'qy.bn_' || md5(p_req);
begin
  if p_op <> 'INSERT' then return true; end if;
  if current_setting(k, true) = '1' then return false; end if;
  if exists (select 1 from public.request_beneficiaries b where b.request_id = p_req) then return true; end if;
  perform set_config(k, '1', true);
  return false;
end $function$
;
drop function if exists public.qy_budget_figures(text);  -- تغيّر نوع الإرجاع (عمود reserved_extra)
CREATE OR REPLACE FUNCTION public.qy_budget_figures(p_company text)
 RETURNS TABLE(budget_item_id text, committed numeric, pending numeric, reserved_extra numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with rq as (
    select r.budget_item_id,
           coalesce(sum(r.total_amount) filter (where r.status in ('pending_transfer_request','pending_transfer_approval','pending_disbursement','pending_accountant','pending_cfo')), 0) as committed,
           coalesce(sum(r.total_amount) filter (where r.status in ('pending_decision','pending_manager','pending_senior','pending_executive')), 0) as pending
    from public.requests r
    where public.can_see_company(p_company) and r.company_id = p_company and r.budget_item_id is not null
      and not coalesce(r.is_cancelled,false) and r.status <> 'rejected'
    group by r.budget_item_id),
  ck as (
    select k.budget_item_id, coalesce(sum(k.carried_in + public.qy_custody_over_amount(k.id)), 0) as extra
    from public.custodies k
    where public.can_see_company(p_company) and k.company_id = p_company and k.budget_item_id is not null
      and k.status in ('open','returned','close_requested','acct_review','pending_sign')
    group by k.budget_item_id)
  select coalesce(rq.budget_item_id, ck.budget_item_id), coalesce(rq.committed,0), coalesce(rq.pending,0), coalesce(ck.extra,0)
  from rq full join ck on ck.budget_item_id = rq.budget_item_id;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; sgn boolean; m text; nd int; nr int; r numeric; e numeric; b numeric; me text := public.qy_me();
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'acct_review' then raise exception 'العهدة ليست عند المحاسب'; end if;
  if not ((public.is_finance() and public.can_see_company(k.company_id)) or public.is_admin()) then raise exception 'قرار الإقفال للمالية'; end if;
  if k.holder_id = me then raise exception 'صاحب العهدة لا يعتمد إقفالها'; end if;
  select coalesce(c.custody_review_mode,'line') into m from public.companies c where c.id = k.company_id;
  select count(*) filter (where status = 'draft'), count(*) filter (where status = 'rejected') into nd, nr from public.custody_lines where custody_id = p_id;
  if not p_accept then
    if m = 'line' and nr = 0 then raise exception 'ارفض السطور التي تحتاج تصحيحاً أولاً'; end if;
    if m = 'whole' and length(btrim(coalesce(p_note,''))) = 0 then raise exception 'اكتب سبب الإرجاع'; end if;
    update public.custodies set status = 'returned' where id = p_id returning * into k;
    perform public.qy_custody_hist(k, 'أعاد المحاسب العهدة للتصحيح', coalesce(nullif(btrim(p_note),''), nr || ' سطر مرفوض'));
    return k;
  end if;
  if m = 'line' and (nd > 0 or nr > 0) then raise exception 'كل السطور يجب أن تكون مقبولة قبل الاعتماد'; end if;
  if m = 'whole' then update public.custody_lines set status = 'accepted', review_note = null, reviewed_by_id = me, reviewed_at = now() where custody_id = p_id; end if;
  select coalesce(sum(amount) filter (where kind = 'receipt'),0), coalesce(sum(amount) filter (where kind = 'expense'),0) into r, e from public.custody_lines where custody_id = p_id;
  b := round(k.amount + k.carried_in + r - e, 3);
  if b > 0 and p_action not in ('return_cash','carry') then raise exception 'اختر: إرجاع الباقي نقداً أو ترحيله'; end if;
  if b < 0 and p_action not in ('pay_diff','carry_debt') then raise exception 'اختر: صرف الفرق لصاحب العهدة أو ترحيله ديناً'; end if;
  update public.custodies set status = 'pending_sign', reviewed_by_id = me, remaining_amount = b,
    remaining_action = case when b = 0 then 'none' else p_action end where id = p_id returning * into k;
  perform public.qy_custody_hist(k, 'اعتمد المحاسب إقفال العهدة',
    'الباقي ' || to_char(b, 'FM999,999,990.000') || ' — ' || case k.remaining_action when 'return_cash' then 'يُرجَع نقداً' when 'carry' then 'يُرحَّل رصيداً معلّقاً' when 'pay_diff' then 'يُصرف الفرق لصاحبها' when 'carry_debt' then 'يُرحَّل ديناً' else 'لا باقي' end);
  select coalesce(c.custody_sign_on, true) into sgn from public.companies c where c.id = k.company_id;
  if not sgn then k := public.qy_custody_finalize(p_id, me, 'أُقفلت العهدة مباشرة بعد اعتماد المحاسب (توقيع الإدارة غير مفعّل)'); end if;
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_admin_undo(p_id bigint, p_reason text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; from_st text; to_st text;
begin
  if not public.is_admin() then raise exception 'التراجع لمدير النظام فقط'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'سبب التراجع مطلوب'; end if;
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  from_st := k.status;
  if from_st = 'pending_sign' then
    update public.custodies set status = 'acct_review', reviewed_by_id = null, remaining_amount = 0, remaining_action = 'none' where id = p_id returning * into k; to_st := 'عند المحاسب';
  elsif from_st = 'acct_review' then
    update public.custodies set status = 'close_requested' where id = p_id returning * into k; to_st := 'عند المراجِع';
  elsif from_st = 'close_requested' then
    update public.custodies set status = 'open', reviewer_id = null, close_requested_at = null where id = p_id returning * into k; to_st := 'مفتوحة عند صاحبها';
  else raise exception 'لا يوجد تراجع من هذه المرحلة';
  end if;
  perform public.qy_custody_hist(k, 'تراجع مدير النظام عن خطوة العهدة', 'إلى: ' || to_st || ' — السبب: ' || btrim(p_reason));
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_balance_settle(p_id bigint, p_note text)
 RETURNS custody_balances
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare b public.custody_balances%rowtype;
begin
  select * into b from public.custody_balances where id = p_id for update;
  if not found then raise exception 'الرصيد غير موجود'; end if;
  if b.status <> 'open' then raise exception 'الرصيد ليس معلّقاً'; end if;
  if not ((public.is_finance() and public.can_see_company(b.company_id)) or public.is_admin()) then raise exception 'التسوية للمالية'; end if;
  update public.custody_balances set status = 'settled', settled_by_id = public.qy_me(), settled_at = now(), note = left(btrim(coalesce(p_note,'')),300)
   where id = p_id returning * into b;
  return b;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_chain(p_req text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r public.requests%rowtype; v_holder text; v_mode text; ch jsonb; ids text[]; err text;
  n int; i int; x text; xr text; hr text; pick text; found_exec boolean := false; v_self boolean := false;
begin
  select * into r from public.requests where id = p_req;
  if not found then return jsonb_build_object('ids','[]'::jsonb,'error','الطلب غير موجود','fast',false,'self',false); end if;
  select k.holder_id into v_holder from public.custodies k where k.request_id = p_req;
  v_holder := coalesce(v_holder, r.created_by_id);
  select c.custody_path_mode into v_mode from public.companies c where c.id = r.company_id;
  v_mode := coalesce(nullif(v_mode, 'finance'), 'exec');
  ch := public.qy_decision_chain(v_holder, r.company_id, case when v_mode = 'full' then r.total_amount end);
  err := ch->>'error';
  select coalesce(array_agg(t.x order by t.o), '{}') into ids from jsonb_array_elements_text(ch->'ids') with ordinality t(x, o);
  n := coalesce(array_length(ids,1), 0);
  if v_mode = 'full' then
    if n > 0 and err is null and ids = array[r.created_by_id] then v_self := true; end if;
    ids := array_remove(ids, r.created_by_id);
    return jsonb_build_object('ids', to_jsonb(ids), 'error', err, 'fast', coalesce((ch->>'fast')::boolean, false), 'self', v_self);
  end if;
  if v_mode = 'exec' then
    select u.role into hr from public.users u where u.id = v_holder;
    if hr is distinct from 'executive_manager' then
      for i in 1 .. n loop
        select u.role into xr from public.users u where u.id = ids[i];
        if xr = 'executive_manager' then
          found_exec := true;
          if ids[i] = r.created_by_id then
            pick := ids[i+1];
            if pick is null and err is null then v_self := true; end if;
          else pick := ids[i]; end if;
          exit;
        end if;
      end loop;
      if not found_exec and err is not null then
        return jsonb_build_object('ids','[]'::jsonb,'error',err,'fast',false,'self',false);
      end if;
    end if;
  end if;
  if not found_exec then
    foreach x in array ids loop
      if x is distinct from r.created_by_id then pick := x; exit; end if;
    end loop;
    if pick is null and err is null and r.created_by_id = any(ids) then v_self := true; end if;
  end if;
  if pick is null and err is not null then
    return jsonb_build_object('ids','[]'::jsonb,'error',err,'fast',false,'self',false);
  end if;
  return jsonb_build_object('ids', case when pick is null then '[]'::jsonb else jsonb_build_array(pick) end, 'error', null, 'fast', false, 'self', v_self);
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_confirm(p_id bigint, p_time text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; me text := public.qy_me(); nm text;
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.holder_id is distinct from me and not public.is_admin() then raise exception 'تأكيد استلام العهدة لصاحبها وحده'; end if;
  if k.status <> 'awaiting_receipt' then raise exception 'العهدة ليست بانتظار تأكيد الاستلام'; end if;
  update public.custodies set status = 'open', received_at = now(),
    carried_in = coalesce((select sum(b.amount) from public.custody_balances b where b.holder_id = k.holder_id and b.company_id = k.company_id and b.status = 'open'), 0)
   where id = p_id returning * into k;
  update public.custody_balances set status = 'applied', applied_custody_id = p_id where holder_id = k.holder_id and company_id = k.company_id and status = 'open';
  select u.name into nm from public.users u where u.id = k.holder_id;
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (k.request_id, 'custody_receipt', nm, k.holder_id, 'تأكيد استلام العهدة', '', left(coalesce(p_time,''), 40));
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; r numeric; e numeric; d numeric; co text; hn text;
begin
  select * into k from public.custodies where id = p_id for update;
  select coalesce(sum(amount) filter (where kind = 'receipt'),0), coalesce(sum(amount) filter (where kind = 'expense'),0) into r, e from public.custody_lines where custody_id = p_id;
  d := round(k.amount + r - e, 3);
  select c.code into co from public.companies c where c.id = k.company_id;
  select u.name into hn from public.users u where u.id = k.holder_id;
  if d <> 0 then
    insert into public.transactions(company_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, note, created_by_id, created_by)
    values (k.company_id, current_date, case when d > 0 then 'in' else 'out' end, abs(d), k.budget_item_id, hn,
      case when d > 0 then 'إقفال عهدة: ما لم يُصرف يعود للبند' else 'إقفال عهدة: مصروف زائد على مبلغها' end,
      'custody', k.id::text, 'العهدة ' || k.id, p_signer, (select u.name from public.users u where u.id = p_signer));
  end if;
  if k.remaining_action in ('carry','carry_debt') and coalesce(k.remaining_amount,0) <> 0 then
    insert into public.custody_balances(holder_id, company_id, amount, source_custody_id) values (k.holder_id, k.company_id, k.remaining_amount, k.id);
  end if;
  update public.custodies set status = 'closed', signed_by_id = p_signer, closed_at = now(),
    settlement_no = coalesce(settlement_no, 'ST-' || coalesce(co,'') || '-' || lpad(k.id::text, 5, '0')) where id = p_id returning * into k;
  perform public.qy_custody_hist(k, p_hist, 'كشف التسوية ' || k.settlement_no);
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_hist(p_k custodies, p_action text, p_note text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (p_k.request_id, 'custody_close', (select u.name from public.users u where u.id = public.qy_me()), public.qy_me(), p_action, coalesce(p_note,''), public.qy_now_txt());
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_ins_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype; lim int; dd int; n int; hn text;
begin
  select * into r from public.requests where id = new.request_id;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.request_type <> 'custody' then raise exception 'الطلب ليس طلب عهدة'; end if;
  new.company_id := r.company_id; new.budget_item_id := r.budget_item_id; new.amount := r.total_amount;
  new.status := 'requested'; new.received_at := null; new.carried_in := 0; new.carried_from_id := null;
  new.remaining_action := null; new.remaining_amount := null; new.settlement_no := null;
  new.reviewed_by_id := null; new.signed_by_id := null; new.closed_at := null;
  new.created_by_id := r.created_by_id;
  select u.name into hn from public.users u where u.id = new.holder_id and not coalesce(u.is_suspended,false);
  if hn is null then raise exception 'صاحب العهدة غير موجود أو موقوف الحساب'; end if;
  if not public.qy_user_in_company(new.holder_id, new.company_id) then
    raise exception 'صاحب العهدة «%» غير مرتبط بهذه الشركة', hn;
  end if;
  new.purpose := left(btrim(coalesce(new.purpose,'')), 500);
  select c.custody_max_open, c.custody_default_days into lim, dd from public.companies c where c.id = new.company_id;
  if new.due_close_at is null then new.due_close_at := current_date + coalesce(dd,30); end if;
  if new.due_close_at < current_date then raise exception 'موعد الإقفال المتوقع لا يكون قبل اليوم'; end if;
  select count(*) into n from public.custodies k
   where k.holder_id = new.holder_id and k.company_id = new.company_id and k.status not in ('closed','cancelled');
  if n >= coalesce(lim,1) then
    raise exception 'لدى «%» % عهدة مفتوحة، وهو الحد الأقصى في هذه الشركة (%). تُقفل عهدة أولاً أو يرفع مدير النظام الحد', hn, n, coalesce(lim,1);
  end if;
  perform public.qy_custody_limits_check(new.holder_id, new.company_id, new.amount, null);
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_limits_check(p_holder text, p_company text, p_amount numeric, p_except bigint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ma numeric; mt numeric; s numeric; hn text;
begin
  select c.custody_max_amount, c.custody_max_total into ma, mt from public.companies c where c.id = p_company;
  if ma is not null and p_amount > ma then
    raise exception 'مبلغ العهدة % د.ك يتجاوز الحد الأقصى للعهدة الواحدة في هذه الشركة (% د.ك)',
      to_char(p_amount,'FM999,999,990.000'), to_char(ma,'FM999,999,990.000');
  end if;
  if mt is not null then
    select coalesce(sum(k.amount),0) into s from public.custodies k
     where k.holder_id = p_holder and k.company_id = p_company and k.status not in ('closed','cancelled')
       and k.id is distinct from p_except;
    if s + p_amount > mt then
      select u.name into hn from public.users u where u.id = p_holder;
      raise exception 'مجموع عهد «%» المفتوحة سيصير % د.ك، وهو أكثر من الحد الأقصى لمجموع العهد المفتوحة للشخص (% د.ك)',
        coalesce(hn,''), to_char(s + p_amount,'FM999,999,990.000'), to_char(mt,'FM999,999,990.000');
    end if;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_line_delete(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; l public.custody_lines%rowtype;
begin
  select * into l from public.custody_lines where id = p_id;
  if not found then raise exception 'السطر غير موجود'; end if;
  select * into k from public.custodies where id = l.custody_id for update;
  if k.holder_id is distinct from public.qy_me() and not public.is_admin() then raise exception 'حذف سطور العهدة لصاحبها وحده'; end if;
  if k.status not in ('open','returned') then raise exception 'العهدة ليست مفتوحة'; end if;
  if l.status = 'accepted' then raise exception 'سطر قبله المراجِع لا يُحذف'; end if;
  delete from public.custody_lines where id = p_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_line_image(p_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select l.image_data from public.custody_lines l join public.custodies k on k.id = l.custody_id
   where l.id = p_id and (k.holder_id = public.qy_me() or k.created_by_id = public.qy_me() or k.reviewer_id = public.qy_me() or public.is_admin()
     or (public.is_finance() and public.can_see_company(k.company_id)) or public.can_see_request(k.request_id));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_line_reopen(p_line bigint)
 RETURNS custody_lines
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l public.custody_lines%rowtype; k public.custodies%rowtype; me text := public.qy_me();
begin
  select * into l from public.custody_lines where id = p_line for update;
  if not found then raise exception 'السطر غير موجود'; end if;
  select * into k from public.custodies where id = l.custody_id;
  if k.status <> 'close_requested' then raise exception 'العهدة ليست عند المراجِع'; end if;
  if k.reviewer_id is distinct from me and not public.is_admin() then raise exception 'للمراجِع وحده'; end if;
  if l.status <> 'rejected' then raise exception 'يُفتح للتصحيح سطر مرفوض فقط'; end if;
  update public.custody_lines set reopened = true where id = p_line returning * into l;
  return l;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean DEFAULT true, p_no_doc boolean DEFAULT false, p_no_doc_reason text DEFAULT NULL::text)
 RETURNS custody_lines
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; l public.custody_lines%rowtype; mn numeric; img text; d date := coalesce(p_date, current_date);
  nd_on boolean; cap numeric; used numeric; nodoc boolean := coalesce(p_no_doc,false);
begin
  select * into k from public.custodies where id = p_custody for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.holder_id is distinct from public.qy_me() and not public.is_admin() then raise exception 'تسجيل سطور العهدة لصاحبها وحده'; end if;
  if p_id is not null then
    select * into l from public.custody_lines where id = p_id and custody_id = p_custody for update;
    if not found then raise exception 'السطر غير موجود'; end if;
  end if;
  if k.status = 'close_requested' then
    if p_id is null or not coalesce(l.reopened,false) then raise exception 'العهدة عند المراجِع: لا يُعدَّل إلا سطر فتحه للتصحيح'; end if;
  elsif k.status not in ('open','returned') then raise exception 'العهدة ليست مفتوحة لتسجيل السطور'; end if;
  if p_kind not in ('expense','receipt') then raise exception 'نوع السطر غير معروف'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'المبلغ يجب أن يكون أكبر من صفر'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'الوصف مطلوب'; end if;
  if d > current_date then raise exception 'تاريخ السطر لا يكون بعد اليوم'; end if;
  if k.received_at is not null and d < (k.received_at at time zone 'Asia/Kuwait')::date then raise exception 'تاريخ السطر لا يكون قبل استلام العهدة'; end if;
  if p_id is not null and l.status = 'accepted' then raise exception 'سطر قبله المراجِع لا يُعدَّل'; end if;
  select c.custody_img_min, c.custody_nodoc_on into mn, nd_on from public.companies c where c.id = k.company_id;
  if nodoc then
    if not coalesce(nd_on,false) then raise exception 'الصرف بلا سند غير مسموح في هذه الشركة'; end if;
    if p_kind <> 'expense' then raise exception 'المقبوض لا يُسجَّل بلا سند'; end if;
    if length(btrim(coalesce(p_no_doc_reason,''))) = 0 then raise exception 'اكتب سبب عدم وجود سند'; end if;
    cap := public.qy_custody_nodoc_cap(p_custody);
    if cap is not null then
      select coalesce(sum(amount),0) into used from public.custody_lines where custody_id = p_custody and no_doc and id is distinct from p_id;
      if used + p_amount > cap then raise exception 'تجاوز سقف المبالغ بلا سند لهذه العهدة (%). المتاح: %', cap, greatest(cap - used, 0); end if;
    end if;
  end if;
  img := case when nullif(p_image,'') is not null then p_image when p_id is not null and coalesce(p_keep_image,true) then l.image_data else null end;
  if img is null and not nodoc and (p_kind = 'receipt' or p_amount >= coalesce(mn,0)) then
    raise exception 'صورة السند إلزامية لهذا السطر';
  end if;
  if p_id is null then
    insert into public.custody_lines(custody_id, kind, amount, description, invoice_no, line_date, image_data, created_by_id, no_doc, no_doc_reason)
      values (p_custody, p_kind, round(p_amount,3), left(btrim(p_desc),300), nullif(left(btrim(coalesce(p_invoice,'')),60),''), d, img, public.qy_me(), nodoc, case when nodoc then left(btrim(p_no_doc_reason),300) end)
      returning * into l;
  else
    update public.custody_lines set kind = p_kind, amount = round(p_amount,3), description = left(btrim(p_desc),300),
      invoice_no = nullif(left(btrim(coalesce(p_invoice,'')),60),''), line_date = d, image_data = img,
      no_doc = nodoc, no_doc_reason = case when nodoc then left(btrim(p_no_doc_reason),300) end,
      status = 'draft', review_note = null, reopened = false, updated_at = now()
     where id = p_id returning * into l;
  end if;
  perform public.qy_custody_over_check(p_custody);
  return l;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_nodoc_cap(p_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case c.custody_nodoc_mode when 'amount' then c.custody_nodoc_value when 'percent' then round(k.amount * c.custody_nodoc_value / 100, 3) else null end
  from public.custodies k join public.companies c on c.id = k.company_id where k.id = p_id;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_over_amount(p_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select greatest(0, round(coalesce(sum(l.amount) filter (where l.kind = 'expense'),0)
                        - (k.amount + k.carried_in + coalesce(sum(l.amount) filter (where l.kind = 'receipt'),0)), 3))
  from public.custodies k left join public.custody_lines l on l.custody_id = k.id
  where k.id = p_id group by k.id, k.amount, k.carried_in;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_over_check(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ov numeric := public.qy_custody_over_amount(p_id); lm numeric := public.qy_custody_over_limit(p_id);
begin
  if lm is not null and ov > lm then
    raise exception 'تجاوزت الحد المسموح للصرف فوق العهدة (% د.ك): الزيادة الآن % د.ك. قدّم طلب صرف فعلياً بدل تسجيلها على العهدة',
      to_char(lm, 'FM999,999,990.000'), to_char(ov, 'FM999,999,990.000');
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_over_limit(p_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case coalesce(k.over_mode, c.custody_over_mode)
           when 'percent' then round(k.amount * coalesce(k.over_value, c.custody_over_value) / 100, 3)
           when 'amount' then coalesce(k.over_value, c.custody_over_value)
           else null end
  from public.custodies k join public.companies c on c.id = k.company_id where k.id = p_id;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_over_list(p_company text)
 RETURNS TABLE(id bigint, holder_name text, purpose text, item_name text, amount numeric, over_amt numeric, lim numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select k.id, u.name, k.purpose, b.name, k.amount, public.qy_custody_over_amount(k.id), public.qy_custody_over_limit(k.id)
  from public.custodies k join public.users u on u.id = k.holder_id left join public.budget_items b on b.id = k.budget_item_id
  where k.company_id = p_company and k.status in ('open','returned','close_requested','acct_review','pending_sign')
    and public.qy_custody_over_amount(k.id) > 0
    and (public.is_admin() or (public.is_finance() and public.can_see_company(p_company))
         or exists (select 1 from public.companies c where c.id = p_company and c.custody_alert_user_id = public.qy_me()));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; rn text; hn text;
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.holder_id is distinct from public.qy_me() and not public.is_admin() then raise exception 'طلب الإقفال لصاحب العهدة وحده'; end if;
  if k.status not in ('open','returned') then raise exception 'العهدة ليست مفتوحة'; end if;
  if p_reviewer is null or p_reviewer = k.holder_id then raise exception 'اختر مراجِعاً غير صاحب العهدة'; end if;
  select u.name into rn from public.users u where u.id = p_reviewer and not coalesce(u.is_suspended,false);
  if rn is null then raise exception 'المراجِع غير موجود أو موقوف'; end if;
  if not public.qy_user_in_company(p_reviewer, k.company_id) then raise exception 'المراجِع «%» غير مرتبط بهذه الشركة', rn; end if;
  -- مراجِع جديد: يراجع كل السطور من البداية
  if k.reviewer_id is not null and k.reviewer_id <> p_reviewer then
    update public.custody_lines set status = 'draft', review_note = null, reviewed_by_id = null, reviewed_at = null where custody_id = p_id;
  end if;
  update public.custodies set status = 'close_requested', reviewer_id = p_reviewer, close_requested_at = now() where id = p_id returning * into k;
  select u.name into hn from public.users u where u.id = k.holder_id;
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (k.request_id, 'custody_close', hn, k.holder_id, 'طلب إقفال العهدة', 'المراجِع: ' || rn, left(coalesce(p_time,''), 40));
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text)
 RETURNS custody_lines
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l public.custody_lines%rowtype; k public.custodies%rowtype; me text := public.qy_me(); m text;
begin
  select * into l from public.custody_lines where id = p_line for update;
  if not found then raise exception 'السطر غير موجود'; end if;
  select * into k from public.custodies where id = l.custody_id;
  if k.holder_id = me then raise exception 'صاحب العهدة لا يراجع سطوره'; end if;
  select coalesce(c.custody_review_mode,'line') into m from public.companies c where c.id = k.company_id;
  if k.status = 'close_requested' then
    if k.reviewer_id is distinct from me and not public.is_admin() then raise exception 'المراجعة للمراجِع الذي اختاره صاحب العهدة'; end if;
  elsif k.status = 'acct_review' then
    if not ((public.is_finance() and public.can_see_company(k.company_id)) or public.is_admin()) then raise exception 'مراجعة المحاسب للمالية'; end if;
    if m <> 'line' then raise exception 'المحاسب يقبل العهدة كلها أو يرجعها (إعداد الشركة)'; end if;
  else raise exception 'العهدة ليست في مرحلة المراجعة'; end if;
  if not p_ok and length(btrim(coalesce(p_note,''))) = 0 then raise exception 'اكتب سبب الرفض'; end if;
  update public.custody_lines set status = case when p_ok then 'accepted' else 'rejected' end,
     review_note = case when p_ok then null else left(btrim(p_note),300) end, reviewed_by_id = me, reviewed_at = now()
   where id = p_line returning * into l;
  return l;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_reviewer_done(p_id bigint)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; nd int; nr int; me text := public.qy_me();
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'close_requested' then raise exception 'العهدة ليست عند المراجِع'; end if;
  if k.reviewer_id is distinct from me and not public.is_admin() then raise exception 'للمراجِع وحده'; end if;
  select count(*) filter (where status = 'draft' or reviewed_by_id is distinct from me),
         count(*) filter (where status = 'rejected' and reviewed_by_id is not distinct from me)
    into nd, nr from public.custody_lines where custody_id = p_id;
  if nd > 0 then raise exception 'بقي % سطر لم تراجعه', nd; end if;
  update public.custodies set status = case when nr > 0 then 'returned' else 'acct_review' end where id = p_id returning * into k;
  perform public.qy_custody_hist(k, case when nr > 0 then 'أعاد المراجِع العهدة للتصحيح' else 'أنهى المراجِع مراجعة العهدة' end,
    case when nr > 0 then nr || ' سطر مرفوض' else '' end);
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype;
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if not public.is_admin() then raise exception 'تعديل حد الصرف لمدير النظام فقط'; end if;
  if coalesce(trim(p_note),'') = '' then raise exception 'سبب التعديل مطلوب'; end if;
  if p_mode is not null and p_mode not in ('none','percent','amount') then raise exception 'نوع الحد غير معروف'; end if;
  if p_mode in ('percent','amount') and (p_value is null or p_value < 0) then raise exception 'قيمة الحد غير صحيحة'; end if;
  if p_mode = 'percent' and p_value > 100 then raise exception 'النسبة لا تزيد عن 100'; end if;
  update public.custodies set over_mode = p_mode, over_value = case when p_mode in ('percent','amount') then round(p_value,3) else null end
   where id = p_id returning * into k;
  perform public.qy_custody_hist(k, 'ضبط حد الصرف فوق العهدة', (case coalesce(p_mode,'') when 'percent' then p_value || '% من مبلغها' when 'amount' then p_value || ' د.ك' when 'none' then 'بلا حد' else 'حسب إعداد الشركة' end) || ' — السبب: ' || trim(p_note));
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_sign(p_id bigint)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; me text := public.qy_me(); sg text; ok boolean;
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'pending_sign' then raise exception 'العهدة ليست بانتظار التوقيع'; end if;
  select coalesce(c.custody_signers,'any') into sg from public.companies c where c.id = k.company_id;
  ok := public.is_admin() or (public.can_see_company(k.company_id) and case sg
          when 'cfo'  then public.qy_is_cfo()
          when 'acct' then exists (select 1 from public.users u where u.id = me and u.role = 'accountant')
          else public.is_finance() end);
  if not ok then raise exception '%', case sg when 'cfo' then 'التوقيع للمدير المالي' when 'acct' then 'التوقيع لمحاسب آخر' else 'التوقيع للمدير المالي أو محاسب' end; end if;
  if me in (k.holder_id, k.reviewer_id, k.reviewed_by_id) and not public.is_admin() then
    raise exception 'لا يوقّع صاحب العهدة ولا من راجعها أو اعتمدها';
  end if;
  return public.qy_custody_finalize(p_id, me, 'وقّع إقفال العهدة');
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_sign_reject(p_id bigint, p_note text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; me text := public.qy_me();
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'pending_sign' then raise exception 'العهدة ليست بانتظار التوقيع'; end if;
  if not ((public.is_finance() and public.can_see_company(k.company_id)) or public.is_admin()) then raise exception 'الرفض للمدير المالي أو محاسب'; end if;
  if me in (k.holder_id, k.reviewer_id, k.reviewed_by_id) and not public.is_admin() then raise exception 'لا ترفض عهدة كنت طرفاً فيها'; end if;
  if coalesce(btrim(p_note),'') = '' then raise exception 'اكتب سبب الرفض'; end if;
  update public.custodies set status = 'acct_review', reviewed_by_id = null, remaining_amount = 0, remaining_action = 'none' where id = p_id returning * into k;
  perform public.qy_custody_hist(k, 'رفض الموقّع إقفال العهدة وأعادها للمحاسب', btrim(p_note));
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype;
begin
  if new.request_type <> 'custody' then return new; end if;
  if new.is_cancelled and not coalesce(old.is_cancelled,false) then
    update public.custodies set status = 'cancelled' where request_id = new.id and status in ('requested','awaiting_receipt');
  elsif not new.is_cancelled and coalesce(old.is_cancelled,false) then
    update public.custodies set status = 'requested' where request_id = new.id and status = 'cancelled';
  end if;
  if new.status = 'completed' and old.status is distinct from 'completed' and not new.is_cancelled then
    update public.custodies set status = 'awaiting_receipt' where request_id = new.id and status = 'requested';
  elsif old.status = 'completed' and new.status is distinct from 'completed' then
    update public.custodies set status = 'requested' where request_id = new.id and status = 'awaiting_receipt';
  end if;
  if new.total_amount is distinct from old.total_amount or new.budget_item_id is distinct from old.budget_item_id then
    select * into k from public.custodies where request_id = new.id and status = 'requested';
    if found then
      if new.total_amount is distinct from old.total_amount then
        perform public.qy_custody_limits_check(k.holder_id, k.company_id, new.total_amount, k.id);
      end if;
      update public.custodies set amount = new.total_amount, budget_item_id = new.budget_item_id where id = k.id;
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_custody_update(p_req text, p_purpose text, p_due date)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; r public.requests%rowtype; adm boolean := public.is_admin();
begin
  select * into r from public.requests where id = p_req;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.created_by_id is distinct from public.qy_me() and not adm then raise exception 'تعديل العهدة لمنشئ طلبها وحده'; end if;
  select * into k from public.custodies where request_id = p_req for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'requested' or r.is_cancelled or not public.qy_content_open(r.id, r.status) then
    raise exception 'العهدة لم تعد قابلة للتعديل';
  end if;
  if not adm and public.qy_page_blocked(r.company_id, 'editreq') then raise exception 'ليست لديك صلاحية «تعديل طلباتي» في هذه الشركة'; end if;
  if p_due is not null and p_due < current_date then raise exception 'موعد الإقفال المتوقع لا يكون قبل اليوم'; end if;
  update public.custodies set purpose = left(btrim(coalesce(p_purpose,'')), 500), due_close_at = coalesce(p_due, due_close_at)
   where id = k.id returning * into k;
  return k;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_decision_chain(p_creator text, p_company text, p_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r public.users%rowtype; a public.users%rowtype; c public.centers%rowtype;
  cur text; ids text[] := '{}'; seen text[]; err text := null;
  skip text[] := '{}'; kept text[] := '{}'; fast boolean := false; x text; xr text;
begin
  select * into r from public.users where id = p_creator;
  if not found then return jsonb_build_object('ids','[]'::jsonb,'error','مستخدم غير موجود','fast',false); end if;
  seen := array[p_creator];
  cur := case when coalesce(r.no_request_approver,false) then null
              else coalesce(nullif(r.request_approver_id,''), case when p_company is not null then public._get_manager_for_company(r.id, p_company) else r.manager_id end) end;
  while nullif(cur,'') is not null loop
    if cur = any(seen) then err := 'حلقة دائرية: تكرر "' || coalesce((select u.name from public.users u where u.id = cur), cur) || '"'; exit; end if;
    if coalesce(array_length(ids,1),0) >= 20 then err := 'مسار طويل جداً (٢٠ خطوة فأكثر) — يُشتبه بحلقة دائرية'; exit; end if;
    seen := seen || cur;
    select * into a from public.users where id = cur;
    if not found then exit; end if;
    if coalesce(a.is_suspended,false) then err := 'المعتمِد «' || a.name || '» موقوف الحساب — أسند معاملاته أو غيّر مدير صاحب الطلب'; exit; end if;
    if p_company is not null and not public.qy_user_in_company(a.id, p_company) then
      err := 'المعتمِد «' || a.name || '» غير مرتبط بشركة الطلب — حدّد مديراً لصاحب الطلب في هذه الشركة (المدير المباشر لكل شركة)'; exit;
    end if;
    ids := ids || a.id;
    cur := case when coalesce(a.no_next_approver,false) then null
                else coalesce(nullif(a.next_approver_id,''), case when p_company is not null then public._get_manager_for_company(a.id, p_company) else a.manager_id end) end;
  end loop;
  if err is null and coalesce(array_length(ids,1),0) > 0 and p_total is not null then
    select * into c from public.centers where id = r.center_id;
    if found and c.min_threshold is not null and p_total <= c.min_threshold then
      if coalesce(c.skip_dept_manager,false) then skip := skip || 'dept_manager'::text; end if;
      if coalesce(c.skip_senior_manager,false) then skip := skip || 'senior_manager'::text; end if;
      if coalesce(c.skip_executive_manager,false) then skip := skip || 'executive_manager'::text; end if;
      if coalesce(array_length(skip,1),0) > 0 then
        foreach x in array ids loop
          select u.role into xr from public.users u where u.id = x;
          if xr is null or not (xr = any(skip)) then kept := kept || x; end if;
        end loop;
        if coalesce(array_length(kept,1),0) <> array_length(ids,1) then
          fast := true;
          if coalesce(array_length(kept,1),0) = 0 then
            -- لا يخلو المسار بالتخطّي: يبقى معتمِد واحد قبل المالية حسب إعداد المركز
            xr := coalesce(c.min_single_approver, 'exec');
            x := null;
            if xr in ('exec','senior') then
              select t.i2 into x from unnest(ids) with ordinality t(i2, o) join public.users u on u.id = t.i2
               where u.role = case xr when 'exec' then 'executive_manager' else 'senior_manager' end order by t.o limit 1;
            end if;
            kept := array[coalesce(x, ids[1])];
          end if;
          ids := kept;
        end if;
      end if;
    end if;
  end if;
  return jsonb_build_object('ids', to_jsonb(ids), 'error', err, 'fast', fast);
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_dev text; v_ip text; v_hdr json;
begin
  if p_kind is null or p_kind not in ('js_error','promise_error','db_error','login_failed','login_suspended','login_ok','logout') then return false; end if;
  v_dev := left(coalesce(p_device->>'id',''), 64);
  if (select count(*) from public.qy_client_events where at > now() - interval '1 minute') >= 300 then return false; end if;
  if v_dev <> '' and (select count(*) from public.qy_client_events where device_id = v_dev and at > now() - interval '1 minute') >= 20 then return false; end if;
  begin
    v_hdr := current_setting('request.headers', true)::json;
    v_ip := nullif(trim(split_part(coalesce(v_hdr->>'cf-connecting-ip', v_hdr->>'x-real-ip', v_hdr->>'x-forwarded-for', ''), ',', 1)), '');
  exception when others then v_ip := null; end;
  insert into public.qy_client_events(kind, page, message, details, user_id, phone_tried, ip, device_id, device)
  values (p_kind, left(p_page,80), left(p_message,500), left(p_details,2000), public.qy_me(), left(p_phone,40), left(v_ip,64),
          nullif(v_dev,''), case when length(coalesce(p_device::text,'')) < 2000 then p_device else null end);
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_monitor(p_company text, p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me text := public.qy_me(); v_role text; ok boolean;
  v_days int := greatest(1, least(coalesce(p_days,7), 90));
  since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days,7), 90)));
  today date := (now() at time zone 'Asia/Kuwait')::date;
  co public.companies%rowtype; out jsonb;
begin
  select u.role into v_role from public.users u where u.id = v_me;
  ok := public.is_admin() or (public.can_see_company(p_company) and (
          exists (select 1 from public.page_permissions p where p.company_id = p_company and p.role = v_role and p.page_key = 'monitor' and p.level in ('read','edit','full'))
       or (v_role in ('accountant','cfo','executive_manager') and not exists (select 1 from public.page_permissions p where p.company_id = p_company and p.role = v_role and p.page_key = 'monitor'))));
  if not ok then raise exception 'غير مصرّح: لوحة المتابعة لمن مُنح صلاحيتها'; end if;
  select * into co from public.companies where id = p_company;

  select jsonb_build_object(
    'days', v_days,
    'status', coalesce((select jsonb_object_agg(s, jsonb_build_object('n', n, 'sum', t)) from (
        select r.status s, count(*) n, coalesce(sum(r.total_amount),0) t from public.requests r
        where r.company_id = p_company and not coalesce(r.is_cancelled,false) group by r.status) x), '{}'::jsonb),
    'cancelled', (select count(*) from public.requests r where r.company_id = p_company and coalesce(r.is_cancelled,false)),
    'today', jsonb_build_object(
        'created',  (select count(*) from public.requests r where r.company_id = p_company and (r.created_at at time zone 'Asia/Kuwait')::date = today),
        'approved', (select count(*) from public.request_history h join public.requests r on r.id = h.request_id where r.company_id = p_company and h.action like 'اعتماد%' and (h.created_at at time zone 'Asia/Kuwait')::date = today),
        'rejected', (select count(*) from public.request_history h join public.requests r on r.id = h.request_id where r.company_id = p_company and h.action like 'رفض%' and (h.created_at at time zone 'Asia/Kuwait')::date = today),
        'paid',     (select count(*) from public.request_history h join public.requests r on r.id = h.request_id where r.company_id = p_company and h.action = 'تم الصرف' and (h.created_at at time zone 'Asia/Kuwait')::date = today),
        'paid_sum', (select coalesce(sum(t.amount),0) from public.transactions t where t.company_id = p_company and t.source_type = 'request' and t.reverses_id is null and t.tx_date = today)),
    'waiting', coalesce((select jsonb_agg(w order by w->>'since') from (
        select jsonb_build_object('req', r.id, 'number', r.number, 'reason', r.reason, 'amount', r.total_amount,
               'approver', s.approver_id, 'approver_name', a.name, 'since', coalesce(s.activated_at, r.created_at),
               'days', round((extract(epoch from now() - coalesce(s.activated_at, r.created_at)) / 86400.0)::numeric, 1),
               'limit', case when a.approval_deadline_days is not null then a.approval_deadline_days else co.default_deadline_days end,
               'escalated', exists (select 1 from public.request_approval_steps e where e.request_id = r.id and e.sequence_order = s.sequence_order and e.kind = 'escalation')) w
        from public.requests r
        join lateral (select s1.* from public.request_approval_steps s1 where s1.request_id = r.id and s1.status = 'pending' and coalesce(s1.kind,'primary') = 'primary'
                      order by s1.sequence_order limit 1) s on true
        left join public.users a on a.id = s.approver_id
        where r.company_id = p_company and r.status = 'pending_decision' and not coalesce(r.is_cancelled,false)) q), '[]'::jsonb),
    'finance', coalesce((select jsonb_agg(f order by f->>'since') from (
        select jsonb_build_object('req', r.id, 'number', r.number, 'reason', r.reason, 'amount', r.total_amount, 'status', r.status,
               'since', coalesce((select max(h.created_at) from public.request_history h where h.request_id = r.id), r.created_at)) f
        from public.requests r
        where r.company_id = p_company and r.status in ('pending_transfer_request','pending_transfer_approval','pending_disbursement') and not coalesce(r.is_cancelled,false)) q), '[]'::jsonb),
    'feed', coalesce((select jsonb_agg(e order by e->>'at' desc) from (
        select jsonb_build_object('req', r.id, 'number', r.number, 'reason', r.reason, 'amount', r.total_amount,
               'actor', h.actor, 'action', h.action, 'note', left(coalesce(h.note,''), 140), 'at', h.created_at) e
        from public.request_history h join public.requests r on r.id = h.request_id
        where r.company_id = p_company and h.created_at >= since
        order by h.created_at desc limit 120) q), '[]'::jsonb),
    'security', case when public.is_admin() then jsonb_build_object(
        'alerts', (select count(*) from public.qy_audit_alerts x where not coalesce(x.reviewed,false)),
        'failed_logins', (select count(*) from public.qy_client_events x where x.kind = 'login_failed' and x.at > now() - interval '1 day'),
        'errors', (select count(*) from public.qy_client_events x where x.kind in ('js_error','promise_error','db_error') and x.at > now() - interval '1 day' and not coalesce(x.reviewed,false)))
      else null end
  ) into out;
  return out;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_my_company_names()
 RETURNS TABLE(id text, name_ar text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select distinct c.id, c.name_ar
  from public.companies c
  where c.id in (select r.company_id from public.requests r where r.created_by_id = public.qy_me());
$function$
;
CREATE OR REPLACE FUNCTION public.qy_now_txt()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_char(now() at time zone 'Asia/Kuwait', 'DD') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'MM') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'YYYY')
    || ' ' || ltrim(to_char(now() at time zone 'Asia/Kuwait', 'HH12'), '0') || ':' || to_char(now() at time zone 'Asia/Kuwait', 'MI')
    || ' ' || case when extract(hour from now() at time zone 'Asia/Kuwait') >= 12 then 'م' else 'ص' end;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_page_blocked(p_company text, p_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
    where p.company_id = p_company and p.role = u.role and p.page_key = p_key and p.level in ('none','read'));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_public_brand()
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select json_build_object(
    'name',     (select s.value from public.app_settings s where s.key = 'system_name'),
    'logo',     (select s.value from public.app_settings s where s.key = 'system_logo'),
    'tagline',  (select s.value from public.app_settings s where s.key = 'system_tagline'),
    'tagline2', (select s.value from public.app_settings s where s.key = 'system_tagline2'));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_requests_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me text; v_admin boolean; v_fin boolean; v_creator boolean; v_appr boolean; v_dlg boolean;
  v_post_old boolean; v_open boolean; n_all int; n_open int;
  v_post text[] := array['pending_transfer_request','pending_transfer_approval','pending_disbursement','completed','pending_accountant','pending_cfo'];
begin
  if auth.uid() is null or public.qy_mode() = 'off' or current_setting('qy.sys', true) = '1' then return new; end if;
  v_me := public.qy_me(); v_admin := public.is_admin(); v_fin := public.is_finance();
  v_creator := coalesce(old.created_by_id = v_me, false);
  v_appr := public.qy_is_approver(old.id, v_me);
  v_post_old := (old.status = any (v_post));
  v_dlg := exists (select 1 from public.companies c where c.id = old.company_id and (
             (c.cfo_delegation_mode = 'delegate_user' and c.cfo_delegate_user_id = v_me
               and (nullif(c.cfo_delegate_until::text,'') is null or nullif(c.cfo_delegate_until::text,'')::date >= current_date))
          or (c.cfo_delegation_mode = 'delegate_manager' and exists (select 1 from public.users u where u.manager_id = v_me and u.role = 'accountant'))));

  if old.is_cancelled then
    if new.is_cancelled = false then
      if not (v_admin or (v_creator and public.can_see_company(old.company_id))) then
        perform public.qy_deny('req_restore', old.id, 'استرجاع طلب ملغى مقصور على صاحبه أو مدير النظام');
      end if;
      return new;
    end if;
    if to_jsonb(new) is distinct from to_jsonb(old) and not v_admin then
      perform public.qy_deny('req_cancelled_edit', old.id, 'لا يُعدَّل طلب ملغى');
    end if;
    return new;
  end if;

  if new.is_cancelled and not old.is_cancelled then
    if not (v_admin or (v_creator and not v_post_old) or (public.qy_is_cfo() and v_post_old)) then
      perform public.qy_deny('req_cancel', old.id, 'إلغاء الطلب: قبل الاعتماد الكامل لصاحبه أو مدير النظام، وبعده للمدير المالي أو مدير النظام');
    end if;
    return new;
  end if;

  if new.company_id is distinct from old.company_id and not v_admin then
    perform public.qy_deny('req_company', old.id, 'نقل الطلب إلى شركة أخرى لمدير النظام فقط');
  end if;

  if new.status is distinct from old.status then
    if not (v_admin or v_fin or v_creator or v_appr or v_dlg) then
      perform public.qy_deny('req_status_stranger', old.id, 'تغيير حالة طلب ليس لك فيه دور');
    end if;
    if new.status = 'pending_transfer_request' and not v_admin
       and old.status in ('pending_decision','rejected','pending_manager','pending_senior','pending_executive') then
      select count(*), count(*) filter (where s.status in ('pending','rejected'))
        into n_all, n_open from public.request_approval_steps s where s.request_id = old.id;
      if n_all > 0 then
        if old.status = 'rejected' or n_open > 0 then
          perform public.qy_deny('req_skip_decision', old.id, 'لا ينتقل الطلب إلى التحويل قبل أن يعتمده كل معتمديه');
        end if;
      elsif not public.qy_transfer_ok(old.created_by_id, old.company_id, new.total_amount) then
        perform public.qy_deny('req_skip_decision', old.id, 'لا ينتقل الطلب إلى التحويل دون اعتماد، إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
      end if;
    end if;
    if new.status in ('pending_transfer_approval','pending_disbursement','completed') and not (v_admin or v_fin) then
      if not (old.status = 'pending_transfer_approval' and new.status = 'pending_disbursement' and v_dlg) then
        perform public.qy_deny('req_fin_stage', old.id, 'مراحل التحويل والصرف للمحاسب أو المدير المالي أو مفوَّضه فقط');
      end if;
    end if;
    if new.status = 'completed' and not v_fin then
      perform public.qy_deny('req_complete', old.id, 'تأكيد الصرف للمحاسب أو المدير المالي فقط');
    end if;
    if old.status = 'completed' and not v_fin then
      perform public.qy_deny('req_reopen', old.id, 'إعادة فتح طلب مصروف للمالية فقط');
    end if;
    if old.status = 'rejected' and new.status = 'pending_decision' then
      update public.request_approval_steps set status = 'pending', acted_at = null
        where request_id = old.id and status <> 'pending';
    end if;
  end if;

  v_open := public.qy_content_open(old.id, old.status);
  if (new.reason, new.detailed_reason, new.total_amount, new.is_recurring, new.created_by_id, new.center_id, new.fast_tracked)
     is distinct from
     (old.reason, old.detailed_reason, old.total_amount, old.is_recurring, old.created_by_id, old.center_id, old.fast_tracked) then
    if not v_admin then
      if not v_open then
        perform public.qy_deny('req_locked_edit', old.id, 'الطلب مقفل بعد أول اعتماد؛ يُرجَع للتعديل أولاً');
      elsif not v_creator then
        perform public.qy_deny('req_edit_stranger', old.id, 'تعديل الطلب لصاحبه فقط');
      elsif public.qy_page_blocked(old.company_id, 'editreq') then
        perform public.qy_deny('req_edit_page', old.id, 'ليست لديك صلاحية «تعديل طلباتي» في هذه الشركة');
      end if;
    end if;
  end if;

  if new.request_notes is distinct from old.request_notes and not (v_admin or v_fin or v_creator) then
    perform public.qy_deny('req_notes', old.id, 'ملاحظات الطلب لصاحبه والمالية');
  end if;
  if new.budget_item_id is distinct from old.budget_item_id and not (v_admin or v_fin) then
    if not (v_creator and v_open) then
      perform public.qy_deny('req_item_locked', old.id, 'تغيير بند الطلب مقفل بعد أول اعتماد');
    elsif public.qy_page_blocked(old.company_id, 'editreq') then
      perform public.qy_deny('req_edit_page', old.id, 'ليست لديك صلاحية «تعديل طلباتي» في هذه الشركة');
    end if;
  end if;

  if (new.bank_transfer_ref is distinct from old.bank_transfer_ref or new.bank_transfer_at is distinct from old.bank_transfer_at)
     and not (v_admin or v_fin) then
    perform public.qy_deny('req_bank_ref', old.id, 'تسجيل التحويل البنكي للمحاسب أو المدير المالي فقط');
  end if;

  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_requests_ins_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return new; end if;
  if new.created_by_id is distinct from public.qy_me() then
    perform public.qy_deny('req_ins_owner', new.id, 'لا تُنشئ طلباً باسم غيرك');
  end if;
  -- صلاحية صفحة «طلب صرف جديد» لدور المستخدم في هذه الشركة (لا يرى / قراءة فقط = لا إنشاء)
  if exists (select 1 from public.page_permissions p join public.users u on u.id = new.created_by_id
             where p.company_id = new.company_id and p.role = u.role and p.page_key = (case when coalesce(new.request_type,'normal') = 'custody' then 'custody' else 'newreq' end) and p.level in ('none','read')) then
    perform public.qy_deny('req_ins_page', new.id, 'ليست لديك صلاحية إنشاء طلب صرف في هذه الشركة');
  end if;
  if coalesce(new.is_cancelled,false) or coalesce(new.status,'') not in ('pending_decision','pending_transfer_request') then
    perform public.qy_deny('req_ins_status', new.id, 'لا يُنشأ طلب بحالة متقدمة');
  end if;
  if new.status = 'pending_transfer_request'
     and not public.qy_transfer_ok(new.created_by_id, new.company_id, new.total_amount) then
    perform public.qy_deny('req_ins_skip', new.id, 'لا يبدأ الطلب في مرحلة التحويل بلا معتمدين إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_requests_type_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.request_type is distinct from old.request_type and current_setting('qy.sys', true) is distinct from '1' then
    perform public.qy_deny('req_type_lock', old.id, 'نوع الطلب (عادي / عهدة) لا يتغير بعد إنشائه');
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_set_chain(p_req text, p_reset boolean DEFAULT false)
 RETURNS SETOF request_approval_steps
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype; v_me text := public.qy_me(); ch jsonb; ids text[]; i int; stamp text; v_staff boolean;
begin
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.is_cancelled then raise exception 'الطلب ملغى'; end if;
  v_staff := public.is_admin() or (public.is_finance() and public.can_see_company(r.company_id));
  if not (v_staff or coalesce(r.created_by_id = v_me, false)) then
    raise exception 'غير مصرّح: بناء المسار لصاحب الطلب أو المالية أو مدير النظام';
  end if;
  if p_reset and not v_staff then raise exception 'غير مصرّح: إعادة المسار وإلغاء الاعتمادات للمالية أو مدير النظام'; end if;
  if not p_reset and exists (select 1 from public.request_approval_steps s where s.request_id = p_req and s.status <> 'pending') then
    raise exception 'بدأ اعتماد الطلب؛ إعادة البناء تكون بـ«إعادة المسار والاعتماد»';
  end if;
  if not v_staff and r.status not in ('pending_decision','pending_transfer_request','rejected') then
    raise exception 'لا يُعاد بناء مسار طلب تجاوز مرحلة القرار';
  end if;
  ch := case when coalesce(r.request_type,'normal') = 'custody' then public.qy_custody_chain(r.id)
              else public.qy_decision_chain(r.created_by_id, r.company_id, r.total_amount) end;
  if ch->>'error' is not null then raise exception 'تعذّر بناء المسار: %', ch->>'error'; end if;
  select coalesce(array_agg(e), '{}') into ids from jsonb_array_elements_text(ch->'ids') e;
  perform set_config('qy.sys', '1', true);
  delete from public.request_approval_steps where request_id = p_req;
  stamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  for i in 1 .. coalesce(array_length(ids,1),0) loop
    insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at)
    values ('as_' || p_req || '_s' || stamp || '_' || i, p_req, ids[i], i, 'pending_decision', 'pending', 'primary', case when i = 1 then now() end);
  end loop;
  if coalesce(array_length(ids,1),0) = 0 then
    if coalesce((ch->>'self')::boolean, false)
       or coalesce((select u.direct_to_transfer from public.users u where u.id = r.created_by_id), false) then
      -- المنشئ في أعلى السلسلة: إنشاؤه اعتماد له (توقيعه وختمه في الموضع الثاني من الورقة)
      insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, acted_at, note)
        values ('as_' || p_req || '_s' || stamp || '_self', p_req, r.created_by_id, 1, 'pending_decision', 'approved', 'primary', now(), now(), 'بإنشائه الطلب');
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
        values (p_req, 'pending_decision', (select u.name from public.users u where u.id = r.created_by_id), r.created_by_id, 'اعتماد', 'بإنشائه الطلب — في أعلى السلسلة',
          to_char(now() at time zone 'Asia/Kuwait', 'DD') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'MM') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'YYYY')
          || ' ' || ltrim(to_char(now() at time zone 'Asia/Kuwait', 'HH12'), '0') || ':' || to_char(now() at time zone 'Asia/Kuwait', 'MI')
          || ' ' || case when extract(hour from now() at time zone 'Asia/Kuwait') >= 12 then 'م' else 'ص' end);
      update public.requests set status = 'pending_transfer_request' where id = p_req and status in ('pending_decision','rejected');
    else
      raise exception 'لا يوجد معتمِد لهذا الطلب، ولا يصل طلب للمالية قبل اعتماد واحد على الأقل. حدّد مديراً لصاحب الطلب، أو فعّل «الانتقال المباشر إلى التحويل» لمن هو في أعلى السلسلة';
    end if;
  end if;
  update public.requests set fast_tracked = coalesce((ch->>'fast')::boolean, false)
    where id = p_req and fast_tracked is distinct from coalesce((ch->>'fast')::boolean, false);
  perform set_config('qy.sys', '', true);
  return query select * from public.request_approval_steps where request_id = p_req order by sequence_order;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_steps_ins_del_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text; r public.requests%rowtype;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() or current_setting('qy.sys', true) = '1' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  v_me := public.qy_me();
  if tg_op = 'INSERT' then
    select * into r from public.requests where id = new.request_id;
    -- خطوات المسار الأساسية يبنيها الخادم (qy_set_chain)؛ الاستثناء الوحيد: «اعتماد وإحالة» من المعتمِد الحالي إلى مديره المباشر
    if coalesce(new.kind,'primary') = 'primary' and not (
         new.escalated_from is not null and new.escalated_from = v_me and r.status = 'pending_decision'
         and public.qy_is_approver(new.request_id, v_me)
         and new.approver_id = public._get_manager_for_company(v_me, r.company_id)) then
      perform public.qy_deny('step_ins_primary', new.request_id, 'خطوات مسار الاعتماد يبنيها الخادم ولا تُضاف يدوياً');
    end if;
    if coalesce(new.status,'pending') <> 'pending' then
      perform public.qy_deny('step_ins_acted', new.request_id, 'خطوة الاعتماد الجديدة تبدأ «بانتظار الاعتماد»');
    end if;
    if new.approver_id is not null and new.approver_id = r.created_by_id then
      perform public.qy_deny('step_ins_self', new.request_id, 'لا يكون صاحب الطلب معتمِداً لطلبه');
    end if;
    if not (coalesce(r.created_by_id = v_me, false) or public.qy_is_approver(new.request_id, v_me) or public.is_finance()) then
      perform public.qy_deny('step_ins_stranger', new.request_id, 'إضافة خطوة اعتماد لطلب ليس لك فيه دور');
    end if;
    return new;
  end if;
  if exists (select 1 from public.requests x where x.id = old.request_id) then
    if public.qy_has_approved(old.request_id) then
      perform public.qy_deny('step_delete', old.request_id, 'لا تُحذف خطوات اعتماد طلب بدأ اعتماده');
    end if;
    select * into r from public.requests where id = old.request_id;
    if not (coalesce(r.created_by_id = v_me, false) or public.qy_is_approver(old.request_id, v_me) or public.is_finance()) then
      perform public.qy_deny('step_delete_stranger', old.request_id, 'حذف خطوات طلب ليس لك فيه دور');
    end if;
  end if;
  return old;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_transfer_ok(p_creator text, p_company text, p_total numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ch jsonb;
begin
  if coalesce((select u.direct_to_transfer from public.users u where u.id = p_creator), false) then return true; end if;
  ch := public.qy_decision_chain(p_creator, p_company, p_total);
  return ch->>'error' is null and jsonb_array_length(ch->'ids') = 0 and coalesce((ch->>'fast')::boolean, false);
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_user_in_company(p_user text, p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.users u where u.id = p_user and (u.company_id = p_company or coalesce(u.is_general,false)))
      or exists (select 1 from public.user_companies l where l.user_id = p_user and l.company_id = p_company);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_users_custody_susp_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if coalesce(new.is_suspended,false) and not coalesce(old.is_suspended,false) then
    if exists (select 1 from public.custodies k where k.holder_id = new.id and k.status not in ('closed','cancelled')) then
      raise exception 'لا يُوقف «%»: عليه عهدة غير مقفلة', new.name;
    end if;
    if exists (select 1 from public.custody_balances b where b.holder_id = new.id and b.status = 'open') then
      raise exception 'لا يُوقف «%»: عليه رصيد عهدة معلّق — يسوّيه المحاسب أولاً', new.name;
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.users_self_update_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  allowed text[] := array['name','email','name_en','iban','national_id','id_file_data','bank_file_data',
    'signature_mode','signature_color','signature_width','signature_data','stamp_data','stamp_data_2','notif_seen_at','idle_minutes','skip_review','avatar_data'];
begin
  if auth.uid() is null then return new; end if;
  if public.is_admin() then return new; end if;
  if (to_jsonb(new) - allowed) is distinct from (to_jsonb(old) - allowed) then
    raise exception 'لا تملك صلاحية تعديل هذه البيانات';
  end if;
  if new.idle_minutes is not null and (new.idle_minutes < 1 or new.idle_minutes > 1440) then
    raise exception 'مهلة الإغلاق غير صحيحة';
  end if;
  return new;
end $function$
;
-- (٦) صلاحيات الدوال (كما في الاختبار)
revoke all on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) from public, anon, authenticated; grant execute on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) to authenticated; grant execute on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) to service_role;
revoke all on function public.admin_set_password(p_user_id text, p_password text) from public, anon, authenticated; grant execute on function public.admin_set_password(p_user_id text, p_password text) to authenticated; grant execute on function public.admin_set_password(p_user_id text, p_password text) to service_role;
revoke all on function public.is_admin() from public, anon, authenticated; grant execute on function public.is_admin() to authenticated; grant execute on function public.is_admin() to service_role; grant execute on function public.is_admin() to public;
revoke all on function public.me() from public, anon, authenticated; grant execute on function public.me() to authenticated; grant execute on function public.me() to service_role;
revoke all on function public.my_company_ids() from public, anon, authenticated; grant execute on function public.my_company_ids() to authenticated; grant execute on function public.my_company_ids() to service_role;
revoke all on function public.can_see_company(p_company_id text) from public, anon, authenticated; grant execute on function public.can_see_company(p_company_id text) to authenticated; grant execute on function public.can_see_company(p_company_id text) to service_role;
revoke all on function public.can_see_request(p_request_id text) from public, anon, authenticated; grant execute on function public.can_see_request(p_request_id text) to authenticated; grant execute on function public.can_see_request(p_request_id text) to service_role;
revoke all on function public.qy_custody_nodoc_cap(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_nodoc_cap(p_id bigint) to authenticated; grant execute on function public.qy_custody_nodoc_cap(p_id bigint) to service_role;
revoke all on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) from public, anon, authenticated; grant execute on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) to authenticated; grant execute on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) to service_role;
revoke all on function public.finalize_request(p_id text) from public, anon, authenticated; grant execute on function public.finalize_request(p_id text) to authenticated; grant execute on function public.finalize_request(p_id text) to service_role;
revoke all on function public.request_password_reset(p_phone text) from public, anon, authenticated; grant execute on function public.request_password_reset(p_phone text) to authenticated; grant execute on function public.request_password_reset(p_phone text) to anon; grant execute on function public.request_password_reset(p_phone text) to service_role;
revoke all on function public.users_self_update_guard() from public, anon, authenticated; grant execute on function public.users_self_update_guard() to service_role;
revoke all on function public.qy_steps_ins_del_guard() from public, anon, authenticated; grant execute on function public.qy_steps_ins_del_guard() to authenticated; grant execute on function public.qy_steps_ins_del_guard() to anon; grant execute on function public.qy_steps_ins_del_guard() to service_role; grant execute on function public.qy_steps_ins_del_guard() to public;
revoke all on function public.qy_ben_guard() from public, anon, authenticated; grant execute on function public.qy_ben_guard() to authenticated; grant execute on function public.qy_ben_guard() to anon; grant execute on function public.qy_ben_guard() to service_role; grant execute on function public.qy_ben_guard() to public;
revoke all on function public.qy_requests_guard() from public, anon, authenticated; grant execute on function public.qy_requests_guard() to authenticated; grant execute on function public.qy_requests_guard() to anon; grant execute on function public.qy_requests_guard() to service_role; grant execute on function public.qy_requests_guard() to public;
revoke all on function public.qy_user_in_company(p_user text, p_company text) from public, anon, authenticated; grant execute on function public.qy_user_in_company(p_user text, p_company text) to service_role;
revoke all on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) from public, anon, authenticated; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to authenticated; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to anon; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to service_role;
revoke all on function public.qy_decision_chain(p_creator text, p_company text, p_total numeric) from public, anon, authenticated; grant execute on function public.qy_decision_chain(p_creator text, p_company text, p_total numeric) to service_role;
revoke all on function public.qy_set_chain(p_req text, p_reset boolean) from public, anon, authenticated; grant execute on function public.qy_set_chain(p_req text, p_reset boolean) to authenticated; grant execute on function public.qy_set_chain(p_req text, p_reset boolean) to service_role;
revoke all on function public.qy_transfer_ok(p_creator text, p_company text, p_total numeric) from public, anon, authenticated; grant execute on function public.qy_transfer_ok(p_creator text, p_company text, p_total numeric) to service_role;
revoke all on function public.qy_monitor(p_company text, p_days integer) from public, anon, authenticated; grant execute on function public.qy_monitor(p_company text, p_days integer) to authenticated; grant execute on function public.qy_monitor(p_company text, p_days integer) to service_role;
revoke all on function public.qy_page_blocked(p_company text, p_key text) from public, anon, authenticated; grant execute on function public.qy_page_blocked(p_company text, p_key text) to service_role;
revoke all on function public.qy_ben_is_edit(p_req text, p_op text) from public, anon, authenticated; grant execute on function public.qy_ben_is_edit(p_req text, p_op text) to service_role;
revoke all on function public.qy_my_company_names() from public, anon, authenticated; grant execute on function public.qy_my_company_names() to authenticated; grant execute on function public.qy_my_company_names() to service_role;
revoke all on function public.qy_custody_ins_guard() from public, anon, authenticated; grant execute on function public.qy_custody_ins_guard() to service_role;
revoke all on function public.qy_custody_limits_check(p_holder text, p_company text, p_amount numeric, p_except bigint) from public, anon, authenticated; grant execute on function public.qy_custody_limits_check(p_holder text, p_company text, p_amount numeric, p_except bigint) to service_role;
revoke all on function public.qy_custody_balance_settle(p_id bigint, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_balance_settle(p_id bigint, p_note text) to authenticated; grant execute on function public.qy_custody_balance_settle(p_id bigint, p_note text) to service_role;
revoke all on function public.qy_requests_ins_guard() from public, anon, authenticated; grant execute on function public.qy_requests_ins_guard() to authenticated; grant execute on function public.qy_requests_ins_guard() to anon; grant execute on function public.qy_requests_ins_guard() to service_role; grant execute on function public.qy_requests_ins_guard() to public;
revoke all on function public.qy_requests_type_lock() from public, anon, authenticated; grant execute on function public.qy_requests_type_lock() to service_role;
revoke all on function public.qy_users_custody_susp_guard() from public, anon, authenticated; grant execute on function public.qy_users_custody_susp_guard() to service_role;
revoke all on function public.qy_custody_sync() from public, anon, authenticated; grant execute on function public.qy_custody_sync() to service_role;
revoke all on function public.qy_custody_confirm(p_id bigint, p_time text) from public, anon, authenticated; grant execute on function public.qy_custody_confirm(p_id bigint, p_time text) to authenticated; grant execute on function public.qy_custody_confirm(p_id bigint, p_time text) to service_role;
revoke all on function public.qy_custody_update(p_req text, p_purpose text, p_due date) from public, anon, authenticated; grant execute on function public.qy_custody_update(p_req text, p_purpose text, p_due date) to authenticated; grant execute on function public.qy_custody_update(p_req text, p_purpose text, p_due date) to service_role;
revoke all on function public.qy_public_brand() from public, anon, authenticated; grant execute on function public.qy_public_brand() to authenticated; grant execute on function public.qy_public_brand() to anon; grant execute on function public.qy_public_brand() to service_role;
revoke all on function public.qy_custody_chain(p_req text) from public, anon, authenticated; grant execute on function public.qy_custody_chain(p_req text) to service_role;
revoke all on function public.qy_custody_line_delete(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_delete(p_id bigint) to authenticated; grant execute on function public.qy_custody_line_delete(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_amount(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_amount(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_amount(p_id bigint) to service_role;
revoke all on function public.qy_custody_line_image(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_image(p_id bigint) to authenticated; grant execute on function public.qy_custody_line_image(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_limit(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_limit(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_limit(p_id bigint) to service_role;
revoke all on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) from public, anon, authenticated; grant execute on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) to authenticated; grant execute on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) to service_role;
revoke all on function public.qy_now_txt() from public, anon, authenticated; grant execute on function public.qy_now_txt() to authenticated; grant execute on function public.qy_now_txt() to anon; grant execute on function public.qy_now_txt() to service_role; grant execute on function public.qy_now_txt() to public;
revoke all on function public.qy_custody_hist(p_k custodies, p_action text, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_hist(p_k custodies, p_action text, p_note text) to service_role;
revoke all on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) to authenticated; grant execute on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) to service_role;
revoke all on function public.qy_custody_over_check(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_check(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_check(p_id bigint) to service_role;
revoke all on function public.qy_custody_line_reopen(p_line bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_reopen(p_line bigint) to authenticated; grant execute on function public.qy_custody_line_reopen(p_line bigint) to service_role;
revoke all on function public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text) from public, anon, authenticated; grant execute on function public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text) to service_role;
revoke all on function public.qy_budget_figures(p_company text) from public, anon, authenticated; grant execute on function public.qy_budget_figures(p_company text) to authenticated; grant execute on function public.qy_budget_figures(p_company text) to service_role;
revoke all on function public.qy_custody_over_list(p_company text) from public, anon, authenticated; grant execute on function public.qy_custody_over_list(p_company text) to authenticated; grant execute on function public.qy_custody_over_list(p_company text) to service_role;
revoke all on function public.qy_custody_sign(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_sign(p_id bigint) to authenticated; grant execute on function public.qy_custody_sign(p_id bigint) to service_role;
revoke all on function public.qy_custody_sign_reject(p_id bigint, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_sign_reject(p_id bigint, p_note text) to authenticated; grant execute on function public.qy_custody_sign_reject(p_id bigint, p_note text) to service_role;
revoke all on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) to authenticated; grant execute on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) to service_role;
revoke all on function public.qy_custody_reviewer_done(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_reviewer_done(p_id bigint) to authenticated; grant execute on function public.qy_custody_reviewer_done(p_id bigint) to service_role;
revoke all on function public.qy_custody_admin_undo(p_id bigint, p_reason text) from public, anon, authenticated; grant execute on function public.qy_custody_admin_undo(p_id bigint, p_reason text) to authenticated; grant execute on function public.qy_custody_admin_undo(p_id bigint, p_reason text) to service_role;
revoke all on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) to authenticated; grant execute on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) to service_role;
-- (٧) أمان الصفوف والسياسات
alter table public.custodies enable row level security;
alter table public.custody_balances enable row level security;
alter table public.custody_lines enable row level security;
drop policy if exists qy_cbal_sel on public.custody_balances; create policy qy_cbal_sel on public.custody_balances as PERMISSIVE for SELECT to authenticated using (((holder_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(company_id))));
drop policy if exists qy_cust_ins on public.custodies; create policy qy_cust_ins on public.custodies as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM requests r
  WHERE ((r.id = custodies.request_id) AND (r.request_type = 'custody'::text) AND ((r.created_by_id = qy_me()) OR is_admin())))));
drop policy if exists qy_cust_sel on public.custodies; create policy qy_cust_sel on public.custodies as PERMISSIVE for SELECT to authenticated using (((holder_id = qy_me()) OR (created_by_id = qy_me()) OR (reviewer_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(company_id)) OR can_see_request(request_id)));
drop policy if exists qy_cline_sel on public.custody_lines; create policy qy_cline_sel on public.custody_lines as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM custodies k
  WHERE ((k.id = custody_lines.custody_id) AND ((k.holder_id = qy_me()) OR (k.created_by_id = qy_me()) OR (k.reviewer_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(k.company_id)) OR can_see_request(k.request_id))))));
-- (٨) صلاحيات الجداول (كما في الاختبار)
revoke all on public.custodies from anon, authenticated; grant INSERT on public.custodies to authenticated; grant SELECT on public.custodies to authenticated;
revoke all on public.custody_balances from anon, authenticated; grant SELECT on public.custody_balances to authenticated;
revoke all on public.custody_lines from anon, authenticated; grant SELECT on public.custody_lines to authenticated;
revoke all on public.login_aliases from anon, authenticated; grant SELECT on public.login_aliases to authenticated;
revoke all on public.request_number_counters from anon, authenticated;
revoke all on public.custodies_id_seq from anon, authenticated; grant USAGE, SELECT on public.custodies_id_seq to authenticated;
revoke all on public.custody_balances_id_seq from anon, authenticated; grant USAGE, SELECT on public.custody_balances_id_seq to authenticated;
revoke all on public.custody_lines_id_seq from anon, authenticated; grant USAGE, SELECT on public.custody_lines_id_seq to authenticated;
-- (٩) المشغّلات
drop trigger if exists qy_users_custody_susp_trg on users; CREATE TRIGGER qy_users_custody_susp_trg BEFORE UPDATE OF is_suspended ON public.users FOR EACH ROW EXECUTE FUNCTION qy_users_custody_susp_guard();
drop trigger if exists qy_custody_sync_trg on requests; CREATE TRIGGER qy_custody_sync_trg AFTER UPDATE OF status, is_cancelled, total_amount, budget_item_id ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_custody_sync();
drop trigger if exists qy_requests_type_lock_trg on requests; CREATE TRIGGER qy_requests_type_lock_trg BEFORE UPDATE OF request_type ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_type_lock();
drop trigger if exists qy_custody_ins_guard_trg on custodies; CREATE TRIGGER qy_custody_ins_guard_trg BEFORE INSERT ON public.custodies FOR EACH ROW EXECUTE FUNCTION qy_custody_ins_guard();
commit;
