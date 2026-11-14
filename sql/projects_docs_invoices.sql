-- المشاريع: ملاحق العقود، الوثائق (عرض سعر / نموذج خدمة / مقترح خدمة)، المشروع، الفواتير والتحصيل (14 نوفمبر 2026) — للتجربة أولاً
-- الكتابة: المالية دائماً، أو دور صلاحيته في صفحة «المشاريع» تعديل/تحكم كامل. القراءة: المالية، المدير التنفيذي، أو دور له صلاحية قراءة فأعلى.

create or replace function public.qy_prj_level_ok(p_company text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = 'projects' and p.level = any(p_levels));
$fn$;
create or replace function public.qy_prj_can_read(p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select public.can_see_company(p_company) and (
    public.is_finance()
    or exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'executive_manager')
    or public.qy_prj_level_ok(p_company, array['read','edit','full']));
$fn$;
create or replace function public.qy_prj_can_write(p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select public.can_see_company(p_company) and (public.is_finance() or public.qy_prj_level_ok(p_company, array['edit','full']));
$fn$;

-- إعدادات الشركة: من يصله تنبيه «اعمل فاتورة» مع المحاسب، والنسبة الافتراضية للصرف قبل الدفع
alter table public.companies add column if not exists invoice_alert_user_ids jsonb not null default '[]'::jsonb;
alter table public.companies add column if not exists prepay_default_pct numeric not null default 80;

-- العقد وملاحقه: الملحق صف في الجدول نفسه أبوه العقد، وله ملفه وجدول أسعاره (خدمات ليست في العقد)
alter table public.client_contracts add column if not exists parent_id uuid references public.client_contracts(id) on delete cascade;
alter table public.client_contracts add column if not exists file_path text;
alter table public.client_contracts add column if not exists file_name text;
alter table public.client_contracts add column if not exists created_by text;
alter table public.client_contracts alter column billing drop not null;
drop policy if exists client_contracts_all on public.client_contracts;
drop policy if exists client_contracts_sel on public.client_contracts;
drop policy if exists client_contracts_wrt on public.client_contracts;
create policy client_contracts_sel on public.client_contracts for select to authenticated using (public.qy_prj_can_read(company_id));
create policy client_contracts_wrt on public.client_contracts for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));
drop policy if exists contract_prices_all on public.contract_prices;
drop policy if exists contract_prices_sel on public.contract_prices;
drop policy if exists contract_prices_wrt on public.contract_prices;
create policy contract_prices_sel on public.contract_prices for select to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_read(c.company_id)));
create policy contract_prices_wrt on public.contract_prices for all to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_write(c.company_id)))
  with check (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_write(c.company_id)));

-- الوثيقة: تُرفع PDF جاهزة الآن؛ وحقول lines/sections محجوزة لبنائها من داخل النظام لاحقاً
create table if not exists public.prj_documents (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text references public.clients(id) on delete set null,
  doc_type text not null check (doc_type in ('quote','service_form','proposal')),
  seq int not null,
  year int not null,
  doc_no text not null,
  title text not null,
  doc_date date,
  contract_id uuid references public.client_contracts(id) on delete set null,
  amount numeric not null default 0 check (amount >= 0),
  amount_kind text not null default 'total' check (amount_kind in ('total','monthly')),
  months int check (months is null or months > 0),
  open_ended boolean not null default false,
  start_date date,
  status text not null default 'sent' check (status in ('sent','approved','rejected','cancelled')),
  file_path text, file_name text,
  signed_path text, signed_name text,
  decided_at timestamptz, decided_by text, decision_note text,
  lines jsonb not null default '[]'::jsonb,
  sections jsonb not null default '[]'::jsonb,
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  unique (company_id, year, seq)
);
create index if not exists prj_documents_company_idx on public.prj_documents(company_id, created_at desc);
alter table public.prj_documents enable row level security;
drop policy if exists prj_documents_sel on public.prj_documents;
drop policy if exists prj_documents_wrt on public.prj_documents;
create policy prj_documents_sel on public.prj_documents for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_documents_wrt on public.prj_documents for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- المشروع: يُفتح عند اعتماد العميل للوثيقة، ويرتبط ببند ميزانية (الصرف من البند، والدخل إليه عند التحصيل)
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text references public.clients(id) on delete set null,
  document_id uuid unique references public.prj_documents(id) on delete set null,
  name text not null,
  budget_item_id text,
  status text not null default 'active' check (status in ('active','closed')),
  value numeric not null default 0,
  invoice_mode text not null default 'single' check (invoice_mode in ('single','monthly')),
  monthly_amount numeric,
  months int check (months is null or months > 0),
  open_ended boolean not null default false,
  start_date date,
  prepay boolean not null default false,
  prepay_pct numeric not null default 80 check (prepay_pct >= 0 and prepay_pct <= 100),
  report_path text, report_name text,
  closed_at timestamptz, closed_by text,
  notes text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists projects_company_idx on public.projects(company_id, status);
alter table public.projects enable row level security;
drop policy if exists projects_sel on public.projects;
drop policy if exists projects_wrt on public.projects;
create policy projects_sel on public.projects for select to authenticated using (public.can_see_company(company_id));
create policy projects_wrt on public.projects for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- الفاتورة: صورتان (الفاتورة المقدّمة، وعلم الوصول من العميل)، والفترة للفواتير الشهرية
create table if not exists public.prj_invoices (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  inv_no text,
  inv_date date not null default current_date,
  period text,
  amount numeric not null check (amount > 0),
  invoice_path text, invoice_name text,
  receipt_path text, receipt_name text,
  status text not null default 'issued' check (status in ('issued','cancelled')),
  notes text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists prj_invoices_project_idx on public.prj_invoices(project_id);
alter table public.prj_invoices enable row level security;
drop policy if exists prj_invoices_sel on public.prj_invoices;
drop policy if exists prj_invoices_wrt on public.prj_invoices;
create policy prj_invoices_sel on public.prj_invoices for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_invoices_wrt on public.prj_invoices for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- التحصيل: دفعة أو أكثر لكل فاتورة؛ كل دفعة تُسجَّل إيراداً على بند المشروع (budget_revenues)
create table if not exists public.prj_collections (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  invoice_id uuid not null references public.prj_invoices(id) on delete cascade,
  amount numeric not null check (amount > 0),
  paid_on date not null default current_date,
  method text,
  revenue_id text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists prj_collections_invoice_idx on public.prj_collections(invoice_id);
alter table public.prj_collections enable row level security;
drop policy if exists prj_collections_sel on public.prj_collections;
drop policy if exists prj_collections_wrt on public.prj_collections;
create policy prj_collections_sel on public.prj_collections for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_collections_wrt on public.prj_collections for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));
