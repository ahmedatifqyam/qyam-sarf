-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — الوحدات الإضافية للمستخدم + الدخول بالبريد
-- ║  17 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
-- ١) جدول الوحدات الإضافية: للمستخدم وحدة أساسية (users.center_id) ووحدات إضافية هنا،
--    ولكل وحدة إضافية مديره المباشر فيها (اختياري؛ فارغ = مديره المعتاد)
create table if not exists public.user_units (
  user_id    text not null references public.users(id) on delete cascade,
  center_id  text not null references public.centers(id) on delete cascade,
  manager_id text references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, center_id)
);
create index if not exists user_units_center_idx on public.user_units(center_id);
alter table public.user_units enable row level security;
drop policy if exists user_units_sel on public.user_units;
drop policy if exists user_units_wrt on public.user_units;
create policy user_units_sel on public.user_units for select to authenticated
  using (public.is_admin() or user_id = public.qy_me()
         or exists (select 1 from public.centers c where c.id = user_units.center_id and public.can_see_company(c.company_id)));
create policy user_units_wrt on public.user_units for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.user_units to authenticated;

-- كل وحدات المستخدم: الأساسية ثم الإضافية
create or replace function public.qy_user_units(p_user text) returns setof text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select center_id from public.users where id = p_user and center_id is not null
  union
  select center_id from public.user_units where user_id = p_user;
$$;
revoke all on function public.qy_user_units(text) from public, anon;
grant execute on function public.qy_user_units(text) to authenticated;

-- ٢) رؤية المركز: من يعمل فيه أو في وحدة فوقه، أساسية كانت أو إضافية
create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and u.role in ('accountant','cfo','executive_manager'))
              or exists (select 1 from public.qy_user_units(public.qy_me()) x(id) where x.id in (select id from public.qy_unit_up(p_center)))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ٣) طلب موظف المركز: على إحدى وحداته (أساسية أو إضافية) أو ما تحتها
create or replace function public.qy_center_staff_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare u public.users%rowtype;
begin
  if coalesce(new.request_type,'') = 'custody' or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into u from public.users where id = public.qy_me();
  if u.id is null or u.role in ('admin','accountant','cfo','executive_manager') then return new; end if;
  -- ليس من موظفي المراكز في أي من وحداته: لا قيد
  if not exists (select 1 from public.qy_user_units(u.id) x(id) join public.qy_unit_up(x.id) up on true where up.kind = 'center') then return new; end if;
  if new.center_id is null or not exists (
       select 1 from public.qy_user_units(u.id) x(id) where x.id in (select id from public.qy_unit_up(new.center_id))) then
    raise exception 'الطلب يكون على إحدى وحداتك أو ما تحتها فقط';
  end if;
  if new.budget_item_id is not null and exists (select 1 from public.qy_unit_up(new.center_id) where kind = 'center') then
    raise exception 'طلب المركز يُصرف من رصيد المركز، فلا يُختار له بند من ميزانية الشركة';
  end if;
  return new;
end $function$;

-- ٤) مسار القرار: إن كان الطلب على وحدة إضافية لها مدير محدد، يبدأ المسار منه
create or replace function public.qy_decision_chain(p_creator text, p_company text, p_total numeric, p_start text, p_center text)
 returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare
  r public.users%rowtype; a public.users%rowtype; c public.centers%rowtype;
  cur text; ids text[] := '{}'; seen text[]; err text := null;
  skip text[] := '{}'; kept text[] := '{}'; fast boolean := false; x text; xr text;
begin
  select * into r from public.users where id = p_creator;
  if not found then return jsonb_build_object('ids','[]'::jsonb,'error','مستخدم غير موجود','fast',false); end if;
  seen := array[p_creator];
  cur := case when nullif(p_start,'') is not null then p_start
              when coalesce(r.no_request_approver,false) then null
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
    select * into c from public.centers where id = coalesce(nullif(p_center,''), r.center_id);
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
end $function$;
revoke all on function public.qy_decision_chain(text,text,numeric,text,text) from public, anon;
grant execute on function public.qy_decision_chain(text,text,numeric,text,text) to authenticated;

-- الصيغة القديمة (ثلاثة مدخلات) تبقى كما هي لمن يستدعيها
create or replace function public.qy_decision_chain(p_creator text, p_company text, p_total numeric)
 returns jsonb language sql stable security definer set search_path to 'public','pg_temp' as $$
  select public.qy_decision_chain(p_creator, p_company, p_total, null::text, null::text);
$$;

-- مدير الوحدة الإضافية التي عليها الطلب (أو التي فوقها)، إن وُجد
create or replace function public.qy_unit_start(p_creator text, p_center text) returns text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select uu.manager_id from public.user_units uu
   join public.qy_unit_up(p_center) up on up.id = uu.center_id
   where uu.user_id = p_creator and uu.manager_id is not null
     and not exists (select 1 from public.users u where u.id = p_creator and u.center_id in (select id from public.qy_unit_up(p_center)))
   order by up.depth limit 1;
$$;
revoke all on function public.qy_unit_start(text,text) from public, anon;

-- ٥) بناء المسار: يمرّر مدير الوحدة الإضافية (إن وُجد) لدالة القرار
create or replace function public.qy_set_chain(p_req text, p_reset boolean default false)
 returns setof request_approval_steps language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare r public.requests%rowtype; v_me text := public.qy_me(); ch jsonb; ids text[]; i int; stamp text; v_staff boolean; v_hr text; v_hr_note boolean := false; v_start text;
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
  v_start := case when r.center_id is not null then public.qy_unit_start(r.created_by_id, r.center_id) end;
  ch := case when coalesce(r.request_type,'normal') = 'custody' then public.qy_custody_chain(r.id)
              else public.qy_decision_chain(r.created_by_id, r.company_id, r.total_amount, v_start, case when v_start is not null then r.center_id end) end;
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

-- ٦) الدخول بالبريد الإلكتروني المسجّل للمستخدم (إضافة إلى رقم الهاتف)
--    البريد المسجّل في بيانات المستخدم يُحوَّل إلى حساب الدخول المرتبط برقمه.
--    أي بريد آخر يُعاد كما هو (لحسابات الدخول الحقيقية بالبريد).
create or replace function public.resolve_login_email(p_login text) returns text
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare v text; v_phone text;
begin
  v := lower(trim(coalesce(p_login,'')));
  if v = '' then return ''; end if;
  if position('@' in v) > 0 then
    if v like '%@qyam.local' or exists (select 1 from auth.users au where lower(au.email) = v) then return v; end if;
    select phone into v_phone from public.users where lower(trim(email)) = v and coalesce(phone,'') <> '' order by is_suspended nulls first limit 1;
    if v_phone is not null then return lower(v_phone) || '@qyam.local'; end if;
    return v;
  end if;
  select phone into v_phone from public.users where lower(phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;
  select u.phone into v_phone
    from public.login_aliases a join public.users u on u.id = a.user_id
   where lower(a.phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;
  return v || '@qyam.local';
end;
$function$;

-- ٧) تحقق
select (select count(*) from pg_tables where schemaname='public' and tablename='user_units') as user_units_table,
       (select count(*) from pg_proc where proname='qy_decision_chain') as decision_chain_versions;
