-- ١٠ نوفمبر: (١) صرف بلا سند (إكراميات، هدايا، مواصلات) بإذن الشركة وسقف  (٢) توقيع الإدارة اختياري ومن يوقّع
alter table public.companies add column if not exists custody_nodoc_on boolean not null default false;
alter table public.companies add column if not exists custody_nodoc_mode text;
alter table public.companies add column if not exists custody_nodoc_value numeric(14,3);
alter table public.companies add column if not exists custody_sign_on boolean not null default true;
alter table public.companies add column if not exists custody_signers text not null default 'any';
alter table public.companies drop constraint if exists companies_custody_nodoc_chk;
alter table public.companies add constraint companies_custody_nodoc_chk check ((custody_nodoc_mode is null or custody_nodoc_mode in ('amount','percent')) and (custody_nodoc_value is null or custody_nodoc_value >= 0) and (custody_nodoc_mode <> 'percent' or custody_nodoc_value <= 100));
alter table public.companies drop constraint if exists companies_custody_signers_chk;
alter table public.companies add constraint companies_custody_signers_chk check (custody_signers in ('any','cfo','acct'));
alter table public.custody_lines add column if not exists no_doc boolean not null default false;
alter table public.custody_lines add column if not exists no_doc_reason text;

-- سقف المبالغ بلا سند لعهدة: مبلغ ثابت أو نسبة من مبلغها (null = بلا سقف)
create or replace function public.qy_custody_nodoc_cap(p_id bigint) returns numeric
language sql stable security definer set search_path to 'public','pg_temp' as $f$
  select case c.custody_nodoc_mode when 'amount' then c.custody_nodoc_value when 'percent' then round(k.amount * c.custody_nodoc_value / 100, 3) else null end
  from public.custodies k join public.companies c on c.id = k.company_id where k.id = p_id;
$f$;
revoke all on function public.qy_custody_nodoc_cap(bigint) from public, anon;
grant execute on function public.qy_custody_nodoc_cap(bigint) to authenticated;

drop function if exists public.qy_custody_line_save(bigint, bigint, text, numeric, text, text, date, text, boolean);
create or replace function public.qy_custody_line_save(p_custody bigint, p_id bigint, p_kind text, p_amount numeric, p_desc text, p_invoice text, p_date date, p_image text, p_keep_image boolean default true, p_no_doc boolean default false, p_no_doc_reason text default null)
 returns custody_lines language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
declare k public.custodies%rowtype; l public.custody_lines%rowtype; mn numeric; img text; d date := coalesce(p_date, current_date);
  nd_on boolean; cap numeric; used numeric; nodoc boolean := coalesce(p_no_doc,false);
begin
  select * into k from public.custodies where id = p_custody for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.holder_id is distinct from public.qy_me() and not public.is_admin() then raise exception 'تسجيل سطور العهدة لصاحبها وحده'; end if;
  if p_id is not null then
    select * into l from public.custody_lines where id = p_id and custody_id = p_custody for update;
    if not found then raise exception 'السطر غير موجود'; end if;
  end if;
  if k.status = 'close_requested' then
    if p_id is null or not coalesce(l.reopened,false) then raise exception 'العهدة عند المراجِع: لا يُعدَّل إلا سطر فتحه للتصحيح'; end if;
  elsif k.status not in ('open','returned') then raise exception 'العهدة ليست مفتوحة لتسجيل السطور'; end if;
  if p_kind not in ('expense','receipt') then raise exception 'نوع السطر غير معروف'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'المبلغ يجب أن يكون أكبر من صفر'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'الوصف مطلوب'; end if;
  if d > current_date then raise exception 'تاريخ السطر لا يكون بعد اليوم'; end if;
  if k.received_at is not null and d < (k.received_at at time zone 'Asia/Kuwait')::date then raise exception 'تاريخ السطر لا يكون قبل استلام العهدة'; end if;
  if p_id is not null and l.status = 'accepted' then raise exception 'سطر قبله المراجِع لا يُعدَّل'; end if;
  select c.custody_img_min, c.custody_nodoc_on into mn, nd_on from public.companies c where c.id = k.company_id;
  if nodoc then
    if not coalesce(nd_on,false) then raise exception 'الصرف بلا سند غير مسموح في هذه الشركة'; end if;
    if p_kind <> 'expense' then raise exception 'المقبوض لا يُسجَّل بلا سند'; end if;
    if length(btrim(coalesce(p_no_doc_reason,''))) = 0 then raise exception 'اكتب سبب عدم وجود سند'; end if;
    cap := public.qy_custody_nodoc_cap(p_custody);
    if cap is not null then
      select coalesce(sum(amount),0) into used from public.custody_lines where custody_id = p_custody and no_doc and id is distinct from p_id;
      if used + p_amount > cap then raise exception 'تجاوز سقف المبالغ بلا سند لهذه العهدة (%). المتاح: %', cap, greatest(cap - used, 0); end if;
    end if;
  end if;
  img := case when nullif(p_image,'') is not null then p_image when p_id is not null and coalesce(p_keep_image,true) then l.image_data else null end;
  if img is null and not nodoc and (p_kind = 'receipt' or p_amount >= coalesce(mn,0)) then
    raise exception 'صورة السند إلزامية لهذا السطر';
  end if;
  if p_id is null then
    insert into public.custody_lines(custody_id, kind, amount, description, invoice_no, line_date, image_data, created_by_id, no_doc, no_doc_reason)
      values (p_custody, p_kind, round(p_amount,3), left(btrim(p_desc),300), nullif(left(btrim(coalesce(p_invoice,'')),60),''), d, img, public.qy_me(), nodoc, case when nodoc then left(btrim(p_no_doc_reason),300) end)
      returning * into l;
  else
    update public.custody_lines set kind = p_kind, amount = round(p_amount,3), description = left(btrim(p_desc),300),
      invoice_no = nullif(left(btrim(coalesce(p_invoice,'')),60),''), line_date = d, image_data = img,
      no_doc = nodoc, no_doc_reason = case when nodoc then left(btrim(p_no_doc_reason),300) end,
      status = 'draft', review_note = null, reopened = false, updated_at = now()
     where id = p_id returning * into l;
  end if;
  perform public.qy_custody_over_check(p_custody);
  return l;
