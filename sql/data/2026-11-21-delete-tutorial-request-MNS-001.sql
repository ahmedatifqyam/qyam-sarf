-- قاعدة التجربة فقط (xisaigwntqeowathxpsr) — بطلب المستخدم 2026-11-21
-- الطلب التعليمي ش.ق.ك-MNS-001/2026 (r1795074040398) «رواتب 9» 700 د.ك — مركز الاندلس — مكتمل.
-- الحذف النهائي رُفض (دفتر الحركات لا يُحذف منه)، فاختير الإبطال + قيد عاكس:
-- رصيد المركز يستبعد الطلبات المبطلة، والقيد العاكس يعيد الـ700 في دفتر الحركات.
-- بيانات فقط، ليس جزءاً من «بناء قاعدة البيانات».
begin;
insert into public.transactions (company_id, center_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, reverses_id, note, created_by_id, created_by)
select company_id, center_id, current_date, 'in', amount, budget_item_id, beneficiary, 'عكس: ' || description, source_type, source_id, id,
       'طلب تعليمي — أُبطل بطلب مدير النظام', 'admin', 'مدير النظام'
from public.transactions where id = 'ff17009e-33a8-446a-a7e7-5515667b2583'
  and not exists (select 1 from public.transactions where reverses_id = 'ff17009e-33a8-446a-a7e7-5515667b2583');
update public.requests set is_cancelled = true, cancelled_at = now(), cancelled_by_id = 'admin', cancel_reason = 'طلب تعليمي'
where id = 'r1795074040398' and number = 'ش.ق.ك-MNS-001/2026';
insert into public.request_history (request_id, step, actor, user_id, action, note, time)
values ('r1795074040398', 'completed', 'مدير النظام', 'admin', 'إبطال الطلب', 'طلب تعليمي — قيد عاكس في دفتر الحركات',
        to_char(now() at time zone 'Asia/Kuwait', 'DD-MM-YYYY HH24:MI'));
commit;
