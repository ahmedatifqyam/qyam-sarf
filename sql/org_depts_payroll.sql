-- أقسام المستخدمين العامّين + صلاحيات طلب الراتب والمكافأة + اعتماد الموارد البشرية في مسار الراتب (16 نوفمبر 2026) — للتجربة أولاً

-- 1) أقسام العامّين (على مستوى المؤسسة، تخدم كل الشركات): لكل قسم وظيفة يفهمها النظام
create table if not exists public.org_departments (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  func text not null default 'none' check (func in ('none','hr','secretary','finance')),
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.org_departments enable row level security;
drop policy if exists org_departments_sel on public.org_departments;
drop policy if exists org_departments_wrt on public.org_departments;
create policy org_departments_sel on public.org_departments for select to authenticated using (true);
create policy org_departments_wrt on public.org_departments for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.org_departments to authenticated;

alter table public.users add column if not exists org_dept_id text references public.org_departments(id) on delete set null;
grant select (org_dept_id) on public.users to authenticated;

create or replace function public.qy_user_dept_func(p_user text)
returns text language sql stable security definer set search_path = public as $fn$
  select d.func from public.users u join public.org_departments d on d.id = u.org_dept_id where u.id = p_user and coalesce(u.is_general,false);
$fn$;

-- 2) من يُنشئ طلب راتب: قسم الموارد البشرية أو السكرتارية، أو دور له الصلاحية صراحة (تعديل/تحكم)، وإلا افتراضياً المالية
create or replace function public.qy_can_payroll(p_user text, p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce(public.qy_user_dept_func(p_user) in ('hr','secretary'), false)
      or coalesce((select p.level in ('edit','full') from public.page_permissions p join public.users u on u.id = p_user
                   where p.company_id = p_company and p.role = u.role and p.page_key = 'payroll' limit 1),
                  (select u.role in ('accountant','cfo','admin') from public.users u where u.id = p_user), false);
$fn$;

create or replace function public.qy_requests_ins_guard()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
declare v_key text := case coalesce(new.request_type,'normal') when 'custody' then 'custody' when 'reward' then 'reward' when 'payroll' then 'payroll' else 'newreq' end;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return new; end if;
  if new.created_by_id is distinct from public.qy_me() then
    perform public.qy_deny('req_ins_owner', new.id, 'لا تُنشئ طلباً باسم غيرك');
  end if;
  if v_key = 'payroll' then
    if not public.qy_can_payroll(new.created_by_id, new.company_id) then
      perform public.qy_deny('req_ins_page', new.id, 'ليست لديك صلاحية إنشاء طلب راتب في هذه الشركة');
    end if;
  -- صلاحية الصفحة لدور المستخدم في هذه الشركة (لا يرى / قراءة فقط = لا إنشاء)
  elsif exists (select 1 from public.page_permissions p join public.users u on u.id = new.created_by_id
             where p.company_id = new.company_id and p.role = u.role and p.page_key = v_key and p.level in ('none','read')) then
    perform public.qy_deny('req_ins_page', new.id, 'ليست لديك صلاحية إنشاء هذا النوع من الطلبات في هذه الشركة');
  end if;
  if coalesce(new.is_cancelled,false) or coalesce(new.status,'') not in ('pending_decision','pending_transfer_request') then
    perform public.qy_deny('req_ins_status', new.id, 'لا يُنشأ طلب بحالة متقدمة');
  end if;
  if new.status = 'pending_transfer_request'
     and not public.qy_transfer_ok(new.created_by_id, new.company_id, new.total_amount) then
    perform public.qy_deny('req_ins_skip', new.id, 'لا يبدأ الطلب في مرحلة التحويل بلا معتمدين إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
  end if;
  return new;
end $function$;

-- 3) معتمد الموارد البشرية: مدير القسم (عضو مديره ليس في القسم)، وإلا أول عضو — ويُستبعد الموقوف
create or replace function public.qy_hr_approver(p_company text)
returns text language sql stable security definer set search_path = public as $fn$
  with m as (
    select u.* from public.users u join public.org_departments d on d.id = u.org_dept_id
    where d.func = 'hr' and coalesce(u.is_general,false) and not coalesce(u.is_suspended,false)
      and (p_company is null or public.qy_user_in_company(u.id, p_company)))
  select id from m order by (case when m.manager_id is null or m.manager_id not in (select id from m) then 0 else 1 end), m.name limit 1;
$fn$;

-- 4) مسار الراتب: بعد المدراء وقبل المحاسب تُضاف خطوة الموارد البشرية
create or replace function public.qy_set_chain(p_req text, p_reset boolean default false)
 returns setof request_approval_steps language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
