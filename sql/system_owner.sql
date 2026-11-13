-- مالك النظام (13 نوفمبر 2026): حساب مدير النظام صاحب الهاتف 98937472 مثبَّت
-- لا يُحذف، ولا يغيّر غيرُه دوره أو إيقافه أو هاتفه أو اسمه أو شركته أو ربط دخوله. وساعات العمل تظهر له وحده.
-- قابل لإعادة التشغيل: يُثبَّت معرّف الحساب وقت التطبيق (يختلف بين التجربة والإنتاج).
do $$
declare v_id text;
begin
  select id into v_id from public.users where regexp_replace(coalesce(phone,''),'\D','','g') like '%98937472' order by (role='admin') desc limit 1;
  if v_id is null then raise exception 'لم يُعثر على حساب الهاتف 98937472'; end if;
  execute format($f$create or replace function public.qy_owner_id() returns text language sql immutable as $b$ select %L::text $b$$f$, v_id);
end $$;
revoke all on function public.qy_owner_id() from public, anon;
grant execute on function public.qy_owner_id() to authenticated;

create or replace function public.qy_owner_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_me text := public.qy_me();
begin
  if old.id <> public.qy_owner_id() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then raise exception 'حساب مالك النظام لا يُحذف'; end if;
  -- التعديل من قاعدة البيانات مباشرة (بلا مستخدم) أو من المالك نفسه مسموح
  if v_me is null or v_me = old.id then
    if new.role is distinct from 'admin' then raise exception 'حساب مالك النظام يبقى مدير نظام'; end if;
    if coalesce(new.is_suspended,false) then raise exception 'حساب مالك النظام لا يُوقف'; end if;
    return new;
  end if;
  if new.role is distinct from old.role or coalesce(new.is_suspended,false) is distinct from coalesce(old.is_suspended,false)
     or new.phone is distinct from old.phone or new.name is distinct from old.name or new.company_id is distinct from old.company_id
     or new.auth_id is distinct from old.auth_id or new.email is distinct from old.email then
    raise exception 'لا يعدّل بيانات حساب مالك النظام إلا صاحبه';
  end if;
  return new;
end $$;
drop trigger if exists qy_owner_guard_t on public.users;
create trigger qy_owner_guard_t before update or delete on public.users for each row execute function public.qy_owner_guard();
