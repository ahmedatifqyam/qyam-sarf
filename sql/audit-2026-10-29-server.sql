-- مراجعة الكود 2026-10-29: إصلاحات الخادم (تُطبَّق على الاختبار أولاً ثم الإنتاج)
-- كل ما هنا قابل لإعادة التشغيل دون ضرر.

-- ============ (1) هل يجوز أن يبدأ الطلب في مرحلة التحويل بلا معتمدين؟ ============
create or replace function public.qy_transfer_allowed(p_creator text, p_center text, p_total numeric, p_fast boolean)
returns boolean language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select coalesce((select u.direct_to_transfer from public.users u where u.id = p_creator), false)
      or (coalesce(p_fast,false) and exists (
            select 1 from public.users u join public.centers c on c.id = u.center_id
            where u.id = p_creator and c.id = p_center and c.min_threshold is not null
              and coalesce(p_total,0) <= c.min_threshold
              and (coalesce(c.skip_dept_manager,false) or coalesce(c.skip_senior_manager,false) or coalesce(c.skip_executive_manager,false))));
$f$;

-- ============ (2) من يتصرف بخطوة اعتماد: صاحبها أو نائبه أو من أُسندت إليه ============
create or replace function public.qy_step_actor_ok(p_approver text, p_req text, p_me text)
returns boolean language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select p_me is not null and (
       p_approver = p_me
    or exists (select 1 from public.users a where a.id = p_approver and a.exec_substitute_id = p_me)
    or exists (select 1 from public.qy_handovers h join public.requests r on r.id = p_req
               where h.from_user_id = p_approver and h.to_user_id = p_me and h.status = 'accepted'
                 and h.company_id = r.company_id and h.from_date <= current_date
                 and (h.to_date is null or h.to_date >= current_date)
                 and (h.scope_all or p_req = any(h.request_ids))));
$f$;

