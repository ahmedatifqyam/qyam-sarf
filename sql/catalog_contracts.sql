-- خدمات الشركة (الكتالوج) وعقود العملاء وأسعارها (14 نوفمبر 2026) — للتجربة أولاً
-- الكتالوج شجرة: 1 خدمة رئيسية ← 2 خدمة فرعية ← 3 بند مسعّر. لكل شركة كتالوجها.
create table if not exists public.svc_catalog (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  parent_id uuid references public.svc_catalog(id) on delete cascade,
  level smallint not null check (level in (1,2,3)),
  name text not null,
  description text,
  unit text,
  price numeric,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists svc_catalog_company_idx on public.svc_catalog(company_id, parent_id);
alter table public.svc_catalog enable row level security;
drop policy if exists svc_catalog_sel on public.svc_catalog;
create policy svc_catalog_sel on public.svc_catalog for select to authenticated using (public.can_see_company(company_id));
drop policy if exists svc_catalog_wrt on public.svc_catalog;
create policy svc_catalog_wrt on public.svc_catalog for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));

-- عقد العميل وشروطه
create table if not exists public.client_contracts (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text not null references public.clients(id) on delete cascade,
  title text not null,
  contract_date date,
  start_date date,
  end_date date,
  auto_renew boolean not null default true,
  renew_notice_months int default 2,
  free_revisions int default 3,
  revision_pct numeric default 10,
  late_pct_day numeric default 2,
  late_pct_max numeric default 20,
  billing text not null default 'monthly' check (billing in ('monthly','per_project','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.client_contracts enable row level security;
drop policy if exists client_contracts_all on public.client_contracts;
create policy client_contracts_all on public.client_contracts for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));

-- جدول أسعار العقد (يُنسخ من الكتالوج ويُعدَّل، أو يُدخل كما في العقد)
create table if not exists public.contract_prices (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.client_contracts(id) on delete cascade,
  catalog_id uuid references public.svc_catalog(id) on delete set null,
  section text,
  name text not null,
  spec text,
  unit text,
  price numeric,
  sort int not null default 0
);
create index if not exists contract_prices_contract_idx on public.contract_prices(contract_id);
alter table public.contract_prices enable row level security;
drop policy if exists contract_prices_all on public.contract_prices;
create policy contract_prices_all on public.contract_prices for all to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.is_finance() and public.can_see_company(c.company_id)))
  with check (exists (select 1 from public.client_contracts c where c.id = contract_id and public.is_finance() and public.can_see_company(c.company_id)));
