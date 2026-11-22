-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٧ (1.43.0): «اعتماد مع تأجيل الصرف».
--   المعتمد يعتمد الطلب ويؤجّل صرفه: لعدد أيام / إلى تاريخ، أو حتى دخول مبلغ مشروع.
--   عند المحاسب يظهر الطلب في «مؤجلة الصرف» ولا يتقدّم قبل الموعد أو دخول المبلغ.
--   يُرفع التأجيل بسبب إلزامي: المحاسب («دخل المبلغ» / «صرف قبل الموعد»)، أو من أجّله، أو مدير النظام.
--   دخول دفعة على المشروع (prj_collections) يُنهي التأجيل تلقائياً ويُشعر المحاسب.
-- يُشغَّل بعد بناء-١..١٦. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.requests add column if not exists defer_kind text;
alter table public.requests add column if not exists defer_until date;
alter table public.requests add column if not exists defer_project_id text;
alter table public.requests add column if not exists defer_project_name text;
alter table public.requests add column if not exists defer_reason text;
alter table public.requests add column if not exists defer_by_id text;
alter table public.requests add column if not exists defer_by_name text;
alter table public.requests add column if not exists defer_at timestamptz;
alter table public.requests add column if not exists defer_met_at timestamptz;
alter table public.requests add column if not exists defer_released_at timestamptz;
alter table public.requests add column if not exists defer_released_by text;
alter table public.requests add column if not exists defer_release_note text;
alter table public.requests drop constraint if exists requests_defer_kind_check;
alter table public.requests add constraint requests_defer_kind_check check (
  defer_kind is null
  or (defer_kind = 'date' and defer_until is not null)
  or (defer_kind = 'project' and defer_project_id is not null));

-- هل الطلب ما زال مؤجلاً الآن؟
create or replace function public.qy_defer_active(p_req text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select r.defer_kind is not null and r.defer_released_at is null and case r.defer_kind
            when 'date' then r.defer_until > (now() at time zone 'Asia/Kuwait')::date
            when 'project' then r.defer_met_at is null else false end
          from public.requests r where r.id = p_req), false);
$$;

-- المشاريع التي يمكن ربط التأجيل بها (للمعتمد حتى لو لم يكن يرى صفحة المشاريع)
create or replace function public.qy_defer_projects(p_company text)
returns table(id text, name text, client text) language sql stable security definer set search_path = public, pg_temp as $$
  select p.id::text, p.name::text, coalesce(c.name, '')::text from public.projects p left join public.clients c on c.id = p.client_id
   where public.can_see_company(p_company) and p.company_id = p_company and coalesce(p.status,'') not in ('closed','cancelled')
   order by p.created_at desc;
$$;