-- ============ (3) حارس إنشاء الطلب ============
create or replace function public.qy_requests_ins_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return new; end if;
  if new.created_by_id is distinct from public.qy_me() then
    perform public.qy_deny('req_ins_owner', new.id, 'لا تُنشئ طلباً باسم غيرك');
  end if;
  if coalesce(new.is_cancelled,false) or coalesce(new.status,'') not in ('pending_decision','pending_transfer_request') then
    perform public.qy_deny('req_ins_status', new.id, 'لا يُنشأ طلب بحالة متقدمة');
  end if;
  if new.status = 'pending_transfer_request'
     and not public.qy_transfer_allowed(new.created_by_id, new.center_id, new.total_amount, new.fast_tracked) then
    perform public.qy_deny('req_ins_skip', new.id, 'لا يبدأ الطلب في مرحلة التحويل بلا معتمدين إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
  end if;
  return new;
end $f$;

-- ============ (4) حارس تعديل الطلب ============
create or replace function public.qy_requests_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare
  v_me text; v_admin boolean; v_fin boolean; v_creator boolean; v_appr boolean; v_dlg boolean;
  v_post_old boolean; v_open boolean; n_all int; n_open int;
  v_post text[] := array['pending_transfer_request','pending_transfer_approval','pending_disbursement','completed','pending_accountant','pending_cfo'];
begin
  if auth.uid() is null or public.qy_mode() = 'off' then return new; end if;
  v_me := public.qy_me(); v_admin := public.is_admin(); v_fin := public.is_finance();
  v_creator := coalesce(old.created_by_id = v_me, false);
  v_appr := public.qy_is_approver(old.id, v_me);
  v_post_old := (old.status = any (v_post));
  -- مفوَّض المدير المالي (تفويض شخص محدد، أو مدير المحاسب)
  v_dlg := exists (select 1 from public.companies c where c.id = old.company_id and (
             (c.cfo_delegation_mode = 'delegate_user' and c.cfo_delegate_user_id = v_me
               and (nullif(c.cfo_delegate_until::text,'') is null or nullif(c.cfo_delegate_until::text,'')::date >= current_date))
          or (c.cfo_delegation_mode = 'delegate_manager' and exists (select 1 from public.users u where u.manager_id = v_me and u.role = 'accountant'))));

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

  -- ب) الإلغاء: قبل اكتمال الاعتماد صاحبه أو المدير، وبعده المدير المالي ومدير النظام فقط
  if new.is_cancelled and not old.is_cancelled then
    if not (v_admin or (v_creator and not v_post_old) or (public.qy_is_cfo() and v_post_old)) then
      perform public.qy_deny('req_cancel', old.id, 'إلغاء الطلب: قبل الاعتماد الكامل لصاحبه أو مدير النظام، وبعده للمدير المالي أو مدير النظام');
    end if;
    return new;
  end if;

  -- ب٢) الطلب لا ينتقل إلى شركة أخرى إلا بمدير النظام
  if new.company_id is distinct from old.company_id and not v_admin then
    perform public.qy_deny('req_company', old.id, 'نقل الطلب إلى شركة أخرى لمدير النظام فقط');
  end if;

  -- ج) تغيير الحالة
  if new.status is distinct from old.status then
    if not (v_admin or v_fin or v_creator or v_appr or v_dlg) then
      perform public.qy_deny('req_status_stranger', old.id, 'تغيير حالة طلب ليس لك فيه دور');
    end if;
    -- إلى مرحلة التحويل: كل خطوات القرار حُسمت، أو طلب بلا معتمدين مسموح له بذلك
    if new.status = 'pending_transfer_request' and not v_admin
       and old.status in ('pending_decision','rejected','pending_manager','pending_senior','pending_executive') then
      select count(*), count(*) filter (where s.status in ('pending','rejected'))
        into n_all, n_open from public.request_approval_steps s where s.request_id = old.id;
      if n_all > 0 then
        if old.status = 'rejected' or n_open > 0 then
          perform public.qy_deny('req_skip_decision', old.id, 'لا ينتقل الطلب إلى التحويل قبل أن يعتمده كل معتمديه');
        end if;
      elsif not public.qy_transfer_allowed(old.created_by_id, old.center_id, new.total_amount, new.fast_tracked) then
        perform public.qy_deny('req_skip_decision', old.id, 'لا ينتقل الطلب إلى التحويل دون اعتماد، إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
      end if;
    end if;
    -- مراحل المالية للمالية وحدها (ومفوَّض المدير المالي في اعتماد التحويل)
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
    -- إعادة الإرسال بعد الرفض تُسقط الاعتمادات السابقة من الخادم نفسه
    if old.status = 'rejected' and new.status = 'pending_decision' then
      update public.request_approval_steps set status = 'pending', acted_at = null
        where request_id = old.id and status <> 'pending';
    end if;
  end if;

  -- د) المحتوى يُقفل من أول اعتماد (مدير النظام مستثنى)
  v_open := public.qy_content_open(old.id, old.status);
  if (new.reason, new.detailed_reason, new.total_amount, new.is_recurring, new.created_by_id, new.center_id, new.fast_tracked)
     is distinct from
     (old.reason, old.detailed_reason, old.total_amount, old.is_recurring, old.created_by_id, old.center_id, old.fast_tracked) then
    if not v_admin then
      if not v_open then
        perform public.qy_deny('req_locked_edit', old.id, 'الطلب مقفل بعد أول اعتماد؛ يُرجَع للتعديل أولاً');
      elsif not (v_creator or v_fin) then
        perform public.qy_deny('req_edit_stranger', old.id, 'تعديل طلب لا يخصك');
      end if;
    end if;
  end if;

  -- هـ) البند: للمالية دائماً، ولصاحب الطلب وهو مفتوح
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
end $f$;

-- ============ (5) حارس تعديل خطوات الاعتماد ============
create or replace function public.qy_steps_watch() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_me text; r public.requests%rowtype;
begin
  if new.status is distinct from old.status and new.status in ('approved','rejected') then
    new.acted_by_auth := auth.uid();
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
  elsif (new.sequence_order, new.activated_at, new.acted_at, new.note, new.role_label)
        is distinct from (old.sequence_order, old.activated_at, old.acted_at, old.note, old.role_label) then
    if not (coalesce(r.created_by_id = v_me, false) or public.qy_is_approver(old.request_id, v_me) or public.is_finance()) then
      perform public.qy_deny('step_edit', old.request_id, 'تعديل خطوات طلب ليس لك فيه دور');
    end if;
  end if;
  return new;
end $f$;

-- ============ (6) حارس إضافة/حذف خطوات الاعتماد ============
create or replace function public.qy_steps_ins_del_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_me text; r public.requests%rowtype;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  v_me := public.qy_me();
  if tg_op = 'INSERT' then
    select * into r from public.requests where id = new.request_id;
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
  -- حذف: لإعادة بناء مسار طلب لم يعتمده أحد، أو عند حذف الطلب نفسه
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
end $f$;

