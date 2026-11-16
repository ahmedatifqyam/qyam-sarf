-- طلب راتب ومكافأة (15 نوفمبر 2026): نوع الطلب request_type = 'payroll'، وكل مستفيد يُربط بعقده
alter table public.request_beneficiaries add column if not exists contract_id uuid references public.worker_contracts(id) on delete set null;
-- موظف المركز يرى العقود السارية لمركزه (أو المركز الأم لوحدته) ليختار منها مستفيدي طلب الراتب
drop policy if exists worker_contracts_sel_center on public.worker_contracts;
create policy worker_contracts_sel_center on public.worker_contracts for select to authenticated
  using (status = 'active' and unit_id is not null and exists (
    select 1 from public.users u left join public.centers cu on cu.id = u.center_id
    where u.id = public.qy_me() and (u.center_id = worker_contracts.unit_id or cu.parent_id = worker_contracts.unit_id)));
-- (16 نوفمبر) السماح بالنوع الجديد في قيد نوع الطلب — كان ناقصاً فرفض إنشاء طلب الراتب (كود 23514)
alter table public.requests drop constraint if exists requests_request_type_chk;
alter table public.requests add constraint requests_request_type_chk check (request_type = any (array['normal','custody','payroll']));
