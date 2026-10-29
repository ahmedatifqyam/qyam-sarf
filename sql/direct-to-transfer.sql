-- خانة «الانتقال المباشر إلى التحويل» + حارس الخادم. طُبّق على الاختبار؛ الإنتاج بعد موافقة صاحب النظام.
alter table public.users add column if not exists direct_to_transfer boolean not null default false;
-- (1) حارس المستخدمين: غير المدير لا يغيّر الخانة (استبدال داخل qy_guard_users)
--   or new.direct_to_transfer is distinct from old.direct_to_transfer
-- (2) حارس الطلبات: داخل فرع تغيير الحالة في qy_requests_guard، قبل فحص completed:
--   من pending_decision إلى pending_transfer_request يحتاج اعتماداً/تخطياً مسجّلاً أو direct_to_transfer لصاحب الطلب أو مدير النظام/المالية
-- (3) تفعيل أولي لمن مساره فارغ فعلاً:
update public.users set direct_to_transfer = true where role <> 'admin' and (no_request_approver or (manager_id is null and request_approver_id is null and not exists (select 1 from public.user_company_managers m where m.user_id = users.id and m.manager_id is not null)));
