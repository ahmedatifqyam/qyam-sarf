-- دفعة 30 أكتوبر: من يرى ماذا، أرقام البنود، أسماء المعتمدين، المستفيد المسجّل، ملاحظات الطلب، تعديل الطلب لمنشئه
-- تُطبَّق على الاختبار أولاً، ثم على الإنتاج بعد ملف audit-2026-10-29-server.sql. قابلة لإعادة التشغيل.

alter table public.requests add column if not exists request_notes text;

-- (1) من يرى الطلب: صاحبه، ومن هو معتمِد فيه (أو نائبه أو من أُسند إليه)، ومن تصرّف فيه، والمالية ومدير النظام، ومفوَّض المدير المالي
create or replace function public.can_see_request(p_request_id text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select exists (
    select 1 from public.requests r
    where r.id = p_request_id and (
         r.created_by_id = public.qy_me()
      or (public.is_finance() and public.can_see_company(r.company_id))
      or exists (select 1 from public.request_approval_steps s where s.request_id = r.id and public.qy_step_actor_ok(s.approver_id, r.id, public.qy_me()))
      or exists (select 1 from public.request_history h where h.request_id = r.id and h.user_id = public.qy_me())
      or exists (select 1 from public.companies c where c.id = r.company_id and public.can_see_company(r.company_id) and (
             (c.cfo_delegation_mode = 'delegate_user' and c.cfo_delegate_user_id = public.qy_me())
          or (c.cfo_delegation_mode = 'delegate_manager' and exists (select 1 from public.users u where u.manager_id = public.qy_me() and u.role = 'accountant'))))
    ));
$f$;
alter policy qyam_sel_requests on public.requests using (public.can_see_request(id));
alter policy qyam_wrt_requests on public.requests using (public.can_see_request(id)) with check (public.can_see_company(company_id));

-- (2) مجاميع البنود من كل طلبات الشركة (أرقام فقط، بلا تفاصيل) حتى يرى الموظف المتاح الصحيح
create or replace function public.qy_budget_figures(p_company text)
returns table(budget_item_id text, committed numeric, pending numeric)
language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select r.budget_item_id,
         coalesce(sum(r.total_amount) filter (where r.status in ('pending_transfer_request','pending_transfer_approval','pending_disbursement','pending_accountant','pending_cfo')), 0),
         coalesce(sum(r.total_amount) filter (where r.status in ('pending_decision','pending_manager','pending_senior','pending_executive')), 0)
  from public.requests r
  where public.can_see_company(p_company) and r.company_id = p_company and r.budget_item_id is not null
    and not coalesce(r.is_cancelled,false) and r.status <> 'rejected'
  group by r.budget_item_id;
$f$;
revoke all on function public.qy_budget_figures(text) from public, anon;
grant execute on function public.qy_budget_figures(text) to authenticated;

-- (3) أسماء معتمدي طلباتي حتى لو كانوا في شركة لم أعد أراها
create or replace function public.qy_people_names()
returns table(id text, name text, role text, job_title text, company_id text)
language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select distinct u.id, u.name, u.role, u.job_title, u.company_id
  from public.users u
  where u.id in (select s.approver_id from public.request_approval_steps s join public.requests r on r.id = s.request_id
                 where r.created_by_id = public.qy_me());
$f$;
revoke all on function public.qy_people_names() from public, anon;
grant execute on function public.qy_people_names() to authenticated;

-- (4) المستفيد المسجّل: آيبانه ورقمه المدني لا يغيّرهما إلا المالية ومدير النظام، والحذف للمالية
create or replace function public.qy_bm_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
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
end $f$;
revoke execute on function public.qy_bm_guard() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'qy_bm_guard_trg') then
    create trigger qy_bm_guard_trg before update or delete on public.beneficiaries_master for each row execute function public.qy_bm_guard();
  end if;
end $$;

