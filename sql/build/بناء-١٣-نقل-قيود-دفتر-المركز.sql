-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٣ (1.41.0): نقل قيود دفتر المركز إلى مركز آخر — تصحيح القديم دون تعديله.
--   السطر الأصلي لا يُحذف ولا تتغير أرقامه: يُشطب ويُكتب عليه «نُقل إلى …» مع السبب ومن نفّذ ومتى.
--   ويُنشأ سطر مطابق في المركز الصحيح (نفس التاريخ والمبلغ والرسوم والإيصال والدافع)
--   وتُحسب حصة الشركة بنسبة المركز الجديد. السطران مربوطان (moved_from_id / moved_to_id).
--   التراجع: نقل السطر الجديد إلى مركزه الأصلي بنفس الأداة. استرجاع سطر منقول ممنوع (حتى لا يُحسب مرتين).
--   الصلاحية: مدير النظام، والمحاسب والمدير المالي في الشركة نفسها (مثل حذف الحركة).
-- يُشغَّل بعد بناء-١..١٢. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.center_ledger add column if not exists moved_from_id bigint references public.center_ledger(id) on delete set null;
alter table public.center_ledger add column if not exists moved_to_id   bigint;
-- مؤجَّل الفحص لآخر العملية: الأصلي يُربط بالجديد قبل إدراجه
alter table public.center_ledger drop constraint if exists center_ledger_moved_to_id_fkey;
alter table public.center_ledger add constraint center_ledger_moved_to_id_fkey foreign key (moved_to_id)
  references public.center_ledger(id) on delete set null deferrable initially deferred;
create index if not exists center_ledger_moved_from on public.center_ledger(moved_from_id) where moved_from_id is not null;

-- رقم الإيصال فريد في الشركة، لكن السطر المنقول (الأصلي المشطوب) يتركه للسطر الجديد
drop index if exists public.center_ledger_receipt_u;
create unique index if not exists center_ledger_receipt_u2 on public.center_ledger(company_id, receipt)
  where receipt is not null and moved_to_id is null;

create or replace function public.qy_ledger_move(p_ids bigint[], p_to text, p_reason text)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  ce public.centers%rowtype; l public.center_ledger%rowtype;
  v_me text := public.qy_me(); v_reason text := trim(coalesce(p_reason,''));
  v_open date; v_pct numeric; v_share numeric; v_new bigint; n int := 0; v_from_name text;
begin
  if v_reason = '' then raise exception 'اكتب سبب النقل'; end if;
  select * into ce from public.centers where id = p_to;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then
    raise exception 'للمالية ومدير النظام فقط';
  end if;
  if ce.stage = 'closed' then raise exception '«%» مغلق ولا تُنقل إليه حركات', ce.name; end if;
  if coalesce(array_length(p_ids,1),0) = 0 then raise exception 'لم تُحدد أي حركة'; end if;
  v_open := public.qy_center_open_date(p_to);

  for l in select * from public.center_ledger where id = any(p_ids) order by entry_date, id for update loop
    if l.company_id <> ce.company_id then raise exception 'الحركة % من شركة أخرى', l.id; end if;
    if l.voided then raise exception 'الحركة بتاريخ % محذوفة أو منقولة من قبل، فلا تُنقل', to_char(l.entry_date,'DD-MM-YYYY'); end if;
    if l.kind in ('opening','transfer') then raise exception 'الرصيد الافتتاحي والترحيل لا يُنقلان'; end if;
    if l.center_id is null then raise exception 'الحركة المعلّقة تُصنَّف من صفحة استيراد البوابة'; end if;
    if l.center_id = p_to then raise exception 'الحركة بتاريخ % في «%» أصلاً', to_char(l.entry_date,'DD-MM-YYYY'), ce.name; end if;
    if v_open is not null and l.entry_date <= v_open then
      raise exception 'الحركة بتاريخ % في يوم الرصيد الافتتاحي لـ«%» (%) أو قبله، فلا تُنقل إليه',
        to_char(l.entry_date,'DD-MM-YYYY'), ce.name, to_char(v_open,'DD-MM-YYYY');
    end if;

    -- حصة الشركة بنسبة المركز الجديد (ما كان بلا حصة يبقى بلا حصة)
    if coalesce(l.company_pct,0) = 0 then v_pct := coalesce(l.company_pct,0);
    else v_pct := public.qy_center_pct(p_to, l.kind = 'support'); end if;
    v_share := public.qy_round3((coalesce(l.gross,0) - coalesce(l.gateway_fee,0)) * v_pct / 100);
    select name into v_from_name from public.centers where id = l.center_id;

    v_new := nextval(pg_get_serial_sequence('public.center_ledger','id'));
    -- الأصلي: يُشطب ويُربط بالجديد (قبل إدراج الجديد حتى يتركه رقم الإيصال)
    update public.center_ledger set
        voided = true, voided_by = v_me, voided_at = now(),
        void_reason = 'نُقل إلى «'||ce.name||'»: '||v_reason,
        restored_by = null, restored_at = null, moved_to_id = v_new
      where id = l.id;
    insert into public.center_ledger(id, company_id, center_id, kind, entry_date, period_from, period_to, gross, gateway_fee,
        company_pct, company_share, net, method, purpose, agent, receipt, note, source, request_id, import_id, created_by, order_ref, moved_from_id)
      values (v_new, l.company_id, p_to, l.kind, l.entry_date, l.period_from, l.period_to, l.gross, l.gateway_fee,
        v_pct, v_share, public.qy_round3(coalesce(l.gross,0) - coalesce(l.gateway_fee,0) - v_share),
        l.method, l.purpose, l.agent, l.receipt,
        nullif(trim(coalesce(l.note,'')||case when coalesce(l.note,'')<>'' then ' · ' else '' end||'منقول من «'||coalesce(v_from_name,'')||'»: '||v_reason),''),
        l.source, l.request_id, l.import_id, v_me, l.order_ref, l.id);
    insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone)
      select v_new, company_id, payer_name, payer_phone from public.center_ledger_payers where ledger_id = l.id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'لم تُوجد الحركات المحددة'; end if;
  return n;
end $function$;

revoke all on function public.qy_ledger_move(bigint[], text, text) from public, anon;
grant execute on function public.qy_ledger_move(bigint[], text, text) to authenticated;

-- الحذف والاسترجاع: لا يُسترجع سطر منقول (تراجع النقل يكون بنقل السطر الجديد)
create or replace function public.qy_ledger_void(p_id bigint, p_void boolean, p_reason text default null::text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare l public.center_ledger%rowtype; v boolean := coalesce(p_void, true);
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if v and length(trim(coalesce(p_reason,''))) = 0 then raise exception 'اكتب سبب الحذف'; end if;
  if not v and l.moved_to_id is not null then
    raise exception 'هذه الحركة منقولة إلى مركز آخر؛ للتراجع انقل الحركة الجديدة إلى مركزها الأصلي';
  end if;
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
end $function$;

-- تحقق
select (select count(*) from information_schema.columns where table_schema='public' and table_name='center_ledger' and column_name in ('moved_from_id','moved_to_id')) as new_cols_2,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='qy_ledger_move') as move_fn_1,
       (select count(*) from pg_indexes where tablename='center_ledger' and indexname='center_ledger_receipt_u2') as receipt_idx_1;