end $function$;
revoke all on function public.qy_custody_line_save(bigint, bigint, text, numeric, text, text, date, text, boolean, boolean, text) from public, anon;
grant execute on function public.qy_custody_line_save(bigint, bigint, text, numeric, text, text, date, text, boolean, boolean, text) to authenticated;

-- الإقفال الفعلي (القيد على البند + الرصيد المعلّق + رقم كشف التسوية) — داخلي لا يُستدعى من المتصفح
create or replace function public.qy_custody_finalize(p_id bigint, p_signer text, p_hist text) returns custodies
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare k public.custodies%rowtype; r numeric; e numeric; d numeric; co text; hn text;
begin
  select * into k from public.custodies where id = p_id for update;
  select coalesce(sum(amount) filter (where kind = 'receipt'),0), coalesce(sum(amount) filter (where kind = 'expense'),0) into r, e from public.custody_lines where custody_id = p_id;
  d := round(k.amount + r - e, 3);
  select c.code into co from public.companies c where c.id = k.company_id;
  select u.name into hn from public.users u where u.id = k.holder_id;
  if d <> 0 then
    insert into public.transactions(company_id, tx_date, direction, amount, budget_item_id, beneficiary, description, source_type, source_id, note, created_by_id, created_by)
    values (k.company_id, current_date, case when d > 0 then 'in' else 'out' end, abs(d), k.budget_item_id, hn,
      case when d > 0 then 'إقفال عهدة: ما لم يُصرف يعود للبند' else 'إقفال عهدة: مصروف زائد على مبلغها' end,
      'custody', k.id::text, 'العهدة ' || k.id, p_signer, (select u.name from public.users u where u.id = p_signer));
  end if;
  if k.remaining_action in ('carry','carry_debt') and coalesce(k.remaining_amount,0) <> 0 then
    insert into public.custody_balances(holder_id, company_id, amount, source_custody_id) values (k.holder_id, k.company_id, k.remaining_amount, k.id);
  end if;
  update public.custodies set status = 'closed', signed_by_id = p_signer, closed_at = now(),
    settlement_no = coalesce(settlement_no, 'ST-' || coalesce(co,'') || '-' || lpad(k.id::text, 5, '0')) where id = p_id returning * into k;
  perform public.qy_custody_hist(k, p_hist, 'كشف التسوية ' || k.settlement_no);
  return k;
end $function$;
revoke all on function public.qy_custody_finalize(bigint, text, text) from public, anon, authenticated;