-- التأجيل أو تعديله
create or replace function public.qy_request_defer(p_req text, p_kind text, p_until date, p_project text, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.requests%rowtype; me text := public.qy_me(); nm text; pname text; v_note text; v_due timestamptz;
begin
  if length(trim(coalesce(p_reason,''))) = 0 then raise exception 'اكتب سبب التأجيل'; end if;
  if p_kind not in ('date','project') then raise exception 'نوع التأجيل غير معروف'; end if;
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
  else
    select p.name into pname from public.projects p where p.id::text = p_project and p.company_id = r.company_id;
    if pname is null then raise exception 'المشروع غير موجود في شركة الطلب'; end if;
  end if;
  select name into nm from public.users where id = me;
  perform set_config('qy.defer', '1', true);
  update public.requests set defer_kind = p_kind,
         defer_until = case when p_kind = 'date' then p_until end,
         defer_project_id = case when p_kind = 'project' then p_project end,
         defer_project_name = case when p_kind = 'project' then pname end,
         defer_reason = trim(p_reason), defer_by_id = me, defer_by_name = coalesce(nm,''), defer_at = now(),
         defer_met_at = null, defer_released_at = null, defer_released_by = null, defer_release_note = null
   where id = r.id;
  v_note := case when p_kind = 'date' then 'حتى '||to_char(p_until,'DD-MM-YYYY') else 'حتى دخول مبلغ مشروع «'||pname||'»' end || ' — ' || trim(p_reason);
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

-- رفع التأجيل بسبب (دخل المبلغ / صرف قبل الموعد / إلغاء التأجيل)
create or replace function public.qy_request_defer_release(p_req text, p_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.requests%rowtype; me text := public.qy_me(); nm text; v_role text;
begin
  if length(trim(coalesce(p_note,''))) = 0 then raise exception 'اكتب السبب'; end if;
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.defer_kind is null or r.defer_released_at is not null then raise exception 'الطلب غير مؤجل'; end if;
  select name, role into nm, v_role from public.users where id = me;
  if not (public.is_admin() or r.defer_by_id = me
          or (v_role in ('accountant','cfo') and public.can_see_company(r.company_id))) then
    raise exception 'رفع التأجيل للمحاسب أو المدير المالي أو من أجّله أو مدير النظام';
  end if;
  perform set_config('qy.defer', '1', true);
  update public.requests set defer_released_at = now(), defer_released_by = me, defer_release_note = trim(p_note) where id = r.id;
  insert into public.request_history(request_id, step, actor, user_id, action, note, time)
  values (r.id, r.status, coalesce(nm,''), me, 'رفع تأجيل الصرف', trim(p_note), to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
  delete from public.push_outbox where request_id = r.id and sent_at is null and kind = 'defer';
end $$;

-- حارس: أعمدة التأجيل لا تُكتب إلا من الدالتين، ولا يتقدّم طلب مؤجل إلى التحويل أو الصرف
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
                              when 'project' then new.defer_met_at is null else false end) then
    raise exception 'الطلب مؤجل الصرف %؛ للصرف الآن اضغط «%» واكتب السبب',
      case new.defer_kind when 'date' then 'حتى '||to_char(new.defer_until,'DD-MM-YYYY') else 'حتى دخول مبلغ مشروع «'||coalesce(new.defer_project_name,'')||'»' end,
      case new.defer_kind when 'date' then 'صرف قبل الموعد' else 'دخل المبلغ' end;
  end if;
  return new;
end $$;
drop trigger if exists qy_requests_defer_guard_t on public.requests;
create trigger qy_requests_defer_guard_t before update on public.requests for each row execute function public.qy_requests_defer_guard();

-- حارس في الدفتر أيضاً: لا قيد صرف لطلب مؤجل
create or replace function public.qy_tx_defer_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.source_type = 'request' and new.reverses_id is null and new.refund_of_id is null and public.qy_defer_active(new.source_id) then
    raise exception 'الطلب مؤجل الصرف؛ ارفع التأجيل أولاً بزر «دخل المبلغ» أو «صرف قبل الموعد» مع السبب';
  end if;
  return new;
end $$;
drop trigger if exists qy_tx_defer_guard_t on public.transactions;
create trigger qy_tx_defer_guard_t before insert on public.transactions for each row execute function public.qy_tx_defer_guard();

-- دخول دفعة على المشروع: يُنهي التأجيل المرتبط به ويُشعر المحاسب ومن أجّل
create or replace function public.qy_defer_on_collection()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_proj text; x record;
begin
  if tg_op = 'INSERT' then
    select project_id into v_proj from public.prj_invoices where id = new.invoice_id;
    if v_proj is null then return new; end if;
    perform set_config('qy.defer', '1', true);
    for x in update public.requests set defer_met_at = now()
              where defer_kind = 'project' and defer_project_id = v_proj and defer_met_at is null and defer_released_at is null
                and not coalesce(is_cancelled,false)
              returning id, number, company_id, defer_by_id, defer_project_name loop
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      select x.id, r.status, 'النظام', null, 'انتهى تأجيل الصرف', 'دخل مبلغ مشروع «'||coalesce(x.defer_project_name,'')||'» في النظام',
             to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI') from public.requests r where r.id = x.id;
      perform public.qy_push_enqueue(public.qy_push_role_users(x.company_id, array['accountant']) || array[x.defer_by_id],
              'دخل مبلغ المشروع — طلب مؤجل جاهز للصرف', coalesce(x.number,''), 'defer', x.id, 'defer_met', now());
    end loop;
    return new;
  else
    -- حذف الدفعة (تراجع عن تسجيل فاشل): يعود التأجيل إن لم يبقَ للمشروع دفعة بعد تاريخ التأجيل
    select project_id into v_proj from public.prj_invoices where id = old.invoice_id;
    if v_proj is null then return old; end if;
    perform set_config('qy.defer', '1', true);
    update public.requests r set defer_met_at = null
     where r.defer_kind = 'project' and r.defer_project_id = v_proj and r.defer_met_at is not null and r.defer_released_at is null
       and r.status = 'pending_transfer_request'
       and not exists (select 1 from public.prj_collections k join public.prj_invoices i on i.id = k.invoice_id
                        where i.project_id::text = v_proj and k.id <> old.id and k.created_at >= r.defer_at);
    return old;
  end if;
end $$;
drop trigger if exists qy_defer_on_collection_t on public.prj_collections;
create trigger qy_defer_on_collection_t after insert or delete on public.prj_collections for each row execute function public.qy_defer_on_collection();

revoke all on function public.qy_defer_active(text), public.qy_defer_projects(text), public.qy_request_defer(text,text,date,text,text),
  public.qy_request_defer_release(text,text) from public, anon;
grant execute on function public.qy_defer_active(text), public.qy_defer_projects(text), public.qy_request_defer(text,text,date,text,text),
  public.qy_request_defer_release(text,text) to authenticated;