-- ============ (7) سجل الطلب لا يُكتب باسم غيرك ============
create or replace function public.qy_history_stamp() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  new.auth_uid := auth.uid();   -- يُفرض من الخادم ويتجاهل ما يرسله المتصفح
  if auth.uid() is not null and new.user_id is not null and not public.is_admin()
     and new.user_id is distinct from public.qy_me() then
    perform public.qy_deny('hist_forge', new.request_id, 'لا يُكتب في سجل الطلب باسم مستخدم آخر');
  end if;
  return new;
end $f$;

-- ============ (8) مستفيدو الطلب: إدخالهم لطلب يبدأ في التحويل (نافذة المراجعة) ============
create or replace function public.qy_ben_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare r public.requests%rowtype; v_me text; rid text; s numeric;
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
  elsif not (public.qy_content_open(r.id, r.status)
             or (r.status = 'pending_transfer_request' and r.number is null and coalesce(r.created_by_id = v_me, false))) then
    perform public.qy_deny('ben_locked', rid, 'مستفيدو الطلب مقفلون بعد أول اعتماد');
  elsif not (coalesce(r.created_by_id = v_me, false) or public.is_finance()) then
    perform public.qy_deny('ben_stranger', rid, 'تعديل مستفيدي طلب لا يخصك');
  end if;
  -- طلب يبدأ في التحويل: لا يتجاوز مجموع المستفيدين مبلغ الطلب الذي فُحص عند إنشائه
  if tg_op <> 'DELETE' and r.status = 'pending_transfer_request' and not public.is_finance() then
    select coalesce(sum(greatest(coalesce(b.amount,0) - coalesce(b.deduction,0) + coalesce(b.extra,0), 0)), 0) into s
      from public.request_beneficiaries b where b.request_id = rid and (tg_op = 'INSERT' or b.id <> old.id);
    s := s + greatest(coalesce(new.amount,0) - coalesce(new.deduction,0) + coalesce(new.extra,0), 0);
    if s > coalesce(r.total_amount,0) + 0.001 then
      perform public.qy_deny('ben_over_total', rid, 'مجموع المستفيدين يتجاوز مبلغ الطلب');
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $f$;

-- ============ (9) بيانات المستخدم الخاصة: لا تُقرأ إلا لصاحبها ولمدير النظام ============
create or replace function public.qy_users_private()
returns table(id text, iban text, national_id text, id_file_data text, bank_file_data text)
language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select u.id, u.iban, u.national_id, u.id_file_data, u.bank_file_data
  from public.users u where u.id = public.qy_me() or public.is_admin();
$f$;
revoke all on function public.qy_users_private() from public, anon;
grant execute on function public.qy_users_private() to authenticated;
revoke select on public.users from anon, authenticated;
grant select (id,phone,name,role,center_id,signature_data,stamp_data,email,name_en,signature_mode,signature_color,signature_width,
  company_id,stamp_data_2,manager_id,notif_seen_at,job_title,level_id,request_approver_id,next_approver_id,exec_substitute_id,
  is_general,no_request_approver,no_next_approver,approval_deadline_days,escalate_mode,escalate_user_id,auth_id,
  can_manage_recurring,idle_minutes,is_suspended,suspended_at,suspended_note,direct_to_transfer) on public.users to authenticated;

-- ============ (10) المستخدم يحفظ مهلة الإغلاق بنفسه ============
create or replace function public.users_self_update_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare
  allowed text[] := array['name','email','name_en','iban','national_id','id_file_data','bank_file_data',
    'signature_mode','signature_color','signature_width','signature_data','stamp_data','stamp_data_2','notif_seen_at','idle_minutes'];
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
end $f$;

-- ============ (11) بنود الميزانية: الإضافة السريعة للجميع، والتعديل والحذف للمالية ============
alter policy qyam_wrt_budget_items on public.budget_items
  using (public.can_see_company(company_id) and public.is_finance())
  with check (public.can_see_company(company_id) and public.is_finance());
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='budget_items' and policyname='qy_budget_items_ins') then
    create policy qy_budget_items_ins on public.budget_items for insert to authenticated with check (public.can_see_company(company_id));
  end if;
end $$;

-- ============ (12) العكس: بنفس المبلغ وعكس الاتجاه وفي الشركة نفسها ============
create or replace function public.transactions_rules() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
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
end $f$;