create or replace function public.qy_custody_sign(p_id bigint) returns custodies
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare k public.custodies%rowtype; me text := public.qy_me(); sg text; ok boolean;
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'pending_sign' then raise exception 'العهدة ليست بانتظار التوقيع'; end if;
  select coalesce(c.custody_signers,'any') into sg from public.companies c where c.id = k.company_id;
  ok := public.is_admin() or (public.can_see_company(k.company_id) and case sg
          when 'cfo'  then public.qy_is_cfo()
          when 'acct' then exists (select 1 from public.users u where u.id = me and u.role = 'accountant')
          else public.is_finance() end);
  if not ok then raise exception '%', case sg when 'cfo' then 'التوقيع للمدير المالي' when 'acct' then 'التوقيع لمحاسب آخر' else 'التوقيع للمدير المالي أو محاسب' end; end if;
  if me in (k.holder_id, k.reviewer_id, k.reviewed_by_id) and not public.is_admin() then
    raise exception 'لا يوقّع صاحب العهدة ولا من راجعها أو اعتمدها';
  end if;
  return public.qy_custody_finalize(p_id, me, 'وقّع إقفال العهدة');
end $function$;
revoke all on function public.qy_custody_sign(bigint) from public, anon;
grant execute on function public.qy_custody_sign(bigint) to authenticated;

CREATE OR REPLACE FUNCTION public.qy_custody_acct_decide(p_id bigint, p_accept boolean, p_action text, p_note text)
 RETURNS custodies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.custodies%rowtype; sgn boolean; m text; nd int; nr int; r numeric; e numeric; b numeric; me text := public.qy_me();
begin
  select * into k from public.custodies where id = p_id for update;
  if not found then raise exception 'العهدة غير موجودة'; end if;
  if k.status <> 'acct_review' then raise exception 'العهدة ليست عند المحاسب'; end if;
  if not ((public.is_finance() and public.can_see_company(k.company_id)) or public.is_admin()) then raise exception 'قرار الإقفال للمالية'; end if;
  if k.holder_id = me then raise exception 'صاحب العهدة لا يعتمد إقفالها'; end if;
  select coalesce(c.custody_review_mode,'line') into m from public.companies c where c.id = k.company_id;
  select count(*) filter (where status = 'draft'), count(*) filter (where status = 'rejected') into nd, nr from public.custody_lines where custody_id = p_id;
  if not p_accept then
    if m = 'line' and nr = 0 then raise exception 'ارفض السطور التي تحتاج تصحيحاً أولاً'; end if;
    if m = 'whole' and length(btrim(coalesce(p_note,''))) = 0 then raise exception 'اكتب سبب الإرجاع'; end if;
    update public.custodies set status = 'returned' where id = p_id returning * into k;
    perform public.qy_custody_hist(k, 'أعاد المحاسب العهدة للتصحيح', coalesce(nullif(btrim(p_note),''), nr || ' سطر مرفوض'));
    return k;
  end if;
  if m = 'line' and (nd > 0 or nr > 0) then raise exception 'كل السطور يجب أن تكون مقبولة قبل الاعتماد'; end if;
  if m = 'whole' then update public.custody_lines set status = 'accepted', review_note = null, reviewed_by_id = me, reviewed_at = now() where custody_id = p_id; end if;
  select coalesce(sum(amount) filter (where kind = 'receipt'),0), coalesce(sum(amount) filter (where kind = 'expense'),0) into r, e from public.custody_lines where custody_id = p_id;
  b := round(k.amount + k.carried_in + r - e, 3);
  if b > 0 and p_action not in ('return_cash','carry') then raise exception 'اختر: إرجاع الباقي نقداً أو ترحيله'; end if;
  if b < 0 and p_action not in ('pay_diff','carry_debt') then raise exception 'اختر: صرف الفرق لصاحب العهدة أو ترحيله ديناً'; end if;
  update public.custodies set status = 'pending_sign', reviewed_by_id = me, remaining_amount = b,
    remaining_action = case when b = 0 then 'none' else p_action end where id = p_id returning * into k;
  perform public.qy_custody_hist(k, 'اعتمد المحاسب إقفال العهدة',
    'الباقي ' || to_char(b, 'FM999,999,990.000') || ' — ' || case k.remaining_action when 'return_cash' then 'يُرجَع نقداً' when 'carry' then 'يُرحَّل رصيداً معلّقاً' when 'pay_diff' then 'يُصرف الفرق لصاحبها' when 'carry_debt' then 'يُرحَّل ديناً' else 'لا باقي' end);
  select coalesce(c.custody_sign_on, true) into sgn from public.companies c where c.id = k.company_id;
  if not sgn then k := public.qy_custody_finalize(p_id, me, 'أُقفلت العهدة مباشرة بعد اعتماد المحاسب (توقيع الإدارة غير مفعّل)'); end if;
  return k;
end $function$;
