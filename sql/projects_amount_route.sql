-- مسار مبلغ المشروع (15 نوفمبر 2026): مشروع عادي (الصرف بطلبات صرف) أو تحويل لمركز
-- في «تحويل لمركز» يُحوَّل المحصّل بطلب صرف مسار «تحويل لمركز»، وعند اكتمال صرفه يسجّل المشغّل qy_route_income الصافي في دفتر المركز بعد نسبة الشركة
alter table public.projects add column if not exists amount_route text not null default 'normal' check (amount_route in ('normal','center'));
alter table public.projects add column if not exists route_center_id text;
