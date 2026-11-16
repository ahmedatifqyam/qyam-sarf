-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — بناء قاعدة البيانات من الصفر — الجزء ٢ من ٣
-- ║  الدوال (187 دالة)
-- ║  مستخرج آلياً من قاعدة التجربة في 16 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public._get_manager_for_company(p_user_id text, p_company_id text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (
      SELECT ucm.manager_id
      FROM   user_company_managers ucm
      WHERE  ucm.user_id    = p_user_id
        AND  ucm.company_id = p_company_id
        AND  ucm.manager_id IS NOT NULL
      LIMIT 1
    ),
    (
      SELECT u.manager_id
      FROM   users u
      WHERE  u.id = p_user_id
    )
  );
$function$
;
CREATE OR REPLACE FUNCTION public._post_recurring_one(o recurring_occurrences, t recurring_templates, amt numeric, by_id text, by_name text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare txid uuid; rid text; dsc text := t.name || coalesce(' — ' || nullif(t.description,''), '');
begin
  if t.direction = 'in' then
    rid := 'rev_rec_' || replace(o.id::text, '-', '');
    delete from public.budget_revenues where id = rid;
    insert into public.budget_revenues (id, budget_item_id, amount, revenue_date, description, source_type, entered_by_id)
      values (rid, t.budget_item_id, amt, o.due_date, dsc, null, by_id);
    insert into public.transactions (company_id, center_id, tx_date, direction, amount, budget_item_id,
                                     beneficiary, description, source_type, source_id, note, created_by_id, created_by)
      values (o.company_id, t.center_id, o.due_date, 'in', amt, t.budget_item_id,
              t.beneficiary, dsc, 'revenue', rid, coalesce(p_note, 'قيد دوري'), by_id, by_name)
      returning id into txid;
  else
    insert into public.transactions (company_id, center_id, tx_date, direction, amount, budget_item_id,
                                     beneficiary, description, source_type, source_id, note, created_by_id, created_by)
      values (o.company_id, t.center_id, o.due_date, 'out', amt, t.budget_item_id,
              t.beneficiary, dsc, 'recurring', o.id::text, p_note, by_id, by_name)
      returning id into txid;
  end if;
  update public.recurring_occurrences
     set status = 'posted', amount = amt, transaction_id = txid,
         handled_by_id = by_id, handled_by = by_name, handled_at = now()
   where id = o.id;
end $function$
;
CREATE OR REPLACE FUNCTION public._user_has_company(p_user_id text, p_company_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM users
    WHERE  id = p_user_id AND company_id = p_company_id
  )
  OR EXISTS (
    SELECT 1 FROM user_companies
    WHERE  user_id = p_user_id AND company_id = p_company_id
  );
$function$
;
CREATE OR REPLACE FUNCTION public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text DEFAULT NULL::text, p_manager_id text DEFAULT NULL::text, p_company_id text DEFAULT NULL::text, p_is_general boolean DEFAULT false, p_level_id text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
AS $function$
declare
  v_uid   uuid := gen_random_uuid();
  v_email text := lower(p_phone) || '@qyam.local';
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية لمدير النظام فقط';
  end if;
  if length(coalesce(p_password,'')) < 6 then
    raise exception 'كلمة المرور يجب ألا تقل عن ٦ خانات';
  end if;
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'رقم الهاتف مستخدم من قبل';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    v_email, extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('sub', v_uid::text, 'email', v_email,
                       'email_verified', true, 'phone_verified', false),
    '', '', '', '', false, false
  );

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (v_uid::text, v_uid,
          jsonb_build_object('sub', v_uid::text, 'email', v_email,
                             'email_verified', true, 'phone_verified', false),
          'email', now(), now());

  insert into public.users (id, phone, name, role, center_id, manager_id,
                            company_id, is_general, level_id, auth_id)
  values (p_id, p_phone, p_name, p_role, p_center_id, p_manager_id,
          p_company_id, coalesce(p_is_general,false), p_level_id, v_uid);

  return p_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_remove_login_alias(p_phone text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية لمدير النظام فقط';
  end if;
  delete from public.login_aliases where lower(phone) = lower(trim(coalesce(p_phone,'')));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_login_phone(p_user_id text, p_phone text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v_auth uuid; v_old text; v_new text; v_owner text;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية لمدير النظام فقط';
  end if;

  v_new := lower(trim(coalesce(p_phone,'')));
  if v_new = '' then raise exception 'رقم الهاتف مطلوب'; end if;
  if position('@' in v_new) > 0 then raise exception 'رقم الهاتف لا يحتوي على @'; end if;

  select auth_id, phone into v_auth, v_old from public.users where id = p_user_id;
  if not found then raise exception 'المستخدم غير موجود'; end if;
  if v_auth is null then raise exception 'المستخدم غير مرتبط بحساب مصادقة'; end if;

  select id into v_owner from public.users
   where lower(phone) = v_new and id <> p_user_id limit 1;
  if v_owner is not null then raise exception 'رقم الهاتف مستخدم من قبل'; end if;

  select user_id into v_owner from public.login_aliases
   where lower(phone) = v_new and user_id <> p_user_id limit 1;
  if v_owner is not null then raise exception 'رقم الهاتف محجوز كرقم قديم لمستخدم آخر'; end if;

  if lower(coalesce(v_old,'')) = v_new then return; end if;

  if coalesce(v_old,'') <> '' then
    insert into public.login_aliases(phone, user_id) values (lower(v_old), p_user_id)
    on conflict (phone) do update set user_id = excluded.user_id;
  end if;

  delete from public.login_aliases where lower(phone) = v_new;

  update auth.users
     set email = v_new || '@qyam.local', updated_at = now()
   where id = v_auth;

  update auth.identities
     set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new || '@qyam.local')),
         updated_at = now()
   where user_id = v_auth and provider = 'email';

  update public.users set phone = p_phone where id = p_user_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_password(p_user_id text, p_password text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
AS $function$
declare v_auth uuid;
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح: هذه العملية لمدير النظام فقط';
  end if;
  if length(coalesce(p_password,'')) < 6 then
    raise exception 'كلمة المرور يجب ألا تقل عن ٦ خانات';
  end if;
  select auth_id into v_auth from public.users where id = p_user_id;
  if v_auth is null then raise exception 'المستخدم غير مرتبط بحساب مصادقة'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_auth;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_suspended(p_user_id text, p_suspended boolean, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
AS $function$
declare v_auth uuid;
begin
  if not public.is_admin() then raise exception 'غير مصرّح: هذه العملية لمدير النظام فقط'; end if;
  select auth_id into v_auth from public.users where id = p_user_id;
  update public.users set is_suspended = p_suspended, suspended_at = case when p_suspended then now() else null end,
         suspended_note = case when p_suspended then p_note else null end where id = p_user_id;
  if v_auth is not null then
    update auth.users set banned_until = case when p_suspended then 'infinity'::timestamptz else null end where id = v_auth;
    if p_suspended then
      delete from auth.refresh_tokens where user_id = v_auth::text;
      delete from auth.sessions where user_id = v_auth;
    end if;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.approve_recurring_template(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare me public.users; t public.recurring_templates;
begin
  select * into me from public.users where auth_id = auth.uid() limit 1;
  if me.id is null or me.role not in ('cfo','admin') then raise exception 'الاعتماد للمدير المالي أو مدير النظام فقط'; end if;
  select * into t from public.recurring_templates where id = p_id for update;
  if not found then raise exception 'القالب غير موجود'; end if;
  if not public.can_see_company(t.company_id) then raise exception 'غير مصرّح'; end if;
  if t.status <> 'pending_approval' then raise exception 'القالب ليس بانتظار الاعتماد'; end if;
  if t.created_by_id = me.id and me.role <> 'admin' then raise exception 'لا يعتمد المُنشئ قالبه بنفسه'; end if;
  perform set_config('app.recurring_rpc', '1', true);
  update public.recurring_templates
     set status = 'active', approved_by_id = me.id, approved_by = me.name, approved_at = now(),
         generation_from = coalesce(generation_from, greatest(start_date, public.kw_today()))
   where id = p_id;
  perform set_config('app.recurring_rpc', '0', true);
  delete from public.recurring_occurrences where template_id = p_id and status = 'proposed';
  perform public.generate_recurring_occurrences(p_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.assign_due_request_numbers()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r record; cnt int := 0;
begin
  for r in
    select id, number_prefix, number_suffix
    from public.requests
    where number is null
      and number_prefix is not null
      and review_until is not null
      and review_until <= now()
    order by created_at
    for update skip locked
  loop
    update public.requests
       set number = public.next_request_number(r.number_prefix, r.number_suffix)
     where id = r.id;
    cnt := cnt + 1;
  end loop;
  return cnt;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.auto_escalate_overdue_approvals()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_step          RECORD;
  v_req           RECORD;
  v_approver      RECORD;
  v_company       RECORD;
  v_deadline_days integer;
  v_elapsed       numeric;
  v_target_id     text;
  v_target_name   text;
  v_escalation_id text;
  v_mode          text;
  v_escalate_mode text;
  v_rows_inserted integer;
  v_now           timestamptz := now();
  v_count         integer := 0;
BEGIN

  FOR v_step IN
    SELECT
      ras.id,
      ras.request_id,
      ras.approver_id,
      ras.sequence_order,
      ras.activated_at
    FROM  request_approval_steps ras
    JOIN  requests r ON r.id = ras.request_id
    WHERE r.status           = 'pending_decision'
      AND r.is_cancelled     = FALSE
      AND ras.role_label     = 'pending_decision'
      AND ras.status         = 'pending'
      AND ras.kind           = 'primary'
      AND ras.activated_at   IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM   request_approval_steps esc
        WHERE  esc.request_id     = ras.request_id
          AND  esc.sequence_order = ras.sequence_order
          AND  esc.kind           = 'escalation'
      )
  LOOP

    SELECT id, company_id, created_by_id
    INTO   v_req
    FROM   requests
    WHERE  id = v_step.request_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    SELECT
      COALESCE(default_deadline_days, 0)         AS default_deadline_days,
      COALESCE(default_escalate_mode, 'manager') AS default_escalate_mode,
      COALESCE(deadline_day_mode,     'work')    AS deadline_day_mode
    INTO   v_company
    FROM   companies
    WHERE  id = v_req.company_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_mode := v_company.deadline_day_mode;

    SELECT
      id,
      name,
      COALESCE(approval_deadline_days, -1) AS approval_deadline_days,
      COALESCE(escalate_mode, '')          AS escalate_mode,
      escalate_user_id,
      manager_id
    INTO   v_approver
    FROM   users
    WHERE  id = v_step.approver_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- حساب المهلة
    IF v_approver.approval_deadline_days >= 0 THEN
      v_deadline_days := v_approver.approval_deadline_days;
    ELSE
      v_deadline_days := GREATEST(v_company.default_deadline_days, 0);
    END IF;
    IF v_deadline_days = 0 THEN CONTINUE; END IF;

    -- حساب الأيام المنقضية
    IF v_mode = 'calendar' THEN
      v_elapsed := EXTRACT(EPOCH FROM (v_now - v_step.activated_at)) / 86400.0;
    ELSE
      SELECT
        EXTRACT(EPOCH FROM (v_now - v_step.activated_at)) / 86400.0 - COUNT(*)
      INTO v_elapsed
      FROM generate_series(
        v_step.activated_at::date,
        v_now::date - INTERVAL '1 day',
        INTERVAL '1 day'
      ) AS gs(d)
      WHERE EXTRACT(DOW FROM gs.d) IN (5, 6);
    END IF;

    IF v_elapsed IS NULL OR v_elapsed < v_deadline_days THEN CONTINUE; END IF;

    -- تحديد وجهة الإحالة
    v_escalate_mode := CASE
      WHEN v_approver.escalate_mode <> '' THEN v_approver.escalate_mode
      ELSE v_company.default_escalate_mode
    END;

    v_target_id := NULL;

    IF v_escalate_mode = 'manager' OR v_escalate_mode = '' THEN

      SELECT u.id INTO v_target_id
      FROM   users u
      WHERE  u.id = _get_manager_for_company(v_step.approver_id, v_req.company_id)
        AND  u.id <> v_step.approver_id
        AND  u.id <> v_req.created_by_id
        AND  _user_has_company(u.id, v_req.company_id)
        AND  NOT EXISTS (
               SELECT 1 FROM request_approval_steps s2
               WHERE  s2.request_id  = v_step.request_id
                 AND  s2.approver_id = u.id
                 AND  s2.status IN ('pending','approved')
             )
      LIMIT 1;

    ELSIF v_escalate_mode = 'next' THEN

      SELECT s2.approver_id INTO v_target_id
      FROM   request_approval_steps s2
      WHERE  s2.request_id     = v_step.request_id
        AND  s2.status         = 'pending'
        AND  s2.sequence_order > v_step.sequence_order
        AND  s2.approver_id   <> v_step.approver_id
        AND  s2.approver_id   <> v_req.created_by_id
        AND  _user_has_company(s2.approver_id, v_req.company_id)
      ORDER  BY s2.sequence_order ASC
      LIMIT  1;

      -- fallback → manager
      IF v_target_id IS NULL THEN
        SELECT u.id INTO v_target_id
        FROM   users u
        WHERE  u.id = _get_manager_for_company(v_step.approver_id, v_req.company_id)
          AND  u.id <> v_step.approver_id
          AND  u.id <> v_req.created_by_id
          AND  _user_has_company(u.id, v_req.company_id)
          AND  NOT EXISTS (
                 SELECT 1 FROM request_approval_steps s2
                 WHERE  s2.request_id  = v_step.request_id
                   AND  s2.approver_id = u.id
                   AND  s2.status IN ('pending','approved')
               )
        LIMIT 1;
      END IF;

    ELSIF v_escalate_mode = 'user' THEN

      SELECT u.id INTO v_target_id
      FROM   users u
      WHERE  u.id = v_approver.escalate_user_id
        AND  u.id <> v_step.approver_id
        AND  u.id <> v_req.created_by_id
        AND  _user_has_company(u.id, v_req.company_id)
        AND  NOT EXISTS (
               SELECT 1 FROM request_approval_steps s2
               WHERE  s2.request_id  = v_step.request_id
                 AND  s2.approver_id = u.id
                 AND  s2.status IN ('pending','approved')
             )
      LIMIT 1;

      -- fallback → manager
      IF v_target_id IS NULL THEN
        SELECT u.id INTO v_target_id
        FROM   users u
        WHERE  u.id = _get_manager_for_company(v_step.approver_id, v_req.company_id)
          AND  u.id <> v_step.approver_id
          AND  u.id <> v_req.created_by_id
          AND  _user_has_company(u.id, v_req.company_id)
          AND  NOT EXISTS (
                 SELECT 1 FROM request_approval_steps s2
                 WHERE  s2.request_id  = v_step.request_id
                   AND  s2.approver_id = u.id
                   AND  s2.status IN ('pending','approved')
               )
        LIMIT 1;
      END IF;

      -- fallback ثانٍ → next
      IF v_target_id IS NULL THEN
        SELECT s2.approver_id INTO v_target_id
        FROM   request_approval_steps s2
        WHERE  s2.request_id     = v_step.request_id
          AND  s2.status         = 'pending'
          AND  s2.sequence_order > v_step.sequence_order
          AND  s2.approver_id   <> v_step.approver_id
          AND  s2.approver_id   <> v_req.created_by_id
          AND  _user_has_company(s2.approver_id, v_req.company_id)
        ORDER  BY s2.sequence_order ASC
        LIMIT  1;
      END IF;

    END IF;

    IF v_target_id IS NULL THEN CONTINUE; END IF;

    SELECT name INTO v_target_name FROM users WHERE id = v_target_id;

    -- إدراج خطوة الإحالة (معرّف حتمي)
    v_escalation_id := 'esc_' || v_step.request_id || '_' || v_step.sequence_order::text;

    INSERT INTO request_approval_steps
      (id, request_id, approver_id, sequence_order, role_label, status, kind, escalated_from, activated_at)
    VALUES
      (v_escalation_id,
       v_step.request_id,
       v_target_id,
       v_step.sequence_order,
       'pending_decision',
       'pending',
       'escalation',
       v_step.approver_id,
       v_now)
    ON CONFLICT (id) DO NOTHING;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

    IF v_rows_inserted > 0 THEN
      INSERT INTO request_history
        (request_id, step, actor, user_id, action, note, time, created_at)
      VALUES
        (v_step.request_id,
         'pending_decision',
         'النظام',
         NULL,
         'إحالة تلقائية',
         'لتأخر ' || v_approver.name
           || ' أكثر من ' || v_deadline_days
           || CASE WHEN v_mode = 'calendar' THEN ' أيام' ELSE ' أيام عمل' END
           || '؛ أُحيل الاعتماد أيضاً إلى ' || COALESCE(v_target_name, '—'),
         to_char(v_now AT TIME ZONE 'Asia/Kuwait', 'YYYY/MM/DD HH12:MI AM'),
         v_now);

      v_count := v_count + 1;
    END IF;

  END LOOP;

  RETURN v_count;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.budget_item_balance(p_item_id text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    COALESCE(rev.total, 0)
    - COALESCE(rev.profit, 0)
    - COALESCE(spent.total, 0)
  FROM
    (
      SELECT
        SUM(amount) AS total,
        SUM(
          CASE bi.profit_mode
            WHEN 'percent' THEN amount * bi.profit_percent / 100.0
            WHEN 'fixed'   THEN LEAST(amount, bi.profit_fixed)
            WHEN 'both'    THEN (amount * bi.profit_percent / 100.0) + bi.profit_fixed
            ELSE 0
          END
        ) AS profit
      FROM budget_revenues br
      JOIN budget_items bi ON bi.id = br.budget_item_id
      WHERE br.budget_item_id = p_item_id
    ) rev,
    (
      SELECT COALESCE(SUM(r.total_amount), 0) AS total
      FROM requests r
      WHERE r.budget_item_id = p_item_id
        AND r.status IN ('approved','pending_decision')
        AND COALESCE(r.is_cancelled, false) = false
    ) spent
$function$
;
CREATE OR REPLACE FUNCTION public.budget_item_company_profit(p_item_id text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(SUM(
    CASE bi.profit_mode
      WHEN 'percent' THEN br.amount * bi.profit_percent / 100.0
      WHEN 'fixed'   THEN LEAST(br.amount, bi.profit_fixed)
      WHEN 'both'    THEN (br.amount * bi.profit_percent / 100.0) + bi.profit_fixed
      ELSE 0
    END
  ), 0)
  FROM budget_revenues br
  JOIN budget_items bi ON bi.id = br.budget_item_id
  WHERE br.budget_item_id = p_item_id
$function$
;
CREATE OR REPLACE FUNCTION public.can_manage_recurring()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.users u
    where u.auth_id = auth.uid()
      and (u.role in ('accountant','cfo','admin') or u.can_manage_recurring)
  )
$function$
;
CREATE OR REPLACE FUNCTION public.can_see_company(p_company_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p_company_id is not null
     and exists (select 1 from public.my_company_ids() x where x.company_id = p_company_id);
$function$
;
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
CREATE OR REPLACE FUNCTION public.ensure_petty_expenses_item(p_company_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id text;
begin
  select id into v_id from public.budget_items
   where company_id = p_company_id and is_protected = true limit 1;
  if v_id is not null then return v_id; end if;

  v_id := 'bi_petty_' || p_company_id;
  insert into public.budget_items
    (id, company_id, parent_id, name, type, is_recurring, is_active,
     profit_mode, profit_percent, profit_fixed, is_protected, notes)
  values
    (v_id, p_company_id, null, 'مصاريف نثرية', 'company', true, true,
     'none', 0, 0, true,
     'بند افتراضي يُنشأ مع كل شركة. المخصص الافتتاحي مؤقت حتى تُربط النثرية بأرباح الشركة عبر جدول الحركات.');

  insert into public.budget_revenues
    (id, budget_item_id, amount, revenue_date, description, source_type)
  values
    ('br_petty_' || p_company_id, v_id, 1000, current_date,
     'مخصص افتتاحي مؤقت — يُستبدل لاحقاً بتمويل من أرباح الشركة', 'other');

  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.finalize_request(p_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r record; new_num text;
begin
  select id, number, number_prefix, number_suffix, created_by_id, company_id
    into r
    from public.requests
   where id = p_id
   for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.number is not null then return r.number; end if;
  if r.number_prefix is null then raise exception 'الطلب بلا قالب ترقيم'; end if;

  if not exists (
      select 1 from public.users u
       where u.auth_id = auth.uid()
         and ( u.id = r.created_by_id
               or (u.role = 'admin' and public.can_see_company(r.company_id)) )
  ) then
    raise exception 'لا تملك هذا الطلب ولست مدير النظام';
  end if;

  new_num := public.next_request_number(r.number_prefix, r.number_suffix);
  update public.requests
     set number = new_num, review_until = now()
   where id = p_id;
  return new_num;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.generate_recurring_occurrences(p_template uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  t public.recurring_templates; o record; oc2 public.recurring_occurrences; n int := 0; c int;
  horizon date := public.kw_today() + 45;
begin
  for t in select * from public.recurring_templates
           where status = 'active' and (p_template is null or id = p_template) loop
    insert into public.recurring_occurrences (template_id, company_id, due_date, amount)
    select t.id, t.company_id, g.due, t.amount
    from public.recurring_due_dates(t, horizon) as g(due)
    on conflict (template_id, due_date) do nothing;
    get diagnostics c = row_count;
    n := n + c;
  end loop;

  for o in
    select oc.id as oid from public.recurring_occurrences oc
    join public.recurring_templates t2 on t2.id = oc.template_id
    where oc.status = 'proposed' and not oc.no_auto and t2.status = 'active' and t2.auto_post
      and t2.amount_mode = 'fixed' and oc.due_date <= public.kw_today()
    order by oc.due_date
  loop
    select * into oc2 from public.recurring_occurrences where id = o.oid for update;
    if oc2.status = 'proposed' then
      select * into t from public.recurring_templates where id = oc2.template_id;
      perform public._post_recurring_one(oc2, t, oc2.amount, null, 'النظام', 'ترحيل تلقائي');
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.users u
    where u.auth_id = auth.uid() and u.role = 'admin'
  );
$function$
;
CREATE OR REPLACE FUNCTION public.is_finance()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.users u
    where u.auth_id = auth.uid()
      and u.role in ('accountant','cfo','admin')
  );
$function$
;
CREATE OR REPLACE FUNCTION public.kw_today()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select (now() at time zone 'Asia/Kuwait')::date $function$
;
CREATE OR REPLACE FUNCTION public.me()
 RETURNS users
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.* from public.users u where u.auth_id = auth.uid() limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.my_company_ids()
 RETURNS TABLE(company_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with m as (select * from public.me())
  select c.id from public.companies c, m
    where m.role = 'admin' or m.is_general = true
  union
  select m.company_id from m where m.company_id is not null
  union
  select uc.company_id from public.user_companies uc, m where uc.user_id = m.id;
$function$
;
CREATE OR REPLACE FUNCTION public.my_user_id()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.id from public.users u where u.auth_id = auth.uid() limit 1
$function$
;
CREATE OR REPLACE FUNCTION public.next_request_number(p_prefix text, p_suffix text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n int;
begin
  insert into public.request_number_counters(prefix, suffix, last_n)
  values (p_prefix, p_suffix, 1)
  on conflict (prefix, suffix) do update
    set last_n = public.request_number_counters.last_n + 1
  returning last_n into n;
  return p_prefix || lpad(n::text, 3, '0') || p_suffix;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.on_company_created()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public.ensure_petty_expenses_item(new.id);
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.post_recurring_occurrences(p_items jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it jsonb; o public.recurring_occurrences; t public.recurring_templates; me public.users;
        amt numeric; n int := 0;
begin
  select * into me from public.users where auth_id = auth.uid() limit 1;
  if me.id is null then raise exception 'غير مصرّح'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into o from public.recurring_occurrences where id = (it->>'id')::uuid for update;
    if not found or o.status <> 'proposed' then raise exception 'هذا القيد غير متاح للترحيل'; end if;
    select * into t from public.recurring_templates where id = o.template_id;
    if t.status <> 'active' then raise exception 'القالب غير مفعّل'; end if;
    if not (public.is_finance() and public.can_see_company(o.company_id)) then raise exception 'غير مصرّح'; end if;
    amt := coalesce((it->>'amount')::numeric, o.amount);
    if amt <= 0 then raise exception 'المبلغ غير صحيح'; end if;
    if t.amount_mode = 'fixed' and amt <> t.amount then raise exception 'مبلغ هذا القالب ثابت'; end if;
    perform public._post_recurring_one(o, t, amt, me.id, me.name, nullif(it->>'note',''));
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.prevent_protected_budget_item_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if old.is_protected then
    raise exception 'هذا بند ثابت في النظام ولا يمكن حذفه. عطّله بدل ذلك.';
  end if;
  return old;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_att_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if (select count(*) from public.qy_attachments where master_id = new.master_id) >= 10 then
    raise exception 'الحد الأقصى 10 مرفقات لكل مستفيد' using errcode = 'P0001';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_backup_dump()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t record; out jsonb := jsonb_build_object('generated_at', now(), 'tables', '{}'::jsonb); rows jsonb;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relkind='r' order by 1 loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t.relname) into rows;
    out := jsonb_set(out, array['tables', t.relname], rows);
  end loop;
  return out;
end $function$
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
CREATE OR REPLACE FUNCTION public.qy_bm_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_finance() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE' then
    perform public.qy_deny('bm_delete', null, 'حذف مستفيد مسجّل للمالية فقط');
    return old;
  end if;
  if (nullif(btrim(coalesce(old.iban,'')),'') is not null
        and regexp_replace(upper(coalesce(new.iban,'')),'\s','','g') is distinct from regexp_replace(upper(coalesce(old.iban,'')),'\s','','g'))
     or (nullif(btrim(coalesce(old.national_id,'')),'') is not null
        and btrim(coalesce(new.national_id,'')) is distinct from btrim(coalesce(old.national_id,''))) then
    perform public.qy_deny('bm_identity', null, 'تغيير آيبان أو رقم مدني لمستفيد مسجّل للمالية فقط');
  end if;
  return new;
end $function$
;
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
CREATE OR REPLACE FUNCTION public.qy_can_import(p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.can_see_company(p_company) and (public.is_admin() or public.is_finance()
     or exists (select 1 from public.gateway_import_users g where g.company_id = p_company and g.user_id = public.qy_me()));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_can_payroll(p_user text, p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(public.qy_user_dept_func(p_user) in ('hr','secretary'), false)
      or exists (select 1 from public.users u join public.custom_roles cr on cr.id = u.role where u.id = p_user and cr.can_payroll)
      or coalesce((select p.level in ('edit','full') from public.page_permissions p join public.users u on u.id = p_user
                   where p.company_id = p_company and p.role = u.role and p.page_key = 'payroll' limit 1),
                  (select u.role in ('accountant','cfo','admin') from public.users u where u.id = p_user), false);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_can_transfer(p_root text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.centers r where r.id = p_root and public.can_see_company(r.company_id)
     and (public.is_admin() or public.is_finance() or public.qy_me() = any(coalesce(r.transfer_user_ids,'{}'))));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_balance(p_center text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.qy_round3(coalesce((select sum(net) from public.center_ledger where center_id = p_center and not voided), 0)
        - coalesce((select sum(total_amount) from public.requests where center_id = p_center and status = 'completed' and not coalesce(is_cancelled,false) and amount_route = 'normal'), 0));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_balances(p_company text)
 RETURNS TABLE(center_id text, income numeric, transfers numeric, expense numeric, balance numeric, pending_requests numeric, pending_payments integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select ce.id,
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind <> 'transfer'),0)),
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind = 'transfer'),0)),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status = 'completed' and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    public.qy_center_balance(ce.id),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    0
  from public.centers ce where ce.company_id = p_company and public.qy_center_can_see(ce.id);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_can_see(p_center text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and (u.role in ('accountant','cfo','executive_manager')
                          or u.center_id in (select id from public.qy_unit_up(p_center))))
          end);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_sus text;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  if new.status is distinct from old.status and new.status in ('pending_transfer_approval','pending_disbursement','completed') then
    v_sus := public.qy_unit_suspended(new.center_id);
    if v_sus is not null then raise exception '«%» متوقف: الصرف مجمّد حتى يعود «شغال»', v_sus; end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_center_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ce public.centers%rowtype; v_avail numeric; v_sus text;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception '«%» مغلق ولا تُنشأ له طلبات جديدة', ce.name; end if;
  v_sus := public.qy_unit_suspended(ce.id);
  if v_sus is not null then raise exception '«%» متوقف ولا تُنشأ طلبات حتى يعود «شغال»', v_sus; end if;
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
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_center_open_date(p_center text)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select max(entry_date) from public.center_ledger where center_id = p_center and kind = 'opening' and not voided;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_pct(p_center text, p_support boolean)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when p_support then coalesce(ce.support_share_pct, co.support_company_pct, 10)
              else coalesce(ce.company_share_pct, co.gateway_company_pct, 5) end
  from public.centers ce join public.companies co on co.id = ce.company_id where ce.id = p_center;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_center_set_stage(p_center text, p_stage text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric; v_note text := nullif(trim(coalesce(p_note,'')),'');
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('potential','open','active','suspended','closed') then raise exception 'حالة غير صالحة'; end if;
  if p_stage = ce.stage then return; end if;
  if (p_stage = 'suspended' or ce.stage in ('suspended','closed')) and v_note is null then
    raise exception '%', case when p_stage = 'suspended' then 'اكتب سبب الإيقاف' else 'اكتب سبب إعادة الفتح' end;
  end if;
  if p_stage = 'closed' then
    if exists (select 1 from public.centers x where x.parent_id = p_center and x.stage <> 'closed') then raise exception 'لا يُغلق نهائياً: تحته بنود غير مغلقة. أغلقها أولاً، أو اختر «متوقف» الآن'; end if;
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'لا يُغلق نهائياً: له طلبات مفتوحة (%). اختر «متوقف» حتى تُنجز أو تُلغى', v_open; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'لا يُغلق نهائياً: الرصيد غير مصفّى (%). اختر «متوقف» حتى ترحّله أو تسوّيه', v_bal; end if;
  end if;
  update public.centers set stage = p_stage, stage_note = v_note, stage_by = public.qy_me(), stage_at = now() where id = p_center;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_center_staff_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u public.users%rowtype;
begin
  if coalesce(new.request_type,'') = 'custody' or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into u from public.users where id = public.qy_me();
  if u.id is null or u.center_id is null or u.role in ('admin','accountant','cfo','executive_manager') then return new; end if;
  if not exists (select 1 from public.qy_unit_up(u.center_id) where kind = 'center') then return new; end if;
  if new.center_id is null or not exists (select 1 from public.qy_unit_up(new.center_id) where id = u.center_id) then
    raise exception 'طلب موظف المركز يكون على مركزه أو أحد بنوده فقط';
  end if;
  if new.budget_item_id is not null then raise exception 'طلب المركز يُصرف من رصيد المركز، فلا يُختار له بند من ميزانية الشركة'; end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_content_open(p_req text, p_status text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p_status = 'rejected'
      or (p_status in ('pending_decision','pending_manager','pending_senior','pending_executive')
          and not public.qy_has_approved(p_req));
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
CREATE OR REPLACE FUNCTION public.qy_deny(p_kind text, p_req text, p_msg text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare m text := public.qy_mode();
begin
  if m = 'off' then return; end if;
  if m = 'watch' then
    insert into public.qy_audit_alerts(kind, request_id, actor_auth, actor_user, details)
    values (p_kind, p_req, auth.uid(), public.qy_me(), p_msg);
    return;
  end if;
  raise exception 'غير مصرّح: %', p_msg;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_agent_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.center_id is not null and not exists(select 1 from public.centers where id = new.center_id and company_id = new.company_id) then
    raise exception 'المركز المختار لا يتبع هذه الشركة';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_bills(p_company text)
 RETURNS TABLE(id bigint, content text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية'; end if;
  return query select g.id, g.content from public.gateway_imports g where g.company_id = p_company and g.kind = 'bills' order by g.id;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb; f jsonb; v_imp bigint; v_first bigint; v_ins int := 0; v_dup int := 0; v_pend int := 0; v_lock int := 0; v_id bigint;
  v_center text; v_pct numeric; v_gross numeric; v_fee numeric; v_share numeric; v_me text := public.qy_me(); v_open date;
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية رفع ملفات البوابة'; end if;
  for f in select * from jsonb_array_elements(coalesce(p_files,'[]'::jsonb)) loop
    insert into public.gateway_imports(company_id, account_id, kind, file_name, date_from, date_to, rows_count, content, uploaded_by)
    values (p_company, nullif(p_account,''), f->>'kind', f->>'file_name', nullif(f->>'date_from','')::date, nullif(f->>'date_to','')::date, coalesce((f->>'rows_count')::int,0), f->>'content', v_me)
    returning id into v_imp;
    if v_first is null then v_first := v_imp; end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_center := nullif(r->>'center_id','');
    if v_center is not null and not exists (select 1 from public.centers where id = v_center and company_id = p_company) then v_center := null; end if;
    v_gross := coalesce((r->>'gross')::numeric,0); v_fee := coalesce((r->>'fee')::numeric,0);
    if exists (select 1 from public.center_ledger where company_id = p_company and receipt = r->>'receipt') then v_dup := v_dup + 1; continue; end if;
    if v_center is not null then
      v_open := public.qy_center_open_date(v_center);
      if v_open is not null and (r->>'txn_date')::date <= v_open then v_lock := v_lock + 1; continue; end if;
      v_pct := public.qy_center_pct(v_center, false); v_share := public.qy_round3((v_gross - v_fee) * v_pct / 100);
    else v_pct := null; v_share := null; v_pend := v_pend + 1; end if;
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, method, purpose, agent, receipt, order_ref, source, import_id, created_by)
    values (p_company, v_center, 'subscription', (r->>'txn_date')::date, v_gross, v_fee, v_pct, v_share,
            case when v_center is null then null else public.qy_round3(v_gross - v_fee - v_share) end,
            r->>'method', r->>'purpose', r->>'agent', r->>'receipt', nullif(r->>'order_ref',''), 'import', v_first, v_me)
    returning id into v_id;
    if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
      insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone');
    end if;
    v_ins := v_ins + 1;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'pending', v_pend, 'locked', v_lock);
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_file(p_id bigint)
 RETURNS TABLE(file_name text, content text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g public.gateway_imports%rowtype;
begin
  select * into g from public.gateway_imports where id = p_id;
  if not found or not public.qy_can_import(g.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  return query select g.file_name, g.content;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_rematch(p_company text, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb; n int := 0; v_id bigint;
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_id := (r->>'id')::bigint;
    update public.center_ledger set agent = r->>'agent', purpose = coalesce(nullif(purpose,''), r->>'purpose')
     where id = v_id and company_id = p_company and center_id is null and not voided and coalesce(agent,'') = '' and coalesce(r->>'agent','') <> '';
    if found then
      n := n + 1;
      if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
        update public.center_ledger_payers set payer_name = coalesce(nullif(r->>'payer_name',''), payer_name), payer_phone = coalesce(nullif(r->>'payer_phone',''), payer_phone) where ledger_id = v_id;
        if not found then insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone'); end if;
      end if;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gateway_stale()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c record; v_last date; v_days int;
begin
  for c in select id, import_stale_days from public.companies loop
    select max(date_to) into v_last from public.gateway_imports where company_id = c.id and kind = 'statement';
    if v_last is null then continue; end if;
    v_days := current_date - v_last;
    if v_days > coalesce(c.import_stale_days, 7) then
      perform public.qy_push_enqueue(public.qy_push_admins('import_stale'), 'ملفات بوابة الدفع متأخرة', 'آخر كشف مرفوع حتى '||to_char(v_last,'DD/MM/YYYY')||' ('||v_days||' يوماً)', 'import_stale', null, c.id||':'||to_char(current_date,'YYYYMMDD'), now());
    end if;
  end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_gen_verify_code(p_prefix text DEFAULT 'Q8'::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  alpha constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';  -- بلا الأحرف المتشابهة (0 O 1 I L)
  b bytea; s text := ''; i int;
  pre text := case when p_prefix ~ '^[A-Z0-9]{2}$' then p_prefix else 'Q8' end;
begin
  b := uuid_send(gen_random_uuid());
  for i in 0..7 loop s := s || substr(alpha, (get_byte(b, i) % 31) + 1, 1); end loop;
  return pre || '-' || substr(s,1,4) || '-' || substr(s,5,4);
end $function$
;
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
CREATE OR REPLACE FUNCTION public.qy_guard_users()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- التشغيل من لوحة SQL (بلا مستخدم مسجّل) أو من مدير النظام مسموح
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  if new.role                is distinct from old.role
  or new.auth_id             is distinct from old.auth_id
  or new.company_id          is distinct from old.company_id
  or new.is_general          is distinct from old.is_general
  or new.can_manage_recurring is distinct from old.can_manage_recurring
  or new.level_id            is distinct from old.level_id
  or new.manager_id          is distinct from old.manager_id
  or new.request_approver_id is distinct from old.request_approver_id
  or new.next_approver_id    is distinct from old.next_approver_id
  or new.exec_substitute_id  is distinct from old.exec_substitute_id
  or new.no_request_approver is distinct from old.no_request_approver
  or new.no_next_approver    is distinct from old.no_next_approver
  or new.approval_deadline_days is distinct from old.approval_deadline_days
  or new.escalate_mode       is distinct from old.escalate_mode
  or new.escalate_user_id    is distinct from old.escalate_user_id
  or new.direct_to_transfer is distinct from old.direct_to_transfer or new.center_id           is distinct from old.center_id then
    raise exception 'غير مصرّح: لا يمكن تعديل الدور أو الشركة أو سلسلة الاعتماد إلا بمدير النظام';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_handover_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text; v_ok boolean;
begin
  if auth.uid() is null or public.is_admin() then
    if tg_op='INSERT' then
      if new.needs_approval then new.status := 'pending'; else new.status := 'accepted'; new.decided_at := now(); end if;
    elsif new.status<>old.status then new.decided_at := now(); end if;
    return new;
  end if;
  v_me := public.qy_me();
  if tg_op = 'INSERT' then
    if new.from_user_id is distinct from v_me then raise exception 'غير مصرّح: الإسناد من حسابك أنت أو بمدير النظام'; end if;
    select exists(select 1 from public.users u where u.id = new.to_user_id and (u.company_id = new.company_id or u.is_general
           or exists(select 1 from public.user_companies uc where uc.user_id=u.id and uc.company_id=new.company_id))) into v_ok;
    if not v_ok then raise exception 'المستلِم غير مرتبط بشركة الإسناد'; end if;
    if new.needs_approval then new.status := 'pending'; else new.status := 'accepted'; new.decided_at := now(); end if;
    new.created_by := v_me;
    return new;
  end if;
  if (to_jsonb(new) - array['status','reject_reason','suggested_user_id','decided_at'])
     is distinct from (to_jsonb(old) - array['status','reject_reason','suggested_user_id','decided_at']) then
    raise exception 'غير مصرّح: لا يُعدَّل الإسناد بعد إنشائه، ألغِه وأنشئ غيره';
  end if;
  if new.status is distinct from old.status then
    if old.status = 'pending' and old.to_user_id = v_me and new.status in ('accepted','rejected') then
      if new.status = 'rejected' and coalesce(btrim(new.reject_reason),'') = '' then raise exception 'اكتب سبب الرفض'; end if;
      new.decided_at := now(); return new;
    elsif old.from_user_id = v_me and old.status in ('pending','accepted') and new.status = 'cancelled' then
      new.decided_at := now(); return new;
    end if;
    raise exception 'غير مصرّح: هذا التغيير في حالة الإسناد';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_has_approved(p_req text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.request_approval_steps s where s.request_id = p_req and s.status = 'approved');
$function$
;
CREATE OR REPLACE FUNCTION public.qy_history_stamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.auth_uid := auth.uid();
  if auth.uid() is not null and new.user_id is not null and not public.is_admin()
     and new.user_id is distinct from public.qy_me() then
    perform public.qy_deny('hist_forge', new.request_id, 'لا يُكتب في سجل الطلب باسم مستخدم آخر');
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_hr_approver(p_company text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with ok as (select u.id from public.users u where not coalesce(u.is_suspended,false) and (p_company is null or public.qy_user_in_company(u.id, p_company))),
  m as (
    select u.* from public.users u join public.org_departments d on d.id = u.org_dept_id
    where d.func = 'hr' and coalesce(u.is_general,false) and u.id in (select id from ok)),
  head as (select id from m order by (case when m.manager_id is null or m.manager_id not in (select id from m) then 0 else 1 end), m.name limit 1)
  select coalesce(
    (select c.hr_approver_id from public.companies c where c.id = p_company and c.hr_approver_id in (select id from ok)),
    (select s.value from public.app_settings s where s.key = 'hr_approver_id' and s.value in (select id from ok)),
    (select id from head));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_is_approver(p_req text, p_me text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.request_approval_steps s where s.request_id = p_req
                 and public.qy_step_actor_ok(s.approver_id, p_req, p_me));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_is_cfo()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.users u where u.auth_id = auth.uid() and u.role = 'cfo');
$function$
;
CREATE OR REPLACE FUNCTION public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric, p_share_pct numeric, p_purpose text, p_note text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ce public.centers%rowtype; v_pct numeric; v_share numeric; v_net numeric; v_id bigint; v_me text := public.qy_me();
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_kind not in ('opening','subscription','support','manual','adjust') then raise exception 'نوع غير صالح'; end if;
  if ce.stage = 'closed' and p_kind <> 'adjust' then raise exception 'المركز مغلق'; end if;
  if p_kind = 'opening' then
    if exists (select 1 from public.center_ledger where center_id = p_center and kind = 'opening' and not voided) then raise exception 'للمركز رصيد افتتاحي مسجّل، ألغِه أولاً ثم أدخل الجديد'; end if;
    v_pct := 0;
  elsif p_kind = 'manual' or p_kind = 'adjust' then v_pct := coalesce(p_share_pct, 0);
  else v_pct := coalesce(p_share_pct, public.qy_center_pct(p_center, p_kind = 'support')); end if;
  v_share := public.qy_round3((coalesce(p_gross,0) - coalesce(p_fee,0)) * v_pct / 100);
  v_net := public.qy_round3(coalesce(p_gross,0) - coalesce(p_fee,0) - v_share);
  insert into public.center_ledger(company_id, center_id, kind, entry_date, period_from, period_to, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by)
  values (ce.company_id, p_center, p_kind, coalesce(p_date, current_date), p_from, p_to, coalesce(p_gross,0), coalesce(p_fee,0), v_pct, v_share, v_net, p_purpose, p_note, 'manual', v_me)
  returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_ledger_assign(p_ids bigint[], p_center text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ce public.centers%rowtype; n int := 0; l public.center_ledger%rowtype; v_pct numeric; v_share numeric; v_open date;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not public.qy_can_import(ce.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  v_pct := public.qy_center_pct(p_center, false); v_open := public.qy_center_open_date(p_center);
  for l in select * from public.center_ledger where id = any(p_ids) and center_id is null and company_id = ce.company_id loop
    if v_open is not null and l.entry_date <= v_open then continue; end if;
    v_share := public.qy_round3((l.gross - l.gateway_fee) * v_pct / 100);
    update public.center_ledger set center_id = p_center, company_pct = v_pct, company_share = v_share, net = public.qy_round3(l.gross - l.gateway_fee - v_share) where id = l.id;
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_ledger_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v date;
begin
  if new.center_id is null or new.kind in ('opening','adjust') or new.voided then return new; end if;
  if tg_op = 'UPDATE' and new.center_id is not distinct from old.center_id and new.entry_date = old.entry_date then return new; end if;
  v := public.qy_center_open_date(new.center_id);
  if v is not null and new.entry_date <= v then
    raise exception 'حركة بتاريخ % في يوم الرصيد الافتتاحي لـ«%» (%) أو قبله، فلا تدخل الدفتر', to_char(new.entry_date,'DD-MM-YYYY'),
      (select name from public.centers where id = new.center_id), to_char(v,'DD-MM-YYYY');
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_ledger_void(p_id bigint, p_void boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
CREATE OR REPLACE FUNCTION public.qy_login_suspended(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$ select coalesce((select u.is_suspended from public.users u join auth.users a on a.id = u.auth_id where lower(a.email) = lower(p_email) limit 1), false) $function$
;
CREATE OR REPLACE FUNCTION public.qy_me()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.id from public.users u where u.auth_id = auth.uid() limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_mode()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select value from public.app_settings where key = 'server_rules'), 'watch');
$function$
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
CREATE OR REPLACE FUNCTION public.qy_owner_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text := public.qy_me();
begin
  if old.id <> public.qy_owner_id() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then raise exception 'حساب مالك النظام لا يُحذف'; end if;
  if v_me is null or v_me = old.id then
    if new.role is distinct from 'admin' then raise exception 'حساب مالك النظام يبقى مدير نظام'; end if;
    if coalesce(new.is_suspended,false) then raise exception 'حساب مالك النظام لا يُوقف'; end if;
    return new;
  end if;
  if new.role is distinct from old.role or coalesce(new.is_suspended,false) is distinct from coalesce(old.is_suspended,false)
     or new.phone is distinct from old.phone or new.name is distinct from old.name or new.company_id is distinct from old.company_id
     or new.auth_id is distinct from old.auth_id or new.email is distinct from old.email then
    raise exception 'لا يعدّل بيانات حساب مالك النظام إلا صاحبه';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_owner_id()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$select 'admin'::text$function$
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
CREATE OR REPLACE FUNCTION public.qy_page_level_ok(p_company text, p_key text, p_levels text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = p_key and p.level = any(p_levels));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_paper_proxy(p_approver text, p_me text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p_me is not null and exists (select 1 from public.users a where a.id = p_approver and a.paper_approval and p_me = any(a.paper_proxy_ids));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_people_names()
 RETURNS TABLE(id text, name text, role text, job_title text, company_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select distinct u.id, u.name, u.role, u.job_title, u.company_id
  from public.users u
  where u.id in (select s.approver_id from public.request_approval_steps s join public.requests r on r.id = s.request_id
                 where r.created_by_id = public.qy_me());
$function$
;
CREATE OR REPLACE FUNCTION public.qy_prj_can_read(p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.can_see_company(p_company) and (
    public.is_finance()
    or exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'executive_manager')
    or public.qy_prj_level_ok(p_company, array['read','edit','full']));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_prj_can_write(p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.can_see_company(p_company) and (public.is_finance() or public.qy_prj_level_ok(p_company, array['edit','full']));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_prj_level_ok(p_company text, p_levels text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = 'projects' and p.level = any(p_levels));
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
CREATE OR REPLACE FUNCTION public.qy_purge_logs()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a int; b int;
begin
  delete from public.qy_client_events where at < now() - interval '90 days'; get diagnostics a = row_count;
  delete from public.qy_audit_alerts where at < now() - interval '90 days'; get diagnostics b = row_count;
  return a + b;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_admins(p_key text)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(array_agg(distinct s.user_id), '{}') from public.push_subscriptions s join public.users u on u.id = s.user_id
  where u.role = 'admin' and coalesce(u.is_suspended,false) = false and p_key = any(s.admin_events);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_push_alert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public.qy_push_enqueue(public.qy_push_admins('security'), 'تنبيه أمان في النظام', null, 'adm_sec', null, new.id::text, now());
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_clientev()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.kind in ('login_failed','login_suspended') then
    perform public.qy_push_enqueue(public.qy_push_admins('login_fail'), case when new.kind='login_suspended' then 'محاولة دخول بحساب موقوف' else 'محاولة دخول فاشلة' end, null, 'adm_login', null, new.id::text, now());
  elsif new.kind in ('js_error','db_error') then
    perform public.qy_push_enqueue(public.qy_push_admins('error'), 'خطأ في النظام عند أحد المستخدمين', null, 'adm_err', null, new.id::text, now());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_custody()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.status = 'awaiting_receipt' and (tg_op = 'INSERT' or old.status is distinct from 'awaiting_receipt') then
    perform public.qy_push_enqueue(array[new.holder_id], 'عهدة بانتظار تأكيد استلامك', null, 'custody', new.request_id, new.id::text, now());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_enqueue(p_users text[], p_title text, p_body text, p_kind text, p_req text, p_ref text, p_after timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text := public.qy_me(); u text;
begin
  foreach u in array coalesce(p_users,'{}') loop
    continue when u is null;
    continue when u = v_me and not exists (select 1 from public.push_subscriptions s join public.users us on us.id = s.user_id
                                            where s.user_id = u and us.role = 'admin' and 'self' = any(s.admin_events));
    continue when not exists (select 1 from public.push_subscriptions s where s.user_id = u);
    insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
    values (u, p_title, p_body, case when p_req is null then null else '?req='||p_req end, 'qy-'||p_kind||'-'||coalesce(p_req,''), p_kind, p_req, p_ref, coalesce(p_after, now()),
            p_kind||':'||coalesce(p_ref,p_req,'')||':'||floor(extract(epoch from now()))::text)
    on conflict (user_id, dedupe) do nothing;
  end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_flush()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp', 'extensions'
AS $function$
declare v_url text; v_secret text; v_items jsonb; v_n int := 0;
begin
  select value into v_url from public.push_config where key = 'push_url';
  select value into v_secret from public.push_config where key = 'push_secret';
  if v_url is null or v_secret is null then return 0; end if;
  perform public.qy_push_scan();
  perform public.qy_push_late();
  delete from public.push_outbox where created_at < now() - interval '7 days';
  create temp table if not exists _qy_due(id bigint) on commit drop;
  truncate _qy_due;
  insert into _qy_due select id from public.push_outbox where sent_at is null and send_after <= now() order by id limit 200 for update skip locked;
  update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and (
    o.send_after < now() - interval '6 hours'
    or (o.kind = 'step' and not exists (select 1 from public.request_approval_steps s join public.requests r on r.id = s.request_id
         where s.id = split_part(o.ref,':',1) and s.status = 'pending' and not coalesce(r.is_cancelled,false) and r.status = 'pending_decision'
           and (r.review_until is null or r.review_until <= now())))
    or (o.kind = 'late' and not exists (select 1 from public.request_approval_steps s where s.id = o.ref and s.status = 'pending'))
    or (o.kind = 'new' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)))
    or (o.kind = 'acc' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)
         and r.status = o.ref and (r.review_until is null or r.review_until <= now()))));
  update public.push_outbox o set body = r.number from _qy_due d, public.requests r where o.id = d.id and o.kind = 'new' and o.sent_at is null and r.id = o.request_id;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',o.user_id,'title',o.title,'body',o.body,'url',o.url,'tag',o.tag)), '[]'::jsonb), count(*)
    into v_items, v_n from public.push_outbox o join _qy_due d on d.id = o.id where o.sent_at is null;
  if v_n > 0 then
    perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type','application/json','x-push-secret',v_secret), body := jsonb_build_object('items', v_items));
    update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and o.sent_at is null;
  end if;
  return v_n;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_hist()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype;
begin
  if new.action = 'إلغاء الاعتماد الورقي' and new.note like '%|ids:%' then
    select * into r from public.requests where id = new.request_id;
    perform public.qy_push_enqueue(string_to_array(split_part(new.note,'|ids:',2), ','), 'أُلغي الاعتماد الورقي — لم يعد عليك تسجيله', r.number, 'paper_off', new.request_id, new.id::text, now());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_late()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r record; v_k timestamp := now() at time zone 'Asia/Kuwait'; v_h int := extract(hour from v_k); v_dow int := extract(dow from v_k);
        v_slot text; v_adm text[]; v_late numeric; u text; v_users text[]; v_cfo text[];
begin
  v_adm := public.qy_push_admins('late');
  for r in
    select s.id sid, s.approver_id, s.activated_at, rq.id rid, rq.number, rq.created_by_id, rq.company_id,
           c.late_from_hour, c.late_to_hour, c.late_repeat_hours, c.late_copy_days, c.late_max_days, c.late_weekend, c.deadline_day_mode,
           case when coalesce(a.approval_deadline_days,-1) >= 0 then a.approval_deadline_days else greatest(coalesce(c.default_deadline_days,0),0) end dl
      from public.request_approval_steps s
      join public.requests rq on rq.id = s.request_id
      join public.companies c on c.id = rq.company_id
      left join public.users a on a.id = s.approver_id
     where s.status = 'pending' and s.activated_at is not null and c.late_on
       and rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false)
       and (rq.review_until is null or rq.review_until <= now())
     limit 200
  loop
    continue when r.dl = 0;
    if r.late_weekend = 'fri_sat' and v_dow in (5,6) then continue; end if;
    if r.late_weekend = 'fri' and v_dow = 5 then continue; end if;
    continue when v_h < r.late_from_hour or v_h >= r.late_to_hour;
    v_late := extract(epoch from (now() - r.activated_at))/86400.0 - r.dl;
    if r.deadline_day_mode <> 'calendar' then
      v_late := v_late - (select count(*) from generate_series(r.activated_at::date, current_date - 1, interval '1 day') g(d) where extract(dow from g.d) in (5,6));
    end if;
    continue when v_late < 0 or v_late > r.late_max_days;
    v_slot := current_date::text || ':' || (v_h / greatest(r.late_repeat_hours,1))::text;
    v_users := array[r.approver_id];
    insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
    select x, 'طلب متأخر بانتظار إجراءك', r.number, '?req='||r.rid, 'qy-late-'||r.rid, 'late', r.rid, r.sid, now(), 'late:'||r.sid||':'||v_slot
      from unnest(v_users) x where exists (select 1 from public.push_subscriptions p where p.user_id = x)
    on conflict (user_id, dedupe) do nothing;
    if v_adm is not null then
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      select x, 'طلب متأخر عند '||coalesce((select name from public.users where id=r.approver_id),''), r.number, '?req='||r.rid, 'qy-lateadm-'||r.rid, 'late', r.rid, r.sid, now(), 'lateadm:'||r.sid||':'||v_slot
        from unnest(v_adm) x where x <> r.approver_id
      on conflict (user_id, dedupe) do nothing;
    end if;
    if v_late >= r.late_copy_days then
      v_users := public.qy_push_role_users(r.company_id, array['cfo']) || array[r.created_by_id];
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      select distinct x, 'طلب متأخر عند '||coalesce((select name from public.users where id=r.approver_id),''), r.number, '?req='||r.rid, 'qy-latecopy-'||r.rid, 'late', r.rid, r.sid, now(), 'latecopy:'||r.sid||':'||v_slot
        from unnest(v_users) x where x is not null and x <> r.approver_id and not (x = any(coalesce(v_adm,'{}')))
         and exists (select 1 from public.push_subscriptions p where p.user_id = x)
      on conflict (user_id, dedupe) do nothing;
    end if;
  end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_new()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_who text;
begin
  perform public.qy_push_enqueue(public.qy_push_admins('new'), 'طلب جديد في النظام', null, 'new', new.id, new.id, greatest(now(), coalesce(new.review_until, now())));
  if new.number is null then
    select name into v_who from public.users where id = new.created_by_id;
    perform public.qy_push_enqueue(public.qy_push_admins('review'), 'طلب قيد المراجعة', 'أنشأه '||coalesce(v_who,'مستخدم'), 'adm_review', new.id, 'c:'||new.id, now());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_note()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text := public.qy_me(); v_name text;
begin
  if v_me is null then return; end if;
  if exists (select 1 from public.push_outbox o where o.kind = 'adm_note' and o.ref like v_me||':%' and o.created_at > now() - interval '1 minute') then return; end if;
  select name into v_name from public.users where id = v_me;
  perform public.qy_push_enqueue(public.qy_push_admins('note'), 'ملحوظة جديدة في الشات', 'من '||coalesce(v_name,''), 'adm_note', null, v_me||':'||floor(extract(epoch from now()))::text, now());
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_overrun()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n text;
begin
  select number into n from public.requests where id = new.request_id;
  perform public.qy_push_enqueue(public.qy_push_admins('overrun'), 'تجاوز ميزانية في طلب', n, 'adm_over', new.request_id, new.id::text, now());
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_pwreset()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public.qy_push_enqueue(public.qy_push_admins('pwreset'), 'طلب إعادة تعيين كلمة مرور', null, 'adm_pw', null, new.id::text, now());
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_release()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.review_until is not null and new.review_until <= now() and (old.review_until is null or old.review_until > now()) then
    update public.push_outbox set send_after = now() where request_id = new.id and sent_at is null and send_after > now();
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_req()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_after timestamptz := greatest(now(), coalesce(new.review_until, now()));
begin
  if coalesce(new.is_cancelled,false) and not coalesce(old.is_cancelled,false) then
    perform public.qy_push_enqueue(public.qy_push_admins('cancel'), 'أُلغي طلب', new.number, 'adm_cancel', new.id, new.id, now());
  end if;
  if new.status is distinct from old.status and not coalesce(new.is_cancelled,false) then
    if new.status in ('pending_transfer_request','pending_disbursement','pending_accountant') then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['accountant']), 'طلب بانتظار إجراءك', new.number, 'acc', new.id, new.status, v_after);
    elsif new.status = 'pending_transfer_approval' then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['cfo']), 'تحويل بانتظار اعتمادك', new.number, 'acc', new.id, new.status, v_after);
    end if;
    if new.status = 'completed' then
      perform public.qy_push_enqueue(public.qy_push_admins('paid'), 'تم صرف طلب', new.number, 'adm_paid', new.id, new.status, now());
    end if;
    if old.status = 'pending_decision' and new.status in ('pending_transfer_request','pending_disbursement','pending_accountant','pending_transfer_approval','completed') then
      perform public.qy_push_enqueue(array[new.created_by_id], 'اعتُمد طلبك', new.number, 'ok', new.id, new.status, now());
    elsif new.status = 'completed' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'تم صرف طلبك', new.number, 'paid', new.id, new.status, now());
    elsif new.status = 'rejected' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'رُفض طلبك', new.number, 'rej', new.id, new.status, now());
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_review_del()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_who text;
begin
  if old.number is null then
    select name into v_who from public.users where id = old.created_by_id;
    perform public.qy_push_enqueue(public.qy_push_admins('review'), 'حُذف طلب قبل إرساله', 'حذفه '||coalesce(v_who,'مستخدم')||' أثناء المراجعة', 'adm_review_del', null, 'd:'||old.id, now());
  end if;
  return old;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_role_users(p_company text, p_roles text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(array_agg(u.id), '{}') from public.users u
  where u.role = any(p_roles) and coalesce(u.is_suspended,false) = false
    and (u.company_id = p_company or exists (select 1 from public.user_companies c where c.user_id = u.id and c.company_id = p_company));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_push_scan()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r record; v_ids text[]; u text;
begin
  v_ids := public.qy_push_admins('structure');
  if coalesce(array_length(v_ids,1),0) = 0 then return; end if;
  for r in
    select q.id, q.number, q.why from (
      select rq.id, rq.number, 'no_step' why from public.requests rq
       where rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false) and (rq.review_until is null or rq.review_until <= now())
         and not exists (select 1 from public.request_approval_steps s where s.request_id = rq.id and s.status = 'pending')
      union all
      select rq.id, rq.number, 'bad_approver' from public.requests rq join public.request_approval_steps s on s.request_id = rq.id and s.status = 'pending' and s.activated_at is not null
       left join public.users ap on ap.id = s.approver_id
       where rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false) and (ap.id is null or coalesce(ap.is_suspended,false))
    ) q limit 50
  loop
    foreach u in array v_ids loop
      continue when exists (select 1 from public.push_outbox o where o.user_id = u and o.kind = 'adm_struct' and o.ref = r.id||':'||r.why||':'||current_date::text);
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      values (u, 'مشكلة في مسار طلب', r.number, '?req='||r.id, 'qy-adm_struct-'||r.id, 'adm_struct', r.id, r.id||':'||r.why||':'||current_date::text, now(), 'adm_struct:'||r.id||':'||r.why||':'||current_date::text)
      on conflict (user_id, dedupe) do nothing;
    end loop;
  end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_set_all(p_endpoint text, p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set all_requests = coalesce(p_on,false) where endpoint = p_endpoint and user_id = public.qy_me();
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_set_events(p_endpoint text, p_events text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error','note','late','review','self','import_stale'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_step()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype; a public.users%rowtype; v_after timestamptz; v_ids text[];
begin
  select * into r from public.requests where id = new.request_id;
  if not found then return new; end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.qy_push_enqueue(public.qy_push_admins('approve'), case when coalesce(new.method,'')='paper' then 'اعتماد ورقي في طلب' else 'اعتماد في طلب' end, r.number, 'adm_ok', r.id, new.id, now());
  elsif new.status = 'rejected' and (tg_op = 'INSERT' or old.status is distinct from 'rejected') then
    perform public.qy_push_enqueue(public.qy_push_admins('reject'), 'رفض في طلب', r.number, 'adm_rej', r.id, new.id, now());
  end if;
  if new.status = 'approved' and coalesce(new.method,'') = 'paper' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.qy_push_enqueue(array[r.created_by_id], 'اعتُمد طلبك ورقياً', r.number, 'paper_ok', r.id, new.id, now());
  end if;
  if new.status = 'pending' and new.activated_at is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'pending' or old.activated_at is distinct from new.activated_at) then
    select * into a from public.users where id = new.approver_id;
    v_after := greatest(now(), coalesce(r.review_until, now()));
    v_ids := array[new.approver_id];
    if a.exec_substitute_id is not null then v_ids := v_ids || a.exec_substitute_id; end if;
    v_ids := v_ids || coalesce((select array_agg(h.to_user_id) from public.qy_handovers h
        where h.from_user_id = new.approver_id and h.status = 'accepted' and h.company_id = r.company_id
          and h.from_date <= current_date and (h.to_date is null or h.to_date >= current_date)
          and (h.scope_all or r.id = any(h.request_ids))), '{}');
    perform public.qy_push_enqueue(v_ids, 'طلب بانتظار اعتمادك', r.number, 'step', r.id, new.id||':'||floor(extract(epoch from new.activated_at))::text, v_after);
    if a.paper_approval and coalesce(array_length(a.paper_proxy_ids,1),0) > 0 then
      perform public.qy_push_enqueue(a.paper_proxy_ids, 'بانتظار تسجيل اعتماد ورقي', r.number||' — عن '||a.name, 'step', r.id, new.id||':p:'||floor(extract(epoch from new.activated_at))::text, v_after);
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text := public.qy_me();
begin
  if v_me is null then raise exception 'غير مسجَّل الدخول'; end if;
  if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'اشتراك غير صالح'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
  insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, ua) values (v_me, p_endpoint, p_p256dh, p_auth, left(p_ua,200));
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_unsubscribe(p_endpoint text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = public.qy_me();
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_push_userchg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.role is distinct from old.role then
    perform public.qy_push_enqueue(public.qy_push_admins('userchange'), 'تغيير صلاحية مستخدم', null, 'adm_user', null, new.id||':role', now());
  elsif coalesce(new.is_suspended,false) is distinct from coalesce(old.is_suspended,false) then
    perform public.qy_push_enqueue(public.qy_push_admins('userchange'), case when new.is_suspended then 'إيقاف مستخدم' else 'إعادة تفعيل مستخدم' end, null, 'adm_user', null, new.id||':susp', now());
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_requests_del_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return old; end if;
  if not (coalesce(old.created_by_id = public.qy_me(), false) and old.number is null and not public.qy_has_approved(old.id)) then
    perform public.qy_deny('req_delete', old.id, 'حذف الطلب لمدير النظام فقط (ولصاحبه قبل أن يأخذ رقماً)');
  end if;
  return old;
end $function$
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
  if (new.reason, new.detailed_reason, new.total_amount, new.is_recurring, new.created_by_id, new.center_id, new.fast_tracked, new.salutation_text, new.reference_text)
     is distinct from
     (old.reason, old.detailed_reason, old.total_amount, old.is_recurring, old.created_by_id, old.center_id, old.fast_tracked, old.salutation_text, old.reference_text) then
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
CREATE OR REPLACE FUNCTION public.qy_requests_vcode()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c text;
begin
  if tg_op = 'INSERT' then
    loop
      c := public.qy_gen_verify_code((select co.verify_prefix from public.companies co where co.id = new.company_id));
      exit when not exists (select 1 from public.requests where verify_code = c);
    end loop;
    new.verify_code := c;                                   -- يُفرض من الخادم ويتجاهل ما يرسله المتصفح
  elsif old.verify_code is not null then
    new.verify_code := old.verify_code;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_round3(x numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select round(coalesce(x,0), 3) $function$
;
CREATE OR REPLACE FUNCTION public.qy_route_income()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_pct numeric; v_share numeric;
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
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_set_chain(p_req text, p_reset boolean DEFAULT false)
 RETURNS SETOF request_approval_steps
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_short_name(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when p is null or btrim(p) = '' then p
    when array_length(regexp_split_to_array(btrim(p), '\s+'), 1) = 1 then btrim(p)
    else (regexp_split_to_array(btrim(p), '\s+'))[1] || ' ' ||
         left((regexp_split_to_array(btrim(p), '\s+'))[array_length(regexp_split_to_array(btrim(p), '\s+'), 1)], 1) || '.'
  end;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_step_actor_core(p_approver text, p_req text, p_me text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p_me is not null and (
       p_approver = p_me
    or exists (select 1 from public.users a where a.id = p_approver and a.exec_substitute_id = p_me)
    or exists (select 1 from public.qy_handovers h join public.requests r on r.id = p_req
               where h.from_user_id = p_approver and h.to_user_id = p_me and h.status = 'accepted'
                 and h.company_id = r.company_id and h.from_date <= current_date
                 and (h.to_date is null or h.to_date >= current_date)
                 and (h.scope_all or p_req = any(h.request_ids))));
$function$
;
CREATE OR REPLACE FUNCTION public.qy_step_actor_ok(p_approver text, p_req text, p_me text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.qy_step_actor_core(p_approver, p_req, p_me) or public.qy_paper_proxy(p_approver, p_me);
$function$
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
CREATE OR REPLACE FUNCTION public.qy_steps_watch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me text; r public.requests%rowtype;
begin
  if new.status is distinct from old.status and new.status in ('approved','rejected') then
    new.acted_by_auth := auth.uid();
  end if;
  if new.status = 'pending' and old.status is distinct from 'pending' then
    new.method := null; new.paper_path := null; new.paper_signed_at := null; new.recorded_by := null;
  end if;
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return new; end if;
  v_me := public.qy_me();
  select * into r from public.requests where id = old.request_id;
  if new.id is distinct from old.id or new.request_id is distinct from old.request_id
     or new.approver_id is distinct from old.approver_id or new.kind is distinct from old.kind
     or new.escalated_from is distinct from old.escalated_from then
    perform public.qy_deny('step_identity', old.request_id, 'لا يُغيَّر صاحب خطوة الاعتماد ولا طلبها');
  end if;
  if new.status is distinct from old.status then
    if new.status in ('approved','rejected') then
      if not (old.status = 'pending' and public.qy_step_actor_ok(old.approver_id, old.request_id, v_me)) then
        perform public.qy_deny('step_status_by_other', old.request_id, 'الاعتماد أو الرفض لصاحب الخطوة أو نائبه أو من أُسندت إليه فقط');
      end if;
      if coalesce(new.method,'') = 'paper' then
        if new.paper_path is null or new.paper_signed_at is null or new.paper_signed_at > current_date
           or new.recorded_by is distinct from v_me
           or not public.qy_paper_proxy(old.approver_id, v_me) then
          perform public.qy_deny('step_paper_bad', old.request_id, 'التسجيل الورقي للمسجِّل المحدد فقط، ومعه الورقة الموقعة وتاريخ توقيع صحيح');
        end if;
      elsif not public.qy_step_actor_core(old.approver_id, old.request_id, v_me) then
        perform public.qy_deny('step_paper_only', old.request_id, 'المسجِّل الورقي يسجّل اعتماداً ورقياً بالورقة الموقعة فقط');
      end if;
    elsif new.status = 'skipped' then
      if not (old.status = 'pending' and public.qy_is_approver(old.request_id, v_me)) then
        perform public.qy_deny('step_skip', old.request_id, 'لا تُتخطّى خطوة اعتماد إلا بقرار معتمِد على الطلب نفسه');
      end if;
    elsif new.status = 'pending' then
      if not ((coalesce(r.created_by_id = v_me, false) or public.is_finance())
              and r.status in ('pending_decision','rejected')) then
        perform public.qy_deny('step_reset', old.request_id, 'إعادة ضبط المسار لصاحب الطلب قبل إعادة إرساله');
      end if;
    else
      perform public.qy_deny('step_status_bad', old.request_id, 'حالة خطوة غير معروفة');
    end if;
  else
    if (new.method, new.paper_path, new.paper_signed_at, new.recorded_by)
       is distinct from (old.method, old.paper_path, old.paper_signed_at, old.recorded_by) then
      perform public.qy_deny('step_paper_edit', old.request_id, 'لا يُعدَّل التسجيل الورقي بعد حفظه');
    end if;
    if (new.sequence_order, new.activated_at, new.acted_at, new.note, new.role_label)
        is distinct from (old.sequence_order, old.activated_at, old.acted_at, old.note, old.role_label) then
      if not (coalesce(r.created_by_id = v_me, false) or public.qy_is_approver(old.request_id, v_me) or public.is_finance()) then
        perform public.qy_deny('step_edit', old.request_id, 'تعديل خطوات طلب ليس لك فيه دور');
      end if;
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_supplier_pick(p_company text)
 RETURNS TABLE(id text, name text, name_en text, iban text, bank_name text, account_name text, activity text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.name, c.name_en, c.iban, c.bank_name, c.account_name, c.activity
  from public.clients c
  where c.company_id = p_company and c.party in ('supplier','both') and c.status = 'active' and public.can_see_company(p_company)
  order by c.name;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_transfer_allowed(p_creator text, p_center text, p_total numeric, p_fast boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select u.direct_to_transfer from public.users u where u.id = p_creator), false)
      or (coalesce(p_fast,false) and exists (
            select 1 from public.users u join public.centers c on c.id = u.center_id
            where u.id = p_creator and c.id = p_center and c.min_threshold is not null
              and coalesce(p_total,0) <= c.min_threshold
              and (coalesce(c.skip_dept_manager,false) or coalesce(c.skip_senior_manager,false) or coalesce(c.skip_executive_manager,false))));
$function$
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
CREATE OR REPLACE FUNCTION public.qy_tx_request_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_total numeric;
begin
  if new.source_type = 'request' and new.reverses_id is null and new.refund_of_id is null and new.source_id is not null then
    perform pg_advisory_xact_lock(hashtext('req_tx:' || new.source_id));
    if exists (select 1 from public.transactions x
               where x.source_type = 'request' and x.source_id = new.source_id and x.reverses_id is null and x.refund_of_id is null
                 and not exists (select 1 from public.transactions z where z.reverses_id = x.id)) then
      raise exception 'صرف هذا الطلب مسجَّل في الدفتر من قبل';
    end if;
    select total_amount into v_total from public.requests where id = new.source_id;
    if v_total is not null and abs(coalesce(new.amount,0) - v_total) > 0.0005 then
      raise exception 'مبلغ قيد الصرف لا يطابق مبلغ الطلب';
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_desc text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_monthly numeric, p_annual numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ce public.centers%rowtype;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'نهاية المدة قبل بدايتها'; end if;
  update public.centers set pre_pay = coalesce(p_pre_pay,false), continuous = coalesce(p_continuous,false), period_from = p_from, period_to = p_to,
    item_budget = p_budget, monthly_budget = p_monthly, annual_budget = p_annual where id = p_center;
end $function$
;
CREATE OR REPLACE FUNCTION public.qy_unit_root(p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select id from public.qy_unit_up(p_center) where kind = 'center' order by depth desc limit 1), p_center);
$function$
;
CREATE OR REPLACE FUNCTION public.qy_unit_suspended(p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select c.name from public.qy_unit_up(p_center) u join public.centers c on c.id = u.id where c.stage = 'suspended' order by u.depth limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_unit_up(p_center text)
 RETURNS TABLE(id text, kind text, depth integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with recursive up(id, kind, parent_id, depth) as (
    select c.id, c.kind, c.parent_id, 0 from public.centers c where c.id = p_center
    union all
    select c.id, c.kind, c.parent_id, up.depth + 1 from public.centers c join up on c.id = up.parent_id where up.depth < 50)
  select id, kind, depth from up;
$function$
;
CREATE OR REPLACE FUNCTION public.qy_user_dept_func(p_user text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select d.func from public.users u join public.org_departments d on d.id = u.org_dept_id where u.id = p_user and coalesce(u.is_general,false);
$function$
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
CREATE OR REPLACE FUNCTION public.qy_users_private()
 RETURNS TABLE(id text, iban text, national_id text, id_file_data text, bank_file_data text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.id, u.iban, u.national_id, u.id_file_data, u.bank_file_data
  from public.users u where u.id = public.qy_me() or public.is_admin();
$function$
;
CREATE OR REPLACE FUNCTION public.recurring_due_dates(t recurring_templates, p_to date)
 RETURNS SETOF date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  eff date := coalesce(t.generation_from, t.start_date);
  n int := 0; k int := 0; step int; d date; d0 date; lastd date; base date; dom int;
begin
  if t.frequency in ('weekly','biweekly') then
    step := case when t.frequency = 'weekly' then 7 else 14 end;
    d := eff + (((t.weekday - extract(dow from eff)::int) + 7) % 7);
    loop
      exit when d > p_to
             or (t.end_mode = 'date' and d > t.end_date)
             or (t.end_mode = 'count' and n >= t.max_count);
      return next d; n := n + 1; d := d + step;
    end loop;
  else
    step := case t.frequency when 'monthly' then 1 when 'bimonthly' then 2 when 'quarterly' then 3 when 'semiannual' then 6 else 12 end;
    base := date_trunc('month', t.start_date)::date;
    dom  := coalesce(t.day_of_month, extract(day from t.start_date)::int);
    loop
      exit when k > 1200;
      d0 := (base + make_interval(months => k * step))::date;
      lastd := (d0 + interval '1 month' - interval '1 day')::date;
      if t.day_mode = 'last_day' then d := lastd;
      else d := d0 + (least(dom, extract(day from lastd)::int) - 1);
      end if;
      k := k + 1;
      continue when d < eff;
      exit when d > p_to
             or (t.end_mode = 'date' and d > t.end_date)
             or (t.end_mode = 'count' and n >= t.max_count);
      return next d; n := n + 1;
    end loop;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.recurring_templates_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  me public.users;
  rpc boolean := coalesce(current_setting('app.recurring_rpc', true), '') = '1';
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    select * into me from public.users where auth_id = auth.uid() limit 1;
    new.status := 'pending_approval';
    new.approved_by_id := null; new.approved_by := null; new.approved_at := null; new.generation_from := null;
    if me.id is not null then new.created_by_id := me.id; new.created_by := me.name; end if;
    return new;
  end if;

  if rpc then return new; end if;

  new.company_id := old.company_id;
  new.created_by_id := old.created_by_id; new.created_by := old.created_by; new.created_at := old.created_at;
  new.approved_by_id := old.approved_by_id; new.approved_by := old.approved_by; new.approved_at := old.approved_at;
  new.generation_from := old.generation_from;

  if old.status = 'ended' and new.status <> 'ended' then
    raise exception 'القالب المنتهي لا يُعاد فتحه — أنشئ قالباً جديداً';
  end if;
  if old.status = 'pending_approval' and new.status <> 'pending_approval' then
    raise exception 'القالب بانتظار الاعتماد ولا يتغير حاله إلا باعتماد المعتمد';
  end if;

  if old.status in ('active','paused') and
     row(new.amount,new.amount_mode,new.direction,new.budget_item_id,new.beneficiary,new.frequency,new.day_mode,
         new.day_of_month,new.weekday,new.auto_post,new.center_id,new.start_date,new.end_mode,new.end_date,new.max_count)
     is distinct from
     row(old.amount,old.amount_mode,old.direction,old.budget_item_id,old.beneficiary,old.frequency,old.day_mode,
         old.day_of_month,old.weekday,old.auto_post,old.center_id,old.start_date,old.end_mode,old.end_date,old.max_count)
  then
    new.status := 'pending_approval';
    new.approved_by_id := null; new.approved_by := null; new.approved_at := null;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.refresh_recurring()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.is_finance() then return 0; end if;
  return public.generate_recurring_occurrences(null);
end $function$
;
CREATE OR REPLACE FUNCTION public.request_password_reset(p_phone text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u record; recent int;
begin
  if coalesce(trim(p_phone),'') = '' then
    return 'ok';
  end if;

  select id, company_id into u
    from public.users
   where phone = trim(p_phone)
   limit 1;

  if not found then
    return 'ok';                      -- لا نكشف أن الرقم غير مسجَّل
  end if;

  select count(*) into recent
    from public.password_reset_requests
   where phone = trim(p_phone)
     and status = 'pending'
     and requested_at > now() - interval '5 minutes';

  if recent > 0 then
    return 'ok';                      -- كبح الإغراق: طلب واحد كل خمس دقائق
  end if;

  insert into public.password_reset_requests (phone, user_id, company_id)
  values (trim(p_phone), u.id, u.company_id);

  return 'ok';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.resolve_login_email(p_login text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text; v_phone text;
begin
  v := lower(trim(coalesce(p_login,'')));
  if v = '' then return ''; end if;
  if position('@' in v) > 0 then return v; end if;

  select phone into v_phone from public.users where lower(phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;

  select u.phone into v_phone
    from public.login_aliases a join public.users u on u.id = a.user_id
   where lower(a.phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;

  return v || '@qyam.local';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.restore_skipped_occurrence(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.recurring_occurrences;
begin
  select * into o from public.recurring_occurrences where id = p_id for update;
  if not found or o.status <> 'skipped' then raise exception 'هذا الاستحقاق ليس متخطّىً'; end if;
  if not (public.is_finance() and public.can_see_company(o.company_id)) then raise exception 'غير مصرّح'; end if;
  update public.recurring_occurrences
     set status = 'proposed', no_auto = true, handled_by_id = null, handled_by = null, handled_at = null,
         note = 'استُعيد بعد التخطي'
   where id = p_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.skip_recurring_occurrence(p_id uuid, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.recurring_occurrences; me public.users;
begin
  select * into me from public.users where auth_id = auth.uid() limit 1;
  select * into o from public.recurring_occurrences where id = p_id for update;
  if not found or o.status <> 'proposed' then raise exception 'هذا القيد غير متاح للتخطي'; end if;
  if not (public.is_finance() and public.can_see_company(o.company_id)) then raise exception 'غير مصرّح'; end if;
  update public.recurring_occurrences
     set status = 'skipped', note = p_note, handled_by_id = me.id, handled_by = me.name, handled_at = now()
   where id = p_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.transactions_after_reverse()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.transactions;
begin
  if new.reverses_id is null then return new; end if;
  select * into o from public.transactions where id = new.reverses_id;
  if found and o.source_type = 'revenue' and o.source_id is not null then
    delete from public.budget_revenues where id = o.source_id;
  end if;
  update public.recurring_occurrences
     set status = 'proposed', transaction_id = null, no_auto = true,
         handled_by_id = null, handled_by = null, handled_at = null,
         note = 'أُعيد إلى الكشف بعد عكس قيده'
   where transaction_id = new.reverses_id and status = 'posted';
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.transactions_are_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  raise exception 'سطور دفتر الحركات لا تُعدَّل ولا تُحذف — التصحيح يكون بقيد عاكس';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.transactions_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.transactions; s numeric;
begin
  if new.reverses_id is not null then
    perform pg_advisory_xact_lock(hashtext(new.reverses_id::text));
    select * into o from public.transactions where id = new.reverses_id;
    if not found then raise exception 'الحركة المراد عكسها غير موجودة'; end if;
    if o.reverses_id is not null then raise exception 'هذه حركة عاكسة ولا تُعكس'; end if;
    if exists (select 1 from public.transactions x where x.reverses_id = o.id) then
      raise exception 'هذه الحركة عُكست من قبل';
    end if;
    if exists (select 1 from public.transactions r where r.refund_of_id = o.id
               and not exists (select 1 from public.transactions z where z.reverses_id = r.id)) then
      raise exception 'عليها استرداد قائم. اعكس الاستردادات أولاً أو اكتفِ بها';
    end if;
    if new.amount is distinct from o.amount or new.direction = o.direction or new.company_id is distinct from o.company_id then
      raise exception 'حركة العكس تكون بنفس المبلغ وعكس الاتجاه وفي الشركة نفسها';
    end if;
  end if;
  if new.refund_of_id is not null then
    perform pg_advisory_xact_lock(hashtext(new.refund_of_id::text));
    select * into o from public.transactions where id = new.refund_of_id;
    if not found then raise exception 'الحركة الأصلية للاسترداد غير موجودة'; end if;
    if new.source_type <> 'refund' then raise exception 'نوع حركة الاسترداد غير صحيح'; end if;
    if o.company_id <> new.company_id then raise exception 'الاسترداد من شركة أخرى غير مسموح'; end if;
    if o.reverses_id is not null or o.source_type = 'refund' then
      raise exception 'لا يُسترد من حركة عاكسة أو من استرداد آخر';
    end if;
    if exists (select 1 from public.transactions x where x.reverses_id = o.id) then
      raise exception 'هذه الحركة معكوسة، فلا استرداد عليها';
    end if;
    if new.direction = o.direction then raise exception 'اتجاه الاسترداد يجب أن يعاكس اتجاه الحركة الأصلية'; end if;
    select coalesce(sum(r.amount), 0) into s from public.transactions r
      where r.refund_of_id = o.id and not exists (select 1 from public.transactions z where z.reverses_id = r.id);
    if s + new.amount > o.amount then
      raise exception 'مجموع الاستردادات يتجاوز المبلغ الأصلي. المتبقي للاسترداد: %', to_char(o.amount - s, 'FM999999990.000');
    end if;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.users_keep_one_admin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if old.role = 'admin' and (tg_op = 'DELETE' or new.role is distinct from 'admin') then
    if not exists (select 1 from public.users u where u.role = 'admin' and u.id <> old.id) then
      raise exception 'لا يمكن حذف آخر مدير نظام أو تغيير صفته. أنشئ مدير نظام آخر أولاً';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
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
    'signature_mode','signature_color','signature_width','signature_data','stamp_data','stamp_data_2','notif_seen_at','idle_minutes','skip_review','avatar_data',
    'paper_approval','paper_proxy_ids'];
  p text;
begin
  if new.paper_proxy_ids is distinct from old.paper_proxy_ids or new.paper_approval is distinct from old.paper_approval then
    if coalesce(array_length(new.paper_proxy_ids,1),0) > 3 then raise exception 'ثلاثة مسجِّلين كحد أقصى'; end if;
    if new.paper_approval and coalesce(array_length(new.paper_proxy_ids,1),0) = 0 then raise exception 'اختر مسجِّلاً واحداً على الأقل'; end if;
    foreach p in array coalesce(new.paper_proxy_ids,'{}') loop
      if p = new.id then raise exception 'لا تختر نفسك مسجِّلاً'; end if;
      if not exists (select 1 from public.users x where x.id = p and coalesce(x.is_suspended,false) = false and (
             x.is_general
          or new.is_general
          or x.company_id = new.company_id
          or exists (select 1 from public.user_companies a where a.user_id = p and (a.company_id = new.company_id
                       or a.company_id in (select b.company_id from public.user_companies b where b.user_id = new.id)))
          or x.company_id in (select b.company_id from public.user_companies b where b.user_id = new.id))) then
        raise exception 'المسجِّل يجب أن يكون من نفس الشركة أو مستخدماً عاماً';
      end if;
    end loop;
  end if;
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
CREATE OR REPLACE FUNCTION public.verify_request(p_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_hdr json; v_ip text; v_key text; v_out jsonb; v_lvl int; v_req public.requests%rowtype;
  v_short boolean; v_ben boolean; v_full boolean;
begin
  begin
    v_hdr := current_setting('request.headers', true)::json;
    v_ip := nullif(trim(split_part(coalesce(v_hdr->>'cf-connecting-ip', v_hdr->>'x-real-ip', v_hdr->>'x-forwarded-for', ''), ',', 1)), '');
  exception when others then v_ip := null; end;
  if v_ip is not null then
    delete from public.qy_verify_hits where at < now() - interval '1 day';
    if (select count(*) from public.qy_verify_hits where ip = v_ip and at > now() - interval '1 minute') >= 30 then
      return null;
    end if;
    insert into public.qy_verify_hits(ip) values (v_ip);
  end if;
  v_key := upper(trim(coalesce(p_id, '')));
  if v_key = '' or length(v_key) > 80 then return null; end if;
  select * into v_req from public.requests r where r.verify_code = v_key or r.id = trim(p_id) limit 1;
  if v_req.id is null then return null; end if;

  select case when value ~ '^[1-7]$' then value::int else 5 end into v_lvl from public.app_settings where key = 'verify_level';
  v_lvl := coalesce(v_lvl, 5);
  v_ben   := v_lvl <> 4;                    -- هل تُعرض قائمة المستفيدين
  v_full  := v_lvl in (1, 5);               -- هل يُعرض البيان وسجل الاعتماد
  v_short := v_lvl in (3, 5, 6);               -- هل تُختصر الأسماء

  v_out := jsonb_build_object(
      'level', v_lvl, 'number', v_req.number, 'verify_code', v_req.verify_code, 'total_amount', v_req.total_amount,
      'date_greg', v_req.date_greg, 'date_hijri', v_req.date_hijri,
      'status', v_req.status, 'is_cancelled', v_req.is_cancelled,
      'company', (select jsonb_build_object('name_ar', c.name_ar, 'logo_data', c.logo_data, 'brand_logo_data', c.brand_logo_data)
                  from public.companies c where c.id = v_req.company_id));
  if v_ben and v_lvl in (6, 7) then          -- أسماء فقط، بلا أي مبالغ
    v_out := v_out || jsonb_build_object('beneficiaries', coalesce((select jsonb_agg(jsonb_build_object(
        'name', case when v_short then public.qy_short_name(b.name) else b.name end) order by b.id)
        from public.request_beneficiaries b where b.request_id = v_req.id), '[]'::jsonb));
  elsif v_ben then
    v_out := v_out || jsonb_build_object('beneficiaries', coalesce((select jsonb_agg(jsonb_build_object(
        'name', case when v_short then public.qy_short_name(b.name) else b.name end,
        'amount', b.amount, 'deduction', b.deduction, 'extra', b.extra) order by b.id)
        from public.request_beneficiaries b where b.request_id = v_req.id), '[]'::jsonb));
  end if;
  if v_full then
    v_out := v_out || jsonb_build_object('reason', v_req.reason, 'history', coalesce((select jsonb_agg(jsonb_build_object(
        'step', h.step, 'actor', case when v_short then public.qy_short_name(h.actor) else h.actor end,
        'action', h.action, 'time', h.time, 'created_at', h.created_at) order by h.created_at)
        from public.request_history h where h.request_id = v_req.id), '[]'::jsonb));
  end if;
  return v_out;
end $function$
;

-- ═══ صلاحيات تنفيذ الدوال ═══
revoke all on function public._get_manager_for_company(p_user_id text, p_company_id text) from public, anon, authenticated; grant execute on function public._get_manager_for_company(p_user_id text, p_company_id text) to service_role;
revoke all on function public._post_recurring_one(o recurring_occurrences, t recurring_templates, amt numeric, by_id text, by_name text, p_note text) from public, anon, authenticated; grant execute on function public._post_recurring_one(o recurring_occurrences, t recurring_templates, amt numeric, by_id text, by_name text, p_note text) to service_role;
revoke all on function public._user_has_company(p_user_id text, p_company_id text) from public, anon, authenticated; grant execute on function public._user_has_company(p_user_id text, p_company_id text) to service_role;
revoke all on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) from public, anon, authenticated; grant execute on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) to authenticated; grant execute on function public.admin_create_user(p_id text, p_phone text, p_password text, p_name text, p_role text, p_center_id text, p_manager_id text, p_company_id text, p_is_general boolean, p_level_id text) to service_role;
revoke all on function public.admin_remove_login_alias(p_phone text) from public, anon, authenticated; grant execute on function public.admin_remove_login_alias(p_phone text) to authenticated; grant execute on function public.admin_remove_login_alias(p_phone text) to service_role;
revoke all on function public.admin_set_login_phone(p_user_id text, p_phone text) from public, anon, authenticated; grant execute on function public.admin_set_login_phone(p_user_id text, p_phone text) to authenticated; grant execute on function public.admin_set_login_phone(p_user_id text, p_phone text) to service_role;
revoke all on function public.admin_set_password(p_user_id text, p_password text) from public, anon, authenticated; grant execute on function public.admin_set_password(p_user_id text, p_password text) to authenticated; grant execute on function public.admin_set_password(p_user_id text, p_password text) to service_role;
revoke all on function public.admin_set_suspended(p_user_id text, p_suspended boolean, p_note text) from public, anon, authenticated; grant execute on function public.admin_set_suspended(p_user_id text, p_suspended boolean, p_note text) to authenticated; grant execute on function public.admin_set_suspended(p_user_id text, p_suspended boolean, p_note text) to service_role;
revoke all on function public.approve_recurring_template(p_id uuid) from public, anon, authenticated; grant execute on function public.approve_recurring_template(p_id uuid) to authenticated; grant execute on function public.approve_recurring_template(p_id uuid) to service_role;
revoke all on function public.assign_due_request_numbers() from public, anon, authenticated; grant execute on function public.assign_due_request_numbers() to service_role;
revoke all on function public.auto_escalate_overdue_approvals() from public, anon, authenticated; grant execute on function public.auto_escalate_overdue_approvals() to service_role;
revoke all on function public.budget_item_balance(p_item_id text) from public, anon, authenticated; grant execute on function public.budget_item_balance(p_item_id text) to service_role;
revoke all on function public.budget_item_company_profit(p_item_id text) from public, anon, authenticated; grant execute on function public.budget_item_company_profit(p_item_id text) to service_role;
revoke all on function public.can_manage_recurring() from public, anon, authenticated; grant execute on function public.can_manage_recurring() to authenticated; grant execute on function public.can_manage_recurring() to service_role;
revoke all on function public.can_see_company(p_company_id text) from public, anon, authenticated; grant execute on function public.can_see_company(p_company_id text) to anon; grant execute on function public.can_see_company(p_company_id text) to authenticated; grant execute on function public.can_see_company(p_company_id text) to service_role;
revoke all on function public.can_see_request(p_request_id text) from public, anon, authenticated; grant execute on function public.can_see_request(p_request_id text) to authenticated; grant execute on function public.can_see_request(p_request_id text) to service_role;
revoke all on function public.ensure_petty_expenses_item(p_company_id text) from public, anon, authenticated; grant execute on function public.ensure_petty_expenses_item(p_company_id text) to service_role;
revoke all on function public.finalize_request(p_id text) from public, anon, authenticated; grant execute on function public.finalize_request(p_id text) to authenticated; grant execute on function public.finalize_request(p_id text) to service_role;
revoke all on function public.generate_recurring_occurrences(p_template uuid) from public, anon, authenticated; grant execute on function public.generate_recurring_occurrences(p_template uuid) to service_role;
revoke all on function public.is_admin() from public, anon, authenticated; grant execute on function public.is_admin() to authenticated; grant execute on function public.is_admin() to service_role;
revoke all on function public.is_finance() from public, anon, authenticated; grant execute on function public.is_finance() to authenticated; grant execute on function public.is_finance() to service_role;
revoke all on function public.kw_today() from public, anon, authenticated; grant execute on function public.kw_today() to authenticated; grant execute on function public.kw_today() to service_role;
revoke all on function public.me() from public, anon, authenticated; grant execute on function public.me() to authenticated; grant execute on function public.me() to service_role;
revoke all on function public.my_company_ids() from public, anon, authenticated; grant execute on function public.my_company_ids() to authenticated; grant execute on function public.my_company_ids() to service_role;
revoke all on function public.my_user_id() from public, anon, authenticated; grant execute on function public.my_user_id() to authenticated; grant execute on function public.my_user_id() to service_role;
revoke all on function public.next_request_number(p_prefix text, p_suffix text) from public, anon, authenticated; grant execute on function public.next_request_number(p_prefix text, p_suffix text) to service_role;
revoke all on function public.on_company_created() from public, anon, authenticated; grant execute on function public.on_company_created() to authenticated; grant execute on function public.on_company_created() to service_role;
revoke all on function public.post_recurring_occurrences(p_items jsonb) from public, anon, authenticated; grant execute on function public.post_recurring_occurrences(p_items jsonb) to authenticated; grant execute on function public.post_recurring_occurrences(p_items jsonb) to service_role;
revoke all on function public.prevent_protected_budget_item_delete() from public, anon, authenticated; grant execute on function public.prevent_protected_budget_item_delete() to authenticated; grant execute on function public.prevent_protected_budget_item_delete() to service_role;
revoke all on function public.qy_att_limit() from public, anon, authenticated; grant execute on function public.qy_att_limit() to authenticated; grant execute on function public.qy_att_limit() to service_role;
revoke all on function public.qy_backup_dump() from public, anon, authenticated; grant execute on function public.qy_backup_dump() to service_role;
revoke all on function public.qy_ben_guard() from public, anon, authenticated; grant execute on function public.qy_ben_guard() to authenticated; grant execute on function public.qy_ben_guard() to service_role;
revoke all on function public.qy_ben_is_edit(p_req text, p_op text) from public, anon, authenticated; grant execute on function public.qy_ben_is_edit(p_req text, p_op text) to service_role;
revoke all on function public.qy_bm_guard() from public, anon, authenticated; grant execute on function public.qy_bm_guard() to service_role;
revoke all on function public.qy_budget_figures(p_company text) from public, anon, authenticated; grant execute on function public.qy_budget_figures(p_company text) to authenticated; grant execute on function public.qy_budget_figures(p_company text) to service_role;
revoke all on function public.qy_can_import(p_company text) from public, anon, authenticated; grant execute on function public.qy_can_import(p_company text) to authenticated; grant execute on function public.qy_can_import(p_company text) to service_role;
revoke all on function public.qy_can_payroll(p_user text, p_company text) from public, anon, authenticated; grant execute on function public.qy_can_payroll(p_user text, p_company text) to anon; grant execute on function public.qy_can_payroll(p_user text, p_company text) to authenticated; grant execute on function public.qy_can_payroll(p_user text, p_company text) to service_role;
revoke all on function public.qy_can_transfer(p_root text) from public, anon, authenticated; grant execute on function public.qy_can_transfer(p_root text) to authenticated; grant execute on function public.qy_can_transfer(p_root text) to service_role;
revoke all on function public.qy_center_balance(p_center text) from public, anon, authenticated; grant execute on function public.qy_center_balance(p_center text) to service_role;
revoke all on function public.qy_center_balances(p_company text) from public, anon, authenticated; grant execute on function public.qy_center_balances(p_company text) to authenticated; grant execute on function public.qy_center_balances(p_company text) to service_role;
revoke all on function public.qy_center_can_see(p_center text) from public, anon, authenticated; grant execute on function public.qy_center_can_see(p_center text) to authenticated; grant execute on function public.qy_center_can_see(p_center text) to service_role;
revoke all on function public.qy_center_freeze() from public, anon, authenticated; grant execute on function public.qy_center_freeze() to authenticated; grant execute on function public.qy_center_freeze() to service_role;
revoke all on function public.qy_center_guard() from public, anon, authenticated; grant execute on function public.qy_center_guard() to authenticated; grant execute on function public.qy_center_guard() to service_role;
revoke all on function public.qy_center_open_date(p_center text) from public, anon, authenticated; grant execute on function public.qy_center_open_date(p_center text) to authenticated; grant execute on function public.qy_center_open_date(p_center text) to service_role;
revoke all on function public.qy_center_pct(p_center text, p_support boolean) from public, anon, authenticated; grant execute on function public.qy_center_pct(p_center text, p_support boolean) to service_role;
revoke all on function public.qy_center_set_stage(p_center text, p_stage text, p_note text) from public, anon, authenticated; grant execute on function public.qy_center_set_stage(p_center text, p_stage text, p_note text) to authenticated; grant execute on function public.qy_center_set_stage(p_center text, p_stage text, p_note text) to service_role;
revoke all on function public.qy_center_staff_guard() from public, anon, authenticated; grant execute on function public.qy_center_staff_guard() to authenticated; grant execute on function public.qy_center_staff_guard() to service_role;
revoke all on function public.qy_content_open(p_req text, p_status text) from public, anon, authenticated; grant execute on function public.qy_content_open(p_req text, p_status text) to authenticated; grant execute on function public.qy_content_open(p_req text, p_status text) to service_role;
revoke all on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) to authenticated; grant execute on function public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text) to service_role;
revoke all on function public.qy_custody_admin_undo(p_id bigint, p_reason text) from public, anon, authenticated; grant execute on function public.qy_custody_admin_undo(p_id bigint, p_reason text) to authenticated; grant execute on function public.qy_custody_admin_undo(p_id bigint, p_reason text) to service_role;
revoke all on function public.qy_custody_balance_settle(p_id bigint, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_balance_settle(p_id bigint, p_note text) to authenticated; grant execute on function public.qy_custody_balance_settle(p_id bigint, p_note text) to service_role;
revoke all on function public.qy_custody_chain(p_req text) from public, anon, authenticated; grant execute on function public.qy_custody_chain(p_req text) to service_role;
revoke all on function public.qy_custody_confirm(p_id bigint, p_time text) from public, anon, authenticated; grant execute on function public.qy_custody_confirm(p_id bigint, p_time text) to authenticated; grant execute on function public.qy_custody_confirm(p_id bigint, p_time text) to service_role;
revoke all on function public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text) from public, anon, authenticated; grant execute on function public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text) to service_role;
revoke all on function public.qy_custody_hist(p_k custodies, p_action text, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_hist(p_k custodies, p_action text, p_note text) to service_role;
revoke all on function public.qy_custody_ins_guard() from public, anon, authenticated; grant execute on function public.qy_custody_ins_guard() to service_role;
revoke all on function public.qy_custody_limits_check(p_holder text, p_company text, p_amount numeric, p_except bigint) from public, anon, authenticated; grant execute on function public.qy_custody_limits_check(p_holder text, p_company text, p_amount numeric, p_except bigint) to service_role;
revoke all on function public.qy_custody_line_delete(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_delete(p_id bigint) to authenticated; grant execute on function public.qy_custody_line_delete(p_id bigint) to service_role;
revoke all on function public.qy_custody_line_image(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_image(p_id bigint) to authenticated; grant execute on function public.qy_custody_line_image(p_id bigint) to service_role;
revoke all on function public.qy_custody_line_reopen(p_line bigint) from public, anon, authenticated; grant execute on function public.qy_custody_line_reopen(p_line bigint) to authenticated; grant execute on function public.qy_custody_line_reopen(p_line bigint) to service_role;
revoke all on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) from public, anon, authenticated; grant execute on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) to authenticated; grant execute on function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean, p_no_doc boolean, p_no_doc_reason text) to service_role;
revoke all on function public.qy_custody_nodoc_cap(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_nodoc_cap(p_id bigint) to authenticated; grant execute on function public.qy_custody_nodoc_cap(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_amount(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_amount(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_amount(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_check(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_check(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_check(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_limit(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_over_limit(p_id bigint) to authenticated; grant execute on function public.qy_custody_over_limit(p_id bigint) to service_role;
revoke all on function public.qy_custody_over_list(p_company text) from public, anon, authenticated; grant execute on function public.qy_custody_over_list(p_company text) to authenticated; grant execute on function public.qy_custody_over_list(p_company text) to service_role;
revoke all on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) from public, anon, authenticated; grant execute on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) to authenticated; grant execute on function public.qy_custody_request_close(p_id bigint, p_reviewer text, p_time text) to service_role;
revoke all on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) to authenticated; grant execute on function public.qy_custody_review_line(p_line bigint, p_ok boolean, p_note text) to service_role;
revoke all on function public.qy_custody_reviewer_done(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_reviewer_done(p_id bigint) to authenticated; grant execute on function public.qy_custody_reviewer_done(p_id bigint) to service_role;
revoke all on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) to authenticated; grant execute on function public.qy_custody_set_over(p_id bigint, p_mode text, p_value numeric, p_note text) to service_role;
revoke all on function public.qy_custody_sign(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_custody_sign(p_id bigint) to authenticated; grant execute on function public.qy_custody_sign(p_id bigint) to service_role;
revoke all on function public.qy_custody_sign_reject(p_id bigint, p_note text) from public, anon, authenticated; grant execute on function public.qy_custody_sign_reject(p_id bigint, p_note text) to authenticated; grant execute on function public.qy_custody_sign_reject(p_id bigint, p_note text) to service_role;
revoke all on function public.qy_custody_sync() from public, anon, authenticated; grant execute on function public.qy_custody_sync() to service_role;
revoke all on function public.qy_custody_update(p_req text, p_purpose text, p_due date) from public, anon, authenticated; grant execute on function public.qy_custody_update(p_req text, p_purpose text, p_due date) to authenticated; grant execute on function public.qy_custody_update(p_req text, p_purpose text, p_due date) to service_role;
revoke all on function public.qy_decision_chain(p_creator text, p_company text, p_total numeric) from public, anon, authenticated; grant execute on function public.qy_decision_chain(p_creator text, p_company text, p_total numeric) to service_role;
revoke all on function public.qy_deny(p_kind text, p_req text, p_msg text) from public, anon, authenticated; grant execute on function public.qy_deny(p_kind text, p_req text, p_msg text) to authenticated; grant execute on function public.qy_deny(p_kind text, p_req text, p_msg text) to service_role;
revoke all on function public.qy_gateway_agent_guard() from public, anon, authenticated; grant execute on function public.qy_gateway_agent_guard() to authenticated; grant execute on function public.qy_gateway_agent_guard() to service_role;
revoke all on function public.qy_gateway_bills(p_company text) from public, anon, authenticated; grant execute on function public.qy_gateway_bills(p_company text) to authenticated; grant execute on function public.qy_gateway_bills(p_company text) to service_role;
revoke all on function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) from public, anon, authenticated; grant execute on function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) to authenticated; grant execute on function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) to service_role;
revoke all on function public.qy_gateway_file(p_id bigint) from public, anon, authenticated; grant execute on function public.qy_gateway_file(p_id bigint) to authenticated; grant execute on function public.qy_gateway_file(p_id bigint) to service_role;
revoke all on function public.qy_gateway_rematch(p_company text, p_rows jsonb) from public, anon, authenticated; grant execute on function public.qy_gateway_rematch(p_company text, p_rows jsonb) to authenticated; grant execute on function public.qy_gateway_rematch(p_company text, p_rows jsonb) to service_role;
revoke all on function public.qy_gateway_stale() from public, anon, authenticated; grant execute on function public.qy_gateway_stale() to service_role;
revoke all on function public.qy_gen_verify_code(p_prefix text) from public, anon, authenticated; grant execute on function public.qy_gen_verify_code(p_prefix text) to authenticated; grant execute on function public.qy_gen_verify_code(p_prefix text) to service_role;
revoke all on function public.qy_gl_block_guard() from public, anon, authenticated; grant execute on function public.qy_gl_block_guard() to service_role;
revoke all on function public.qy_gl_can(p_company text) from public, anon, authenticated; grant execute on function public.qy_gl_can(p_company text) to authenticated; grant execute on function public.qy_gl_can(p_company text) to service_role;
revoke all on function public.qy_gl_copy_chart(p_from text, p_to text) from public, anon, authenticated; grant execute on function public.qy_gl_copy_chart(p_from text, p_to text) to authenticated; grant execute on function public.qy_gl_copy_chart(p_from text, p_to text) to service_role;
revoke all on function public.qy_gl_delete_account(p_company text, p_code text) from public, anon, authenticated; grant execute on function public.qy_gl_delete_account(p_company text, p_code text) to authenticated; grant execute on function public.qy_gl_delete_account(p_company text, p_code text) to service_role;
revoke all on function public.qy_gl_exp_of(p_item text, p_center text) from public, anon, authenticated; grant execute on function public.qy_gl_exp_of(p_item text, p_center text) to authenticated; grant execute on function public.qy_gl_exp_of(p_item text, p_center text) to service_role;
revoke all on function public.qy_gl_inc_of(p_item text) from public, anon, authenticated; grant execute on function public.qy_gl_inc_of(p_item text) to authenticated; grant execute on function public.qy_gl_inc_of(p_item text) to service_role;
revoke all on function public.qy_gl_journal(p_company text, p_from date, p_to date) from public, anon, authenticated; grant execute on function public.qy_gl_journal(p_company text, p_from date, p_to date) to authenticated; grant execute on function public.qy_gl_journal(p_company text, p_from date, p_to date) to service_role;
revoke all on function public.qy_gl_link(p_company text, p_target text, p_id text, p_field text, p_code text) from public, anon, authenticated; grant execute on function public.qy_gl_link(p_company text, p_target text, p_id text, p_field text, p_code text) to authenticated; grant execute on function public.qy_gl_link(p_company text, p_target text, p_id text, p_field text, p_code text) to service_role;
revoke all on function public.qy_gl_mark_exported(p_company text, p_month date, p_entries integer, p_total numeric, p_unlinked integer) from public, anon, authenticated; grant execute on function public.qy_gl_mark_exported(p_company text, p_month date, p_entries integer, p_total numeric, p_unlinked integer) to authenticated; grant execute on function public.qy_gl_mark_exported(p_company text, p_month date, p_entries integer, p_total numeric, p_unlinked integer) to service_role;
revoke all on function public.qy_gl_new_custody_account(p_company text, p_holder text) from public, anon, authenticated; grant execute on function public.qy_gl_new_custody_account(p_company text, p_holder text) to authenticated; grant execute on function public.qy_gl_new_custody_account(p_company text, p_holder text) to service_role;
revoke all on function public.qy_gl_save_account(p_company text, p_old_code text, p_code text, p_name text, p_kind text, p_parent text, p_is_group boolean, p_active boolean, p_note text) from public, anon, authenticated; grant execute on function public.qy_gl_save_account(p_company text, p_old_code text, p_code text, p_name text, p_kind text, p_parent text, p_is_group boolean, p_active boolean, p_note text) to authenticated; grant execute on function public.qy_gl_save_account(p_company text, p_old_code text, p_code text, p_name text, p_kind text, p_parent text, p_is_group boolean, p_active boolean, p_note text) to service_role;
revoke all on function public.qy_gl_trust_of(p_center text) from public, anon, authenticated; grant execute on function public.qy_gl_trust_of(p_center text) to authenticated; grant execute on function public.qy_gl_trust_of(p_center text) to service_role;
revoke all on function public.qy_guard_users() from public, anon, authenticated; grant execute on function public.qy_guard_users() to authenticated; grant execute on function public.qy_guard_users() to service_role;
revoke all on function public.qy_handover_guard() from public, anon, authenticated; grant execute on function public.qy_handover_guard() to authenticated; grant execute on function public.qy_handover_guard() to service_role;
revoke all on function public.qy_has_approved(p_req text) from public, anon, authenticated; grant execute on function public.qy_has_approved(p_req text) to authenticated; grant execute on function public.qy_has_approved(p_req text) to service_role;
revoke all on function public.qy_history_stamp() from public, anon, authenticated; grant execute on function public.qy_history_stamp() to authenticated; grant execute on function public.qy_history_stamp() to service_role;
revoke all on function public.qy_hr_approver(p_company text) from public, anon, authenticated; grant execute on function public.qy_hr_approver(p_company text) to anon; grant execute on function public.qy_hr_approver(p_company text) to authenticated; grant execute on function public.qy_hr_approver(p_company text) to service_role;
revoke all on function public.qy_is_approver(p_req text, p_me text) from public, anon, authenticated; grant execute on function public.qy_is_approver(p_req text, p_me text) to authenticated; grant execute on function public.qy_is_approver(p_req text, p_me text) to service_role;
revoke all on function public.qy_is_cfo() from public, anon, authenticated; grant execute on function public.qy_is_cfo() to authenticated; grant execute on function public.qy_is_cfo() to service_role;
revoke all on function public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric, p_share_pct numeric, p_purpose text, p_note text) from public, anon, authenticated; grant execute on function public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric, p_share_pct numeric, p_purpose text, p_note text) to authenticated; grant execute on function public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric, p_share_pct numeric, p_purpose text, p_note text) to service_role;
revoke all on function public.qy_ledger_assign(p_ids bigint[], p_center text) from public, anon, authenticated; grant execute on function public.qy_ledger_assign(p_ids bigint[], p_center text) to authenticated; grant execute on function public.qy_ledger_assign(p_ids bigint[], p_center text) to service_role;
revoke all on function public.qy_ledger_lock() from public, anon, authenticated; grant execute on function public.qy_ledger_lock() to authenticated; grant execute on function public.qy_ledger_lock() to service_role;
revoke all on function public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text) from public, anon, authenticated; grant execute on function public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text) to authenticated; grant execute on function public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text) to service_role;
revoke all on function public.qy_ledger_void(p_id bigint, p_void boolean) from public, anon, authenticated; grant execute on function public.qy_ledger_void(p_id bigint, p_void boolean) to authenticated; grant execute on function public.qy_ledger_void(p_id bigint, p_void boolean) to service_role;
revoke all on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) from public, anon, authenticated; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to anon; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to authenticated; grant execute on function public.qy_log_event(p_kind text, p_page text, p_message text, p_details text, p_phone text, p_device jsonb) to service_role;
revoke all on function public.qy_login_suspended(p_email text) from public, anon, authenticated; grant execute on function public.qy_login_suspended(p_email text) to anon; grant execute on function public.qy_login_suspended(p_email text) to authenticated; grant execute on function public.qy_login_suspended(p_email text) to service_role;
revoke all on function public.qy_me() from public, anon, authenticated; grant execute on function public.qy_me() to anon; grant execute on function public.qy_me() to authenticated; grant execute on function public.qy_me() to service_role;
revoke all on function public.qy_mode() from public, anon, authenticated; grant execute on function public.qy_mode() to authenticated; grant execute on function public.qy_mode() to service_role;
revoke all on function public.qy_monitor(p_company text, p_days integer) from public, anon, authenticated; grant execute on function public.qy_monitor(p_company text, p_days integer) to authenticated; grant execute on function public.qy_monitor(p_company text, p_days integer) to service_role;
revoke all on function public.qy_my_company_names() from public, anon, authenticated; grant execute on function public.qy_my_company_names() to authenticated; grant execute on function public.qy_my_company_names() to service_role;
revoke all on function public.qy_now_txt() from public, anon, authenticated; grant execute on function public.qy_now_txt() to authenticated; grant execute on function public.qy_now_txt() to service_role;
revoke all on function public.qy_owner_guard() from public, anon, authenticated; grant execute on function public.qy_owner_guard() to authenticated; grant execute on function public.qy_owner_guard() to service_role;
revoke all on function public.qy_owner_id() from public, anon, authenticated; grant execute on function public.qy_owner_id() to authenticated; grant execute on function public.qy_owner_id() to service_role;
revoke all on function public.qy_page_blocked(p_company text, p_key text) from public, anon, authenticated; grant execute on function public.qy_page_blocked(p_company text, p_key text) to service_role;
revoke all on function public.qy_page_level_ok(p_company text, p_key text, p_levels text[]) from public, anon, authenticated; grant execute on function public.qy_page_level_ok(p_company text, p_key text, p_levels text[]) to authenticated; grant execute on function public.qy_page_level_ok(p_company text, p_key text, p_levels text[]) to service_role;
revoke all on function public.qy_paper_proxy(p_approver text, p_me text) from public, anon, authenticated; grant execute on function public.qy_paper_proxy(p_approver text, p_me text) to authenticated; grant execute on function public.qy_paper_proxy(p_approver text, p_me text) to service_role;
revoke all on function public.qy_people_names() from public, anon, authenticated; grant execute on function public.qy_people_names() to authenticated; grant execute on function public.qy_people_names() to service_role;
revoke all on function public.qy_prj_can_read(p_company text) from public, anon, authenticated; grant execute on function public.qy_prj_can_read(p_company text) to authenticated; grant execute on function public.qy_prj_can_read(p_company text) to service_role;
revoke all on function public.qy_prj_can_write(p_company text) from public, anon, authenticated; grant execute on function public.qy_prj_can_write(p_company text) to authenticated; grant execute on function public.qy_prj_can_write(p_company text) to service_role;
revoke all on function public.qy_prj_level_ok(p_company text, p_levels text[]) from public, anon, authenticated; grant execute on function public.qy_prj_level_ok(p_company text, p_levels text[]) to authenticated; grant execute on function public.qy_prj_level_ok(p_company text, p_levels text[]) to service_role;
revoke all on function public.qy_public_brand() from public, anon, authenticated; grant execute on function public.qy_public_brand() to anon; grant execute on function public.qy_public_brand() to authenticated; grant execute on function public.qy_public_brand() to service_role;
revoke all on function public.qy_purge_logs() from public, anon, authenticated; grant execute on function public.qy_purge_logs() to service_role;
revoke all on function public.qy_push_admins(p_key text) from public, anon, authenticated; grant execute on function public.qy_push_admins(p_key text) to service_role;
revoke all on function public.qy_push_alert() from public, anon, authenticated; grant execute on function public.qy_push_alert() to authenticated; grant execute on function public.qy_push_alert() to service_role;
revoke all on function public.qy_push_clientev() from public, anon, authenticated; grant execute on function public.qy_push_clientev() to authenticated; grant execute on function public.qy_push_clientev() to service_role;
revoke all on function public.qy_push_custody() from public, anon, authenticated; grant execute on function public.qy_push_custody() to authenticated; grant execute on function public.qy_push_custody() to service_role;
revoke all on function public.qy_push_enqueue(p_users text[], p_title text, p_body text, p_kind text, p_req text, p_ref text, p_after timestamp with time zone) from public, anon, authenticated; grant execute on function public.qy_push_enqueue(p_users text[], p_title text, p_body text, p_kind text, p_req text, p_ref text, p_after timestamp with time zone) to service_role;
revoke all on function public.qy_push_flush() from public, anon, authenticated; grant execute on function public.qy_push_flush() to service_role;
revoke all on function public.qy_push_hist() from public, anon, authenticated; grant execute on function public.qy_push_hist() to authenticated; grant execute on function public.qy_push_hist() to service_role;
revoke all on function public.qy_push_late() from public, anon, authenticated; grant execute on function public.qy_push_late() to service_role;
revoke all on function public.qy_push_new() from public, anon, authenticated; grant execute on function public.qy_push_new() to authenticated; grant execute on function public.qy_push_new() to service_role;
revoke all on function public.qy_push_note() from public, anon, authenticated; grant execute on function public.qy_push_note() to authenticated; grant execute on function public.qy_push_note() to service_role;
revoke all on function public.qy_push_overrun() from public, anon, authenticated; grant execute on function public.qy_push_overrun() to authenticated; grant execute on function public.qy_push_overrun() to service_role;
revoke all on function public.qy_push_pwreset() from public, anon, authenticated; grant execute on function public.qy_push_pwreset() to authenticated; grant execute on function public.qy_push_pwreset() to service_role;
revoke all on function public.qy_push_release() from public, anon, authenticated; grant execute on function public.qy_push_release() to service_role;
revoke all on function public.qy_push_req() from public, anon, authenticated; grant execute on function public.qy_push_req() to authenticated; grant execute on function public.qy_push_req() to service_role;
revoke all on function public.qy_push_review_del() from public, anon, authenticated; grant execute on function public.qy_push_review_del() to authenticated; grant execute on function public.qy_push_review_del() to service_role;
revoke all on function public.qy_push_role_users(p_company text, p_roles text[]) from public, anon, authenticated; grant execute on function public.qy_push_role_users(p_company text, p_roles text[]) to service_role;
revoke all on function public.qy_push_scan() from public, anon, authenticated; grant execute on function public.qy_push_scan() to service_role;
revoke all on function public.qy_push_set_all(p_endpoint text, p_on boolean) from public, anon, authenticated; grant execute on function public.qy_push_set_all(p_endpoint text, p_on boolean) to authenticated; grant execute on function public.qy_push_set_all(p_endpoint text, p_on boolean) to service_role;
revoke all on function public.qy_push_set_events(p_endpoint text, p_events text[]) from public, anon, authenticated; grant execute on function public.qy_push_set_events(p_endpoint text, p_events text[]) to authenticated; grant execute on function public.qy_push_set_events(p_endpoint text, p_events text[]) to service_role;
revoke all on function public.qy_push_step() from public, anon, authenticated; grant execute on function public.qy_push_step() to authenticated; grant execute on function public.qy_push_step() to service_role;
revoke all on function public.qy_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text) from public, anon, authenticated; grant execute on function public.qy_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text) to authenticated; grant execute on function public.qy_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text) to service_role;
revoke all on function public.qy_push_unsubscribe(p_endpoint text) from public, anon, authenticated; grant execute on function public.qy_push_unsubscribe(p_endpoint text) to authenticated; grant execute on function public.qy_push_unsubscribe(p_endpoint text) to service_role;
revoke all on function public.qy_push_userchg() from public, anon, authenticated; grant execute on function public.qy_push_userchg() to authenticated; grant execute on function public.qy_push_userchg() to service_role;
revoke all on function public.qy_requests_del_guard() from public, anon, authenticated; grant execute on function public.qy_requests_del_guard() to authenticated; grant execute on function public.qy_requests_del_guard() to service_role;
revoke all on function public.qy_requests_guard() from public, anon, authenticated; grant execute on function public.qy_requests_guard() to authenticated; grant execute on function public.qy_requests_guard() to service_role;
revoke all on function public.qy_requests_ins_guard() from public, anon, authenticated; grant execute on function public.qy_requests_ins_guard() to authenticated; grant execute on function public.qy_requests_ins_guard() to service_role;
revoke all on function public.qy_requests_type_lock() from public, anon, authenticated; grant execute on function public.qy_requests_type_lock() to service_role;
revoke all on function public.qy_requests_vcode() from public, anon, authenticated; grant execute on function public.qy_requests_vcode() to authenticated; grant execute on function public.qy_requests_vcode() to service_role;
revoke all on function public.qy_round3(x numeric) from public, anon, authenticated; grant execute on function public.qy_round3(x numeric) to authenticated; grant execute on function public.qy_round3(x numeric) to service_role;
revoke all on function public.qy_route_income() from public, anon, authenticated; grant execute on function public.qy_route_income() to authenticated; grant execute on function public.qy_route_income() to service_role;
revoke all on function public.qy_set_chain(p_req text, p_reset boolean) from public, anon, authenticated; grant execute on function public.qy_set_chain(p_req text, p_reset boolean) to authenticated; grant execute on function public.qy_set_chain(p_req text, p_reset boolean) to service_role;
revoke all on function public.qy_short_name(p text) from public, anon, authenticated; grant execute on function public.qy_short_name(p text) to authenticated; grant execute on function public.qy_short_name(p text) to service_role;
revoke all on function public.qy_step_actor_core(p_approver text, p_req text, p_me text) from public, anon, authenticated; grant execute on function public.qy_step_actor_core(p_approver text, p_req text, p_me text) to authenticated; grant execute on function public.qy_step_actor_core(p_approver text, p_req text, p_me text) to service_role;
revoke all on function public.qy_step_actor_ok(p_approver text, p_req text, p_me text) from public, anon, authenticated; grant execute on function public.qy_step_actor_ok(p_approver text, p_req text, p_me text) to service_role;
revoke all on function public.qy_steps_ins_del_guard() from public, anon, authenticated; grant execute on function public.qy_steps_ins_del_guard() to authenticated; grant execute on function public.qy_steps_ins_del_guard() to service_role;
revoke all on function public.qy_steps_watch() from public, anon, authenticated; grant execute on function public.qy_steps_watch() to authenticated; grant execute on function public.qy_steps_watch() to service_role;
revoke all on function public.qy_supplier_pick(p_company text) from public, anon, authenticated; grant execute on function public.qy_supplier_pick(p_company text) to anon; grant execute on function public.qy_supplier_pick(p_company text) to authenticated; grant execute on function public.qy_supplier_pick(p_company text) to service_role;
revoke all on function public.qy_transfer_allowed(p_creator text, p_center text, p_total numeric, p_fast boolean) from public, anon, authenticated; grant execute on function public.qy_transfer_allowed(p_creator text, p_center text, p_total numeric, p_fast boolean) to service_role;
revoke all on function public.qy_transfer_ok(p_creator text, p_company text, p_total numeric) from public, anon, authenticated; grant execute on function public.qy_transfer_ok(p_creator text, p_company text, p_total numeric) to service_role;
revoke all on function public.qy_tx_request_guard() from public, anon, authenticated; grant execute on function public.qy_tx_request_guard() to service_role;
revoke all on function public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_desc text) from public, anon, authenticated; grant execute on function public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_desc text) to authenticated; grant execute on function public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_desc text) to service_role;
revoke all on function public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_monthly numeric, p_annual numeric) from public, anon, authenticated; grant execute on function public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_monthly numeric, p_annual numeric) to authenticated; grant execute on function public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric, p_monthly numeric, p_annual numeric) to service_role;
revoke all on function public.qy_unit_root(p_center text) from public, anon, authenticated; grant execute on function public.qy_unit_root(p_center text) to service_role;
revoke all on function public.qy_unit_suspended(p_center text) from public, anon, authenticated; grant execute on function public.qy_unit_suspended(p_center text) to service_role;
revoke all on function public.qy_unit_up(p_center text) from public, anon, authenticated; grant execute on function public.qy_unit_up(p_center text) to service_role;
revoke all on function public.qy_user_dept_func(p_user text) from public, anon, authenticated; grant execute on function public.qy_user_dept_func(p_user text) to anon; grant execute on function public.qy_user_dept_func(p_user text) to authenticated; grant execute on function public.qy_user_dept_func(p_user text) to service_role;
revoke all on function public.qy_user_in_company(p_user text, p_company text) from public, anon, authenticated; grant execute on function public.qy_user_in_company(p_user text, p_company text) to service_role;
revoke all on function public.qy_users_custody_susp_guard() from public, anon, authenticated; grant execute on function public.qy_users_custody_susp_guard() to service_role;
revoke all on function public.qy_users_private() from public, anon, authenticated; grant execute on function public.qy_users_private() to authenticated; grant execute on function public.qy_users_private() to service_role;
revoke all on function public.recurring_due_dates(t recurring_templates, p_to date) from public, anon, authenticated; grant execute on function public.recurring_due_dates(t recurring_templates, p_to date) to authenticated; grant execute on function public.recurring_due_dates(t recurring_templates, p_to date) to service_role;
revoke all on function public.recurring_templates_guard() from public, anon, authenticated; grant execute on function public.recurring_templates_guard() to service_role;
revoke all on function public.refresh_recurring() from public, anon, authenticated; grant execute on function public.refresh_recurring() to authenticated; grant execute on function public.refresh_recurring() to service_role;
revoke all on function public.request_password_reset(p_phone text) from public, anon, authenticated; grant execute on function public.request_password_reset(p_phone text) to anon; grant execute on function public.request_password_reset(p_phone text) to authenticated; grant execute on function public.request_password_reset(p_phone text) to service_role;
revoke all on function public.resolve_login_email(p_login text) from public, anon, authenticated; grant execute on function public.resolve_login_email(p_login text) to anon; grant execute on function public.resolve_login_email(p_login text) to authenticated; grant execute on function public.resolve_login_email(p_login text) to service_role;
revoke all on function public.restore_skipped_occurrence(p_id uuid) from public, anon, authenticated; grant execute on function public.restore_skipped_occurrence(p_id uuid) to authenticated; grant execute on function public.restore_skipped_occurrence(p_id uuid) to service_role;
revoke all on function public.skip_recurring_occurrence(p_id uuid, p_note text) from public, anon, authenticated; grant execute on function public.skip_recurring_occurrence(p_id uuid, p_note text) to authenticated; grant execute on function public.skip_recurring_occurrence(p_id uuid, p_note text) to service_role;
revoke all on function public.transactions_after_reverse() from public, anon, authenticated; grant execute on function public.transactions_after_reverse() to service_role;
revoke all on function public.transactions_are_immutable() from public, anon, authenticated; grant execute on function public.transactions_are_immutable() to authenticated; grant execute on function public.transactions_are_immutable() to service_role;
revoke all on function public.transactions_rules() from public, anon, authenticated; grant execute on function public.transactions_rules() to service_role;
revoke all on function public.users_keep_one_admin() from public, anon, authenticated; grant execute on function public.users_keep_one_admin() to service_role;
revoke all on function public.users_self_update_guard() from public, anon, authenticated; grant execute on function public.users_self_update_guard() to service_role;
revoke all on function public.verify_request(p_id text) from public, anon, authenticated; grant execute on function public.verify_request(p_id text) to anon; grant execute on function public.verify_request(p_id text) to authenticated; grant execute on function public.verify_request(p_id text) to service_role;

