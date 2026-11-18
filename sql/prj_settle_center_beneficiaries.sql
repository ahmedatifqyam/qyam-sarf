-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٥ (1.26.0): معالجة المبالغ غير المحصّلة عند إغلاق المشروع،
--                  ومستفيدو المراكز لا يراهم إلا من يرى المركز.
-- يُشغَّل بعد بناء-١..٤. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── ١) من يعالج المبالغ عند الإغلاق (مع مدير النظام والمدير المالي) ───
alter table public.companies add column if not exists settle_user_ids jsonb not null default '[]'::jsonb;

create or replace function public.qy_prj_can_settle(p_company text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.can_see_company(p_company) and (
       public.is_admin()
    or exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'cfo')
    or exists (select 1 from public.companies c where c.id = p_company
               and coalesce(c.settle_user_ids, '[]'::jsonb) ? public.qy_me()));
$$;

-- ─── ٢) الفاتورة المرحّلة لعميل آخر ───
alter table public.prj_invoices add column if not exists client_id text references public.clients(id) on delete set null;
alter table public.prj_invoices add column if not exists transferred_from uuid references public.prj_invoices(id) on delete set null;

-- ─── ٣) معالجات المبالغ غير المحصّلة ───
create table if not exists public.prj_settlements (
  id          uuid primary key default gen_random_uuid(),
  company_id  text not null references public.companies(id) on delete cascade,
  project_id  uuid not null references public.projects(id) on delete cascade,
  invoice_id  uuid not null references public.prj_invoices(id) on delete cascade,
  kind        text not null check (kind in ('later','bad_debt','discount','transfer','waive')),
  amount      numeric(14,3) not null check (amount > 0),
  due_date    date,
  reason      text,
  transfer_client_id  text references public.clients(id) on delete set null,
  transfer_invoice_id uuid references public.prj_invoices(id) on delete set null,
  created_by  text,
  created_at  timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by text,
  constraint prj_settle_later_date check (kind <> 'later' or due_date is not null),
  constraint prj_settle_reason check (kind = 'later' or length(trim(coalesce(reason,''))) > 0),
  constraint prj_settle_transfer check (kind <> 'transfer' or transfer_client_id is not null)
);
create index if not exists prj_settlements_inv_idx on public.prj_settlements(invoice_id);
create index if not exists prj_settlements_prj_idx on public.prj_settlements(project_id);
alter table public.prj_settlements enable row level security;
drop policy if exists prj_settlements_sel on public.prj_settlements;
create policy prj_settlements_sel on public.prj_settlements for select using (public.qy_prj_can_read(company_id));
drop policy if exists prj_settlements_wrt on public.prj_settlements;
create policy prj_settlements_wrt on public.prj_settlements for all
  using (public.qy_prj_can_settle(company_id)) with check (public.qy_prj_can_settle(company_id));

-- ─── ٤) لا يُغلق مشروع وفيه مبلغ غير محصّل ولم يُعالَج ───
create or replace function public.qy_prj_open_amount(p_project uuid)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(greatest(0,
           i.amount
         - coalesce((select sum(c.amount) from public.prj_collections c where c.invoice_id = i.id), 0)
         - coalesce((select sum(s.amount) from public.prj_settlements s where s.invoice_id = i.id
                       and s.cancelled_at is null and s.kind <> 'later'), 0))), 0)
  from public.prj_invoices i where i.project_id = p_project and i.status = 'issued';
$$;
create or replace function public.qy_prj_close_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'closed' and coalesce(old.status,'') <> 'closed' then
    if public.qy_prj_open_amount(new.id) > 0.0005 then
      raise exception 'لا يُغلق المشروع: فيه مبلغ غير محصّل لم يُعالَج (%)', round(public.qy_prj_open_amount(new.id), 3)
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qy_prj_close_guard on public.projects;
create trigger qy_prj_close_guard before update of status on public.projects
  for each row execute function public.qy_prj_close_guard();

-- ─── ٥) مستفيدو المراكز: لكل مستفيد وحدته (فارغة = الشركة) ───
alter table public.beneficiaries_master add column if not exists center_id text references public.centers(id) on delete set null;
alter table public.beneficiaries_master add column if not exists scope_key text generated always as (coalesce(center_id, '')) stored;

-- موظف المركز: ليس من المالية أو الإدارة العليا، وإحدى وحداته مركز أو تحت مركز
create or replace function public.qy_is_center_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select not public.is_admin()
     and not exists (select 1 from public.users u where u.id = public.qy_me()
                     and u.role in ('accountant','cfo','executive_manager'))
     and exists (select 1 from public.qy_user_units(public.qy_me()) x(id)
                 join lateral public.qy_unit_up(x.id) up on true where up.kind = 'center');
$$;

-- تعبئة المستفيدين القدامى: من ظهر في طلبات مركز واحد فقط (وحدة مركز أو تحته) يُنسب إليه
update public.beneficiaries_master bm set center_id = t.cid
from (
  select rb.name, r.company_id, min(r.center_id) cid
  from public.request_beneficiaries rb join public.requests r on r.id = rb.request_id
  group by rb.name, r.company_id
  having count(distinct coalesce(r.center_id,'')) = 1 and min(r.center_id) is not null
) t
where bm.center_id is null and bm.name = t.name and bm.company_id = t.company_id
  and exists (select 1 from public.qy_unit_up(t.cid) up where up.kind = 'center');

-- التفرّد: الاسم مرة واحدة لكل شركة ولكل وحدة
alter table public.beneficiaries_master drop constraint if exists beneficiaries_master_co_name_key;
drop index if exists public.beneficiaries_master_co_name_key;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'beneficiaries_master_co_scope_name_key') then
    alter table public.beneficiaries_master add constraint beneficiaries_master_co_scope_name_key unique (company_id, scope_key, name);
  end if;
end $$;

create or replace function public.qy_bene_can_see(p_company text, p_center text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_company is null then true
    when not public.can_see_company(p_company) then false
    when p_center is null then not public.qy_is_center_staff()
    else public.qy_center_can_see(p_center) end;
$$;
drop policy if exists qyam_sel_beneficiaries on public.beneficiaries_master;
create policy qyam_sel_beneficiaries on public.beneficiaries_master for select
  using (public.qy_bene_can_see(company_id, center_id));
drop policy if exists qyam_wrt_beneficiaries on public.beneficiaries_master;
create policy qyam_wrt_beneficiaries on public.beneficiaries_master for all
  using (company_id is not null and public.qy_bene_can_see(company_id, center_id))
  with check (company_id is not null and public.qy_bene_can_see(company_id, center_id));

grant execute on function public.qy_prj_can_settle(text),
  public.qy_is_center_staff(), public.qy_bene_can_see(text, text) to authenticated;
