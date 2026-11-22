-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٨ (1.44.0): تأجيل الصرف «حتى يتوفر رصيد المركز» + المتاح من رصيد المركز للطلب.
--   نوع تأجيل جديد 'balance' لطلبات المراكز: ينتهي تلقائياً حين يغطي رصيد المركز مبلغ الطلب
--   (عند تسجيل اشتراكات أو دعم أو إيراد في دفتر المركز)، ويُشعر المحاسب ومن أجّل.
--   qy_req_center_avail: رصيد المركز ناقص طلباته الأخرى التي في مرحلة التحويل أو الصرف.
--   (يُعرض للمحاسب تنبيهاً إن لم يكفِ الرصيد بعد انتهاء أي تأجيل.)
-- يُشغَّل بعد بناء-١..١٧. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.requests drop constraint if exists requests_defer_kind_check;
alter table public.requests add constraint requests_defer_kind_check check (
  defer_kind is null
  or (defer_kind = 'date' and defer_until is not null)
  or (defer_kind = 'project' and defer_project_id is not null)
  or (defer_kind = 'balance' and center_id is not null));

-- المتاح من رصيد مركز الطلب له: رصيد المركز ناقص طلباته الأخرى التي اعتُمد تحويلها ولم تُصرف بعد
create or replace function public.qy_req_center_avail(p_req text)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select public.qy_center_balance(r.center_id)
       - coalesce((select sum(x.total_amount) from public.requests x
                    where x.center_id = r.center_id and x.id <> r.id and x.status in ('pending_transfer_approval','pending_disbursement')
                      and not coalesce(x.is_cancelled,false) and coalesce(x.amount_route,'normal') = 'normal'), 0)
    from public.requests r where r.id = p_req and r.center_id is not null;
$$;
-- للواجهة: لا يُرجِع شيئاً لمن لا يرى شركة الطلب
create or replace function public.qy_req_center_avail_ui(p_req text)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select public.qy_req_center_avail(r.id) from public.requests r where r.id = p_req and public.can_see_company(r.company_id);
$$;

create or replace function public.qy_defer_active(p_req text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select r.defer_kind is not null and r.defer_released_at is null and case r.defer_kind
            when 'date' then r.defer_until > (now() at time zone 'Asia/Kuwait')::date
            when 'project' then r.defer_met_at is null
            when 'balance' then r.defer_met_at is null else false end
          from public.requests r where r.id = p_req), false);
$$;

