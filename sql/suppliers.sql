-- الموردون (16 نوفمبر 2026) — للتجربة أولاً
-- المورد صف في جدول العملاء نفسه: party = client | supplier | both (جهة واحدة قد تكون عميلاً ومورداً)
alter table public.clients add column if not exists party text not null default 'client';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'clients_party_chk') then
    alter table public.clients add constraint clients_party_chk check (party in ('client','supplier','both'));
  end if;
end $$;
alter table public.clients add column if not exists activity text;        -- نوع النشاط: طباعة، تجهيزات، نقل…
alter table public.clients add column if not exists bank_name text;
alter table public.clients add column if not exists iban text;
alter table public.clients add column if not exists account_name text;    -- اسم صاحب الحساب
alter table public.clients add column if not exists license_no text;      -- رقم الرخصة التجارية
alter table public.clients add column if not exists files jsonb not null default '[]'::jsonb;  -- [{kind: iban|license|other, path, name}]

-- القراءة والكتابة: المالية دائماً، أو دور صلاحيته في صفحة «الموردون» (قراءة/تعديل/تحكم) للموردين
drop policy if exists clients_all on public.clients;
drop policy if exists clients_sel on public.clients;
drop policy if exists clients_wrt on public.clients;
drop policy if exists clients_sup_ins on public.clients;
drop policy if exists clients_sup_upd on public.clients;
drop policy if exists clients_sup_del on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));
create policy clients_sel on public.clients for select to authenticated
  using (party <> 'client' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['read','edit','full']));
create policy clients_sup_ins on public.clients for insert to authenticated
  with check (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']));
create policy clients_sup_upd on public.clients for update to authenticated
  using (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']))
  with check (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']));
create policy clients_sup_del on public.clients for delete to authenticated
  using (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['full']));

-- قائمة الاختيار في طلب الصرف: كل من يرى الشركة يختار مورداً نشطاً (الاسم والآيبان فقط) دون فتح صفحة الموردين
create or replace function public.qy_supplier_pick(p_company text)
returns table (id text, name text, name_en text, iban text, bank_name text, account_name text, activity text)
language sql stable security definer set search_path = public as $fn$
  select c.id, c.name, c.name_en, c.iban, c.bank_name, c.account_name, c.activity
  from public.clients c
  where c.company_id = p_company and c.party in ('supplier','both') and c.status = 'active' and public.can_see_company(p_company)
  order by c.name;
$fn$;
grant execute on function public.qy_supplier_pick(text) to authenticated;

-- ربط المستفيد بالمورد: تظهر مدفوعات المورد في صفحته
alter table public.request_beneficiaries add column if not exists supplier_id text references public.clients(id) on delete set null;
create index if not exists request_beneficiaries_supplier_idx on public.request_beneficiaries(supplier_id) where supplier_id is not null;

-- نوع الطلب: عادي، عهدة، راتب، مكافأة
alter table public.requests drop constraint if exists requests_request_type_chk;
alter table public.requests add constraint requests_request_type_chk check (request_type = any (array['normal','custody','payroll','reward']));