-- (5) مستفيدو الطلب يعدّلهم صاحبه فقط (والمالية ترفض بملاحظة)
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.qy_ben_guard()'::regprocedure);
  n := replace(d, 'elsif not (coalesce(r.created_by_id = v_me, false) or public.is_finance()) then
    perform public.qy_deny(''ben_stranger'', rid, ''تعديل مستفيدي طلب لا يخصك'');',
                  'elsif not coalesce(r.created_by_id = v_me, false) then
    perform public.qy_deny(''ben_stranger'', rid, ''تعديل مستفيدي الطلب لصاحبه فقط؛ المالية ترفض الطلب بملاحظة'');');
  if n <> d then execute n; end if;
end $$;

-- (6) محتوى الطلب يعدّله صاحبه فقط، وملاحظات الطلب لصاحبه والمالية
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.qy_requests_guard()'::regprocedure);
  n := replace(d, 'elsif not (v_creator or v_fin) then
        perform public.qy_deny(''req_edit_stranger'', old.id, ''تعديل طلب لا يخصك'');',
                  'elsif not v_creator then
        perform public.qy_deny(''req_edit_stranger'', old.id, ''تعديل الطلب لصاحبه فقط'');');
  if position('req_notes' in n) = 0 then
    n := replace(n, '  if new.budget_item_id is distinct from old.budget_item_id and not (v_admin or v_fin) then',
                    '  if new.request_notes is distinct from old.request_notes and not (v_admin or v_fin or v_creator) then
    perform public.qy_deny(''req_notes'', old.id, ''ملاحظات الطلب لصاحبه والمالية'');
  end if;
  if new.budget_item_id is distinct from old.budget_item_id and not (v_admin or v_fin) then');
  end if;
  if n <> d then execute n; end if;
end $$;

-- (7) نافذة «مراجعة قبل الإرسال» لكل شركة: required إلزامية · optional اختيارية لكل مستخدم · off معطّلة
alter table public.companies add column if not exists review_mode text not null default 'optional';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='companies_review_mode_chk') then
    alter table public.companies add constraint companies_review_mode_chk check (review_mode in ('required','optional','off'));
  end if;
end $$;
-- اختيار المستخدم «لا تُظهر مرة أخرى» يُحفظ في حسابه (يحفظه بنفسه)
alter table public.users add column if not exists skip_review boolean not null default false;
grant select (skip_review) on public.users to authenticated;
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.users_self_update_guard()'::regprocedure);
  if position('skip_review' in d) = 0 then
    n := replace(d, '''notif_seen_at'',''idle_minutes''];', '''notif_seen_at'',''idle_minutes'',''skip_review''];');
    if n = d then raise exception 'users_self_update_guard: anchor not found'; end if;
    execute n;
  end if;
end $$;

-- (8) صلاحية «طلب صرف جديد» تُفرض في الخادم: من مُنع (لا يرى / قراءة فقط) لا يُنشئ طلباً ولو تجاوز الواجهة
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.qy_requests_ins_guard()'::regprocedure);
  if position('req_ins_page' in d) = 0 then
    n := replace(d, '  if coalesce(new.is_cancelled,false) or coalesce(new.status,'''') not in',
'  -- صلاحية صفحة «طلب صرف جديد» لدور المستخدم في هذه الشركة (لا يرى / قراءة فقط = لا إنشاء)
  if exists (select 1 from public.page_permissions p join public.users u on u.id = new.created_by_id
             where p.company_id = new.company_id and p.role = u.role and p.page_key = ''newreq'' and p.level in (''none'',''read'')) then
    perform public.qy_deny(''req_ins_page'', new.id, ''ليست لديك صلاحية إنشاء طلب صرف في هذه الشركة'');
  end if;
  if coalesce(new.is_cancelled,false) or coalesce(new.status,'''') not in');
    if n = d then raise exception 'qy_requests_ins_guard: anchor not found'; end if;
    execute n;
  end if;
end $$;
