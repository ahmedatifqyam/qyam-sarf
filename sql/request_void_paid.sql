-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١١ (1.39.0): إبطال طلب مصروف (مكتمل) واسترجاعه — عملية واحدة في الخادم.
--   الإبطال: قيد عاكس لكل صرف قائم للطلب في دفتر الحركات + إبطال الطلب + سطر في سجله.
--   الاسترجاع: إعادة قيد الصرف (بنفس المبلغ) + رفع الإبطال + سطر في سجله.
--   المسموح: مدير النظام، ومن يختاره في إعدادات الشركة (companies.void_paid_user_ids).
-- يُشغَّل بعد بناء-١..١٠. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.companies add column if not exists void_paid_user_ids jsonb not null default '[]'::jsonb;

create or replace function public.qy_can_void_paid(p_company text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin()
      or (public.can_see_company(p_company) and exists (select 1 from public.companies c where c.id = p_company
            and coalesce(c.void_paid_user_ids, '[]'::jsonb) ? public.qy_me()));
$$;

-- الإبطال
create or replace function public.qy_request_void_paid(p_req text, p_reason text)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.requests%rowtype; t public.transactions%rowtype; n integer := 0; me text := public.qy_me(); nm text;
begin
  if length(trim(coalesce(p_reason,''))) = 0 then raise exception 'اكتب سبب الإبطال'; end if;
  perform pg_advisory_xact_lock(hashtext('req_void:' || p_req));
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if not public.qy_can_void_paid(r.company_id) then raise exception 'ليست لديك صلاحية إبطال الطلبات المصروفة'; end if;
  if coalesce(r.is_cancelled,false) then raise exception 'الطلب مُبطل من قبل'; end if;
  if r.status <> 'completed' then raise exception 'هذا الإجراء للطلبات المصروفة فقط؛ أبطل غيرها بالطريقة العادية'; end if;
  select name into nm from public.users where id = me;
  for t in select * from public.transactions x
            where x.source_type = 'request' and x.source_id = r.id and x.reverses_id is null and x.refund_of_id is null
              and not exists (select 1 from public.transactions z where z.reverses_id = x.id)
  loop
    -- قاعدة الدفتر نفسها ترفض العكس إن كان على الصرف استرداد قائم
    insert into public.transactions(company_id, center_id, tx_date, direction, amount, budget_item_id, beneficiary,
                                    description, source_type, source_id, reverses_id, note, created_by_id, created_by)
    values (t.company_id, t.center_id, current_date, case when t.direction='out' then 'in' else 'out' end, t.amount, t.budget_item_id, t.beneficiary,
            'عكس: ' || t.description, t.source_type, t.source_id, t.id, 'إبطال طلب مصروف — ' || trim(p_reason), me, coalesce(nm,''));
    n := n + 1;
  end loop;
  update public.requests set is_cancelled = true, cancelled_at = now(), cancelled_by_id = me, cancel_reason = trim(p_reason) where id = r.id;
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (r.id, r.status, coalesce(nm,''), me, 'إبطال طلب مصروف',
          trim(p_reason) || case when n > 0 then ' — عُكس قيد الصرف في دفتر الحركات' else ' — لا قيد صرف في الدفتر' end,
          to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
  return n;
end $$;

-- الاسترجاع (لطلب مصروف أُبطل): يعيد قيد الصرف ثم يرفع الإبطال
create or replace function public.qy_request_restore_paid(p_req text)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.requests%rowtype; t public.transactions%rowtype; n integer := 0; me text := public.qy_me(); nm text;
begin
  perform pg_advisory_xact_lock(hashtext('req_void:' || p_req));
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if not public.qy_can_void_paid(r.company_id) then raise exception 'ليست لديك صلاحية استرجاع الطلبات المصروفة'; end if;
  if not coalesce(r.is_cancelled,false) then raise exception 'الطلب غير مُبطل'; end if;
  if r.status <> 'completed' then raise exception 'هذا الإجراء للطلبات المصروفة فقط'; end if;
  select name into nm from public.users where id = me;
  -- إن لم يبقَ صرف قائم: يُعاد آخر صرف معكوس بنفس بياناته
  if not exists (select 1 from public.transactions x where x.source_type='request' and x.source_id=r.id and x.reverses_id is null and x.refund_of_id is null
                   and not exists (select 1 from public.transactions z where z.reverses_id = x.id)) then
    select * into t from public.transactions x
      where x.source_type='request' and x.source_id=r.id and x.reverses_id is null and x.refund_of_id is null
      order by x.created_at desc limit 1;
    if found then
      insert into public.transactions(company_id, center_id, tx_date, direction, amount, budget_item_id, beneficiary,
                                      description, source_type, source_id, note, created_by_id, created_by)
      values (t.company_id, t.center_id, current_date, t.direction, r.total_amount, t.budget_item_id, t.beneficiary,
              t.description, 'request', r.id, 'إعادة صرف بعد استرجاع الطلب', me, coalesce(nm,''));
      n := 1;
    end if;
  end if;
  update public.requests set is_cancelled = false, cancelled_at = null, cancelled_by_id = null, cancel_reason = null where id = r.id;
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (r.id, r.status, coalesce(nm,''), me, 'استرجاع طلب مصروف',
          case when n > 0 then 'أُعيد قيد الصرف في دفتر الحركات' else 'قيد الصرف قائم أصلاً' end,
          to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
  return n;
end $$;

revoke all on function public.qy_request_void_paid(text, text), public.qy_request_restore_paid(text), public.qy_can_void_paid(text) from public, anon;
grant execute on function public.qy_request_void_paid(text, text), public.qy_request_restore_paid(text), public.qy_can_void_paid(text) to authenticated;
