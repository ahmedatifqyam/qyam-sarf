-- عقود العاملين (15 نوفمبر 2026): لكل عامل عقده مع الشركة أو أحد مراكزها — أساس قاعدة «لا يُصرف لأحد بلا عقد» لاحقاً
-- الصلاحية: صفحة «العقود» (contracts): المالية دائماً، أو دور له في الصفحة قراءة/تعديل/تحكم كامل
create or replace function public.qy_page_level_ok(p_company text, p_key text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = p_key and p.level = any(p_levels));
$fn$;
create table if not exists public.worker_contracts (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  unit_id text references public.centers(id) on delete set null,
  user_id text references public.users(id) on delete set null,
  person_name text, civil_id text, phone text, iban text,
  contract_type text not null default 'employment' check (contract_type in ('employment','reward','freelance')),
  job_title text,
  start_date date, end_date date,
  amount numeric check (amount is null or amount >= 0),
  pay_cycle text not null default 'monthly' check (pay_cycle in ('monthly','per_task','lump')),
  file_path text, file_name text,
  status text not null default 'active' check (status in ('active','ended')),
  notes text, created_by text, created_at timestamptz not null default now(),
  check (user_id is not null or coalesce(trim(person_name),'') <> '')
);
create index if not exists worker_contracts_company_idx on public.worker_contracts(company_id, status);
alter table public.worker_contracts enable row level security;
drop policy if exists worker_contracts_sel on public.worker_contracts;
drop policy if exists worker_contracts_wrt on public.worker_contracts;
create policy worker_contracts_sel on public.worker_contracts for select to authenticated
  using (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['read','edit','full'])));
create policy worker_contracts_wrt on public.worker_contracts for all to authenticated
  using (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['edit','full'])))
  with check (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['edit','full'])));
