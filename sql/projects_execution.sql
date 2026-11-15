-- مرحلة «التنفيذ» في المشروع: المنفذ (الشركة / جهة خارجية / الاثنان) وبيانات الجهة الخارجية وحالة التنفيذ (15 نوفمبر 2026)
alter table public.projects add column if not exists exec_by text check (exec_by is null or exec_by in ('company','external','both'));
alter table public.projects add column if not exists exec_party text;
alter table public.projects add column if not exists exec_amount numeric check (exec_amount is null or exec_amount >= 0);
alter table public.projects add column if not exists exec_file_path text;
alter table public.projects add column if not exists exec_file_name text;
alter table public.projects add column if not exists exec_status text not null default 'not_started' check (exec_status in ('not_started','in_progress','done'));
alter table public.projects add column if not exists exec_done_at timestamptz;
