-- نسخة الاسترجاع: تعريفات الإنتاج قبل تطبيق audit-2026-10-29 و batch-2026-10-30 (2026-11-01)
-- لا تُشغَّل إلا عند الحاجة للرجوع.

CREATE OR REPLACE FUNCTION public._get_manager_for_company(p_user_id text, p_company_id text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
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

CREATE OR REPLACE FUNCTION public._user_has_company(p_user_id text, p_company_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
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

CREATE OR REPLACE FUNCTION public.auto_escalate_overdue_approvals()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
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

CREATE OR REPLACE FUNCTION public.can_see_request(p_request_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.requests r
    where r.id = p_request_id
      and (public.can_see_company(r.company_id) or r.created_by_id = public.qy_me())
  );
$function$
;

CREATE OR REPLACE FUNCTION public.qy_ben_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.requests%rowtype; v_me text; rid text;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  rid := case when tg_op = 'DELETE' then old.request_id else new.request_id end;
  select * into r from public.requests where id = rid;
  if not found then return case when tg_op = 'DELETE' then old else new end; end if;   -- طلب يُحذف الآن
  v_me := public.qy_me();
  if r.is_cancelled then
    perform public.qy_deny('ben_cancelled', rid, 'لا يُعدَّل مستفيدو طلب ملغى');
  elsif not public.qy_content_open(r.id, r.status) then
    perform public.qy_deny('ben_locked', rid, 'مستفيدو الطلب مقفلون بعد أول اعتماد');
  elsif not (coalesce(r.created_by_id = v_me, false) or public.is_finance()) then
    perform public.qy_deny('ben_stranger', rid, 'تعديل مستفيدي طلب لا يخصك');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_history_stamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.auth_uid := auth.uid();   -- يُفرض من الخادم ويتجاهل ما يرسله المتصفح
  return new;
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
  if p_kind is null or p_kind not in ('js_error','promise_error','db_error','login_failed','login_ok','logout') then return false; end if;
  v_dev := left(coalesce(p_device->>'id',''), 64);
  if (select count(*) from public.qy_client_events where at > now() - interval '1 minute') >= 300 then return false; end if;
  if v_dev <> '' and (select count(*) from public.qy_client_events where device_id = v_dev and at > now() - interval '1 minute') >= 20 then return false; end if;
  begin
    v_hdr := current_setting('request.headers', true)::json;
    v_ip := nullif(trim(split_part(coalesce(v_hdr->>'x-forwarded-for', v_hdr->>'cf-connecting-ip', ''), ',', 1)), '');
  exception when others then v_ip := null; end;
  insert into public.qy_client_events(kind, page, message, details, user_id, phone_tried, ip, device_id, device)
  values (p_kind, left(p_page,80), left(p_message,500), left(p_details,2000), public.qy_me(), left(p_phone,40), left(v_ip,64),
          nullif(v_dev,''), case when length(coalesce(p_device::text,'')) < 2000 then p_device else null end);
  return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_requests_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me text; v_admin boolean; v_fin boolean; v_creator boolean; v_appr boolean;
  v_post_old boolean; v_open boolean;
  v_post text[] := array['pending_transfer_request','pending_transfer_approval','pending_disbursement','completed','pending_accountant','pending_cfo'];
begin
  if auth.uid() is null or public.qy_mode() = 'off' then return new; end if;
  v_me := public.qy_me(); v_admin := public.is_admin(); v_fin := public.is_finance();
  v_creator := coalesce(old.created_by_id = v_me, false);
  v_appr := public.qy_is_approver(old.id, v_me);
  v_post_old := (old.status = any (v_post));

  -- أ) الطلب الملغى مجمَّد؛ الاسترجاع وحده مسموح لصاحبه أو مدير النظام
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

  -- ب) الإلغاء: قبل اكتمال الاعتماد صاحبه أو المدير، وبعده المدير ومدير النظام فقط
  if new.is_cancelled and not old.is_cancelled then
    if not (v_admin or (v_creator and not v_post_old) or (public.qy_is_cfo() and v_post_old)) then
      perform public.qy_deny('req_cancel', old.id, 'إلغاء الطلب: قبل الاعتماد الكامل لصاحبه أو مدير النظام، وبعده للمدير المالي أو مدير النظام');
    end if;
    return new;
  end if;

  -- ج) تغيير الحالة: لمدير النظام أو المالية أو صاحب الطلب أو أحد معتمديه فقط
  if new.status is distinct from old.status then
    if not (v_admin or v_fin or v_creator or v_appr) then
      perform public.qy_deny('req_status_stranger', old.id, 'تغيير حالة طلب ليس لك فيه دور');
    end if;
    if old.status = 'pending_decision' and new.status = 'pending_transfer_request' and not (v_admin or v_fin) then
      if not exists (select 1 from public.request_approval_steps s where s.request_id = old.id and s.status in ('approved','skipped'))
         and not exists (select 1 from public.request_history h where h.request_id = old.id and h.action like 'اعتماد%')
         and not coalesce((select u.direct_to_transfer from public.users u where u.id = old.created_by_id), false) then
        perform public.qy_deny('req_skip_decision', old.id, 'لا ينتقل الطلب إلى التحويل دون اعتماد واحد على الأقل، إلا لمن فُعّل له الانتقال المباشر');
      end if;
    end if;
    if new.status = 'completed' and not v_fin then
      perform public.qy_deny('req_complete', old.id, 'تأكيد الصرف للمحاسب أو المدير المالي فقط');
    end if;
    if old.status = 'completed' and not v_fin then
      perform public.qy_deny('req_reopen', old.id, 'إعادة فتح طلب مصروف للمالية فقط');
    end if;
    if v_creator and not (v_admin or v_fin or v_appr)
       and new.status in ('completed','pending_disbursement','pending_transfer_approval') then
      perform public.qy_deny('req_status_forward', old.id, 'لا يُرفع طلبك إلى مراحل الصرف بنفسك');
    end if;
  end if;

  -- د) المحتوى يُقفل من أول اعتماد (مدير النظام مستثنى)
  v_open := public.qy_content_open(old.id, old.status);
  if (new.reason, new.detailed_reason, new.total_amount, new.is_recurring, new.company_id, new.created_by_id, new.center_id)
     is distinct from
     (old.reason, old.detailed_reason, old.total_amount, old.is_recurring, old.company_id, old.created_by_id, old.center_id) then
    if not v_admin then
      if not v_open then
        perform public.qy_deny('req_locked_edit', old.id, 'الطلب مقفل بعد أول اعتماد؛ يُرجَع للتعديل أولاً');
      elsif not (v_creator or v_fin) then
        perform public.qy_deny('req_edit_stranger', old.id, 'تعديل طلب لا يخصك');
      end if;
    end if;
  end if;

  -- هـ) البند: للمالية دائماً (إسناد البند غير المحدد)، ولصاحب الطلب وهو مفتوح
  if new.budget_item_id is distinct from old.budget_item_id and not (v_admin or v_fin) then
    if not (v_creator and v_open) then
      perform public.qy_deny('req_item_locked', old.id, 'تغيير بند الطلب مقفل بعد أول اعتماد');
    end if;
  end if;

  -- و) بيانات التحويل البنكي: للمالية فقط
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
  if new.status in ('completed','pending_disbursement','pending_transfer_approval','pending_accountant','pending_cfo')
     or new.is_cancelled then
    perform public.qy_deny('req_ins_status', new.id, 'لا يُنشأ طلب بحالة متقدمة');
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_steps_ins_del_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    if new.status in ('approved','rejected') then
      perform public.qy_deny('step_ins_acted', new.request_id, 'لا تُنشأ خطوة اعتماد جاهزة المعتمدة');
    end if;
    return new;
  end if;
  -- حذف: مسموح لإعادة بناء مسار طلب لم يعتمده أحد، أو عند حذف الطلب نفسه
  if public.qy_has_approved(old.request_id) and exists (select 1 from public.requests r where r.id = old.request_id) then
    perform public.qy_deny('step_delete', old.request_id, 'لا تُحذف خطوات اعتماد طلب بدأ اعتماده');
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
declare v_actor text; v_ok boolean := false;
begin
  if new.status is distinct from old.status and new.status in ('approved','rejected') then
    new.acted_by_auth := auth.uid();
    if auth.uid() is not null then
      select u.id into v_actor from public.users u where u.auth_id = auth.uid();
      v_ok := public.is_admin()
           or v_actor = new.approver_id
           or exists (select 1 from public.users a where a.id = new.approver_id and a.exec_substitute_id = v_actor);
      if not v_ok then
        if public.qy_mode() = 'watch' then
          insert into public.qy_audit_alerts(kind, request_id, step_id, actor_auth, actor_user, approver_id, details)
          values ('step_status_by_other', new.request_id, new.id::text, auth.uid(), v_actor, new.approver_id,
                  old.status || ' -> ' || new.status);
        elsif public.qy_mode() = 'on' then
          raise exception 'غير مصرّح: الاعتماد أو الرفض لصاحب الخطوة أو نائبه أو مدير النظام فقط';
        end if;
      end if;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.transactions_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.transactions; s numeric;
