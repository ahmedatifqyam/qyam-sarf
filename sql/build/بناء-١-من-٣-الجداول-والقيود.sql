-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — بناء قاعدة البيانات من الصفر — الجزء ١ من ٣
-- ║  الإضافات والجداول والأعمدة والقيود والفهارس
-- ║  مستخرج آلياً من قاعدة التجربة في 16 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
-- شغّله في قاعدة Supabase فارغة (أو قائمة لتحديثها). لا يحتوي أي بيانات.
set check_function_bodies = off;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
do $n$ begin create extension if not exists pg_net; exception when others then raise notice 'تعذر تفعيل pg_net (إشعارات الجهاز): %', sqlerrm; end $n$;
do $e$ begin create extension if not exists pg_cron; exception when others then raise notice 'فعّل pg_cron من Database ← Extensions ثم أعد تشغيل الجزء ٣: %', sqlerrm; end $e$;

-- دالة هوية المستخدم الحالي (تحتاجها قيمة افتراضية في بعض الجداول)
CREATE OR REPLACE FUNCTION public.qy_me()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.id from public.users u where u.auth_id = auth.uid() limit 1;
$function$
;

-- ═══ التسلسلات ═══
create sequence if not exists public.beneficiaries_master_id_seq;
create sequence if not exists public.request_beneficiaries_id_seq;
create sequence if not exists public.request_history_id_seq;
create sequence if not exists public.push_outbox_id_seq;
create sequence if not exists public.gateway_agents_id_seq;
create sequence if not exists public.gateway_imports_id_seq;
create sequence if not exists public.center_ledger_id_seq;
create sequence if not exists public.gl_exports_id_seq;

