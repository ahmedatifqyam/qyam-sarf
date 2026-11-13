-- بوابة الدفع (13 نوفمبر 2026): رقم الطلب، مطابقة الفواتير المحفوظة، رفع الفواتير وحدها، وقفل ما قبل الرصيد الافتتاحي — للتجربة أولاً
alter table public.center_ledger add column if not exists order_ref text;   -- reference_order من الكشف = رقم الفاتورة (فيه تاريخ إنشائها)

-- تعبئة رقم الطلب للحركات المستوردة سابقاً من الكشوف المحفوظة (العمود 5 = reference_order، 6 = receipt)
update public.center_ledger l set order_ref = s.ref from (
  select distinct on (x.receipt) x.receipt, x.ref from (
    select trim(split_part(line, ',', 6)) receipt, trim(split_part(line, ',', 5)) ref, g.id
    from public.gateway_imports g, regexp_split_to_table(g.content, E'\n') line where g.kind = 'statement') x
  where x.receipt <> '' and x.ref ~ '^\d+$' order by x.receipt, x.id desc) s
where l.receipt = s.receipt and l.source = 'import' and l.order_ref is null;

-- تاريخ الرصيد الافتتاحي للوحدة
create or replace function public.qy_center_open_date(p_center text) returns date
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select max(entry_date) from public.center_ledger where center_id = p_center and kind = 'opening' and not voided;
$$;
revoke all on function public.qy_center_open_date(text) from public, anon;
grant execute on function public.qy_center_open_date(text) to authenticated;

-- القفل: لا تدخل حركة (غير الافتتاحي والتسوية) بتاريخ يوم الرصيد الافتتاحي للوحدة أو قبله
create or replace function public.qy_ledger_lock() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v date;
begin
  if new.center_id is null or new.kind in ('opening','adjust') or new.voided then return new; end if;
  if tg_op = 'UPDATE' and new.center_id is not distinct from old.center_id and new.entry_date = old.entry_date then return new; end if;
  v := public.qy_center_open_date(new.center_id);
  if v is not null and new.entry_date <= v then
    raise exception 'حركة بتاريخ % في يوم الرصيد الافتتاحي لـ«%» (%) أو قبله، فلا تدخل الدفتر', to_char(new.entry_date,'DD-MM-YYYY'),
      (select name from public.centers where id = new.center_id), to_char(v,'DD-MM-YYYY');
  end if;
  return new;
end $$;
drop trigger if exists qy_ledger_lock_t on public.center_ledger;
create trigger qy_ledger_lock_t before insert or update of center_id, entry_date on public.center_ledger for each row execute function public.qy_ledger_lock();

-- الاعتماد: يحفظ رقم الطلب، ويستبعد ما قبل الرصيد الافتتاحي للمركز المربوط
create or replace function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r jsonb; f jsonb; v_imp bigint; v_first bigint; v_ins int := 0; v_dup int := 0; v_pend int := 0; v_lock int := 0; v_id bigint;
  v_center text; v_pct numeric; v_gross numeric; v_fee numeric; v_share numeric; v_me text := public.qy_me(); v_open date;
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية رفع ملفات البوابة'; end if;
  for f in select * from jsonb_array_elements(coalesce(p_files,'[]'::jsonb)) loop
    insert into public.gateway_imports(company_id, account_id, kind, file_name, date_from, date_to, rows_count, content, uploaded_by)
    values (p_company, nullif(p_account,''), f->>'kind', f->>'file_name', nullif(f->>'date_from','')::date, nullif(f->>'date_to','')::date, coalesce((f->>'rows_count')::int,0), f->>'content', v_me)
    returning id into v_imp;
    if v_first is null then v_first := v_imp; end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_center := nullif(r->>'center_id','');
    if v_center is not null and not exists (select 1 from public.centers where id = v_center and company_id = p_company) then v_center := null; end if;
    v_gross := coalesce((r->>'gross')::numeric,0); v_fee := coalesce((r->>'fee')::numeric,0);
    if exists (select 1 from public.center_ledger where company_id = p_company and receipt = r->>'receipt') then v_dup := v_dup + 1; continue; end if;
    if v_center is not null then
      v_open := public.qy_center_open_date(v_center);
      if v_open is not null and (r->>'txn_date')::date <= v_open then v_lock := v_lock + 1; continue; end if;
      v_pct := public.qy_center_pct(v_center, false); v_share := public.qy_round3((v_gross - v_fee) * v_pct / 100);
    else v_pct := null; v_share := null; v_pend := v_pend + 1; end if;
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, method, purpose, agent, receipt, order_ref, source, import_id, created_by)
    values (p_company, v_center, 'subscription', (r->>'txn_date')::date, v_gross, v_fee, v_pct, v_share,
            case when v_center is null then null else public.qy_round3(v_gross - v_fee - v_share) end,
            r->>'method', r->>'purpose', r->>'agent', r->>'receipt', nullif(r->>'order_ref',''), 'import', v_first, v_me)
    returning id into v_id;
    if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
      insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone');
    end if;
    v_ins := v_ins + 1;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'pending', v_pend, 'locked', v_lock);
end $$;

-- التصنيف: يتخطى ما قبل الرصيد الافتتاحي فيبقى معلّقاً
create or replace function public.qy_ledger_assign(p_ids bigint[], p_center text) returns integer
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; n int := 0; l public.center_ledger%rowtype; v_pct numeric; v_share numeric; v_open date;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not public.qy_can_import(ce.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  v_pct := public.qy_center_pct(p_center, false); v_open := public.qy_center_open_date(p_center);
  for l in select * from public.center_ledger where id = any(p_ids) and center_id is null and company_id = ce.company_id loop
    if v_open is not null and l.entry_date <= v_open then continue; end if;
    v_share := public.qy_round3((l.gross - l.gateway_fee) * v_pct / 100);
    update public.center_ledger set center_id = p_center, company_pct = v_pct, company_share = v_share, net = public.qy_round3(l.gross - l.gateway_fee - v_share) where id = l.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ملفات الفواتير المحفوظة (للمطابقة مع أي كشف لاحق)
create or replace function public.qy_gateway_bills(p_company text) returns table(id bigint, content text)
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية'; end if;
  return query select g.id, g.content from public.gateway_imports g where g.company_id = p_company and g.kind = 'bills' order by g.id;
end $$;
revoke all on function public.qy_gateway_bills(text) from public, anon;
grant execute on function public.qy_gateway_bills(text) to authenticated;

-- تعبئة الجهة والغرض والدافع للحركات المعلّقة بلا جهة (من الفواتير)
create or replace function public.qy_gateway_rematch(p_company text, p_rows jsonb) returns int
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r jsonb; n int := 0; v_id bigint;
begin
  if not public.qy_can_import(p_company) then raise exception 'ليست لديك صلاحية'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_id := (r->>'id')::bigint;
    update public.center_ledger set agent = r->>'agent', purpose = coalesce(nullif(purpose,''), r->>'purpose')
     where id = v_id and company_id = p_company and center_id is null and not voided and coalesce(agent,'') = '' and coalesce(r->>'agent','') <> '';
    if found then
      n := n + 1;
      if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
        update public.center_ledger_payers set payer_name = coalesce(nullif(r->>'payer_name',''), payer_name), payer_phone = coalesce(nullif(r->>'payer_phone',''), payer_phone) where ledger_id = v_id;
        if not found then insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone'); end if;
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.qy_gateway_rematch(text, jsonb) from public, anon;
grant execute on function public.qy_gateway_rematch(text, jsonb) to authenticated;