declare r public.requests%rowtype; v_me text := public.qy_me(); ch jsonb; ids text[]; i int; stamp text; v_staff boolean; v_hr text; v_hr_note boolean := false;
  v_time text := to_char(now() at time zone 'Asia/Kuwait', 'DD') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'MM') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'YYYY')
          || ' ' || ltrim(to_char(now() at time zone 'Asia/Kuwait', 'HH12'), '0') || ':' || to_char(now() at time zone 'Asia/Kuwait', 'MI')
          || ' ' || case when extract(hour from now() at time zone 'Asia/Kuwait') >= 12 then 'م' else 'ص' end;
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
  if coalesce(r.request_type,'normal') = 'payroll' then
    v_hr := public.qy_hr_approver(r.company_id);
    if v_hr is null then v_hr_note := true;
    elsif v_hr <> r.created_by_id and not (v_hr = any(ids)) then ids := ids || v_hr;
    end if;
  end if;
  perform set_config('qy.sys', '1', true);
  delete from public.request_approval_steps where request_id = p_req;
  stamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  for i in 1 .. coalesce(array_length(ids,1),0) loop
    insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, note)
    values ('as_' || p_req || '_s' || stamp || '_' || i, p_req, ids[i], i, 'pending_decision', 'pending', 'primary', case when i = 1 then now() end,
            case when v_hr is not null and ids[i] = v_hr then 'الموارد البشرية' end);
  end loop;
  if v_hr_note and not exists (select 1 from public.request_history h where h.request_id = p_req and h.note like 'لم يُحدَّد قسم الموارد البشرية%') then
    insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      values (p_req, 'pending_decision', 'النظام', null, 'ملاحظة', 'لم يُحدَّد قسم الموارد البشرية للمستخدمين العامّين — مضى طلب الراتب على المسار العادي', v_time);
  end if;
  if coalesce(array_length(ids,1),0) = 0 then
    if coalesce((ch->>'self')::boolean, false)
       or coalesce((select u.direct_to_transfer from public.users u where u.id = r.created_by_id), false) then
      insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, acted_at, note)
        values ('as_' || p_req || '_s' || stamp || '_self', p_req, r.created_by_id, 1, 'pending_decision', 'approved', 'primary', now(), now(), 'بإنشائه الطلب');
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
        values (p_req, 'pending_decision', (select u.name from public.users u where u.id = r.created_by_id), r.created_by_id, 'اعتماد', 'بإنشائه الطلب — في أعلى السلسلة', v_time);
      update public.requests set status = 'pending_transfer_request' where id = p_req and status in ('pending_decision','rejected');
    else
      raise exception 'لا يوجد معتمِد لهذا الطلب، ولا يصل طلب للمالية قبل اعتماد واحد على الأقل. حدّد مديراً لصاحب الطلب، أو فعّل «الانتقال المباشر إلى التحويل» لمن هو في أعلى السلسلة';
    end if;
  end if;
  update public.requests set fast_tracked = coalesce((ch->>'fast')::boolean, false)
    where id = p_req and fast_tracked is distinct from coalesce((ch->>'fast')::boolean, false);
  perform set_config('qy.sys', '', true);
  return query select * from public.request_approval_steps where request_id = p_req order by sequence_order;
end $function$;