-- ═══ الجداول ═══
create table if not exists public.app_settings (
  key text not null,
  value text
);
create table if not exists public.beneficiaries_master (
  id bigint default nextval('beneficiaries_master_id_seq'::regclass) not null,
  name text not null,
  name_en text,
  iban text,
  id_file_data text,
  bank_file_data text,
  company_id text,
  national_id text
);
create table if not exists public.bottom_bar_toggles (
  button_key text not null,
  visible boolean default true not null
);
create table if not exists public.budget_items (
  id text not null,
  company_id text not null,
  parent_id text,
  name text not null,
  type text not null,
  is_recurring boolean default false not null,
  is_active boolean default true not null,
  profit_mode text default 'none'::text not null,
  profit_percent numeric(5,2) default 0 not null,
  profit_fixed numeric(14,3) default 0 not null,
  notes text default ''::text not null,
  created_at timestamp with time zone default now() not null,
  is_protected boolean default false not null,
  gl_expense text,
  gl_income text
);
create table if not exists public.budget_overrun_log (
  id uuid default gen_random_uuid() not null,
  request_id text not null,
  budget_item_id text not null,
  stage text not null,
  actor_id text,
  actor_name text,
  requested_amount numeric(12,3),
  available_balance numeric(12,3),
  created_at timestamp with time zone default now()
);
create table if not exists public.budget_revenues (
  id text not null,
  budget_item_id text not null,
  amount numeric(14,3) not null,
  revenue_date date default CURRENT_DATE not null,
  description text default ''::text not null,
  source_type text,
  entered_by_id text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.center_access (
  center_id text not null,
  user_id text not null,
  mode text not null
);
create table if not exists public.center_ledger (
  id bigint default nextval('center_ledger_id_seq'::regclass) not null,
  company_id text not null,
  center_id text,
  kind text not null,
  entry_date date default CURRENT_DATE not null,
  period_from date,
  period_to date,
  gross numeric default 0 not null,
  gateway_fee numeric default 0 not null,
  company_pct numeric,
  company_share numeric,
  net numeric,
  method text,
  purpose text,
  agent text,
  receipt text,
  note text,
  source text default 'manual'::text not null,
  request_id text,
  import_id bigint,
  voided boolean default false not null,
  created_by text,
  created_at timestamp with time zone default now() not null,
  pair_id bigint,
  order_ref text
);
create table if not exists public.center_ledger_payers (
  ledger_id bigint not null,
  company_id text not null,
  payer_name text,
  payer_phone text
);
create table if not exists public.centers (
  id text not null,
  name text not null,
  letterhead_data text,
  company_id text,
  code text,
  annual_budget numeric,
  monthly_budget numeric,
  min_threshold numeric,
  skip_dept_manager boolean default false,
  skip_senior_manager boolean default false,
  skip_executive_manager boolean default false,
  max_request_amount numeric,
  max_beneficiary_amount numeric,
  require_bank_transfer_ref boolean default true,
  kind text default 'center'::text,
  scope text default 'company'::text,
  footer_mode text default 'company'::text,
  footer_text text,
  parent_id text,
  min_single_approver text default 'exec'::text not null,
  client_id text,
  stage text default 'active'::text not null,
  balance_control boolean default false not null,
  overdraft_limit numeric default 0 not null,
  company_share_pct numeric,
  support_share_pct numeric,
  description text,
  pre_pay boolean default false not null,
  continuous boolean default false not null,
  period_from date,
  period_to date,
  item_budget numeric,
  transfer_user_ids text[] default '{}'::text[] not null,
  stage_note text,
  stage_by text,
  stage_at timestamp with time zone,
  sort integer,
  gl_trust text,
  gl_expense text
);
create table if not exists public.client_contracts (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  client_id text not null,
  title text not null,
  contract_date date,
  start_date date,
  end_date date,
  auto_renew boolean default true not null,
  renew_notice_months integer default 2,
  free_revisions integer default 3,
  revision_pct numeric default 10,
  late_pct_day numeric default 2,
  late_pct_max numeric default 20,
  billing text default 'monthly'::text,
  notes text,
  active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  parent_id uuid,
  file_path text,
  file_name text,
  created_by text
);
create table if not exists public.clients (
  id text default (gen_random_uuid())::text not null,
  company_id text not null,
  parent_id text,
  name text not null,
  name_en text,
  kind text default 'association'::text not null,
  status text default 'active'::text not null,
  address text,
  email text,
  website text,
  tax_no text,
  phones jsonb default '[]'::jsonb not null,
  contacts jsonb default '[]'::jsonb not null,
  notes text,
  created_by text,
  created_at timestamp with time zone default now() not null,
  party text default 'client'::text not null,
  activity text,
  bank_name text,
  iban text,
  account_name text,
  license_no text,
  files jsonb default '[]'::jsonb not null
);
create table if not exists public.companies (
  id text not null,
  name_ar text not null,
  name_en text,
  tax_number text,
  logo_data text,
  primary_color text default '#C0392B'::text,
  code text not null,
  hq_code text default 'HQ'::text not null,
  created_at timestamp with time zone default now(),
  salutation_text text default 'الإخوة / الإدارة المالية'::text,
  reference_text text default 'بالإشارة إلى الموضوع أعلاه'::text,
  org_id text,
  cfo_delegation_mode text default 'normal'::text,
  brand_logo_data text,
  footer_text text,
  footer_show_text boolean default true,
  footer_show_line boolean default true,
  footer_text_color text default '#111111'::text,
  footer_num_color text default '#111111'::text,
  footer_line_color text default '#888888'::text,
  page_num_style text default 'full'::text,
  footer_offset_mm numeric default 4,
  footer_font_mode text default 'auto'::text,
  footer_font_size numeric default 10,
  default_deadline_days integer,
  default_escalate_mode text default 'manager'::text,
  deadline_day_mode text default 'work'::text,
  cfo_delegate_user_id text,
  cfo_delegate_until date,
  signature_mode text default 'seq'::text,
  signature_dir text default 'ltr'::text,
  review_window_minutes integer default 10 not null,
  verify_prefix text,
  currency_symbol text default 'د.ك'::text not null,
  review_mode text default 'optional'::text not null,
  custody_max_open integer default 1 not null,
  custody_default_days integer default 30 not null,
  custody_receipt_days integer default 3 not null,
  custody_max_amount numeric(14,3),
  custody_max_total numeric(14,3),
  custody_path_mode text default 'exec'::text not null,
  custody_img_min numeric(14,3) default 0 not null,
  custody_review_mode text default 'line'::text not null,
  custody_over_mode text default 'none'::text not null,
  custody_over_value numeric(14,3) default 0 not null,
  custody_alert_user_id text,
  custody_nodoc_on boolean default false not null,
  custody_nodoc_mode text,
  custody_nodoc_value numeric(14,3),
  custody_sign_on boolean default true not null,
  custody_signers text default 'any'::text not null,
  late_on boolean default true not null,
  late_from_hour integer default 8 not null,
  late_to_hour integer default 20 not null,
  late_repeat_hours integer default 8 not null,
  late_copy_days integer default 3 not null,
  late_max_days integer default 10 not null,
  late_weekend text default 'fri_sat'::text not null,
  gateway_company_pct numeric default 5 not null,
  support_company_pct numeric default 10 not null,
  import_stale_days integer default 7 not null,
  invoice_alert_user_ids jsonb default '[]'::jsonb not null,
  prepay_default_pct numeric default 80 not null,
  gl_cash text default '120101'::text,
  gl_share text default '4402'::text,
  gl_opening text default '2901'::text,
  gl_custody_parent text default '120201'::text,
  gl_unlinked_mode text default 'warn'::text,
  hr_approver_id text
);
create table if not exists public.contract_prices (
  id uuid default gen_random_uuid() not null,
  contract_id uuid not null,
  catalog_id uuid,
  section text,
  name text not null,
  spec text,
  unit text,
  price numeric,
  sort integer default 0 not null
);
create table if not exists public.custodies (
  id bigint generated always as identity not null,
  request_id text not null,
  company_id text not null,
  holder_id text not null,
  budget_item_id text,
  amount numeric(14,3) not null,
  purpose text,
  carried_in numeric(14,3) default 0 not null,
  carried_from_id bigint,
  status text default 'requested'::text not null,
  due_close_at date,
  received_at timestamp with time zone,
  remaining_action text,
  remaining_amount numeric(14,3),
  settlement_no text,
  reviewed_by_id text,
  signed_by_id text,
  closed_at timestamp with time zone,
  created_by_id text default qy_me() not null,
  created_at timestamp with time zone default now() not null,
  reviewer_id text,
  close_requested_at timestamp with time zone,
  over_mode text,
  over_value numeric(14,3)
);
create table if not exists public.custody_balances (
  id bigint generated always as identity not null,
  holder_id text not null,
  company_id text not null,
  amount numeric(14,3) not null,
  source_custody_id bigint,
  status text default 'open'::text not null,
  applied_custody_id bigint,
  settled_by_id text,
  settled_at timestamp with time zone,
  note text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.custody_lines (
  id bigint generated always as identity not null,
  custody_id bigint not null,
  kind text not null,
  amount numeric(14,3) not null,
  description text not null,
  invoice_no text,
  line_date date default CURRENT_DATE not null,
  image_data text,
  has_image boolean generated always as ((image_data IS NOT NULL)) stored,
  status text default 'draft'::text not null,
  review_note text,
  created_by_id text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  reviewed_by_id text,
  reviewed_at timestamp with time zone,
  reopened boolean default false not null,
  no_doc boolean default false not null,
  no_doc_reason text
);
create table if not exists public.custom_roles (
  id text not null,
  company_id text,
  name text not null,
  description text,
  created_at timestamp with time zone default now(),
  default_level_name text default 'موظف'::text,
  general_default boolean default false,
  can_payroll boolean default false not null
);
create table if not exists public.gateway_accounts (
  id text default (gen_random_uuid())::text not null,
  company_id text not null,
  name text not null,
  merchant_id text,
  active boolean default true not null
);
create table if not exists public.gateway_agents (
  id bigint default nextval('gateway_agents_id_seq'::regclass) not null,
  company_id text not null,
  account_id text,
  agent_name text not null,
  center_id text
);
create table if not exists public.gateway_import_users (
  company_id text not null,
  user_id text not null
);
create table if not exists public.gateway_imports (
  id bigint default nextval('gateway_imports_id_seq'::regclass) not null,
  company_id text not null,
  account_id text,
  kind text not null,
  file_name text,
  date_from date,
  date_to date,
  rows_count integer default 0 not null,
  content text,
  uploaded_by text,
  uploaded_at timestamp with time zone default now() not null
);
create table if not exists public.gl_accounts (
  company_id text not null,
  code text not null,
  name text not null,
  kind text not null,
  parent_code text,
  is_group boolean default false not null,
  is_active boolean default true not null,
  note text,
  updated_by text,
  updated_at timestamp with time zone default now() not null
);
create table if not exists public.gl_custody_accounts (
  company_id text not null,
  holder_id text not null,
  code text not null
);
create table if not exists public.gl_exports (
  id bigint default nextval('gl_exports_id_seq'::regclass) not null,
  company_id text not null,
  month date not null,
  entries integer default 0 not null,
  total numeric default 0 not null,
  unlinked integer default 0 not null,
  exported_by text,
  exported_by_name text,
  exported_at timestamp with time zone default now() not null
);
create table if not exists public.job_levels (
  id text not null,
  company_id text,
  name text not null,
  sort_order integer default 0 not null
);
create table if not exists public.login_aliases (
  phone text not null,
  user_id text not null,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.org_departments (
  id text default (gen_random_uuid())::text not null,
  name text not null,
  func text default 'none'::text not null,
  sort integer default 0 not null,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.organizations (
  id text not null,
  name text not null
);
create table if not exists public.page_permissions (
  company_id text not null,
  role text not null,
  page_key text not null,
  level text not null,
  updated_by text,
  updated_at timestamp with time zone default now() not null
);
create table if not exists public.password_reset_requests (
  id uuid default gen_random_uuid() not null,
  phone text not null,
  user_id text,
  company_id text,
  status text default 'pending'::text not null,
  requested_at timestamp with time zone default now() not null,
  handled_by text,
  handled_at timestamp with time zone
);
create table if not exists public.prj_collections (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  invoice_id uuid not null,
  amount numeric not null,
  paid_on date default CURRENT_DATE not null,
  method text,
  revenue_id text,
  created_by text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.prj_documents (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  client_id text,
  doc_type text not null,
  seq integer not null,
  year integer not null,
  doc_no text not null,
  title text not null,
  doc_date date,
  contract_id uuid,
  amount numeric default 0 not null,
  amount_kind text default 'total'::text not null,
  months integer,
  open_ended boolean default false not null,
  start_date date,
  status text default 'sent'::text not null,
  file_path text,
  file_name text,
  signed_path text,
  signed_name text,
  decided_at timestamp with time zone,
  decided_by text,
  decision_note text,
  lines jsonb default '[]'::jsonb not null,
  sections jsonb default '[]'::jsonb not null,
  notes text,
  created_by text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.prj_invoices (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  project_id uuid not null,
  inv_no text,
  inv_date date default CURRENT_DATE not null,
  period text,
  amount numeric not null,
  invoice_path text,
  invoice_name text,
  receipt_path text,
  receipt_name text,
  status text default 'issued'::text not null,
  notes text,
  created_by text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.projects (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  client_id text,
  document_id uuid,
  name text not null,
  budget_item_id text,
  status text default 'active'::text not null,
  value numeric default 0 not null,
  invoice_mode text default 'single'::text not null,
  monthly_amount numeric,
  months integer,
  open_ended boolean default false not null,
  start_date date,
  prepay boolean default false not null,
  prepay_pct numeric default 80 not null,
  report_path text,
  report_name text,
  closed_at timestamp with time zone,
  closed_by text,
  notes text,
  created_by text,
  created_at timestamp with time zone default now() not null,
  exec_by text,
  exec_party text,
  exec_amount numeric,
  exec_file_path text,
  exec_file_name text,
  exec_status text default 'not_started'::text not null,
  exec_done_at timestamp with time zone,
  amount_route text default 'normal'::text not null,
  route_center_id text
);
create table if not exists public.push_config (
  key text not null,
  value text not null
);
create table if not exists public.push_outbox (
  id bigint default nextval('push_outbox_id_seq'::regclass) not null,
  user_id text not null,
  title text not null,
  body text,
  url text,
  tag text,
  kind text not null,
  request_id text,
  ref text,
  send_after timestamp with time zone default now() not null,
  sent_at timestamp with time zone,
  dedupe text not null,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.push_subscriptions (
  id uuid default gen_random_uuid() not null,
  user_id text not null,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  ua text,
  created_at timestamp with time zone default now() not null,
  all_requests boolean default false not null,
  admin_events text[] default '{}'::text[] not null
);
create table if not exists public.qy_attachments (
  id uuid default gen_random_uuid() not null,
  master_id bigint not null,
  company_id text not null,
  label text not null,
  file_name text not null,
  mime text not null,
  size_bytes integer not null,
  path text not null,
  created_by uuid default auth.uid(),
  created_at timestamp with time zone default now() not null,
  request_id text
);
create table if not exists public.qy_audit_alerts (
  id bigint generated always as identity not null,
  at timestamp with time zone default now() not null,
  kind text not null,
  request_id text,
  step_id text,
  actor_auth uuid,
  actor_user text,
  approver_id text,
  details text,
  reviewed boolean default false not null
);
create table if not exists public.qy_client_events (
  id bigint generated always as identity not null,
  at timestamp with time zone default now() not null,
  kind text not null,
  page text,
  message text,
  details text,
  user_id text,
  phone_tried text,
  ip text,
  device_id text,
  device jsonb,
  reviewed boolean default false not null
);
create table if not exists public.qy_handovers (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  from_user_id text not null,
  to_user_id text not null,
  reason text default 'absence'::text not null,
  scope_all boolean default true not null,
  request_ids text[],
  from_date date default CURRENT_DATE not null,
  to_date date,
  needs_approval boolean default true not null,
  status text default 'pending'::text not null,
  reject_reason text,
  suggested_user_id text,
  note text,
  created_by text,
  created_at timestamp with time zone default now() not null,
  decided_at timestamp with time zone
);
create table if not exists public.qy_verify_hits (
  at timestamp with time zone default now() not null,
  ip text
);
create table if not exists public.recurring_occurrences (
  id uuid default gen_random_uuid() not null,
  template_id uuid not null,
  company_id text not null,
  due_date date not null,
  amount numeric not null,
  status text default 'proposed'::text not null,
  transaction_id uuid,
  note text,
  handled_by_id text,
  handled_by text,
  handled_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  no_auto boolean default false not null
);
create table if not exists public.recurring_settings (
  company_id text not null,
  approval_notify_roles text[] default ARRAY['cfo'::text, 'admin'::text] not null,
  approval_notify_user_ids text[] default '{}'::text[] not null,
  updated_by text,
  updated_at timestamp with time zone default now() not null
);
create table if not exists public.recurring_templates (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  center_id text,
  name text not null,
  category text,
  direction text default 'out'::text not null,
  budget_item_id text not null,
  beneficiary text,
  description text,
  amount numeric not null,
  amount_mode text default 'fixed'::text not null,
  frequency text not null,
  day_mode text default 'day_of_month'::text not null,
  day_of_month integer,
  weekday integer,
  start_date date not null,
  end_mode text default 'none'::text not null,
  end_date date,
  max_count integer,
  auto_post boolean default false not null,
  status text default 'pending_approval'::text not null,
  generation_from date,
  notify_days_before integer default 3 not null,
  notify_on_due boolean default true not null,
  notify_overdue boolean default true not null,
  notify_repeat boolean default false not null,
  notify_roles text[] default ARRAY['creator'::text, 'accountant'::text] not null,
  notify_user_ids text[] default '{}'::text[] not null,
  created_by_id text,
  created_by text,
  approved_by_id text,
  approved_by text,
  approved_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  approval_notify_roles text[],
  approval_notify_user_ids text[]
);
create table if not exists public.request_approval_steps (
  id text not null,
  request_id text,
  approver_id text,
  sequence_order integer not null,
  role_label text,
  status text default 'pending'::text,
  acted_at timestamp with time zone,
  note text,
  created_at timestamp with time zone default now(),
  kind text default 'primary'::text,
  escalated_from text,
  activated_at timestamp with time zone,
  acted_by_auth uuid,
  method text,
  paper_path text,
  paper_signed_at date,
  recorded_by text
);
create table if not exists public.request_beneficiaries (
  id bigint default nextval('request_beneficiaries_id_seq'::regclass) not null,
  request_id text,
  name text,
  name_en text,
  iban text,
  statement text,
  notes text,
  amount numeric default 0,
  deduction numeric default 0,
  deduction_note text,
  national_id text,
  extra numeric default 0,
  extra_note text,
  contract_id uuid,
  supplier_id text
);
create table if not exists public.request_history (
  id bigint default nextval('request_history_id_seq'::regclass) not null,
  request_id text,
  step text,
  actor text,
  user_id text,
  action text,
  note text,
  "time" text,
  created_at timestamp with time zone default now(),
  signature_override text,
  auth_uid uuid
);
create table if not exists public.request_number_counters (
  prefix text not null,
  suffix text not null,
  last_n integer default 0 not null
);
create table if not exists public.requests (
  id text not null,
  number text,
  reason text not null,
  total_amount numeric default 0 not null,
  status text not null,
  origin text not null,
  center_id text,
  created_by text not null,
  created_by_id text,
  date_greg text,
  date_hijri text,
  created_at timestamp with time zone default now(),
  is_recurring boolean default false,
  company_id text,
  detailed_reason text,
  is_cancelled boolean default false,
  cancelled_at timestamp with time zone,
  cancelled_by_id text,
  cancel_reason text,
  bank_transfer_ref text,
  bank_transfer_at timestamp with time zone,
  fast_tracked boolean default false,
  limit_exceeded boolean default false,
  budget_item_id text,
  review_until timestamp with time zone,
  number_prefix text,
  number_suffix text,
  verify_code text,
  request_notes text,
  request_type text default 'normal'::text not null,
  salutation_text text,
  reference_text text,
  amount_route text default 'normal'::text not null,
  route_center_id text
);
create table if not exists public.signature_layout_configs (
  id text not null,
  role text not null,
  config jsonb default '{}'::jsonb not null,
  updated_at timestamp with time zone default now(),
  context text default 'final'::text not null
);
create table if not exists public.svc_catalog (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  parent_id uuid,
  level smallint not null,
  name text not null,
  description text,
  unit text,
  price numeric,
  active boolean default true not null,
  sort integer default 0 not null,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.transactions (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  center_id text,
  tx_date date default CURRENT_DATE not null,
  direction text not null,
  amount numeric(14,3) not null,
  budget_item_id text,
  beneficiary text,
  description text not null,
  source_type text not null,
  source_id text,
  reverses_id uuid,
  note text,
  created_by_id text,
  created_by text,
  created_at timestamp with time zone default now() not null,
  refund_of_id uuid
);
create table if not exists public.user_companies (
  user_id text not null,
  company_id text not null
);
create table if not exists public.user_company_managers (
  user_id text not null,
  company_id text not null,
  manager_id text
);
create table if not exists public.users (
  id text not null,
  phone text not null,
  name text not null,
  role text not null,
  center_id text,
  signature_data text,
  stamp_data text,
  email text,
  name_en text,
  iban text,
  id_file_data text,
  bank_file_data text,
  signature_mode text default 'fixed'::text,
  signature_color text default '#1B2733'::text,
  signature_width numeric default 2.2,
  company_id text,
  national_id text,
  stamp_data_2 text,
  manager_id text,
  notif_seen_at timestamp with time zone,
  job_title text,
  level_id text,
  request_approver_id text,
  next_approver_id text,
  exec_substitute_id text,
  is_general boolean default false,
  no_request_approver boolean default false,
  no_next_approver boolean default false,
  approval_deadline_days integer,
  escalate_mode text,
  escalate_user_id text,
  auth_id uuid,
  can_manage_recurring boolean default false not null,
  idle_minutes integer,
  is_suspended boolean default false not null,
  suspended_at timestamp with time zone,
  suspended_note text,
  direct_to_transfer boolean default false not null,
  skip_review boolean default false not null,
  avatar_data text,
  paper_approval boolean default false not null,
  paper_proxy_ids text[] default '{}'::text[] not null,
  org_dept_id text
);
create table if not exists public.worker_contracts (
  id uuid default gen_random_uuid() not null,
  company_id text not null,
  unit_id text,
  user_id text,
  person_name text,
  civil_id text,
  phone text,
  iban text,
  contract_type text default 'employment'::text not null,
  job_title text,
  start_date date,
  end_date date,
  amount numeric,
  pay_cycle text default 'monthly'::text not null,
  file_path text,
  file_name text,
  status text default 'active'::text not null,
  notes text,
  created_by text,
  created_at timestamp with time zone default now() not null
);

-- ═══ الأعمدة (لتحديث قاعدة قائمة: تضيف الناقص فقط) ═══
alter table public.app_settings add column if not exists key text;
alter table public.app_settings add column if not exists value text;
alter table public.beneficiaries_master add column if not exists id bigint default nextval('beneficiaries_master_id_seq'::regclass) not null;
alter table public.beneficiaries_master add column if not exists name text;
alter table public.beneficiaries_master add column if not exists name_en text;
alter table public.beneficiaries_master add column if not exists iban text;
alter table public.beneficiaries_master add column if not exists id_file_data text;
alter table public.beneficiaries_master add column if not exists bank_file_data text;
alter table public.beneficiaries_master add column if not exists company_id text;
alter table public.beneficiaries_master add column if not exists national_id text;
alter table public.bottom_bar_toggles add column if not exists button_key text;
alter table public.bottom_bar_toggles add column if not exists visible boolean default true not null;
alter table public.budget_items add column if not exists id text;
alter table public.budget_items add column if not exists company_id text;
alter table public.budget_items add column if not exists parent_id text;
alter table public.budget_items add column if not exists name text;
alter table public.budget_items add column if not exists type text;
alter table public.budget_items add column if not exists is_recurring boolean default false not null;
alter table public.budget_items add column if not exists is_active boolean default true not null;
alter table public.budget_items add column if not exists profit_mode text default 'none'::text not null;
alter table public.budget_items add column if not exists profit_percent numeric(5,2) default 0 not null;
alter table public.budget_items add column if not exists profit_fixed numeric(14,3) default 0 not null;
alter table public.budget_items add column if not exists notes text default ''::text not null;
alter table public.budget_items add column if not exists created_at timestamp with time zone default now() not null;
alter table public.budget_items add column if not exists is_protected boolean default false not null;
alter table public.budget_items add column if not exists gl_expense text;
alter table public.budget_items add column if not exists gl_income text;
alter table public.budget_overrun_log add column if not exists id uuid default gen_random_uuid() not null;
alter table public.budget_overrun_log add column if not exists request_id text;
alter table public.budget_overrun_log add column if not exists budget_item_id text;
alter table public.budget_overrun_log add column if not exists stage text;
alter table public.budget_overrun_log add column if not exists actor_id text;
alter table public.budget_overrun_log add column if not exists actor_name text;
alter table public.budget_overrun_log add column if not exists requested_amount numeric(12,3);
alter table public.budget_overrun_log add column if not exists available_balance numeric(12,3);
alter table public.budget_overrun_log add column if not exists created_at timestamp with time zone default now();
alter table public.budget_revenues add column if not exists id text;
alter table public.budget_revenues add column if not exists budget_item_id text;
alter table public.budget_revenues add column if not exists amount numeric(14,3);
alter table public.budget_revenues add column if not exists revenue_date date default CURRENT_DATE not null;
alter table public.budget_revenues add column if not exists description text default ''::text not null;
alter table public.budget_revenues add column if not exists source_type text;
alter table public.budget_revenues add column if not exists entered_by_id text;
alter table public.budget_revenues add column if not exists created_at timestamp with time zone default now() not null;
alter table public.center_access add column if not exists center_id text;
alter table public.center_access add column if not exists user_id text;
alter table public.center_access add column if not exists mode text;
alter table public.center_ledger add column if not exists id bigint default nextval('center_ledger_id_seq'::regclass) not null;
alter table public.center_ledger add column if not exists company_id text;
alter table public.center_ledger add column if not exists center_id text;
alter table public.center_ledger add column if not exists kind text;
alter table public.center_ledger add column if not exists entry_date date default CURRENT_DATE not null;
alter table public.center_ledger add column if not exists period_from date;
alter table public.center_ledger add column if not exists period_to date;
alter table public.center_ledger add column if not exists gross numeric default 0 not null;
alter table public.center_ledger add column if not exists gateway_fee numeric default 0 not null;
alter table public.center_ledger add column if not exists company_pct numeric;
alter table public.center_ledger add column if not exists company_share numeric;
alter table public.center_ledger add column if not exists net numeric;
alter table public.center_ledger add column if not exists method text;
alter table public.center_ledger add column if not exists purpose text;
alter table public.center_ledger add column if not exists agent text;
alter table public.center_ledger add column if not exists receipt text;
alter table public.center_ledger add column if not exists note text;
alter table public.center_ledger add column if not exists source text default 'manual'::text not null;
alter table public.center_ledger add column if not exists request_id text;
alter table public.center_ledger add column if not exists import_id bigint;
alter table public.center_ledger add column if not exists voided boolean default false not null;
alter table public.center_ledger add column if not exists created_by text;
alter table public.center_ledger add column if not exists created_at timestamp with time zone default now() not null;
alter table public.center_ledger add column if not exists pair_id bigint;
alter table public.center_ledger add column if not exists order_ref text;
alter table public.center_ledger_payers add column if not exists ledger_id bigint;
alter table public.center_ledger_payers add column if not exists company_id text;
alter table public.center_ledger_payers add column if not exists payer_name text;
alter table public.center_ledger_payers add column if not exists payer_phone text;
alter table public.centers add column if not exists id text;
alter table public.centers add column if not exists name text;
alter table public.centers add column if not exists letterhead_data text;
alter table public.centers add column if not exists company_id text;
alter table public.centers add column if not exists code text;
alter table public.centers add column if not exists annual_budget numeric;
alter table public.centers add column if not exists monthly_budget numeric;
alter table public.centers add column if not exists min_threshold numeric;
alter table public.centers add column if not exists skip_dept_manager boolean default false;
alter table public.centers add column if not exists skip_senior_manager boolean default false;
alter table public.centers add column if not exists skip_executive_manager boolean default false;
alter table public.centers add column if not exists max_request_amount numeric;
alter table public.centers add column if not exists max_beneficiary_amount numeric;
alter table public.centers add column if not exists require_bank_transfer_ref boolean default true;
alter table public.centers add column if not exists kind text default 'center'::text;
alter table public.centers add column if not exists scope text default 'company'::text;
alter table public.centers add column if not exists footer_mode text default 'company'::text;
alter table public.centers add column if not exists footer_text text;
alter table public.centers add column if not exists parent_id text;
alter table public.centers add column if not exists min_single_approver text default 'exec'::text not null;
alter table public.centers add column if not exists client_id text;
alter table public.centers add column if not exists stage text default 'active'::text not null;
alter table public.centers add column if not exists balance_control boolean default false not null;
alter table public.centers add column if not exists overdraft_limit numeric default 0 not null;
alter table public.centers add column if not exists company_share_pct numeric;
alter table public.centers add column if not exists support_share_pct numeric;
alter table public.centers add column if not exists description text;
alter table public.centers add column if not exists pre_pay boolean default false not null;
alter table public.centers add column if not exists continuous boolean default false not null;
alter table public.centers add column if not exists period_from date;
alter table public.centers add column if not exists period_to date;
alter table public.centers add column if not exists item_budget numeric;
alter table public.centers add column if not exists transfer_user_ids text[] default '{}'::text[] not null;
alter table public.centers add column if not exists stage_note text;
alter table public.centers add column if not exists stage_by text;
alter table public.centers add column if not exists stage_at timestamp with time zone;
alter table public.centers add column if not exists sort integer;
alter table public.centers add column if not exists gl_trust text;
alter table public.centers add column if not exists gl_expense text;
alter table public.client_contracts add column if not exists id uuid default gen_random_uuid() not null;
alter table public.client_contracts add column if not exists company_id text;
alter table public.client_contracts add column if not exists client_id text;
alter table public.client_contracts add column if not exists title text;
alter table public.client_contracts add column if not exists contract_date date;
alter table public.client_contracts add column if not exists start_date date;
alter table public.client_contracts add column if not exists end_date date;
alter table public.client_contracts add column if not exists auto_renew boolean default true not null;
alter table public.client_contracts add column if not exists renew_notice_months integer default 2;
alter table public.client_contracts add column if not exists free_revisions integer default 3;
alter table public.client_contracts add column if not exists revision_pct numeric default 10;
alter table public.client_contracts add column if not exists late_pct_day numeric default 2;
alter table public.client_contracts add column if not exists late_pct_max numeric default 20;
alter table public.client_contracts add column if not exists billing text default 'monthly'::text;
alter table public.client_contracts add column if not exists notes text;
alter table public.client_contracts add column if not exists active boolean default true not null;
alter table public.client_contracts add column if not exists created_at timestamp with time zone default now() not null;
alter table public.client_contracts add column if not exists parent_id uuid;
alter table public.client_contracts add column if not exists file_path text;
alter table public.client_contracts add column if not exists file_name text;
alter table public.client_contracts add column if not exists created_by text;
alter table public.clients add column if not exists id text default (gen_random_uuid())::text not null;
alter table public.clients add column if not exists company_id text;
alter table public.clients add column if not exists parent_id text;
alter table public.clients add column if not exists name text;
alter table public.clients add column if not exists name_en text;
alter table public.clients add column if not exists kind text default 'association'::text not null;
alter table public.clients add column if not exists status text default 'active'::text not null;
alter table public.clients add column if not exists address text;
alter table public.clients add column if not exists email text;
alter table public.clients add column if not exists website text;
alter table public.clients add column if not exists tax_no text;
alter table public.clients add column if not exists phones jsonb default '[]'::jsonb not null;
alter table public.clients add column if not exists contacts jsonb default '[]'::jsonb not null;
alter table public.clients add column if not exists notes text;
alter table public.clients add column if not exists created_by text;
alter table public.clients add column if not exists created_at timestamp with time zone default now() not null;
alter table public.clients add column if not exists party text default 'client'::text not null;
alter table public.clients add column if not exists activity text;
alter table public.clients add column if not exists bank_name text;
alter table public.clients add column if not exists iban text;
alter table public.clients add column if not exists account_name text;
alter table public.clients add column if not exists license_no text;
alter table public.clients add column if not exists files jsonb default '[]'::jsonb not null;
alter table public.companies add column if not exists id text;
alter table public.companies add column if not exists name_ar text;
alter table public.companies add column if not exists name_en text;
alter table public.companies add column if not exists tax_number text;
alter table public.companies add column if not exists logo_data text;
alter table public.companies add column if not exists primary_color text default '#C0392B'::text;
alter table public.companies add column if not exists code text;
alter table public.companies add column if not exists hq_code text default 'HQ'::text not null;
alter table public.companies add column if not exists created_at timestamp with time zone default now();
alter table public.companies add column if not exists salutation_text text default 'الإخوة / الإدارة المالية'::text;
alter table public.companies add column if not exists reference_text text default 'بالإشارة إلى الموضوع أعلاه'::text;
alter table public.companies add column if not exists org_id text;
alter table public.companies add column if not exists cfo_delegation_mode text default 'normal'::text;
alter table public.companies add column if not exists brand_logo_data text;
alter table public.companies add column if not exists footer_text text;
alter table public.companies add column if not exists footer_show_text boolean default true;
alter table public.companies add column if not exists footer_show_line boolean default true;
alter table public.companies add column if not exists footer_text_color text default '#111111'::text;
alter table public.companies add column if not exists footer_num_color text default '#111111'::text;
alter table public.companies add column if not exists footer_line_color text default '#888888'::text;
alter table public.companies add column if not exists page_num_style text default 'full'::text;
alter table public.companies add column if not exists footer_offset_mm numeric default 4;
alter table public.companies add column if not exists footer_font_mode text default 'auto'::text;
alter table public.companies add column if not exists footer_font_size numeric default 10;
alter table public.companies add column if not exists default_deadline_days integer;
alter table public.companies add column if not exists default_escalate_mode text default 'manager'::text;
alter table public.companies add column if not exists deadline_day_mode text default 'work'::text;
alter table public.companies add column if not exists cfo_delegate_user_id text;
alter table public.companies add column if not exists cfo_delegate_until date;
alter table public.companies add column if not exists signature_mode text default 'seq'::text;
alter table public.companies add column if not exists signature_dir text default 'ltr'::text;
alter table public.companies add column if not exists review_window_minutes integer default 10 not null;
alter table public.companies add column if not exists verify_prefix text;
alter table public.companies add column if not exists currency_symbol text default 'د.ك'::text not null;
alter table public.companies add column if not exists review_mode text default 'optional'::text not null;
alter table public.companies add column if not exists custody_max_open integer default 1 not null;
alter table public.companies add column if not exists custody_default_days integer default 30 not null;
alter table public.companies add column if not exists custody_receipt_days integer default 3 not null;
alter table public.companies add column if not exists custody_max_amount numeric(14,3);
alter table public.companies add column if not exists custody_max_total numeric(14,3);
alter table public.companies add column if not exists custody_path_mode text default 'exec'::text not null;
alter table public.companies add column if not exists custody_img_min numeric(14,3) default 0 not null;
alter table public.companies add column if not exists custody_review_mode text default 'line'::text not null;
alter table public.companies add column if not exists custody_over_mode text default 'none'::text not null;
alter table public.companies add column if not exists custody_over_value numeric(14,3) default 0 not null;
alter table public.companies add column if not exists custody_alert_user_id text;
alter table public.companies add column if not exists custody_nodoc_on boolean default false not null;
alter table public.companies add column if not exists custody_nodoc_mode text;
alter table public.companies add column if not exists custody_nodoc_value numeric(14,3);
alter table public.companies add column if not exists custody_sign_on boolean default true not null;
alter table public.companies add column if not exists custody_signers text default 'any'::text not null;
alter table public.companies add column if not exists late_on boolean default true not null;
alter table public.companies add column if not exists late_from_hour integer default 8 not null;
alter table public.companies add column if not exists late_to_hour integer default 20 not null;
alter table public.companies add column if not exists late_repeat_hours integer default 8 not null;
alter table public.companies add column if not exists late_copy_days integer default 3 not null;
alter table public.companies add column if not exists late_max_days integer default 10 not null;
alter table public.companies add column if not exists late_weekend text default 'fri_sat'::text not null;
alter table public.companies add column if not exists gateway_company_pct numeric default 5 not null;
alter table public.companies add column if not exists support_company_pct numeric default 10 not null;
alter table public.companies add column if not exists import_stale_days integer default 7 not null;
alter table public.companies add column if not exists invoice_alert_user_ids jsonb default '[]'::jsonb not null;
alter table public.companies add column if not exists prepay_default_pct numeric default 80 not null;
alter table public.companies add column if not exists gl_cash text default '120101'::text;
alter table public.companies add column if not exists gl_share text default '4402'::text;
alter table public.companies add column if not exists gl_opening text default '2901'::text;
alter table public.companies add column if not exists gl_custody_parent text default '120201'::text;
alter table public.companies add column if not exists gl_unlinked_mode text default 'warn'::text;
alter table public.companies add column if not exists hr_approver_id text;
alter table public.contract_prices add column if not exists id uuid default gen_random_uuid() not null;
alter table public.contract_prices add column if not exists contract_id uuid;
alter table public.contract_prices add column if not exists catalog_id uuid;
alter table public.contract_prices add column if not exists section text;
alter table public.contract_prices add column if not exists name text;
alter table public.contract_prices add column if not exists spec text;
alter table public.contract_prices add column if not exists unit text;
alter table public.contract_prices add column if not exists price numeric;
alter table public.contract_prices add column if not exists sort integer default 0 not null;
alter table public.custodies add column if not exists id bigint not null;
alter table public.custodies add column if not exists request_id text;
alter table public.custodies add column if not exists company_id text;
alter table public.custodies add column if not exists holder_id text;
alter table public.custodies add column if not exists budget_item_id text;
alter table public.custodies add column if not exists amount numeric(14,3);
alter table public.custodies add column if not exists purpose text;
alter table public.custodies add column if not exists carried_in numeric(14,3) default 0 not null;
alter table public.custodies add column if not exists carried_from_id bigint;
alter table public.custodies add column if not exists status text default 'requested'::text not null;
alter table public.custodies add column if not exists due_close_at date;
alter table public.custodies add column if not exists received_at timestamp with time zone;
alter table public.custodies add column if not exists remaining_action text;
alter table public.custodies add column if not exists remaining_amount numeric(14,3);
alter table public.custodies add column if not exists settlement_no text;
alter table public.custodies add column if not exists reviewed_by_id text;
alter table public.custodies add column if not exists signed_by_id text;
alter table public.custodies add column if not exists closed_at timestamp with time zone;
alter table public.custodies add column if not exists created_by_id text default qy_me() not null;
alter table public.custodies add column if not exists created_at timestamp with time zone default now() not null;
alter table public.custodies add column if not exists reviewer_id text;
alter table public.custodies add column if not exists close_requested_at timestamp with time zone;
alter table public.custodies add column if not exists over_mode text;
alter table public.custodies add column if not exists over_value numeric(14,3);
alter table public.custody_balances add column if not exists id bigint not null;
alter table public.custody_balances add column if not exists holder_id text;
alter table public.custody_balances add column if not exists company_id text;
alter table public.custody_balances add column if not exists amount numeric(14,3);
alter table public.custody_balances add column if not exists source_custody_id bigint;
alter table public.custody_balances add column if not exists status text default 'open'::text not null;
alter table public.custody_balances add column if not exists applied_custody_id bigint;
alter table public.custody_balances add column if not exists settled_by_id text;
alter table public.custody_balances add column if not exists settled_at timestamp with time zone;
alter table public.custody_balances add column if not exists note text;
alter table public.custody_balances add column if not exists created_at timestamp with time zone default now() not null;
alter table public.custody_lines add column if not exists id bigint not null;
alter table public.custody_lines add column if not exists custody_id bigint;
alter table public.custody_lines add column if not exists kind text;
alter table public.custody_lines add column if not exists amount numeric(14,3);
alter table public.custody_lines add column if not exists description text;
alter table public.custody_lines add column if not exists invoice_no text;
alter table public.custody_lines add column if not exists line_date date default CURRENT_DATE not null;
alter table public.custody_lines add column if not exists image_data text;
alter table public.custody_lines add column if not exists has_image boolean generated always as ((image_data IS NOT NULL)) stored;
alter table public.custody_lines add column if not exists status text default 'draft'::text not null;
alter table public.custody_lines add column if not exists review_note text;
alter table public.custody_lines add column if not exists created_by_id text;
alter table public.custody_lines add column if not exists created_at timestamp with time zone default now() not null;
alter table public.custody_lines add column if not exists updated_at timestamp with time zone default now() not null;
alter table public.custody_lines add column if not exists reviewed_by_id text;
alter table public.custody_lines add column if not exists reviewed_at timestamp with time zone;
alter table public.custody_lines add column if not exists reopened boolean default false not null;
alter table public.custody_lines add column if not exists no_doc boolean default false not null;
alter table public.custody_lines add column if not exists no_doc_reason text;
alter table public.custom_roles add column if not exists id text;
alter table public.custom_roles add column if not exists company_id text;
alter table public.custom_roles add column if not exists name text;
alter table public.custom_roles add column if not exists description text;
alter table public.custom_roles add column if not exists created_at timestamp with time zone default now();
alter table public.custom_roles add column if not exists default_level_name text default 'موظف'::text;
alter table public.custom_roles add column if not exists general_default boolean default false;
alter table public.custom_roles add column if not exists can_payroll boolean default false not null;
alter table public.gateway_accounts add column if not exists id text default (gen_random_uuid())::text not null;
alter table public.gateway_accounts add column if not exists company_id text;
alter table public.gateway_accounts add column if not exists name text;
alter table public.gateway_accounts add column if not exists merchant_id text;
alter table public.gateway_accounts add column if not exists active boolean default true not null;
alter table public.gateway_agents add column if not exists id bigint default nextval('gateway_agents_id_seq'::regclass) not null;
alter table public.gateway_agents add column if not exists company_id text;
alter table public.gateway_agents add column if not exists account_id text;
alter table public.gateway_agents add column if not exists agent_name text;
alter table public.gateway_agents add column if not exists center_id text;
alter table public.gateway_import_users add column if not exists company_id text;
alter table public.gateway_import_users add column if not exists user_id text;
alter table public.gateway_imports add column if not exists id bigint default nextval('gateway_imports_id_seq'::regclass) not null;
alter table public.gateway_imports add column if not exists company_id text;
alter table public.gateway_imports add column if not exists account_id text;
alter table public.gateway_imports add column if not exists kind text;
alter table public.gateway_imports add column if not exists file_name text;
alter table public.gateway_imports add column if not exists date_from date;
alter table public.gateway_imports add column if not exists date_to date;
alter table public.gateway_imports add column if not exists rows_count integer default 0 not null;
alter table public.gateway_imports add column if not exists content text;
alter table public.gateway_imports add column if not exists uploaded_by text;
alter table public.gateway_imports add column if not exists uploaded_at timestamp with time zone default now() not null;
alter table public.gl_accounts add column if not exists company_id text;
alter table public.gl_accounts add column if not exists code text;
alter table public.gl_accounts add column if not exists name text;
alter table public.gl_accounts add column if not exists kind text;
alter table public.gl_accounts add column if not exists parent_code text;
alter table public.gl_accounts add column if not exists is_group boolean default false not null;
alter table public.gl_accounts add column if not exists is_active boolean default true not null;
alter table public.gl_accounts add column if not exists note text;
alter table public.gl_accounts add column if not exists updated_by text;
alter table public.gl_accounts add column if not exists updated_at timestamp with time zone default now() not null;
alter table public.gl_custody_accounts add column if not exists company_id text;
alter table public.gl_custody_accounts add column if not exists holder_id text;
alter table public.gl_custody_accounts add column if not exists code text;
alter table public.gl_exports add column if not exists id bigint default nextval('gl_exports_id_seq'::regclass) not null;
alter table public.gl_exports add column if not exists company_id text;
alter table public.gl_exports add column if not exists month date;
alter table public.gl_exports add column if not exists entries integer default 0 not null;
alter table public.gl_exports add column if not exists total numeric default 0 not null;
alter table public.gl_exports add column if not exists unlinked integer default 0 not null;
alter table public.gl_exports add column if not exists exported_by text;
alter table public.gl_exports add column if not exists exported_by_name text;
alter table public.gl_exports add column if not exists exported_at timestamp with time zone default now() not null;
alter table public.job_levels add column if not exists id text;
alter table public.job_levels add column if not exists company_id text;
alter table public.job_levels add column if not exists name text;
alter table public.job_levels add column if not exists sort_order integer default 0 not null;
alter table public.login_aliases add column if not exists phone text;
alter table public.login_aliases add column if not exists user_id text;
alter table public.login_aliases add column if not exists created_at timestamp with time zone default now() not null;
alter table public.org_departments add column if not exists id text default (gen_random_uuid())::text not null;
alter table public.org_departments add column if not exists name text;
alter table public.org_departments add column if not exists func text default 'none'::text not null;
alter table public.org_departments add column if not exists sort integer default 0 not null;
alter table public.org_departments add column if not exists created_at timestamp with time zone default now() not null;
alter table public.organizations add column if not exists id text;
alter table public.organizations add column if not exists name text;
alter table public.page_permissions add column if not exists company_id text;
alter table public.page_permissions add column if not exists role text;
alter table public.page_permissions add column if not exists page_key text;
alter table public.page_permissions add column if not exists level text;
alter table public.page_permissions add column if not exists updated_by text;
alter table public.page_permissions add column if not exists updated_at timestamp with time zone default now() not null;
alter table public.password_reset_requests add column if not exists id uuid default gen_random_uuid() not null;
alter table public.password_reset_requests add column if not exists phone text;
alter table public.password_reset_requests add column if not exists user_id text;
alter table public.password_reset_requests add column if not exists company_id text;
alter table public.password_reset_requests add column if not exists status text default 'pending'::text not null;
alter table public.password_reset_requests add column if not exists requested_at timestamp with time zone default now() not null;
alter table public.password_reset_requests add column if not exists handled_by text;
alter table public.password_reset_requests add column if not exists handled_at timestamp with time zone;
alter table public.prj_collections add column if not exists id uuid default gen_random_uuid() not null;
alter table public.prj_collections add column if not exists company_id text;
alter table public.prj_collections add column if not exists invoice_id uuid;
alter table public.prj_collections add column if not exists amount numeric;
alter table public.prj_collections add column if not exists paid_on date default CURRENT_DATE not null;
alter table public.prj_collections add column if not exists method text;
alter table public.prj_collections add column if not exists revenue_id text;
alter table public.prj_collections add column if not exists created_by text;
alter table public.prj_collections add column if not exists created_at timestamp with time zone default now() not null;
alter table public.prj_documents add column if not exists id uuid default gen_random_uuid() not null;
alter table public.prj_documents add column if not exists company_id text;
alter table public.prj_documents add column if not exists client_id text;
alter table public.prj_documents add column if not exists doc_type text;
alter table public.prj_documents add column if not exists seq integer;
alter table public.prj_documents add column if not exists year integer;
alter table public.prj_documents add column if not exists doc_no text;
alter table public.prj_documents add column if not exists title text;
alter table public.prj_documents add column if not exists doc_date date;
alter table public.prj_documents add column if not exists contract_id uuid;
alter table public.prj_documents add column if not exists amount numeric default 0 not null;
alter table public.prj_documents add column if not exists amount_kind text default 'total'::text not null;
alter table public.prj_documents add column if not exists months integer;
alter table public.prj_documents add column if not exists open_ended boolean default false not null;
alter table public.prj_documents add column if not exists start_date date;
alter table public.prj_documents add column if not exists status text default 'sent'::text not null;
alter table public.prj_documents add column if not exists file_path text;
alter table public.prj_documents add column if not exists file_name text;
alter table public.prj_documents add column if not exists signed_path text;
alter table public.prj_documents add column if not exists signed_name text;
alter table public.prj_documents add column if not exists decided_at timestamp with time zone;
alter table public.prj_documents add column if not exists decided_by text;
alter table public.prj_documents add column if not exists decision_note text;
alter table public.prj_documents add column if not exists lines jsonb default '[]'::jsonb not null;
alter table public.prj_documents add column if not exists sections jsonb default '[]'::jsonb not null;
alter table public.prj_documents add column if not exists notes text;
alter table public.prj_documents add column if not exists created_by text;
alter table public.prj_documents add column if not exists created_at timestamp with time zone default now() not null;
alter table public.prj_invoices add column if not exists id uuid default gen_random_uuid() not null;
alter table public.prj_invoices add column if not exists company_id text;
alter table public.prj_invoices add column if not exists project_id uuid;
alter table public.prj_invoices add column if not exists inv_no text;
alter table public.prj_invoices add column if not exists inv_date date default CURRENT_DATE not null;
alter table public.prj_invoices add column if not exists period text;
alter table public.prj_invoices add column if not exists amount numeric;
alter table public.prj_invoices add column if not exists invoice_path text;
alter table public.prj_invoices add column if not exists invoice_name text;
alter table public.prj_invoices add column if not exists receipt_path text;
alter table public.prj_invoices add column if not exists receipt_name text;
alter table public.prj_invoices add column if not exists status text default 'issued'::text not null;
alter table public.prj_invoices add column if not exists notes text;
alter table public.prj_invoices add column if not exists created_by text;
alter table public.prj_invoices add column if not exists created_at timestamp with time zone default now() not null;
alter table public.projects add column if not exists id uuid default gen_random_uuid() not null;
alter table public.projects add column if not exists company_id text;
alter table public.projects add column if not exists client_id text;
alter table public.projects add column if not exists document_id uuid;
alter table public.projects add column if not exists name text;
alter table public.projects add column if not exists budget_item_id text;
alter table public.projects add column if not exists status text default 'active'::text not null;
alter table public.projects add column if not exists value numeric default 0 not null;
alter table public.projects add column if not exists invoice_mode text default 'single'::text not null;
alter table public.projects add column if not exists monthly_amount numeric;
alter table public.projects add column if not exists months integer;
alter table public.projects add column if not exists open_ended boolean default false not null;
alter table public.projects add column if not exists start_date date;
alter table public.projects add column if not exists prepay boolean default false not null;
alter table public.projects add column if not exists prepay_pct numeric default 80 not null;
alter table public.projects add column if not exists report_path text;
alter table public.projects add column if not exists report_name text;
alter table public.projects add column if not exists closed_at timestamp with time zone;
alter table public.projects add column if not exists closed_by text;
alter table public.projects add column if not exists notes text;
alter table public.projects add column if not exists created_by text;
alter table public.projects add column if not exists created_at timestamp with time zone default now() not null;
alter table public.projects add column if not exists exec_by text;
alter table public.projects add column if not exists exec_party text;
alter table public.projects add column if not exists exec_amount numeric;
alter table public.projects add column if not exists exec_file_path text;
alter table public.projects add column if not exists exec_file_name text;
alter table public.projects add column if not exists exec_status text default 'not_started'::text not null;
alter table public.projects add column if not exists exec_done_at timestamp with time zone;
alter table public.projects add column if not exists amount_route text default 'normal'::text not null;
alter table public.projects add column if not exists route_center_id text;
alter table public.push_config add column if not exists key text;
alter table public.push_config add column if not exists value text;
alter table public.push_outbox add column if not exists id bigint default nextval('push_outbox_id_seq'::regclass) not null;
alter table public.push_outbox add column if not exists user_id text;
alter table public.push_outbox add column if not exists title text;
alter table public.push_outbox add column if not exists body text;
alter table public.push_outbox add column if not exists url text;
alter table public.push_outbox add column if not exists tag text;
alter table public.push_outbox add column if not exists kind text;
alter table public.push_outbox add column if not exists request_id text;
alter table public.push_outbox add column if not exists ref text;
alter table public.push_outbox add column if not exists send_after timestamp with time zone default now() not null;
alter table public.push_outbox add column if not exists sent_at timestamp with time zone;
alter table public.push_outbox add column if not exists dedupe text;
alter table public.push_outbox add column if not exists created_at timestamp with time zone default now() not null;
alter table public.push_subscriptions add column if not exists id uuid default gen_random_uuid() not null;
alter table public.push_subscriptions add column if not exists user_id text;
alter table public.push_subscriptions add column if not exists endpoint text;
alter table public.push_subscriptions add column if not exists p256dh text;
alter table public.push_subscriptions add column if not exists auth text;
alter table public.push_subscriptions add column if not exists ua text;
alter table public.push_subscriptions add column if not exists created_at timestamp with time zone default now() not null;
alter table public.push_subscriptions add column if not exists all_requests boolean default false not null;
alter table public.push_subscriptions add column if not exists admin_events text[] default '{}'::text[] not null;
alter table public.qy_attachments add column if not exists id uuid default gen_random_uuid() not null;
alter table public.qy_attachments add column if not exists master_id bigint;
alter table public.qy_attachments add column if not exists company_id text;
alter table public.qy_attachments add column if not exists label text;
alter table public.qy_attachments add column if not exists file_name text;
alter table public.qy_attachments add column if not exists mime text;
alter table public.qy_attachments add column if not exists size_bytes integer;
alter table public.qy_attachments add column if not exists path text;
alter table public.qy_attachments add column if not exists created_by uuid default auth.uid();
alter table public.qy_attachments add column if not exists created_at timestamp with time zone default now() not null;
alter table public.qy_attachments add column if not exists request_id text;
alter table public.qy_audit_alerts add column if not exists id bigint not null;
alter table public.qy_audit_alerts add column if not exists at timestamp with time zone default now() not null;
alter table public.qy_audit_alerts add column if not exists kind text;
alter table public.qy_audit_alerts add column if not exists request_id text;
alter table public.qy_audit_alerts add column if not exists step_id text;
alter table public.qy_audit_alerts add column if not exists actor_auth uuid;
alter table public.qy_audit_alerts add column if not exists actor_user text;
alter table public.qy_audit_alerts add column if not exists approver_id text;
alter table public.qy_audit_alerts add column if not exists details text;
alter table public.qy_audit_alerts add column if not exists reviewed boolean default false not null;
alter table public.qy_client_events add column if not exists id bigint not null;
alter table public.qy_client_events add column if not exists at timestamp with time zone default now() not null;
alter table public.qy_client_events add column if not exists kind text;
alter table public.qy_client_events add column if not exists page text;
alter table public.qy_client_events add column if not exists message text;
alter table public.qy_client_events add column if not exists details text;
alter table public.qy_client_events add column if not exists user_id text;
alter table public.qy_client_events add column if not exists phone_tried text;
alter table public.qy_client_events add column if not exists ip text;
alter table public.qy_client_events add column if not exists device_id text;
alter table public.qy_client_events add column if not exists device jsonb;
alter table public.qy_client_events add column if not exists reviewed boolean default false not null;
alter table public.qy_handovers add column if not exists id uuid default gen_random_uuid() not null;
alter table public.qy_handovers add column if not exists company_id text;
alter table public.qy_handovers add column if not exists from_user_id text;
alter table public.qy_handovers add column if not exists to_user_id text;
alter table public.qy_handovers add column if not exists reason text default 'absence'::text not null;
alter table public.qy_handovers add column if not exists scope_all boolean default true not null;
alter table public.qy_handovers add column if not exists request_ids text[];
alter table public.qy_handovers add column if not exists from_date date default CURRENT_DATE not null;
alter table public.qy_handovers add column if not exists to_date date;
alter table public.qy_handovers add column if not exists needs_approval boolean default true not null;
alter table public.qy_handovers add column if not exists status text default 'pending'::text not null;
alter table public.qy_handovers add column if not exists reject_reason text;
alter table public.qy_handovers add column if not exists suggested_user_id text;
alter table public.qy_handovers add column if not exists note text;
alter table public.qy_handovers add column if not exists created_by text;
alter table public.qy_handovers add column if not exists created_at timestamp with time zone default now() not null;
alter table public.qy_handovers add column if not exists decided_at timestamp with time zone;
alter table public.qy_verify_hits add column if not exists at timestamp with time zone default now() not null;
alter table public.qy_verify_hits add column if not exists ip text;
alter table public.recurring_occurrences add column if not exists id uuid default gen_random_uuid() not null;
alter table public.recurring_occurrences add column if not exists template_id uuid;
alter table public.recurring_occurrences add column if not exists company_id text;
alter table public.recurring_occurrences add column if not exists due_date date;
alter table public.recurring_occurrences add column if not exists amount numeric;
alter table public.recurring_occurrences add column if not exists status text default 'proposed'::text not null;
alter table public.recurring_occurrences add column if not exists transaction_id uuid;
alter table public.recurring_occurrences add column if not exists note text;
alter table public.recurring_occurrences add column if not exists handled_by_id text;
alter table public.recurring_occurrences add column if not exists handled_by text;
alter table public.recurring_occurrences add column if not exists handled_at timestamp with time zone;
alter table public.recurring_occurrences add column if not exists created_at timestamp with time zone default now() not null;
alter table public.recurring_occurrences add column if not exists no_auto boolean default false not null;
alter table public.recurring_settings add column if not exists company_id text;
alter table public.recurring_settings add column if not exists approval_notify_roles text[] default ARRAY['cfo'::text, 'admin'::text] not null;
alter table public.recurring_settings add column if not exists approval_notify_user_ids text[] default '{}'::text[] not null;
alter table public.recurring_settings add column if not exists updated_by text;
alter table public.recurring_settings add column if not exists updated_at timestamp with time zone default now() not null;
alter table public.recurring_templates add column if not exists id uuid default gen_random_uuid() not null;
alter table public.recurring_templates add column if not exists company_id text;
alter table public.recurring_templates add column if not exists center_id text;
alter table public.recurring_templates add column if not exists name text;
alter table public.recurring_templates add column if not exists category text;
alter table public.recurring_templates add column if not exists direction text default 'out'::text not null;
alter table public.recurring_templates add column if not exists budget_item_id text;
alter table public.recurring_templates add column if not exists beneficiary text;
alter table public.recurring_templates add column if not exists description text;
alter table public.recurring_templates add column if not exists amount numeric;
alter table public.recurring_templates add column if not exists amount_mode text default 'fixed'::text not null;
alter table public.recurring_templates add column if not exists frequency text;
alter table public.recurring_templates add column if not exists day_mode text default 'day_of_month'::text not null;
alter table public.recurring_templates add column if not exists day_of_month integer;
alter table public.recurring_templates add column if not exists weekday integer;
alter table public.recurring_templates add column if not exists start_date date;
alter table public.recurring_templates add column if not exists end_mode text default 'none'::text not null;
alter table public.recurring_templates add column if not exists end_date date;
alter table public.recurring_templates add column if not exists max_count integer;
alter table public.recurring_templates add column if not exists auto_post boolean default false not null;
alter table public.recurring_templates add column if not exists status text default 'pending_approval'::text not null;
alter table public.recurring_templates add column if not exists generation_from date;
alter table public.recurring_templates add column if not exists notify_days_before integer default 3 not null;
alter table public.recurring_templates add column if not exists notify_on_due boolean default true not null;
alter table public.recurring_templates add column if not exists notify_overdue boolean default true not null;
alter table public.recurring_templates add column if not exists notify_repeat boolean default false not null;
alter table public.recurring_templates add column if not exists notify_roles text[] default ARRAY['creator'::text, 'accountant'::text] not null;
alter table public.recurring_templates add column if not exists notify_user_ids text[] default '{}'::text[] not null;
alter table public.recurring_templates add column if not exists created_by_id text;
alter table public.recurring_templates add column if not exists created_by text;
alter table public.recurring_templates add column if not exists approved_by_id text;
alter table public.recurring_templates add column if not exists approved_by text;
alter table public.recurring_templates add column if not exists approved_at timestamp with time zone;
alter table public.recurring_templates add column if not exists created_at timestamp with time zone default now() not null;
alter table public.recurring_templates add column if not exists updated_at timestamp with time zone default now() not null;
alter table public.recurring_templates add column if not exists approval_notify_roles text[];
alter table public.recurring_templates add column if not exists approval_notify_user_ids text[];
alter table public.request_approval_steps add column if not exists id text;
alter table public.request_approval_steps add column if not exists request_id text;
alter table public.request_approval_steps add column if not exists approver_id text;
alter table public.request_approval_steps add column if not exists sequence_order integer;
alter table public.request_approval_steps add column if not exists role_label text;
alter table public.request_approval_steps add column if not exists status text default 'pending'::text;
alter table public.request_approval_steps add column if not exists acted_at timestamp with time zone;
alter table public.request_approval_steps add column if not exists note text;
alter table public.request_approval_steps add column if not exists created_at timestamp with time zone default now();
alter table public.request_approval_steps add column if not exists kind text default 'primary'::text;
alter table public.request_approval_steps add column if not exists escalated_from text;
alter table public.request_approval_steps add column if not exists activated_at timestamp with time zone;
alter table public.request_approval_steps add column if not exists acted_by_auth uuid;
alter table public.request_approval_steps add column if not exists method text;
alter table public.request_approval_steps add column if not exists paper_path text;
alter table public.request_approval_steps add column if not exists paper_signed_at date;
alter table public.request_approval_steps add column if not exists recorded_by text;
alter table public.request_beneficiaries add column if not exists id bigint default nextval('request_beneficiaries_id_seq'::regclass) not null;
alter table public.request_beneficiaries add column if not exists request_id text;
alter table public.request_beneficiaries add column if not exists name text;
alter table public.request_beneficiaries add column if not exists name_en text;
alter table public.request_beneficiaries add column if not exists iban text;
alter table public.request_beneficiaries add column if not exists statement text;
alter table public.request_beneficiaries add column if not exists notes text;
alter table public.request_beneficiaries add column if not exists amount numeric default 0;
alter table public.request_beneficiaries add column if not exists deduction numeric default 0;
alter table public.request_beneficiaries add column if not exists deduction_note text;
alter table public.request_beneficiaries add column if not exists national_id text;
alter table public.request_beneficiaries add column if not exists extra numeric default 0;
alter table public.request_beneficiaries add column if not exists extra_note text;
alter table public.request_beneficiaries add column if not exists contract_id uuid;
alter table public.request_beneficiaries add column if not exists supplier_id text;
alter table public.request_history add column if not exists id bigint default nextval('request_history_id_seq'::regclass) not null;
alter table public.request_history add column if not exists request_id text;
alter table public.request_history add column if not exists step text;
alter table public.request_history add column if not exists actor text;
alter table public.request_history add column if not exists user_id text;
alter table public.request_history add column if not exists action text;
alter table public.request_history add column if not exists note text;
alter table public.request_history add column if not exists "time" text;
alter table public.request_history add column if not exists created_at timestamp with time zone default now();
alter table public.request_history add column if not exists signature_override text;
alter table public.request_history add column if not exists auth_uid uuid;
alter table public.request_number_counters add column if not exists prefix text;
alter table public.request_number_counters add column if not exists suffix text;
alter table public.request_number_counters add column if not exists last_n integer default 0 not null;
alter table public.requests add column if not exists id text;
alter table public.requests add column if not exists number text;
alter table public.requests add column if not exists reason text;
alter table public.requests add column if not exists total_amount numeric default 0 not null;
alter table public.requests add column if not exists status text;
alter table public.requests add column if not exists origin text;
alter table public.requests add column if not exists center_id text;
alter table public.requests add column if not exists created_by text;
alter table public.requests add column if not exists created_by_id text;
alter table public.requests add column if not exists date_greg text;
alter table public.requests add column if not exists date_hijri text;
alter table public.requests add column if not exists created_at timestamp with time zone default now();
alter table public.requests add column if not exists is_recurring boolean default false;
alter table public.requests add column if not exists company_id text;
alter table public.requests add column if not exists detailed_reason text;
alter table public.requests add column if not exists is_cancelled boolean default false;
alter table public.requests add column if not exists cancelled_at timestamp with time zone;
alter table public.requests add column if not exists cancelled_by_id text;
alter table public.requests add column if not exists cancel_reason text;
alter table public.requests add column if not exists bank_transfer_ref text;
alter table public.requests add column if not exists bank_transfer_at timestamp with time zone;
alter table public.requests add column if not exists fast_tracked boolean default false;
alter table public.requests add column if not exists limit_exceeded boolean default false;
alter table public.requests add column if not exists budget_item_id text;
alter table public.requests add column if not exists review_until timestamp with time zone;
alter table public.requests add column if not exists number_prefix text;
alter table public.requests add column if not exists number_suffix text;
alter table public.requests add column if not exists verify_code text;
alter table public.requests add column if not exists request_notes text;
alter table public.requests add column if not exists request_type text default 'normal'::text not null;
alter table public.requests add column if not exists salutation_text text;
alter table public.requests add column if not exists reference_text text;
alter table public.requests add column if not exists amount_route text default 'normal'::text not null;
alter table public.requests add column if not exists route_center_id text;
alter table public.signature_layout_configs add column if not exists id text;
alter table public.signature_layout_configs add column if not exists role text;
alter table public.signature_layout_configs add column if not exists config jsonb default '{}'::jsonb not null;
alter table public.signature_layout_configs add column if not exists updated_at timestamp with time zone default now();
alter table public.signature_layout_configs add column if not exists context text default 'final'::text not null;
alter table public.svc_catalog add column if not exists id uuid default gen_random_uuid() not null;
alter table public.svc_catalog add column if not exists company_id text;
alter table public.svc_catalog add column if not exists parent_id uuid;
alter table public.svc_catalog add column if not exists level smallint;
alter table public.svc_catalog add column if not exists name text;
alter table public.svc_catalog add column if not exists description text;
alter table public.svc_catalog add column if not exists unit text;
alter table public.svc_catalog add column if not exists price numeric;
alter table public.svc_catalog add column if not exists active boolean default true not null;
alter table public.svc_catalog add column if not exists sort integer default 0 not null;
alter table public.svc_catalog add column if not exists created_at timestamp with time zone default now() not null;
alter table public.transactions add column if not exists id uuid default gen_random_uuid() not null;
alter table public.transactions add column if not exists company_id text;
alter table public.transactions add column if not exists center_id text;
alter table public.transactions add column if not exists tx_date date default CURRENT_DATE not null;
alter table public.transactions add column if not exists direction text;
alter table public.transactions add column if not exists amount numeric(14,3);
alter table public.transactions add column if not exists budget_item_id text;
alter table public.transactions add column if not exists beneficiary text;
alter table public.transactions add column if not exists description text;
alter table public.transactions add column if not exists source_type text;
alter table public.transactions add column if not exists source_id text;
alter table public.transactions add column if not exists reverses_id uuid;
alter table public.transactions add column if not exists note text;
alter table public.transactions add column if not exists created_by_id text;
alter table public.transactions add column if not exists created_by text;
alter table public.transactions add column if not exists created_at timestamp with time zone default now() not null;
alter table public.transactions add column if not exists refund_of_id uuid;
alter table public.user_companies add column if not exists user_id text;
alter table public.user_companies add column if not exists company_id text;
alter table public.user_company_managers add column if not exists user_id text;
alter table public.user_company_managers add column if not exists company_id text;
alter table public.user_company_managers add column if not exists manager_id text;
alter table public.users add column if not exists id text;
alter table public.users add column if not exists phone text;
alter table public.users add column if not exists name text;
alter table public.users add column if not exists role text;
alter table public.users add column if not exists center_id text;
alter table public.users add column if not exists signature_data text;
alter table public.users add column if not exists stamp_data text;
alter table public.users add column if not exists email text;
alter table public.users add column if not exists name_en text;
alter table public.users add column if not exists iban text;
alter table public.users add column if not exists id_file_data text;
alter table public.users add column if not exists bank_file_data text;
alter table public.users add column if not exists signature_mode text default 'fixed'::text;
alter table public.users add column if not exists signature_color text default '#1B2733'::text;
alter table public.users add column if not exists signature_width numeric default 2.2;
alter table public.users add column if not exists company_id text;
alter table public.users add column if not exists national_id text;
alter table public.users add column if not exists stamp_data_2 text;
alter table public.users add column if not exists manager_id text;
alter table public.users add column if not exists notif_seen_at timestamp with time zone;
alter table public.users add column if not exists job_title text;
alter table public.users add column if not exists level_id text;
alter table public.users add column if not exists request_approver_id text;
alter table public.users add column if not exists next_approver_id text;
alter table public.users add column if not exists exec_substitute_id text;
alter table public.users add column if not exists is_general boolean default false;
alter table public.users add column if not exists no_request_approver boolean default false;
alter table public.users add column if not exists no_next_approver boolean default false;
alter table public.users add column if not exists approval_deadline_days integer;
alter table public.users add column if not exists escalate_mode text;
alter table public.users add column if not exists escalate_user_id text;
alter table public.users add column if not exists auth_id uuid;
alter table public.users add column if not exists can_manage_recurring boolean default false not null;
alter table public.users add column if not exists idle_minutes integer;
alter table public.users add column if not exists is_suspended boolean default false not null;
alter table public.users add column if not exists suspended_at timestamp with time zone;
alter table public.users add column if not exists suspended_note text;
alter table public.users add column if not exists direct_to_transfer boolean default false not null;
alter table public.users add column if not exists skip_review boolean default false not null;
alter table public.users add column if not exists avatar_data text;
alter table public.users add column if not exists paper_approval boolean default false not null;
alter table public.users add column if not exists paper_proxy_ids text[] default '{}'::text[] not null;
alter table public.users add column if not exists org_dept_id text;
alter table public.worker_contracts add column if not exists id uuid default gen_random_uuid() not null;
alter table public.worker_contracts add column if not exists company_id text;
alter table public.worker_contracts add column if not exists unit_id text;
alter table public.worker_contracts add column if not exists user_id text;
alter table public.worker_contracts add column if not exists person_name text;
alter table public.worker_contracts add column if not exists civil_id text;
alter table public.worker_contracts add column if not exists phone text;
alter table public.worker_contracts add column if not exists iban text;
alter table public.worker_contracts add column if not exists contract_type text default 'employment'::text not null;
alter table public.worker_contracts add column if not exists job_title text;
alter table public.worker_contracts add column if not exists start_date date;
alter table public.worker_contracts add column if not exists end_date date;
alter table public.worker_contracts add column if not exists amount numeric;
alter table public.worker_contracts add column if not exists pay_cycle text default 'monthly'::text not null;
alter table public.worker_contracts add column if not exists file_path text;
alter table public.worker_contracts add column if not exists file_name text;
alter table public.worker_contracts add column if not exists status text default 'active'::text not null;
alter table public.worker_contracts add column if not exists notes text;
alter table public.worker_contracts add column if not exists created_by text;
alter table public.worker_contracts add column if not exists created_at timestamp with time zone default now() not null;

alter sequence public.beneficiaries_master_id_seq owned by public.beneficiaries_master.id;
alter sequence public.request_beneficiaries_id_seq owned by public.request_beneficiaries.id;
alter sequence public.request_history_id_seq owned by public.request_history.id;
alter sequence public.push_outbox_id_seq owned by public.push_outbox.id;
alter sequence public.gateway_agents_id_seq owned by public.gateway_agents.id;
alter sequence public.gateway_imports_id_seq owned by public.gateway_imports.id;
alter sequence public.center_ledger_id_seq owned by public.center_ledger.id;
alter sequence public.gl_exports_id_seq owned by public.gl_exports.id;

-- ═══ المفاتيح والقيود ═══
do $c$ begin if not exists (select 1 from pg_constraint where conname='app_settings_pkey' and conrelid='public.app_settings'::regclass) then alter table public.app_settings add constraint app_settings_pkey PRIMARY KEY (key); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='beneficiaries_master_pkey' and conrelid='public.beneficiaries_master'::regclass) then alter table public.beneficiaries_master add constraint beneficiaries_master_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='bottom_bar_toggles_pkey' and conrelid='public.bottom_bar_toggles'::regclass) then alter table public.bottom_bar_toggles add constraint bottom_bar_toggles_pkey PRIMARY KEY (button_key); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_pkey' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_overrun_log_pkey' and conrelid='public.budget_overrun_log'::regclass) then alter table public.budget_overrun_log add constraint budget_overrun_log_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_pkey' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_access_pkey' and conrelid='public.center_access'::regclass) then alter table public.center_access add constraint center_access_pkey PRIMARY KEY (center_id, user_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_pkey' and conrelid='public.center_ledger'::regclass) then alter table public.center_ledger add constraint center_ledger_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_payers_pkey' and conrelid='public.center_ledger_payers'::regclass) then alter table public.center_ledger_payers add constraint center_ledger_payers_pkey PRIMARY KEY (ledger_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_pkey' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='client_contracts_pkey' and conrelid='public.client_contracts'::regclass) then alter table public.client_contracts add constraint client_contracts_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='clients_pkey' and conrelid='public.clients'::regclass) then alter table public.clients add constraint clients_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_pkey' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='contract_prices_pkey' and conrelid='public.contract_prices'::regclass) then alter table public.contract_prices add constraint contract_prices_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_pkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_pkey' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_pkey' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custom_roles_pkey' and conrelid='public.custom_roles'::regclass) then alter table public.custom_roles add constraint custom_roles_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_accounts_pkey' and conrelid='public.gateway_accounts'::regclass) then alter table public.gateway_accounts add constraint gateway_accounts_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_agents_pkey' and conrelid='public.gateway_agents'::regclass) then alter table public.gateway_agents add constraint gateway_agents_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_import_users_pkey' and conrelid='public.gateway_import_users'::regclass) then alter table public.gateway_import_users add constraint gateway_import_users_pkey PRIMARY KEY (company_id, user_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_imports_pkey' and conrelid='public.gateway_imports'::regclass) then alter table public.gateway_imports add constraint gateway_imports_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_accounts_pkey' and conrelid='public.gl_accounts'::regclass) then alter table public.gl_accounts add constraint gl_accounts_pkey PRIMARY KEY (company_id, code); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_custody_accounts_pkey' and conrelid='public.gl_custody_accounts'::regclass) then alter table public.gl_custody_accounts add constraint gl_custody_accounts_pkey PRIMARY KEY (company_id, holder_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_exports_pkey' and conrelid='public.gl_exports'::regclass) then alter table public.gl_exports add constraint gl_exports_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='job_levels_pkey' and conrelid='public.job_levels'::regclass) then alter table public.job_levels add constraint job_levels_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='login_aliases_pkey' and conrelid='public.login_aliases'::regclass) then alter table public.login_aliases add constraint login_aliases_pkey PRIMARY KEY (phone); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='org_departments_pkey' and conrelid='public.org_departments'::regclass) then alter table public.org_departments add constraint org_departments_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='organizations_pkey' and conrelid='public.organizations'::regclass) then alter table public.organizations add constraint organizations_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='page_permissions_pkey' and conrelid='public.page_permissions'::regclass) then alter table public.page_permissions add constraint page_permissions_pkey PRIMARY KEY (company_id, role, page_key); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='password_reset_requests_pkey' and conrelid='public.password_reset_requests'::regclass) then alter table public.password_reset_requests add constraint password_reset_requests_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_collections_pkey' and conrelid='public.prj_collections'::regclass) then alter table public.prj_collections add constraint prj_collections_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_pkey' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_pkey' and conrelid='public.prj_invoices'::regclass) then alter table public.prj_invoices add constraint prj_invoices_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_pkey' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='push_config_pkey' and conrelid='public.push_config'::regclass) then alter table public.push_config add constraint push_config_pkey PRIMARY KEY (key); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='push_outbox_pkey' and conrelid='public.push_outbox'::regclass) then alter table public.push_outbox add constraint push_outbox_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='push_subscriptions_pkey' and conrelid='public.push_subscriptions'::regclass) then alter table public.push_subscriptions add constraint push_subscriptions_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_pkey' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_audit_alerts_pkey' and conrelid='public.qy_audit_alerts'::regclass) then alter table public.qy_audit_alerts add constraint qy_audit_alerts_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_client_events_pkey' and conrelid='public.qy_client_events'::regclass) then alter table public.qy_client_events add constraint qy_client_events_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_handovers_pkey' and conrelid='public.qy_handovers'::regclass) then alter table public.qy_handovers add constraint qy_handovers_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_pkey' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_settings_pkey' and conrelid='public.recurring_settings'::regclass) then alter table public.recurring_settings add constraint recurring_settings_pkey PRIMARY KEY (company_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_pkey' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_approval_steps_pkey' and conrelid='public.request_approval_steps'::regclass) then alter table public.request_approval_steps add constraint request_approval_steps_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_beneficiaries_pkey' and conrelid='public.request_beneficiaries'::regclass) then alter table public.request_beneficiaries add constraint request_beneficiaries_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_history_pkey' and conrelid='public.request_history'::regclass) then alter table public.request_history add constraint request_history_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_number_counters_pkey' and conrelid='public.request_number_counters'::regclass) then alter table public.request_number_counters add constraint request_number_counters_pkey PRIMARY KEY (prefix, suffix); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_pkey' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='signature_layout_configs_pkey' and conrelid='public.signature_layout_configs'::regclass) then alter table public.signature_layout_configs add constraint signature_layout_configs_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='svc_catalog_pkey' and conrelid='public.svc_catalog'::regclass) then alter table public.svc_catalog add constraint svc_catalog_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_pkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_companies_pkey' and conrelid='public.user_companies'::regclass) then alter table public.user_companies add constraint user_companies_pkey PRIMARY KEY (user_id, company_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_company_managers_pkey' and conrelid='public.user_company_managers'::regclass) then alter table public.user_company_managers add constraint user_company_managers_pkey PRIMARY KEY (user_id, company_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_pkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_pkey' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_pkey PRIMARY KEY (id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_request_id_key' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_request_id_key UNIQUE (request_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_agents_company_id_account_id_agent_name_key' and conrelid='public.gateway_agents'::regclass) then alter table public.gateway_agents add constraint gateway_agents_company_id_account_id_agent_name_key UNIQUE (company_id, account_id, agent_name); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_company_id_year_seq_key' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_company_id_year_seq_key UNIQUE (company_id, year, seq); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_document_id_key' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_document_id_key UNIQUE (document_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='push_outbox_user_id_dedupe_key' and conrelid='public.push_outbox'::regclass) then alter table public.push_outbox add constraint push_outbox_user_id_dedupe_key UNIQUE (user_id, dedupe); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='push_subscriptions_endpoint_key' and conrelid='public.push_subscriptions'::regclass) then alter table public.push_subscriptions add constraint push_subscriptions_endpoint_key UNIQUE (endpoint); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_path_key' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_path_key UNIQUE (path); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_template_id_due_date_key' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_template_id_due_date_key UNIQUE (template_id, due_date); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='signature_layout_configs_role_context_key' and conrelid='public.signature_layout_configs'::regclass) then alter table public.signature_layout_configs add constraint signature_layout_configs_role_context_key UNIQUE (role, context); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_auth_id_key' and conrelid='public.users'::regclass) then alter table public.users add constraint users_auth_id_key UNIQUE (auth_id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_phone_key' and conrelid='public.users'::regclass) then alter table public.users add constraint users_phone_key UNIQUE (phone); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_id_safe' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_id_safe CHECK ((id ~ '^[A-Za-z0-9_.-]+$'::text)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_profit_fixed_check' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_profit_fixed_check CHECK ((profit_fixed >= (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_profit_mode_check' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_profit_mode_check CHECK ((profit_mode = ANY (ARRAY['percent'::text, 'fixed'::text, 'both'::text, 'none'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_profit_percent_check' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_profit_percent_check CHECK (((profit_percent >= (0)::numeric) AND (profit_percent <= (100)::numeric))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_type_check' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_type_check CHECK ((type = ANY (ARRAY['company'::text, 'center'::text, 'club'::text, 'project'::text, 'department'::text, 'program'::text, 'trip'::text, 'entity'::text, 'client'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_overrun_log_stage_check' and conrelid='public.budget_overrun_log'::regclass) then alter table public.budget_overrun_log add constraint budget_overrun_log_stage_check CHECK ((stage = ANY (ARRAY['submit'::text, 'approve'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_amount_check' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_id_safe' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_id_safe CHECK ((id ~ '^[A-Za-z0-9_.-]+$'::text)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_source_type_check' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_source_type_check CHECK ((source_type = ANY (ARRAY['transfer'::text, 'payment_link'::text, 'cash'::text, 'other'::text, NULL::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_access_mode_check' and conrelid='public.center_access'::regclass) then alter table public.center_access add constraint center_access_mode_check CHECK ((mode = ANY (ARRAY['allow'::text, 'deny'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_kind_check' and conrelid='public.center_ledger'::regclass) then alter table public.center_ledger add constraint center_ledger_kind_check CHECK ((kind = ANY (ARRAY['opening'::text, 'subscription'::text, 'support'::text, 'manual'::text, 'adjust'::text, 'transfer'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_id_safe' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_id_safe CHECK ((id ~ '^[A-Za-z0-9_.-]+$'::text)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_min_single_approver_chk' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_min_single_approver_chk CHECK ((min_single_approver = ANY (ARRAY['exec'::text, 'direct'::text, 'senior'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_stage_chk' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_stage_chk CHECK ((stage = ANY (ARRAY['potential'::text, 'open'::text, 'active'::text, 'suspended'::text, 'closed'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='client_contracts_billing_check' and conrelid='public.client_contracts'::regclass) then alter table public.client_contracts add constraint client_contracts_billing_check CHECK ((billing = ANY (ARRAY['monthly'::text, 'per_project'::text, 'other'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='clients_party_chk' and conrelid='public.clients'::regclass) then alter table public.clients add constraint clients_party_chk CHECK ((party = ANY (ARRAY['client'::text, 'supplier'::text, 'both'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_amounts_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_amounts_chk CHECK ((((custody_max_amount IS NULL) OR (custody_max_amount > (0)::numeric)) AND ((custody_max_total IS NULL) OR (custody_max_total > (0)::numeric)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_limits_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_limits_chk CHECK ((((custody_max_open >= 1) AND (custody_max_open <= 20)) AND ((custody_default_days >= 1) AND (custody_default_days <= 365)) AND ((custody_receipt_days >= 1) AND (custody_receipt_days <= 60)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_nodoc_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_nodoc_chk CHECK ((((custody_nodoc_mode IS NULL) OR (custody_nodoc_mode = ANY (ARRAY['amount'::text, 'percent'::text]))) AND ((custody_nodoc_value IS NULL) OR (custody_nodoc_value >= (0)::numeric)) AND ((custody_nodoc_mode <> 'percent'::text) OR (custody_nodoc_value <= (100)::numeric)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_over_mode_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_over_mode_chk CHECK ((custody_over_mode = ANY (ARRAY['none'::text, 'percent'::text, 'amount'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_over_value_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_over_value_chk CHECK ((custody_over_value >= (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_path_mode_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_path_mode_chk CHECK ((custody_path_mode = ANY (ARRAY['exec'::text, 'direct'::text, 'full'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_review_mode_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_review_mode_chk CHECK (((custody_review_mode = ANY (ARRAY['line'::text, 'whole'::text])) AND (custody_img_min >= (0)::numeric))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_custody_signers_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_custody_signers_chk CHECK ((custody_signers = ANY (ARRAY['any'::text, 'cfo'::text, 'acct'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_gl_unlinked_mode_check' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_gl_unlinked_mode_check CHECK ((gl_unlinked_mode = ANY (ARRAY['warn'::text, 'block'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_review_mode_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_review_mode_chk CHECK ((review_mode = ANY (ARRAY['required'::text, 'optional'::text, 'off'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_verify_prefix_chk' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_verify_prefix_chk CHECK (((verify_prefix IS NULL) OR (verify_prefix ~ '^[A-Z0-9]{2}$'::text))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_amount_check' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_over_mode_chk' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_over_mode_chk CHECK (((over_mode IS NULL) OR (over_mode = ANY (ARRAY['none'::text, 'percent'::text, 'amount'::text])))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_status_check' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_status_check CHECK ((status = ANY (ARRAY['requested'::text, 'awaiting_receipt'::text, 'open'::text, 'close_requested'::text, 'acct_review'::text, 'returned'::text, 'pending_sign'::text, 'closed'::text, 'cancelled'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_amount_check' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_amount_check CHECK ((amount <> (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_status_check' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_status_check CHECK ((status = ANY (ARRAY['open'::text, 'applied'::text, 'settled'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_amount_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_description_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_description_check CHECK (((length(btrim(description)) >= 1) AND (length(btrim(description)) <= 300))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_image_data_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_image_data_check CHECK (((image_data IS NULL) OR (length(image_data) <= 3000000))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_invoice_no_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_invoice_no_check CHECK (((invoice_no IS NULL) OR (length(invoice_no) <= 60))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_kind_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_kind_check CHECK ((kind = ANY (ARRAY['expense'::text, 'receipt'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_status_check' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'accepted'::text, 'rejected'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_imports_kind_check' and conrelid='public.gateway_imports'::regclass) then alter table public.gateway_imports add constraint gateway_imports_kind_check CHECK ((kind = ANY (ARRAY['statement'::text, 'bills'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_accounts_kind_check' and conrelid='public.gl_accounts'::regclass) then alter table public.gl_accounts add constraint gl_accounts_kind_check CHECK ((kind = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text, 'income'::text, 'expense'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='org_departments_func_check' and conrelid='public.org_departments'::regclass) then alter table public.org_departments add constraint org_departments_func_check CHECK ((func = ANY (ARRAY['none'::text, 'hr'::text, 'secretary'::text, 'finance'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='page_permissions_level_check' and conrelid='public.page_permissions'::regclass) then alter table public.page_permissions add constraint page_permissions_level_check CHECK ((level = ANY (ARRAY['none'::text, 'read'::text, 'edit'::text, 'full'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='password_reset_requests_status_check' and conrelid='public.password_reset_requests'::regclass) then alter table public.password_reset_requests add constraint password_reset_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'handled'::text, 'dismissed'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_collections_amount_check' and conrelid='public.prj_collections'::regclass) then alter table public.prj_collections add constraint prj_collections_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_amount_check' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_amount_check CHECK ((amount >= (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_amount_kind_check' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_amount_kind_check CHECK ((amount_kind = ANY (ARRAY['total'::text, 'monthly'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_doc_type_check' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_doc_type_check CHECK ((doc_type = ANY (ARRAY['quote'::text, 'service_form'::text, 'proposal'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_months_check' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_months_check CHECK (((months IS NULL) OR (months > 0))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_status_check' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_status_check CHECK ((status = ANY (ARRAY['sent'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_amount_check' and conrelid='public.prj_invoices'::regclass) then alter table public.prj_invoices add constraint prj_invoices_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_status_check' and conrelid='public.prj_invoices'::regclass) then alter table public.prj_invoices add constraint prj_invoices_status_check CHECK ((status = ANY (ARRAY['issued'::text, 'cancelled'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_amount_route_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_amount_route_check CHECK ((amount_route = ANY (ARRAY['normal'::text, 'center'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_exec_amount_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_exec_amount_check CHECK (((exec_amount IS NULL) OR (exec_amount >= (0)::numeric))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_exec_by_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_exec_by_check CHECK (((exec_by IS NULL) OR (exec_by = ANY (ARRAY['company'::text, 'external'::text, 'both'::text])))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_exec_status_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_exec_status_check CHECK ((exec_status = ANY (ARRAY['not_started'::text, 'in_progress'::text, 'done'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_invoice_mode_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_invoice_mode_check CHECK ((invoice_mode = ANY (ARRAY['single'::text, 'monthly'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_months_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_months_check CHECK (((months IS NULL) OR (months > 0))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_prepay_pct_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_prepay_pct_check CHECK (((prepay_pct >= (0)::numeric) AND (prepay_pct <= (100)::numeric))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_status_check' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_status_check CHECK ((status = ANY (ARRAY['active'::text, 'closed'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_file_name_check' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_file_name_check CHECK (((char_length(file_name) >= 1) AND (char_length(file_name) <= 200))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_label_check' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_label_check CHECK (((char_length(label) >= 1) AND (char_length(label) <= 60))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_mime_check' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_mime_check CHECK ((mime = ANY (ARRAY['image/jpeg'::text, 'image/png'::text, 'image/webp'::text, 'application/pdf'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_size_bytes_check' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_size_bytes_check CHECK (((size_bytes > 0) AND (size_bytes <= 10485760))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_client_events_kind_chk' and conrelid='public.qy_client_events'::regclass) then alter table public.qy_client_events add constraint qy_client_events_kind_chk CHECK ((kind = ANY (ARRAY['js_error'::text, 'promise_error'::text, 'db_error'::text, 'login_failed'::text, 'login_suspended'::text, 'login_ok'::text, 'logout'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_ho_diff_chk' and conrelid='public.qy_handovers'::regclass) then alter table public.qy_handovers add constraint qy_ho_diff_chk CHECK ((from_user_id <> to_user_id)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_ho_status_chk' and conrelid='public.qy_handovers'::regclass) then alter table public.qy_handovers add constraint qy_ho_status_chk CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text, 'cancelled'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_amount_check' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_status_check' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_status_check CHECK ((status = ANY (ARRAY['proposed'::text, 'posted'::text, 'skipped'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='rs_roles' and conrelid='public.recurring_settings'::regclass) then alter table public.recurring_settings add constraint rs_roles CHECK ((approval_notify_roles <@ ARRAY['accountant'::text, 'cfo'::text, 'admin'::text])); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_amount_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_amount_mode_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_amount_mode_check CHECK ((amount_mode = ANY (ARRAY['fixed'::text, 'variable'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_day_mode_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_day_mode_check CHECK ((day_mode = ANY (ARRAY['day_of_month'::text, 'last_day'::text, 'weekday'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_day_of_month_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_day_of_month_check CHECK (((day_of_month >= 1) AND (day_of_month <= 31))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_direction_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_direction_check CHECK ((direction = ANY (ARRAY['out'::text, 'in'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_end_mode_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_end_mode_check CHECK ((end_mode = ANY (ARRAY['none'::text, 'date'::text, 'count'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_frequency_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_frequency_check CHECK ((frequency = ANY (ARRAY['weekly'::text, 'biweekly'::text, 'monthly'::text, 'bimonthly'::text, 'quarterly'::text, 'semiannual'::text, 'yearly'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_max_count_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_max_count_check CHECK ((max_count > 0)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_notify_days_before_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_notify_days_before_check CHECK (((notify_days_before >= 0) AND (notify_days_before <= 60))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_status_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_status_check CHECK ((status = ANY (ARRAY['pending_approval'::text, 'active'::text, 'paused'::text, 'ended'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_weekday_check' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='rt_auto_fixed' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint rt_auto_fixed CHECK (((NOT auto_post) OR (amount_mode = 'fixed'::text))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='rt_day' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint rt_day CHECK ((((frequency = ANY (ARRAY['weekly'::text, 'biweekly'::text])) = (day_mode = 'weekday'::text)) AND ((day_mode <> 'weekday'::text) OR (weekday IS NOT NULL)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='rt_end' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint rt_end CHECK ((((end_mode <> 'date'::text) OR (end_date IS NOT NULL)) AND ((end_mode <> 'count'::text) OR (max_count IS NOT NULL)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='rt_roles' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint rt_roles CHECK ((notify_roles <@ ARRAY['creator'::text, 'accountant'::text, 'cfo'::text, 'admin'::text])); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_approval_steps_id_safe' and conrelid='public.request_approval_steps'::regclass) then alter table public.request_approval_steps add constraint request_approval_steps_id_safe CHECK ((id ~ '^[A-Za-z0-9_.-]+$'::text)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_amount_route_chk' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_amount_route_chk CHECK ((amount_route = ANY (ARRAY['normal'::text, 'center'::text, 'revenue'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_id_safe' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_id_safe CHECK ((id ~ '^[A-Za-z0-9_.-]+$'::text)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_request_type_chk' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_request_type_chk CHECK ((request_type = ANY (ARRAY['normal'::text, 'custody'::text, 'payroll'::text, 'reward'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='svc_catalog_level_check' and conrelid='public.svc_catalog'::regclass) then alter table public.svc_catalog add constraint svc_catalog_level_check CHECK ((level = ANY (ARRAY[1, 2, 3]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_amount_check' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_amount_check CHECK ((amount > (0)::numeric)); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_direction_check' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_direction_check CHECK ((direction = ANY (ARRAY['in'::text, 'out'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_source_type_check' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_source_type_check CHECK ((source_type = ANY (ARRAY['request'::text, 'recurring'::text, 'manual'::text, 'revenue'::text, 'opening'::text, 'refund'::text, 'custody'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_avatar_size_chk' and conrelid='public.users'::regclass) then alter table public.users add constraint users_avatar_size_chk CHECK (((avatar_data IS NULL) OR (length(avatar_data) <= 200000))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_idle_minutes_chk' and conrelid='public.users'::regclass) then alter table public.users add constraint users_idle_minutes_chk CHECK (((idle_minutes IS NULL) OR ((idle_minutes >= 5) AND (idle_minutes <= 1440)))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_amount_check' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_amount_check CHECK (((amount IS NULL) OR (amount >= (0)::numeric))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_check' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_check CHECK (((user_id IS NOT NULL) OR (COALESCE(TRIM(BOTH FROM person_name), ''::text) <> ''::text))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_contract_type_check' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_contract_type_check CHECK ((contract_type = ANY (ARRAY['employment'::text, 'reward'::text, 'freelance'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_pay_cycle_check' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_pay_cycle_check CHECK ((pay_cycle = ANY (ARRAY['monthly'::text, 'per_task'::text, 'lump'::text]))); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_status_check' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_status_check CHECK ((status = ANY (ARRAY['active'::text, 'ended'::text]))); end if; end $c$;

-- ═══ المفاتيح الأجنبية ═══
do $c$ begin if not exists (select 1 from pg_constraint where conname='beneficiaries_master_company_id_fkey' and conrelid='public.beneficiaries_master'::regclass) then alter table public.beneficiaries_master add constraint beneficiaries_master_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_company_id_fkey' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_items_parent_id_fkey' and conrelid='public.budget_items'::regclass) then alter table public.budget_items add constraint budget_items_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES budget_items(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_budget_item_id_fkey' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_budget_item_id_fkey FOREIGN KEY (budget_item_id) REFERENCES budget_items(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='budget_revenues_entered_by_id_fkey' and conrelid='public.budget_revenues'::regclass) then alter table public.budget_revenues add constraint budget_revenues_entered_by_id_fkey FOREIGN KEY (entered_by_id) REFERENCES users(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_access_center_id_fkey' and conrelid='public.center_access'::regclass) then alter table public.center_access add constraint center_access_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_center_id_fkey' and conrelid='public.center_ledger'::regclass) then alter table public.center_ledger add constraint center_ledger_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='center_ledger_payers_ledger_id_fkey' and conrelid='public.center_ledger_payers'::regclass) then alter table public.center_ledger_payers add constraint center_ledger_payers_ledger_id_fkey FOREIGN KEY (ledger_id) REFERENCES center_ledger(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_client_id_fkey' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_company_id_fkey' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='centers_parent_id_fkey' and conrelid='public.centers'::regclass) then alter table public.centers add constraint centers_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='client_contracts_client_id_fkey' and conrelid='public.client_contracts'::regclass) then alter table public.client_contracts add constraint client_contracts_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='client_contracts_company_id_fkey' and conrelid='public.client_contracts'::regclass) then alter table public.client_contracts add constraint client_contracts_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='client_contracts_parent_id_fkey' and conrelid='public.client_contracts'::regclass) then alter table public.client_contracts add constraint client_contracts_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES client_contracts(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='clients_parent_id_fkey' and conrelid='public.clients'::regclass) then alter table public.clients add constraint clients_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES clients(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_cfo_delegate_user_id_fkey' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_cfo_delegate_user_id_fkey FOREIGN KEY (cfo_delegate_user_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_hr_approver_id_fkey' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_hr_approver_id_fkey FOREIGN KEY (hr_approver_id) REFERENCES users(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='companies_org_id_fkey' and conrelid='public.companies'::regclass) then alter table public.companies add constraint companies_org_id_fkey FOREIGN KEY (org_id) REFERENCES organizations(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='contract_prices_catalog_id_fkey' and conrelid='public.contract_prices'::regclass) then alter table public.contract_prices add constraint contract_prices_catalog_id_fkey FOREIGN KEY (catalog_id) REFERENCES svc_catalog(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='contract_prices_contract_id_fkey' and conrelid='public.contract_prices'::regclass) then alter table public.contract_prices add constraint contract_prices_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES client_contracts(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_carried_from_id_fkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_carried_from_id_fkey FOREIGN KEY (carried_from_id) REFERENCES custodies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_company_id_fkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_holder_id_fkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_holder_id_fkey FOREIGN KEY (holder_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_request_id_fkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_request_id_fkey FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custodies_reviewer_id_fkey' and conrelid='public.custodies'::regclass) then alter table public.custodies add constraint custodies_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_applied_custody_id_fkey' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_applied_custody_id_fkey FOREIGN KEY (applied_custody_id) REFERENCES custodies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_holder_id_fkey' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_holder_id_fkey FOREIGN KEY (holder_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_balances_source_custody_id_fkey' and conrelid='public.custody_balances'::regclass) then alter table public.custody_balances add constraint custody_balances_source_custody_id_fkey FOREIGN KEY (source_custody_id) REFERENCES custodies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custody_lines_custody_id_fkey' and conrelid='public.custody_lines'::regclass) then alter table public.custody_lines add constraint custody_lines_custody_id_fkey FOREIGN KEY (custody_id) REFERENCES custodies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='custom_roles_company_id_fkey' and conrelid='public.custom_roles'::regclass) then alter table public.custom_roles add constraint custom_roles_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_agents_account_id_fkey' and conrelid='public.gateway_agents'::regclass) then alter table public.gateway_agents add constraint gateway_agents_account_id_fkey FOREIGN KEY (account_id) REFERENCES gateway_accounts(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_agents_center_id_fkey' and conrelid='public.gateway_agents'::regclass) then alter table public.gateway_agents add constraint gateway_agents_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gateway_imports_account_id_fkey' and conrelid='public.gateway_imports'::regclass) then alter table public.gateway_imports add constraint gateway_imports_account_id_fkey FOREIGN KEY (account_id) REFERENCES gateway_accounts(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_accounts_company_id_fkey' and conrelid='public.gl_accounts'::regclass) then alter table public.gl_accounts add constraint gl_accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_custody_accounts_company_id_fkey' and conrelid='public.gl_custody_accounts'::regclass) then alter table public.gl_custody_accounts add constraint gl_custody_accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='gl_exports_company_id_fkey' and conrelid='public.gl_exports'::regclass) then alter table public.gl_exports add constraint gl_exports_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='job_levels_company_id_fkey' and conrelid='public.job_levels'::regclass) then alter table public.job_levels add constraint job_levels_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='login_aliases_user_id_fkey' and conrelid='public.login_aliases'::regclass) then alter table public.login_aliases add constraint login_aliases_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='page_permissions_company_id_fkey' and conrelid='public.page_permissions'::regclass) then alter table public.page_permissions add constraint page_permissions_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='password_reset_requests_company_id_fkey' and conrelid='public.password_reset_requests'::regclass) then alter table public.password_reset_requests add constraint password_reset_requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='password_reset_requests_user_id_fkey' and conrelid='public.password_reset_requests'::regclass) then alter table public.password_reset_requests add constraint password_reset_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_collections_company_id_fkey' and conrelid='public.prj_collections'::regclass) then alter table public.prj_collections add constraint prj_collections_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_collections_invoice_id_fkey' and conrelid='public.prj_collections'::regclass) then alter table public.prj_collections add constraint prj_collections_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES prj_invoices(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_client_id_fkey' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_company_id_fkey' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_documents_contract_id_fkey' and conrelid='public.prj_documents'::regclass) then alter table public.prj_documents add constraint prj_documents_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES client_contracts(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_company_id_fkey' and conrelid='public.prj_invoices'::regclass) then alter table public.prj_invoices add constraint prj_invoices_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='prj_invoices_project_id_fkey' and conrelid='public.prj_invoices'::regclass) then alter table public.prj_invoices add constraint prj_invoices_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_client_id_fkey' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_company_id_fkey' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='projects_document_id_fkey' and conrelid='public.projects'::regclass) then alter table public.projects add constraint projects_document_id_fkey FOREIGN KEY (document_id) REFERENCES prj_documents(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='qy_attachments_master_id_fkey' and conrelid='public.qy_attachments'::regclass) then alter table public.qy_attachments add constraint qy_attachments_master_id_fkey FOREIGN KEY (master_id) REFERENCES beneficiaries_master(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_template_id_fkey' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_template_id_fkey FOREIGN KEY (template_id) REFERENCES recurring_templates(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_occurrences_transaction_id_fkey' and conrelid='public.recurring_occurrences'::regclass) then alter table public.recurring_occurrences add constraint recurring_occurrences_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_settings_company_id_fkey' and conrelid='public.recurring_settings'::regclass) then alter table public.recurring_settings add constraint recurring_settings_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_budget_item_id_fkey' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_budget_item_id_fkey FOREIGN KEY (budget_item_id) REFERENCES budget_items(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_center_id_fkey' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='recurring_templates_company_id_fkey' and conrelid='public.recurring_templates'::regclass) then alter table public.recurring_templates add constraint recurring_templates_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_approval_steps_approver_id_fkey' and conrelid='public.request_approval_steps'::regclass) then alter table public.request_approval_steps add constraint request_approval_steps_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_approval_steps_request_id_fkey' and conrelid='public.request_approval_steps'::regclass) then alter table public.request_approval_steps add constraint request_approval_steps_request_id_fkey FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_beneficiaries_contract_id_fkey' and conrelid='public.request_beneficiaries'::regclass) then alter table public.request_beneficiaries add constraint request_beneficiaries_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES worker_contracts(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_beneficiaries_request_id_fkey' and conrelid='public.request_beneficiaries'::regclass) then alter table public.request_beneficiaries add constraint request_beneficiaries_request_id_fkey FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_beneficiaries_supplier_id_fkey' and conrelid='public.request_beneficiaries'::regclass) then alter table public.request_beneficiaries add constraint request_beneficiaries_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES clients(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='request_history_request_id_fkey' and conrelid='public.request_history'::regclass) then alter table public.request_history add constraint request_history_request_id_fkey FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_budget_item_id_fkey' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_budget_item_id_fkey FOREIGN KEY (budget_item_id) REFERENCES budget_items(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_cancelled_by_id_fkey' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_cancelled_by_id_fkey FOREIGN KEY (cancelled_by_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_center_id_fkey' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='requests_company_id_fkey' and conrelid='public.requests'::regclass) then alter table public.requests add constraint requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='svc_catalog_company_id_fkey' and conrelid='public.svc_catalog'::regclass) then alter table public.svc_catalog add constraint svc_catalog_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='svc_catalog_parent_id_fkey' and conrelid='public.svc_catalog'::regclass) then alter table public.svc_catalog add constraint svc_catalog_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES svc_catalog(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_budget_item_id_fkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_budget_item_id_fkey FOREIGN KEY (budget_item_id) REFERENCES budget_items(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_center_id_fkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_company_id_fkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_refund_of_id_fkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_refund_of_id_fkey FOREIGN KEY (refund_of_id) REFERENCES transactions(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='transactions_reverses_id_fkey' and conrelid='public.transactions'::regclass) then alter table public.transactions add constraint transactions_reverses_id_fkey FOREIGN KEY (reverses_id) REFERENCES transactions(id) ON DELETE RESTRICT; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_companies_company_id_fkey' and conrelid='public.user_companies'::regclass) then alter table public.user_companies add constraint user_companies_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_companies_user_id_fkey' and conrelid='public.user_companies'::regclass) then alter table public.user_companies add constraint user_companies_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_company_managers_company_id_fkey' and conrelid='public.user_company_managers'::regclass) then alter table public.user_company_managers add constraint user_company_managers_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_company_managers_manager_id_fkey' and conrelid='public.user_company_managers'::regclass) then alter table public.user_company_managers add constraint user_company_managers_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='user_company_managers_user_id_fkey' and conrelid='public.user_company_managers'::regclass) then alter table public.user_company_managers add constraint user_company_managers_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_auth_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_auth_id_fkey FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_center_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_center_id_fkey FOREIGN KEY (center_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_company_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_escalate_user_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_escalate_user_id_fkey FOREIGN KEY (escalate_user_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_exec_substitute_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_exec_substitute_id_fkey FOREIGN KEY (exec_substitute_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_level_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_level_id_fkey FOREIGN KEY (level_id) REFERENCES job_levels(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_manager_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_next_approver_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_next_approver_id_fkey FOREIGN KEY (next_approver_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_org_dept_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_org_dept_id_fkey FOREIGN KEY (org_dept_id) REFERENCES org_departments(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='users_request_approver_id_fkey' and conrelid='public.users'::regclass) then alter table public.users add constraint users_request_approver_id_fkey FOREIGN KEY (request_approver_id) REFERENCES users(id); end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_company_id_fkey' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_unit_id_fkey' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES centers(id) ON DELETE SET NULL; end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname='worker_contracts_user_id_fkey' and conrelid='public.worker_contracts'::regclass) then alter table public.worker_contracts add constraint worker_contracts_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL; end if; end $c$;

-- ═══ الفهارس ═══
create unique index if not exists beneficiaries_master_co_name_key ON public.beneficiaries_master USING btree (company_id, name);
create index if not exists idx_budget_items_company ON public.budget_items USING btree (company_id);
create index if not exists idx_budget_items_parent ON public.budget_items USING btree (parent_id);
create index if not exists idx_budget_items_type ON public.budget_items USING btree (type);
create index if not exists idx_budget_revenues_date ON public.budget_revenues USING btree (revenue_date);
create index if not exists idx_budget_revenues_item ON public.budget_revenues USING btree (budget_item_id);
create index if not exists center_ledger_center ON public.center_ledger USING btree (center_id, entry_date);
create unique index if not exists center_ledger_receipt_u ON public.center_ledger USING btree (company_id, receipt) WHERE (receipt IS NOT NULL);
create index if not exists clp_company ON public.center_ledger_payers USING btree (company_id);
create index if not exists clients_company ON public.clients USING btree (company_id);
create index if not exists contract_prices_contract_idx ON public.contract_prices USING btree (contract_id);
create index if not exists custodies_holder_idx ON public.custodies USING btree (holder_id, company_id, status);
create index if not exists custody_lines_custody_idx ON public.custody_lines USING btree (custody_id);
create index if not exists gateway_imports_co ON public.gateway_imports USING btree (company_id, kind, date_to);
create index if not exists idx_job_levels_company ON public.job_levels USING btree (company_id);
create index if not exists login_aliases_user_idx ON public.login_aliases USING btree (user_id);
create index if not exists prr_pending_idx ON public.password_reset_requests USING btree (status, requested_at DESC);
create index if not exists prj_collections_invoice_idx ON public.prj_collections USING btree (invoice_id);
create index if not exists prj_documents_company_idx ON public.prj_documents USING btree (company_id, created_at DESC);
create index if not exists prj_invoices_project_idx ON public.prj_invoices USING btree (project_id);
create index if not exists projects_company_idx ON public.projects USING btree (company_id, status);
create index if not exists push_outbox_due ON public.push_outbox USING btree (send_after) WHERE (sent_at IS NULL);
create index if not exists push_subscriptions_user ON public.push_subscriptions USING btree (user_id);
create index if not exists qy_att_req_idx ON public.qy_attachments USING btree (request_id);
create index if not exists qy_attachments_master_idx ON public.qy_attachments USING btree (master_id);
create index if not exists qy_client_events_at_idx ON public.qy_client_events USING btree (at DESC);
create index if not exists qy_client_events_dev_idx ON public.qy_client_events USING btree (device_id, at DESC);
create index if not exists qy_client_events_kind_idx ON public.qy_client_events USING btree (kind, at DESC);
create index if not exists qy_ho_from_idx ON public.qy_handovers USING btree (from_user_id, status);
create index if not exists qy_ho_to_idx ON public.qy_handovers USING btree (to_user_id, status);
create index if not exists qy_verify_hits_idx ON public.qy_verify_hits USING btree (ip, at DESC);
create index if not exists recurring_occ_idx ON public.recurring_occurrences USING btree (company_id, status, due_date);
create index if not exists idx_approval_steps_approver ON public.request_approval_steps USING btree (approver_id);
create index if not exists idx_approval_steps_request ON public.request_approval_steps USING btree (request_id);
create index if not exists idx_approval_steps_status ON public.request_approval_steps USING btree (status);
create index if not exists idx_reqben_request ON public.request_beneficiaries USING btree (request_id);
create index if not exists request_beneficiaries_supplier_idx ON public.request_beneficiaries USING btree (supplier_id) WHERE (supplier_id IS NOT NULL);
create index if not exists idx_reqhist_request ON public.request_history USING btree (request_id);
create index if not exists idx_requests_budget_item ON public.requests USING btree (budget_item_id);
create index if not exists idx_requests_company ON public.requests USING btree (company_id);
create index if not exists idx_requests_created_by ON public.requests USING btree (created_by_id);
create index if not exists idx_requests_status ON public.requests USING btree (status);
create unique index if not exists requests_verify_code_uidx ON public.requests USING btree (verify_code);
create index if not exists svc_catalog_company_idx ON public.svc_catalog USING btree (company_id, parent_id);
create index if not exists transactions_budget_item_idx ON public.transactions USING btree (budget_item_id);
create index if not exists transactions_company_date_idx ON public.transactions USING btree (company_id, tx_date DESC);
create index if not exists transactions_refund_of_idx ON public.transactions USING btree (refund_of_id) WHERE (refund_of_id IS NOT NULL);
create unique index if not exists transactions_reverses_once_idx ON public.transactions USING btree (reverses_id) WHERE (reverses_id IS NOT NULL);
create index if not exists transactions_source_idx ON public.transactions USING btree (source_type, source_id);
create index if not exists idx_ucm_company ON public.user_company_managers USING btree (company_id);
create index if not exists idx_users_center ON public.users USING btree (center_id);
create index if not exists idx_users_company ON public.users USING btree (company_id);
create index if not exists idx_users_manager ON public.users USING btree (manager_id);
create index if not exists worker_contracts_company_idx ON public.worker_contracts USING btree (company_id, status);

