-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٩ (1.31.0): تفضيلات واجهة المستخدم — عرض أعمدة الجداول لكل مستخدم (يجدها في أي جهاز).
-- يُشغَّل بعد بناء-١..٨. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.user_ui_prefs (
  user_id    text primary key references public.users(id) on delete cascade,
  col_widths jsonb not null default '{}'::jsonb check (jsonb_typeof(col_widths) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.user_ui_prefs enable row level security;
drop policy if exists user_ui_prefs_own on public.user_ui_prefs;
create policy user_ui_prefs_own on public.user_ui_prefs for all
  using (user_id = public.qy_me()) with check (user_id = public.qy_me());
