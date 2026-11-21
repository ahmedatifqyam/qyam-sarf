-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٢ (1.40.0): صلاحيات الصفحات للمراكز — تُضبط لكل دور على «كل المراكز» أو مركز بعينه.
--   تسري على موظفي المراكز فقط (من وحدته مركز أو تحت مركز، وليس من المالية أو الإدارة أو المدير التنفيذي).
--   الأولوية: الوحدة الأقرب للموظف ثم ما فوقها حتى المركز ← «كل المراكز» ← صلاحية الشركة ← الافتراضي.
--   مثال: «كل المراكز»: الموظف لا يرى «العهد»، ومدير المركز يرى «العهد»، و«طلب راتب» لا يرى لكليهما.
-- يُشغَّل بعد بناء-١..١١. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.page_permissions_center (
  company_id text not null references public.companies(id) on delete cascade,
  scope      text not null,              -- معرّف المركز، أو '*' = كل المراكز
  role       text not null,
  page_key   text not null,
  level      text not null check (level in ('none','read','edit','full')),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (company_id, scope, role, page_key)
);
alter table public.page_permissions_center enable row level security;
drop policy if exists ppc_sel on public.page_permissions_center;
drop policy if exists ppc_ins on public.page_permissions_center;
drop policy if exists ppc_upd on public.page_permissions_center;
drop policy if exists ppc_del on public.page_permissions_center;
create policy ppc_sel on public.page_permissions_center for select to authenticated using (public.can_see_company(company_id));
create policy ppc_ins on public.page_permissions_center for insert to authenticated with check (public.is_admin() and public.can_see_company(company_id));
create policy ppc_upd on public.page_permissions_center for update to authenticated using (public.is_admin() and public.can_see_company(company_id)) with check (public.is_admin() and public.can_see_company(company_id));
create policy ppc_del on public.page_permissions_center for delete to authenticated using (public.is_admin() and public.can_see_company(company_id));
revoke all on public.page_permissions_center from anon;
grant select, insert, update, delete on public.page_permissions_center to authenticated;

-- وحدة الموظف في مركز (لصلاحيات المراكز): وحدته الأساسية إن كانت مركزاً أو تحت مركز، وإلا أول وحدة إضافية كذلك.
-- لا شيء للمالية والإدارة والمدير التنفيذي. مطابق لـ permCenterUnit() في الواجهة.
create or replace function public.qy_user_perm_unit(p_user text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case when u.role in ('admin','accountant','cfo','executive_manager') then null else coalesce(
    (select u.center_id where u.center_id is not null and exists (select 1 from public.qy_unit_up(u.center_id) x where x.kind = 'center')),
    (select uu.center_id from public.user_units uu where uu.user_id = u.id
        and exists (select 1 from public.qy_unit_up(uu.center_id) x where x.kind = 'center') order by uu.center_id limit 1)) end
  from public.users u where u.id = p_user;
$$;

-- الصلاحية المضبوطة صراحة لمستخدم في صفحة (أو null = الافتراضي)
create or replace function public.qy_page_row(p_user text, p_company text, p_key text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  with me as (select u.role, public.qy_user_perm_unit(u.id) unit from public.users u where u.id = p_user)
  select coalesce(
    (select p.level from me, public.qy_unit_up(me.unit) up
       join public.page_permissions_center p on p.scope = up.id
      where me.unit is not null and p.company_id = p_company and p.role = me.role and p.page_key = p_key
      order by up.depth limit 1),
    (select p.level from me join public.page_permissions_center p on p.scope = '*' and p.role = me.role
      where me.unit is not null and p.company_id = p_company and p.page_key = p_key),
    (select p.level from me join public.page_permissions p on p.role = me.role
      where p.company_id = p_company and p.page_key = p_key));
$$;

-- كل الفحوص التي تقرأ صلاحيات الصفحات صارت تمر عبر qy_page_row
create or replace function public.qy_page_blocked(p_company text, p_key text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(public.qy_page_row(public.qy_me(), p_company, p_key) in ('none','read'), false);
$$;
create or replace function public.qy_page_level_ok(p_company text, p_key text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.qy_page_row(public.qy_me(), p_company, p_key) = any(p_levels), false);
$$;
create or replace function public.qy_prj_level_ok(p_company text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.qy_page_row(public.qy_me(), p_company, 'projects') = any(p_levels), false);
$$;
create or replace function public.qy_can_payroll(p_user text, p_company text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.qy_user_dept_func(p_user) in ('hr','secretary'), false)
      or exists (select 1 from public.users u join public.custom_roles cr on cr.id = u.role where u.id = p_user and cr.can_payroll)
      or coalesce(public.qy_page_row(p_user, p_company, 'payroll') in ('edit','full'),
                  (select u.role in ('accountant','cfo','admin') from public.users u where u.id = p_user), false);
$$;

-- حارس إنشاء الطلب: نفس الفحص عبر qy_page_row (تعديل نصي محدد لدالة قائمة)
do $p$ declare d text; begin
  d := pg_get_functiondef('public.qy_requests_ins_guard()'::regprocedure);
  if position('public.page_permissions p' in d) > 0 then
    d := replace(d, $o$exists (select 1 from public.page_permissions p join public.users u on u.id = new.created_by_id
             where p.company_id = new.company_id and p.role = u.role and p.page_key = v_key and p.level in ('none','read'))$o$,
                 $n$coalesce(public.qy_page_row(new.created_by_id, new.company_id, v_key) in ('none','read'), false)$n$);
    if position('public.page_permissions p' in d) > 0 then raise exception 'بناء-١٢: لم يُطابَق نص qy_requests_ins_guard'; end if;
    execute d;
  end if;
end $p$;

-- لوحة المتابعة: نفس الفحص عبر qy_page_row
do $p$ declare d text; begin
  d := pg_get_functiondef('public.qy_monitor(text,integer)'::regprocedure);
  if position('public.page_permissions p' in d) > 0 then
    d := replace(d, $o$exists (select 1 from public.page_permissions p where p.company_id = p_company and p.role = v_role and p.page_key = 'monitor' and p.level in ('read','edit','full'))$o$,
                 $n$coalesce(public.qy_page_row(v_me, p_company, 'monitor') in ('read','edit','full'), false)$n$);
    d := replace(d, $o$not exists (select 1 from public.page_permissions p where p.company_id = p_company and p.role = v_role and p.page_key = 'monitor')$o$,
                 $n$public.qy_page_row(v_me, p_company, 'monitor') is null$n$);
    if position('public.page_permissions p' in d) > 0 then raise exception 'بناء-١٢: لم يُطابَق نص qy_monitor'; end if;
    execute d;
  end if;
end $p$;

revoke all on function public.qy_user_perm_unit(text), public.qy_page_row(text,text,text) from public, anon;
grant execute on function public.qy_user_perm_unit(text), public.qy_page_row(text,text,text) to authenticated;
