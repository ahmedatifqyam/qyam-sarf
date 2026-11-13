-- حالة «متوقف» (إغلاق مؤقت) + سبب تغيير الحالة + إعادة الفتح (13 نوفمبر 2026) — للتجربة أولاً
-- متوقف: لا طلبات جديدة، ويُجمَّد صرف الطلبات المفتوحة عند المحاسب، والدخل والترحيل مستمران. إيقاف المركز يسري على بنوده.
-- مغلق: بعد تصفير الرصيد وإنجاز الطلبات. ويمكن إعادة فتحه بسبب.

alter table public.centers drop constraint if exists centers_stage_chk;
alter table public.centers add constraint centers_stage_chk check (stage in ('potential','open','active','suspended','closed'));
alter table public.centers add column if not exists stage_note text;
alter table public.centers add column if not exists stage_by text;
alter table public.centers add column if not exists stage_at timestamptz;
grant select (stage_note, stage_by, stage_at) on public.centers to authenticated;

-- متوقف فعلياً: هو أو أحد أسلافه
create or replace function public.qy_unit_suspended(p_center text) returns text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select c.name from public.qy_unit_up(p_center) u join public.centers c on c.id = u.id where c.stage = 'suspended' order by u.depth limit 1;
$$;
revoke all on function public.qy_unit_suspended(text) from public, anon, authenticated;

drop function if exists public.qy_center_set_stage(text, text);
create or replace function public.qy_center_set_stage(p_center text, p_stage text, p_note text default null) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric; v_note text := nullif(trim(coalesce(p_note,'')),'');
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('potential','open','active','suspended','closed') then raise exception 'حالة غير صالحة'; end if;
  if p_stage = ce.stage then return; end if;
  if (p_stage = 'suspended' or ce.stage in ('suspended','closed')) and v_note is null then
    raise exception '%', case when p_stage = 'suspended' then 'اكتب سبب الإيقاف' else 'اكتب سبب إعادة الفتح' end;
  end if;
  if p_stage = 'closed' then
    if exists (select 1 from public.centers x where x.parent_id = p_center and x.stage <> 'closed') then raise exception 'لا يُغلق نهائياً: تحته بنود غير مغلقة. أغلقها أولاً، أو اختر «متوقف» الآن'; end if;
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'لا يُغلق نهائياً: له طلبات مفتوحة (%). اختر «متوقف» حتى تُنجز أو تُلغى', v_open; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'لا يُغلق نهائياً: الرصيد غير مصفّى (%). اختر «متوقف» حتى ترحّله أو تسوّيه', v_bal; end if;
  end if;
  update public.centers set stage = p_stage, stage_note = v_note, stage_by = public.qy_me(), stage_at = now() where id = p_center;
end $$;
revoke all on function public.qy_center_set_stage(text, text, text) from public, anon;
grant execute on function public.qy_center_set_stage(text, text, text) to authenticated;

-- منع الطلب الجديد حسب الحالة والرصيد
create or replace function public.qy_center_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_avail numeric; v_sus text;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception '«%» مغلق ولا تُنشأ له طلبات جديدة', ce.name; end if;
  v_sus := public.qy_unit_suspended(ce.id);
  if v_sus is not null then raise exception '«%» متوقف ولا تُنشأ طلبات حتى يعود «شغال»', v_sus; end if;
  if ce.stage = 'potential' then raise exception '«%» محتمل ولم يُعتمد بعد، فلا تُنشأ له طلبات', ce.name; end if;
  if ce.stage = 'open' and not coalesce(ce.pre_pay,false) then raise exception '«%» مفتوح ولم يُدفع بعد، ولا يُصرف له قبل الدفع', ce.name; end if;
  if ce.balance_control then
    v_avail := public.qy_center_balance(ce.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if coalesce(new.total_amount,0) > v_avail + coalesce(ce.overdraft_limit,0) then
      raise exception 'يتجاوز الطلب الرصيد المتاح (%) مع حد السالب (%)', v_avail, coalesce(ce.overdraft_limit,0);
    end if;
  end if;
  return new;
end $$;

-- تجميد الصرف: لا ينتقل طلب وحدة متوقفة إلى اعتماد التحويل أو إتمام الصرف أو الاكتمال
create or replace function public.qy_center_freeze() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_sus text;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  if new.status is distinct from old.status and new.status in ('pending_transfer_approval','pending_disbursement','completed') then
    v_sus := public.qy_unit_suspended(new.center_id);
    if v_sus is not null then raise exception '«%» متوقف: الصرف مجمّد حتى يعود «شغال»', v_sus; end if;
  end if;
  return new;
end $$;
create or replace trigger qy_center_freeze_t before update of status on public.requests for each row execute function public.qy_center_freeze();
