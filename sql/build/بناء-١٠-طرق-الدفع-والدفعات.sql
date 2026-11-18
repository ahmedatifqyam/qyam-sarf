-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٠ (1.34.0): طرق دفع قيمة الوثيقة والمشروع.
--   مرة واحدة (فاتورة أو أكثر بجدول دفعات)، شهري، ربع سنوي، نصف سنوي، سنوي.
--   في الطرق الدورية المبلغ المكتوب = مبلغ الفترة الواحدة (مثال: شهري 1,000 = كل شهر 1,000).
-- يُشغَّل بعد بناء-١..٩. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── ١) الوثيقة: نوع القيمة + جدول الدفعات [{date, amount}] ───
alter table public.prj_documents drop constraint if exists prj_documents_amount_kind_check;
alter table public.prj_documents add constraint prj_documents_amount_kind_check
  check (amount_kind in ('total','monthly','quarterly','semiannual','annual'));
alter table public.prj_documents add column if not exists installments jsonb not null default '[]'::jsonb;
alter table public.prj_documents drop constraint if exists prj_documents_installments_check;
alter table public.prj_documents add constraint prj_documents_installments_check
  check (jsonb_typeof(installments) = 'array' and jsonb_array_length(installments) <= 24);

-- ─── ٢) المشروع: طريقة الفاتورة + جدول الدفعات ───
alter table public.projects drop constraint if exists projects_invoice_mode_check;
alter table public.projects add constraint projects_invoice_mode_check
  check (invoice_mode in ('single','monthly','quarterly','semiannual','annual','installments'));
alter table public.projects add column if not exists installments jsonb not null default '[]'::jsonb;
alter table public.projects drop constraint if exists projects_installments_check;
alter table public.projects add constraint projects_installments_check
  check (jsonb_typeof(installments) = 'array' and jsonb_array_length(installments) <= 24);

-- ملاحظة: monthly_amount في المشاريع صار يعني «مبلغ الفترة الواحدة» (شهر/ربع/نصف/سنة).
comment on column public.projects.monthly_amount is 'مبلغ الفترة الواحدة حسب invoice_mode (شهر، ربع سنة، نصف سنة، سنة)';
