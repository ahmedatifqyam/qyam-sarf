-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٢٠ (1.53.0): الطلب نيابةً ينتظر الإرسال.
--   مدير النظام يُعدّ الطلب باسم الموظف فيُحفظ «بانتظار الإرسال» (awaiting_owner):
--   بلا رقم، ولا مدة مراجعة تنتهي (review_until بعيد)، ولا يصل المعتمدين، ولا يُحسب على البند.
--   • إن أرسله صاحبه بعد مراجعته: يصير طلبه تماماً (يُمسح أثر «نيابةً»، ويبقى في السجل سطر «أعدّه … وأرسله صاحبه»).
--   • إن أرسله مدير النظام: يمضي بأثر «نيابةً» (المسار والسجل والطباعة).
--   • إن حذفه صاحبه: يُشعَر من أعدّه.
-- يُشغَّل بعد بناء-١..١٩. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
-- طُبّق على قاعدة التجربة في 23 نوفمبر.

alter table public.requests add column if not exists awaiting_owner boolean not null default false;

-- الإنشاء: الطلب نيابةً ينتظر الإرسال. والأثر وحالة الانتظار لا تتغير إلا من finalize_request
create or replace function public.qy_req_onbehalf_set()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare me text;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then return new; end if;
    me := public.qy_me();
    if new.created_by_id is distinct from me then
      new.on_behalf_by_id := me;
      new.on_behalf_by_name := (select name from public.users where id = me);
      new.awaiting_owner := true;
      new.number := null;
      new.review_until := '2099-12-31T00:00:00Z';
    else
      new.on_behalf_by_id := null; new.on_behalf_by_name := null; new.awaiting_owner := false;
    end if;
  elsif current_setting('qy.onbehalf', true) is distinct from '1' then
    new.on_behalf_by_id := old.on_behalf_by_id; new.on_behalf_by_name := old.on_behalf_by_name;
    new.awaiting_owner := old.awaiting_owner;
    if old.awaiting_owner then new.review_until := old.review_until; new.number := old.number; end if;
  end if;
  return new;
end $$;

-- إشعار الموظف: أُعدّ له طلب ينتظر مراجعته وإرساله
create or replace function public.qy_req_onbehalf_notify()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.on_behalf_by_id is not null and new.awaiting_owner then
    perform public.qy_push_enqueue(array[new.created_by_id], 'أعدّ لك ' || coalesce(new.on_behalf_by_name,'مدير النظام') || ' طلباً',
      'راجعه وأرسله: ' || coalesce(new.reason,''), 'onbehalf', new.id, 'onbehalf', now());
  end if;
  return new;
end $$;

-- حذف صاحبه له قبل الإرسال: يُشعَر من أعدّه
create or replace function public.qy_req_onbehalf_deleted()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.awaiting_owner and old.on_behalf_by_id is not null and public.qy_me() is distinct from old.on_behalf_by_id then
    perform public.qy_push_enqueue(array[old.on_behalf_by_id], 'حُذف طلب أعددته',
      coalesce((select name from public.users where id = old.created_by_id),'') || ' حذف: ' || coalesce(old.reason,''), 'onbehalf_del', null, old.id, now());
  end if;
  return old;
end $$;
drop trigger if exists qy_req_onbehalf_deleted_t on public.requests;
create trigger qy_req_onbehalf_deleted_t after delete on public.requests for each row execute function public.qy_req_onbehalf_deleted();

-- منح الرقم (الإرسال النهائي): للطلب نيابةً يحدد من أرسله ما يبقى من أثر
create or replace function public.finalize_request(p_id text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; new_num text; me text := public.qy_me(); nm text;
begin
  select id, number, number_prefix, number_suffix, created_by_id, company_id, awaiting_owner, on_behalf_by_name, status
    into r from public.requests where id = p_id for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.number is not null then return r.number; end if;
  if r.number_prefix is null then raise exception 'الطلب بلا قالب ترقيم'; end if;
  if not exists (select 1 from public.users u where u.auth_id = auth.uid()
                  and (u.id = r.created_by_id or (u.role = 'admin' and public.can_see_company(r.company_id)))) then
    raise exception 'لا تملك هذا الطلب ولست مدير النظام';
  end if;
  new_num := public.next_request_number(r.number_prefix, r.number_suffix);
  perform set_config('qy.onbehalf', '1', true);
  if coalesce(r.awaiting_owner, false) then
    select name into nm from public.users where id = me;
    if me = r.created_by_id then
      update public.requests set number = new_num, review_until = now(), awaiting_owner = false,
             on_behalf_by_id = null, on_behalf_by_name = null where id = p_id;
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      values (p_id, r.status, coalesce(nm,''), me, 'إرسال الطلب', 'أعدّه ' || coalesce(r.on_behalf_by_name,'مدير النظام') || '، وأرسله صاحبه بعد مراجعته',
              to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
    else
      update public.requests set number = new_num, review_until = now(), awaiting_owner = false where id = p_id;
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      values (p_id, r.status, coalesce(nm,''), me, 'إرسال الطلب نيابةً', 'أرسله مدير النظام دون انتظار صاحبه',
              to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
    end if;
  else
    update public.requests set number = new_num, review_until = now() where id = p_id;
  end if;
  return new_num;
end $$;

-- المجاميع للبنود (لغير المالية): الطلب المنتظر إرسال صاحبه لا يُحسب
create or replace function public.qy_budget_figures(p_company text)
returns table(budget_item_id text, committed numeric, pending numeric, reserved_extra numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  with rq as (
    select r.budget_item_id,
           coalesce(sum(r.total_amount) filter (where r.status in ('pending_transfer_request','pending_transfer_approval','pending_disbursement','pending_accountant','pending_cfo')), 0) as committed,
           coalesce(sum(r.total_amount) filter (where r.status in ('pending_decision','pending_manager','pending_senior','pending_executive')), 0) as pending
    from public.requests r
    where public.can_see_company(p_company) and r.company_id = p_company and r.budget_item_id is not null
      and not coalesce(r.is_cancelled,false) and r.status <> 'rejected' and not coalesce(r.awaiting_owner,false)
    group by r.budget_item_id),
  ck as (
    select k.budget_item_id, coalesce(sum(k.carried_in + public.qy_custody_over_amount(k.id)), 0) as extra
    from public.custodies k
    where public.can_see_company(p_company) and k.company_id = p_company and k.budget_item_id is not null
      and k.status in ('open','returned','close_requested','acct_review','pending_sign')
    group by k.budget_item_id)
  select coalesce(rq.budget_item_id, ck.budget_item_id), coalesce(rq.committed,0), coalesce(rq.pending,0), coalesce(ck.extra,0)
  from rq full join ck on ck.budget_item_id = rq.budget_item_id;
$$;