begin
  -- العكس: مرة واحدة، وليس على حركة عليها استرداد قائم
  if new.reverses_id is not null then
    perform pg_advisory_xact_lock(hashtext(new.reverses_id::text));
    select * into o from public.transactions where id = new.reverses_id;
    if not found then raise exception 'الحركة المراد عكسها غير موجودة'; end if;
    if o.reverses_id is not null then raise exception 'هذه حركة عاكسة ولا تُعكس'; end if;
    if exists (select 1 from public.transactions x where x.reverses_id = o.id) then
      raise exception 'هذه الحركة عُكست من قبل';
    end if;
    if exists (select 1 from public.transactions r
                where r.refund_of_id = o.id
                  and not exists (select 1 from public.transactions z where z.reverses_id = r.id)) then
      raise exception 'عليها استرداد قائم. اعكس الاستردادات أولاً أو اكتفِ بها';
    end if;
  end if;

  -- الاسترداد: على صرف أو إيراد سليم، ولا يتجاوز مجموعه المبلغ الأصلي
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
     where r.refund_of_id = o.id
       and not exists (select 1 from public.transactions z where z.reverses_id = r.id);
    if s + new.amount > o.amount then
      raise exception 'مجموع الاستردادات يتجاوز المبلغ الأصلي. المتبقي للاسترداد: %', to_char(o.amount - s, 'FM999999990.000');
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
  allowed text[] := array[
    'name','email','name_en','iban','national_id',
    'id_file_data','bank_file_data',
    'signature_mode','signature_color','signature_width','signature_data',
    'stamp_data','stamp_data_2','notif_seen_at'
  ];
