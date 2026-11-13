-- موظف المركز (14 نوفمبر 2026): طلبه على مركزه أو أحد بنوده فقط، ولا يختار بنود ميزانية الشركة — للتجربة أولاً
-- موظف المركز = مستخدم وحدته «مركز» أو تحت مركز في الشجرة، وليس من المالية أو الإدارة.
update public.centers set kind = 'department' where id = 'demo_dept_1' and name = 'إدارة المالية' and kind = 'center';   -- تصحيح بيانات الشركة التجريبية

create or replace function public.qy_center_staff_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u public.users%rowtype;
begin
  if coalesce(new.request_type,'') = 'custody' or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into u from public.users where id = public.qy_me();
  if u.id is null or u.center_id is null or u.role in ('admin','accountant','cfo','executive_manager') then return new; end if;
  if not exists (select 1 from public.qy_unit_up(u.center_id) where kind = 'center') then return new; end if;
  if new.center_id is null or not exists (select 1 from public.qy_unit_up(new.center_id) where id = u.center_id) then
    raise exception 'طلب موظف المركز يكون على مركزه أو أحد بنوده فقط';
  end if;
  if new.budget_item_id is not null then raise exception 'طلب المركز يُصرف من رصيد المركز، فلا يُختار له بند من ميزانية الشركة'; end if;
  return new;
end $$;
drop trigger if exists qy_center_staff_guard_t on public.requests;
create trigger qy_center_staff_guard_t before insert on public.requests for each row execute function public.qy_center_staff_guard();