-- ============ (13) دوال داخلية لا يستدعيها المتصفح ولا الزائر ============
revoke execute on function public.next_request_number(text,text) from public, anon, authenticated;
revoke execute on function public.assign_due_request_numbers() from public, anon, authenticated;
revoke execute on function public.auto_escalate_overdue_approvals() from public, anon, authenticated;
revoke execute on function public.ensure_petty_expenses_item(text) from public, anon, authenticated;
revoke execute on function public.budget_item_balance(text) from public, anon, authenticated;
revoke execute on function public.budget_item_company_profit(text) from public, anon, authenticated;
revoke execute on function public._get_manager_for_company(text,text) from public, anon, authenticated;
revoke execute on function public._user_has_company(text,text) from public, anon, authenticated;
revoke execute on function public.qy_transfer_allowed(text,text,numeric,boolean) from public, anon, authenticated;
revoke execute on function public.qy_step_actor_ok(text,text,text) from public, anon, authenticated;
alter function public.auto_escalate_overdue_approvals() set search_path to 'public','pg_temp';
alter function public._get_manager_for_company(text,text) set search_path to 'public','pg_temp';
alter function public._user_has_company(text,text) set search_path to 'public','pg_temp';
alter function public.budget_item_balance(text) set search_path to 'public','pg_temp';
alter function public.budget_item_company_profit(text) set search_path to 'public','pg_temp';

-- ============ (14) المعرّفات النصية: حروف وأرقام و _ - . فقط (تمنع حقن سكربت في أزرار الواجهة) ============
do $$
declare t text;
begin
  foreach t in array array['requests','budget_items','centers','request_approval_steps','beneficiaries_master','budget_revenues'] loop
    if exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='id' and data_type='text')
       and not exists (select 1 from pg_constraint where conname = t||'_id_safe') then
      execute format('alter table public.%I add constraint %I check (id ~ %L) not valid', t, t||'_id_safe', '^[A-Za-z0-9_.-]+$');
      execute format('alter table public.%I validate constraint %I', t, t||'_id_safe');
    end if;
  end loop;
end $$;

-- ============ (15) طلبات إعادة كلمة المرور: لمدير النظام وحده ============
alter policy qyam_sel_prr on public.password_reset_requests using (public.is_admin());
alter policy qyam_upd_prr on public.password_reset_requests using (public.is_admin()) with check (public.is_admin());

-- ============ (16) المرفقات: يحذفها رافعها أو المالية/مدير النظام ============
alter policy qy_att_del on public.qy_attachments using (public.can_see_company(company_id) and (created_by = auth.uid() or public.is_finance()));

-- ============ (17) قيد صرف الطلب: مرة واحدة، وبمبلغ الطلب نفسه ============
create or replace function public.qy_tx_request_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
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
end $f$;
revoke execute on function public.qy_tx_request_guard() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_tx_request_guard') then
    create trigger trg_tx_request_guard before insert on public.transactions for each row execute function public.qy_tx_request_guard();
  end if;
end $$;

-- ============ (18) ملفات المرفقات في التخزين: يحذفها رافعها أو المالية ============
alter policy qy_att_obj_del on storage.objects using ((bucket_id = 'attachments') and public.can_see_company((storage.foldername(name))[1]) and (owner_id = auth.uid()::text or public.is_finance()));

-- ============ (19) عنوان الزائر في صفحة التحقق والسجل: من cf-connecting-ip أولاً (X-Forwarded-For قابل للتزوير) ============
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.verify_request(text)'::regprocedure);
  n := replace(d, 'coalesce(v_hdr->>''x-forwarded-for'', v_hdr->>''cf-connecting-ip'', '''')', 'coalesce(v_hdr->>''cf-connecting-ip'', v_hdr->>''x-real-ip'', v_hdr->>''x-forwarded-for'', '''')');
  if n <> d then execute n; end if;
  d := pg_get_functiondef('public.qy_log_event(text,text,text,text,text,jsonb)'::regprocedure);
  n := replace(d, 'coalesce(v_hdr->>''x-forwarded-for'', v_hdr->>''cf-connecting-ip'', '''')', 'coalesce(v_hdr->>''cf-connecting-ip'', v_hdr->>''x-real-ip'', v_hdr->>''x-forwarded-for'', '''')');
  if n <> d then execute n; end if;
end $$;
