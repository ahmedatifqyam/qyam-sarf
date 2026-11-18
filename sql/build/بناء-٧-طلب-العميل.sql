-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٧ (1.27.0): طلب العميل — ما يشرح فيه العميل المطلوب في المشروع.
-- اختياري. قد يأتي قبل الوثيقة (يظهر «طلب جديد — بانتظار الوثيقة») ثم يُربط بها.
-- يُشغَّل بعد بناء-١..٥. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.prj_client_requests (
  id          uuid primary key default gen_random_uuid(),
  company_id  text not null references public.companies(id) on delete cascade,
  client_id   text references public.clients(id) on delete set null,
  req_date    date not null default current_date,
  channel     text not null default 'other' check (channel in ('letter','email','whatsapp','meeting','phone','other')),
  description text not null check (length(trim(description)) > 0),
  files       jsonb not null default '[]'::jsonb check (jsonb_typeof(files) = 'array' and jsonb_array_length(files) <= 3),
  status      text not null default 'new' check (status in ('new','linked','cancelled')),
  doc_id      uuid references public.prj_documents(id) on delete set null,
  created_by  text,
  created_at  timestamptz not null default now(),
  constraint prj_creq_linked check (status <> 'linked' or doc_id is not null)
);
create index if not exists prj_creq_company_idx on public.prj_client_requests(company_id, status);
create index if not exists prj_creq_doc_idx on public.prj_client_requests(doc_id);
alter table public.prj_client_requests enable row level security;
drop policy if exists prj_creq_sel on public.prj_client_requests;
create policy prj_creq_sel on public.prj_client_requests for select using (public.qy_prj_can_read(company_id));
drop policy if exists prj_creq_wrt on public.prj_client_requests;
create policy prj_creq_wrt on public.prj_client_requests for all
  using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));