begin
  -- من يعمل من لوحة SQL أو من مهمة مجدولة لا يحمل هوية مستخدم، فلا قيد عليه
  if auth.uid() is null then return new; end if;
  -- المدير حرّ
  if public.is_admin() then return new; end if;
  if (to_jsonb(new) - allowed) is distinct from (to_jsonb(old) - allowed) then
    raise exception 'لا تملك صلاحية تعديل هذه البيانات';
  end if;
  return new;
end
$function$
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
    v_ip := nullif(trim(split_part(coalesce(v_hdr->>'x-forwarded-for', v_hdr->>'cf-connecting-ip', ''), ',', 1)), '');
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

alter policy qy_att_obj_del on storage.objects using (((bucket_id = 'attachments'::text) AND can_see_company((storage.foldername(name))[1])));

alter policy qyam_wrt_budget_items on public.budget_items using (can_see_company(company_id)) with check (can_see_company(company_id));

alter policy qyam_sel_prr on public.password_reset_requests using (can_see_company(company_id));

alter policy qyam_upd_prr on public.password_reset_requests using (can_see_company(company_id)) with check (can_see_company(company_id));

alter policy qyam_sel_requests on public.requests using (can_see_company(company_id));

alter policy qyam_wrt_requests on public.requests using (can_see_company(company_id)) with check (can_see_company(company_id));

alter policy qy_att_del on public.qy_attachments using (can_see_company(company_id));

-- صلاحيات كانت قائمة قبل التطبيق
grant select on public.users to anon, authenticated;
grant execute on function public.next_request_number(text,text), public.assign_due_request_numbers(), public.auto_escalate_overdue_approvals(),
  public.ensure_petty_expenses_item(text), public.budget_item_balance(text), public.budget_item_company_profit(text),
  public._get_manager_for_company(text,text), public._user_has_company(text,text) to public;
