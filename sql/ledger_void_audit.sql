-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٨ (1.29.0): أثر الحذف والاسترجاع في دفتر المراكز — من حذف ومتى ولماذا، ومن استرجع ومتى.
-- يُشغَّل بعد بناء-١..٧. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.center_ledger add column if not exists voided_by text;
alter table public.center_ledger add column if not exists voided_at timestamptz;
alter table public.center_ledger add column if not exists void_reason text;
alter table public.center_ledger add column if not exists restored_by text;
alter table public.center_ledger add column if not exists restored_at timestamptz;

drop function if exists public.qy_ledger_void(bigint, boolean);
create or replace function public.qy_ledger_void(p_id bigint, p_void boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.center_ledger%rowtype; v boolean := coalesce(p_void, true);
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if v and length(trim(coalesce(p_reason,''))) = 0 then raise exception 'اكتب سبب الحذف'; end if;
  if l.kind = 'transfer' then
    if not public.qy_can_transfer(public.qy_unit_root(l.center_id)) then raise exception 'ليست لديك صلاحية'; end if;
  elsif not (public.is_admin() or (public.is_finance() and public.can_see_company(l.company_id))) then
    raise exception 'للمالية ومدير النظام فقط';
  end if;
  update public.center_ledger set
      voided      = v,
      voided_by   = case when v then public.qy_me() else voided_by end,
      voided_at   = case when v then now() else voided_at end,
      void_reason = case when v then trim(p_reason) else void_reason end,
      restored_by = case when v then null else public.qy_me() end,
      restored_at = case when v then null else now() end
  where id = p_id or (l.kind = 'transfer' and l.pair_id is not null and id = l.pair_id);
end $$;
grant execute on function public.qy_ledger_void(bigint, boolean, text) to authenticated;