create or replace function public.qy_request_defer(p_req text, p_kind text, p_until date, p_project text, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.requests%rowtype; me text := public.qy_me(); nm text; pname text; v_note text; v_due timestamptz;
begin
  if length(trim(coalesce(p_reason,''))) = 0 then raise exception 'اكتب سبب التأجيل'; end if;
  if p_kind not in ('date','project','balance') then raise exception 'نوع التأجيل غير معروف'; end if;
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if coalesce(r.is_cancelled,false) or r.status not in ('pending_decision','pending_transfer_request') then
    raise exception 'التأجيل للطلبات قبل تسجيل التحويل فقط';
  end if;
  if not (public.is_admin()
          or (r.defer_kind is not null and r.defer_by_id = me)
          or exists (select 1 from public.request_approval_steps s where s.request_id = r.id and s.approver_id = me)
          or exists (select 1 from public.request_history h where h.request_id = r.id and h.user_id = me and h.action = 'اعتماد')) then
    raise exception 'التأجيل لمعتمدي الطلب أو من أجّله أو مدير النظام';
  end if;
  if p_kind = 'date' then
    if p_until is null or p_until <= (now() at time zone 'Asia/Kuwait')::date then raise exception 'اختر تاريخاً بعد اليوم'; end if;
  elsif p_kind = 'balance' then
    if r.center_id is null or coalesce(r.amount_route,'normal') <> 'normal' then raise exception 'التأجيل حتى توفر الرصيد لطلبات المراكز فقط'; end if;
    if public.qy_req_center_avail(r.id) >= coalesce(r.total_amount,0) then raise exception 'رصيد المركز يكفي الطلب الآن؛ لا حاجة لهذا التأجيل'; end if;
    select name into pname from public.centers where id = r.center_id;
  else
    select p.name into pname from public.projects p where p.id::text = p_project and p.company_id = r.company_id;
    if pname is null then raise exception 'المشروع غير موجود في شركة الطلب'; end if;
  end if;
  select name into nm from public.users where id = me;
  perform set_config('qy.defer', '1', true);
  update public.requests set defer_kind = p_kind,
         defer_until = case when p_kind = 'date' then p_until end,
         defer_project_id = case when p_kind = 'project' then p_project end,
         defer_project_name = case when p_kind in ('project','balance') then pname end,
         defer_reason = trim(p_reason), defer_by_id = me, defer_by_name = coalesce(nm,''), defer_at = now(),
         defer_met_at = null, defer_released_at = null, defer_released_by = null, defer_release_note = null
   where id = r.id;
  v_note := case when p_kind = 'date' then 'حتى '||to_char(p_until,'DD-MM-YYYY') when p_kind = 'balance' then 'حتى يتوفر رصيد «'||coalesce(pname,'')||'»' else 'حتى دخول مبلغ مشروع «'||pname||'»' end || ' — ' || trim(p_reason);
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (r.id, r.status, coalesce(nm,''), me, case when r.defer_kind is null then 'تأجيل الصرف' else 'تعديل تأجيل الصرف' end, v_note,
          to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
  -- إشعار «بانتظار إجراءك» للمحاسب لا يُرسل الآن، ويُرسل بدلاً منه يوم انتهاء التأجيل
  delete from public.push_outbox where request_id = r.id and sent_at is null and (ref = 'pending_transfer_request' or kind = 'defer');
  if p_kind = 'date' then
    v_due := (p_until::timestamp + interval '8 hours') at time zone 'Asia/Kuwait';
    perform public.qy_push_enqueue(public.qy_push_role_users(r.company_id, array['accountant']) || array[me], 'انتهى تأجيل صرف طلب', coalesce(r.number,''), 'defer', r.id, 'defer_due', v_due);
  end if;
end $$;

create or replace function public.qy_requests_defer_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null and current_setting('qy.defer', true) is distinct from '1'
     and (new.defer_kind, new.defer_until, new.defer_project_id, new.defer_project_name, new.defer_reason, new.defer_by_id, new.defer_by_name,
          new.defer_at, new.defer_met_at, new.defer_released_at, new.defer_released_by, new.defer_release_note)
     is distinct from
         (old.defer_kind, old.defer_until, old.defer_project_id, old.defer_project_name, old.defer_reason, old.defer_by_id, old.defer_by_name,
          old.defer_at, old.defer_met_at, old.defer_released_at, old.defer_released_by, old.defer_release_note) then
    perform public.qy_deny('req_defer_cols', old.id, 'التأجيل يُضبط من زر «اعتماد مع تأجيل الصرف» أو يُرفع بسبب فقط');
  end if;
  if new.status is distinct from old.status and not coalesce(new.is_cancelled,false)
     and new.status in ('pending_transfer_approval','pending_disbursement','completed','pending_accountant','pending_cfo')
     and new.defer_kind is not null and new.defer_released_at is null
     and (case new.defer_kind when 'date' then new.defer_until > (now() at time zone 'Asia/Kuwait')::date
                              when 'project' then new.defer_met_at is null
                              when 'balance' then new.defer_met_at is null else false end) then
    raise exception 'الطلب مؤجل الصرف %؛ للصرف الآن اضغط «%» واكتب السبب',
      case new.defer_kind when 'date' then 'حتى '||to_char(new.defer_until,'DD-MM-YYYY') when 'balance' then 'حتى يتوفر رصيد «'||coalesce(new.defer_project_name,'')||'»' else 'حتى دخول مبلغ مشروع «'||coalesce(new.defer_project_name,'')||'»' end,
      case new.defer_kind when 'date' then 'صرف قبل الموعد' else 'دخل المبلغ' end;
  end if;
  return new;
end $$;

-- دفتر المركز: كل حركة (إضافة أو حذف/استرجاع) تفحص الطلبات المؤجلة حتى توفر رصيد هذا المركز
create or replace function public.qy_defer_on_center_ledger()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare x record;
begin
  perform set_config('qy.defer', '1', true);
  for x in select r.id, r.number, r.company_id, r.defer_by_id, r.defer_project_name, r.status from public.requests r
            where r.center_id = new.center_id and r.defer_kind = 'balance' and r.defer_met_at is null and r.defer_released_at is null
              and not coalesce(r.is_cancelled,false) and r.status in ('pending_decision','pending_transfer_request')
              and public.qy_req_center_avail(r.id) >= coalesce(r.total_amount,0)
            order by r.created_at loop
    update public.requests set defer_met_at = now() where id = x.id;
    insert into public.request_history(request_id, step, actor, user_id, action, note, time)
    values (x.id, x.status, 'النظام', null, 'انتهى تأجيل الصرف', 'توفر رصيد «'||coalesce(x.defer_project_name,'')||'»',
            to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
    perform public.qy_push_enqueue(public.qy_push_role_users(x.company_id, array['accountant']) || array[x.defer_by_id],
            'توفر رصيد المركز — طلب مؤجل جاهز للصرف', coalesce(x.number,''), 'defer', x.id, 'defer_met', now());
  end loop;
  return new;
end $$;
drop trigger if exists qy_defer_on_center_ledger_t on public.center_ledger;
create trigger qy_defer_on_center_ledger_t after insert or update of net, voided, center_id on public.center_ledger
  for each row execute function public.qy_defer_on_center_ledger();

revoke all on function public.qy_req_center_avail(text), public.qy_req_center_avail_ui(text) from public, anon, authenticated;
grant execute on function public.qy_req_center_avail_ui(text) to authenticated;
revoke all on function public.qy_defer_active(text), public.qy_request_defer(text,text,date,text,text) from public, anon;
grant execute on function public.qy_defer_active(text), public.qy_request_defer(text,text,date,text,text) to authenticated;
