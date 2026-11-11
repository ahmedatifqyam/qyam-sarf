-- إشعارات الجهاز (Web Push): الاشتراكات + طابور الإرسال + محفّزات الأحداث + إرسال كل دقيقة
create extension if not exists pg_net;

create table if not exists public.push_config (key text primary key, value text not null);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id text not null, endpoint text not null unique, p256dh text not null, auth text not null,
  ua text, created_at timestamptz not null default now());
create index if not exists push_subscriptions_user on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon;
revoke insert, update, delete on public.push_subscriptions from authenticated;
grant select on public.push_subscriptions to authenticated;
drop policy if exists push_subs_select on public.push_subscriptions;
create policy push_subs_select on public.push_subscriptions for select to authenticated using (user_id = public.qy_me());

create table if not exists public.push_outbox (
  id bigserial primary key, user_id text not null, title text not null, body text, url text, tag text,
  kind text not null, request_id text, ref text, send_after timestamptz not null default now(),
  sent_at timestamptz, dedupe text not null, created_at timestamptz not null default now(),
  unique (user_id, dedupe));
create index if not exists push_outbox_due on public.push_outbox(send_after) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

create or replace function public.qy_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_me text := public.qy_me();
begin
  if v_me is null then raise exception 'غير مسجَّل الدخول'; end if;
  if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'اشتراك غير صالح'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
  insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, ua) values (v_me, p_endpoint, p_p256dh, p_auth, left(p_ua,200));
end $$;
create or replace function public.qy_push_unsubscribe(p_endpoint text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_subscribe(text,text,text,text), public.qy_push_unsubscribe(text) from public, anon;
grant execute on function public.qy_push_subscribe(text,text,text,text), public.qy_push_unsubscribe(text) to authenticated;

-- وضع الإرسال: يقتصر على من لديه اشتراك، ولا يُبلَّغ من فعل الإجراء بنفسه
create or replace function public.qy_push_enqueue(p_users text[], p_title text, p_body text, p_kind text, p_req text, p_ref text, p_after timestamptz) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_me text := public.qy_me(); u text;
begin
  foreach u in array coalesce(p_users,'{}') loop
    continue when u is null or u = v_me;
    continue when not exists (select 1 from public.push_subscriptions s where s.user_id = u);
    insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
    values (u, p_title, p_body, case when p_req is null then null else '?req='||p_req end, 'qy-'||p_kind||'-'||coalesce(p_req,''), p_kind, p_req, p_ref, coalesce(p_after, now()),
            p_kind||':'||coalesce(p_ref,p_req,'')||':'||floor(extract(epoch from now()))::text)
    on conflict (user_id, dedupe) do nothing;
  end loop;
end $$;
revoke all on function public.qy_push_enqueue(text[],text,text,text,text,text,timestamptz) from public, anon, authenticated;

create or replace function public.qy_push_role_users(p_company text, p_roles text[]) returns text[]
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select coalesce(array_agg(u.id), '{}') from public.users u
  where u.role = any(p_roles) and coalesce(u.is_suspended,false) = false
    and (u.company_id = p_company or exists (select 1 from public.user_companies c where c.user_id = u.id and c.company_id = p_company));
$$;
revoke all on function public.qy_push_role_users(text,text[]) from public, anon, authenticated;

-- خطوة اعتماد تفعَّلت أو سُجّلت ورقياً
create or replace function public.qy_push_step() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r public.requests%rowtype; a public.users%rowtype; v_after timestamptz; v_ids text[];
begin
  select * into r from public.requests where id = new.request_id;
  if not found then return new; end if;
  if new.status = 'approved' and coalesce(new.method,'') = 'paper' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.qy_push_enqueue(array[r.created_by_id], 'اعتُمد طلبك ورقياً', r.number, 'paper_ok', r.id, new.id, now());
  end if;
  if new.status = 'pending' and new.activated_at is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'pending' or old.activated_at is distinct from new.activated_at) then
    select * into a from public.users where id = new.approver_id;
    v_after := greatest(now(), coalesce(r.review_until, now()));
    v_ids := array[new.approver_id];
    if a.exec_substitute_id is not null then v_ids := v_ids || a.exec_substitute_id; end if;
    v_ids := v_ids || coalesce((select array_agg(h.to_user_id) from public.qy_handovers h
        where h.from_user_id = new.approver_id and h.status = 'accepted' and h.company_id = r.company_id
          and h.from_date <= current_date and (h.to_date is null or h.to_date >= current_date)
          and (h.scope_all or r.id = any(h.request_ids))), '{}');
    perform public.qy_push_enqueue(v_ids, 'طلب بانتظار اعتمادك', r.number, 'step', r.id, new.id||':'||floor(extract(epoch from new.activated_at))::text, v_after);
    if a.paper_approval and coalesce(array_length(a.paper_proxy_ids,1),0) > 0 then
      perform public.qy_push_enqueue(a.paper_proxy_ids, 'بانتظار تسجيل اعتماد ورقي', r.number||' — عن '||a.name, 'step', r.id, new.id||':p:'||floor(extract(epoch from new.activated_at))::text, v_after);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qy_push_step_t on public.request_approval_steps;
create trigger qy_push_step_t after insert or update of status, activated_at on public.request_approval_steps
  for each row execute function public.qy_push_step();

-- تغيّر حالة الطلب
create or replace function public.qy_push_req() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_after timestamptz := greatest(now(), coalesce(new.review_until, now()));
begin
  if new.status is distinct from old.status and not coalesce(new.is_cancelled,false) then
    if new.status in ('pending_transfer_request','pending_disbursement','pending_accountant') then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['accountant']), 'طلب بانتظار إجراءك', new.number, 'acc', new.id, new.status, v_after);
    elsif new.status = 'pending_transfer_approval' then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['cfo']), 'تحويل بانتظار اعتمادك', new.number, 'acc', new.id, new.status, v_after);
    end if;
    if old.status = 'pending_decision' and new.status in ('pending_transfer_request','pending_disbursement','pending_accountant','pending_transfer_approval','completed') then
      perform public.qy_push_enqueue(array[new.created_by_id], 'اعتُمد طلبك', new.number, 'ok', new.id, new.status, now());
    elsif new.status = 'completed' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'تم صرف طلبك', new.number, 'paid', new.id, new.status, now());
    elsif new.status = 'rejected' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'رُفض طلبك', new.number, 'rej', new.id, new.status, now());
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qy_push_req_t on public.requests;
create trigger qy_push_req_t after update of status on public.requests for each row execute function public.qy_push_req();

-- إلغاء الاعتماد الورقي: يُبلَّغ المسجِّلون القدامى
create or replace function public.qy_push_hist() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r public.requests%rowtype;
begin
  if new.action = 'إلغاء الاعتماد الورقي' and new.note like '%|ids:%' then
    select * into r from public.requests where id = new.request_id;
    perform public.qy_push_enqueue(string_to_array(split_part(new.note,'|ids:',2), ','), 'أُلغي الاعتماد الورقي — لم يعد عليك تسجيله', r.number, 'paper_off', new.request_id, new.id::text, now());
  end if;
  return new;
end $$;
drop trigger if exists qy_push_hist_t on public.request_history;
create trigger qy_push_hist_t after insert on public.request_history for each row execute function public.qy_push_hist();

-- عهدة بانتظار تأكيد الاستلام
create or replace function public.qy_push_custody() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.status = 'awaiting_receipt' and (tg_op = 'INSERT' or old.status is distinct from 'awaiting_receipt') then
    perform public.qy_push_enqueue(array[new.holder_id], 'عهدة بانتظار تأكيد استلامك', null, 'custody', new.request_id, new.id::text, now());
  end if;
  return new;
end $$;
drop trigger if exists qy_push_custody_t on public.custodies;
create trigger qy_push_custody_t after insert or update of status on public.custodies for each row execute function public.qy_push_custody();

-- الإرسال: كل دقيقة. يتحقق أن الإجراء ما زال مطلوباً قبل إرسال الإشعار
create or replace function public.qy_push_flush() returns int
language plpgsql security definer set search_path to 'public','pg_temp','extensions' as $$
declare v_url text; v_secret text; v_items jsonb; v_n int := 0;
begin
  select value into v_url from public.push_config where key = 'push_url';
  select value into v_secret from public.push_config where key = 'push_secret';
  if v_url is null or v_secret is null then return 0; end if;
  delete from public.push_outbox where created_at < now() - interval '7 days';
  create temp table if not exists _qy_due(id bigint) on commit drop;
  truncate _qy_due;
  insert into _qy_due select id from public.push_outbox where sent_at is null and send_after <= now() order by id limit 200 for update skip locked;
  -- قديمة (أكثر من 6 ساعات) أو لم يعد الإجراء مطلوباً: تُهمل
  update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and (
    o.send_after < now() - interval '6 hours'
    or (o.kind = 'step' and not exists (select 1 from public.request_approval_steps s join public.requests r on r.id = s.request_id
         where s.id = split_part(o.ref,':',1) and s.status = 'pending' and not coalesce(r.is_cancelled,false) and r.status = 'pending_decision'
           and (r.review_until is null or r.review_until <= now())))
    or (o.kind = 'acc' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)
         and r.status = o.ref and (r.review_until is null or r.review_until <= now()))));
  select coalesce(jsonb_agg(jsonb_build_object('user_id',o.user_id,'title',o.title,'body',o.body,'url',o.url,'tag',o.tag)), '[]'::jsonb), count(*)
    into v_items, v_n from public.push_outbox o join _qy_due d on d.id = o.id where o.sent_at is null;
  if v_n > 0 then
    perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type','application/json','x-push-secret',v_secret), body := jsonb_build_object('items', v_items));
    update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and o.sent_at is null;
  end if;
  return v_n;
end $$;
revoke all on function public.qy_push_flush() from public, anon, authenticated;
grant all on public.push_config, public.push_subscriptions, public.push_outbox to service_role;

-- (إضافة) مدير النظام: خيار «إشعار بكل طلب جديد» لكل جهاز
alter table public.push_subscriptions add column if not exists all_requests boolean not null default false;
create or replace function public.qy_push_set_all(p_endpoint text, p_on boolean) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set all_requests = coalesce(p_on,false) where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_all(text,boolean) from public, anon;
grant execute on function public.qy_push_set_all(text,boolean) to authenticated;
create or replace function public.qy_push_new() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_ids text[];
begin
  select coalesce(array_agg(distinct s.user_id), '{}') into v_ids from public.push_subscriptions s join public.users u on u.id = s.user_id
   where s.all_requests and u.role = 'admin' and s.user_id is distinct from new.created_by_id;
  perform public.qy_push_enqueue(v_ids, 'طلب جديد في النظام', null, 'new', new.id, new.id, greatest(now(), coalesce(new.review_until, now())));
  return new;
end $$;
drop trigger if exists qy_push_new_t on public.requests;
create trigger qy_push_new_t after insert on public.requests for each row execute function public.qy_push_new();

create or replace function public.qy_push_flush() returns int
language plpgsql security definer set search_path to 'public','pg_temp','extensions' as $$
declare v_url text; v_secret text; v_items jsonb; v_n int := 0;
begin
  select value into v_url from public.push_config where key = 'push_url';
  select value into v_secret from public.push_config where key = 'push_secret';
  if v_url is null or v_secret is null then return 0; end if;
  delete from public.push_outbox where created_at < now() - interval '7 days';
  create temp table if not exists _qy_due(id bigint) on commit drop;
  truncate _qy_due;
  insert into _qy_due select id from public.push_outbox where sent_at is null and send_after <= now() order by id limit 200 for update skip locked;
  -- قديمة (أكثر من 6 ساعات) أو لم يعد الإجراء مطلوباً: تُهمل
  update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and (
    o.send_after < now() - interval '6 hours'
    or (o.kind = 'step' and not exists (select 1 from public.request_approval_steps s join public.requests r on r.id = s.request_id
         where s.id = split_part(o.ref,':',1) and s.status = 'pending' and not coalesce(r.is_cancelled,false) and r.status = 'pending_decision'
           and (r.review_until is null or r.review_until <= now())))
    or (o.kind = 'new' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)))
    or (o.kind = 'acc' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)
         and r.status = o.ref and (r.review_until is null or r.review_until <= now()))));
  update public.push_outbox o set body = r.number from _qy_due d, public.requests r where o.id = d.id and o.kind = 'new' and o.sent_at is null and r.id = o.request_id;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',o.user_id,'title',o.title,'body',o.body,'url',o.url,'tag',o.tag)), '[]'::jsonb), count(*)
    into v_items, v_n from public.push_outbox o join _qy_due d on d.id = o.id where o.sent_at is null;
  if v_n > 0 then
    perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type','application/json','x-push-secret',v_secret), body := jsonb_build_object('items', v_items));
    update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and o.sent_at is null;
  end if;
  return v_n;
end $$;
revoke all on function public.qy_push_flush() from public, anon, authenticated;

-- (لم يُطبَّق بعد على القاعدتين — بانتظار تأكيد المستخدم) خيارات إشعارات مدير النظام (لكل جهاز): admin_events
alter table public.push_subscriptions add column if not exists admin_events text[] not null default '{}';
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='push_subscriptions' and column_name='all_requests') then
    execute 'update public.push_subscriptions set admin_events = array[''new''] where all_requests';
    drop trigger if exists qy_push_new_t on public.requests;
    alter table public.push_subscriptions drop column all_requests;
  end if;
end $$;
drop function if exists public.qy_push_set_all(text,boolean);

create or replace function public.qy_push_admins(p_key text) returns text[]
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select coalesce(array_agg(distinct s.user_id), '{}') from public.push_subscriptions s join public.users u on u.id = s.user_id
  where u.role = 'admin' and coalesce(u.is_suspended,false) = false and p_key = any(s.admin_events);
$$;
revoke all on function public.qy_push_admins(text) from public, anon, authenticated;

create or replace function public.qy_push_set_events(p_endpoint text, p_events text[]) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_events(text,text[]) from public, anon;
grant execute on function public.qy_push_set_events(text,text[]) to authenticated;

create or replace function public.qy_push_new() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  perform public.qy_push_enqueue(public.qy_push_admins('new'), 'طلب جديد في النظام', null, 'new', new.id, new.id, greatest(now(), coalesce(new.review_until, now())));
  return new;
end $$;
drop trigger if exists qy_push_new_t on public.requests;
create trigger qy_push_new_t after insert on public.requests for each row execute function public.qy_push_new();

create or replace function public.qy_push_step() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r public.requests%rowtype; a public.users%rowtype; v_after timestamptz; v_ids text[];
begin
  select * into r from public.requests where id = new.request_id;
  if not found then return new; end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.qy_push_enqueue(public.qy_push_admins('approve'), case when coalesce(new.method,'')='paper' then 'اعتماد ورقي في طلب' else 'اعتماد في طلب' end, r.number, 'adm_ok', r.id, new.id, now());
  elsif new.status = 'rejected' and (tg_op = 'INSERT' or old.status is distinct from 'rejected') then
    perform public.qy_push_enqueue(public.qy_push_admins('reject'), 'رفض في طلب', r.number, 'adm_rej', r.id, new.id, now());
  end if;
  if new.status = 'approved' and coalesce(new.method,'') = 'paper' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform public.qy_push_enqueue(array[r.created_by_id], 'اعتُمد طلبك ورقياً', r.number, 'paper_ok', r.id, new.id, now());
  end if;
  if new.status = 'pending' and new.activated_at is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'pending' or old.activated_at is distinct from new.activated_at) then
    select * into a from public.users where id = new.approver_id;
    v_after := greatest(now(), coalesce(r.review_until, now()));
    v_ids := array[new.approver_id];
    if a.exec_substitute_id is not null then v_ids := v_ids || a.exec_substitute_id; end if;
    v_ids := v_ids || coalesce((select array_agg(h.to_user_id) from public.qy_handovers h
        where h.from_user_id = new.approver_id and h.status = 'accepted' and h.company_id = r.company_id
          and h.from_date <= current_date and (h.to_date is null or h.to_date >= current_date)
          and (h.scope_all or r.id = any(h.request_ids))), '{}');
    perform public.qy_push_enqueue(v_ids, 'طلب بانتظار اعتمادك', r.number, 'step', r.id, new.id||':'||floor(extract(epoch from new.activated_at))::text, v_after);
    if a.paper_approval and coalesce(array_length(a.paper_proxy_ids,1),0) > 0 then
      perform public.qy_push_enqueue(a.paper_proxy_ids, 'بانتظار تسجيل اعتماد ورقي', r.number||' — عن '||a.name, 'step', r.id, new.id||':p:'||floor(extract(epoch from new.activated_at))::text, v_after);
    end if;
  end if;
  return new;
end $$;

create or replace function public.qy_push_req() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_after timestamptz := greatest(now(), coalesce(new.review_until, now()));
begin
  if coalesce(new.is_cancelled,false) and not coalesce(old.is_cancelled,false) then
    perform public.qy_push_enqueue(public.qy_push_admins('cancel'), 'أُلغي طلب', new.number, 'adm_cancel', new.id, new.id, now());
  end if;
  if new.status is distinct from old.status and not coalesce(new.is_cancelled,false) then
    if new.status in ('pending_transfer_request','pending_disbursement','pending_accountant') then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['accountant']), 'طلب بانتظار إجراءك', new.number, 'acc', new.id, new.status, v_after);
    elsif new.status = 'pending_transfer_approval' then
      perform public.qy_push_enqueue(public.qy_push_role_users(new.company_id, array['cfo']), 'تحويل بانتظار اعتمادك', new.number, 'acc', new.id, new.status, v_after);
    end if;
    if new.status = 'completed' then
      perform public.qy_push_enqueue(public.qy_push_admins('paid'), 'تم صرف طلب', new.number, 'adm_paid', new.id, new.status, now());
    end if;
    if old.status = 'pending_decision' and new.status in ('pending_transfer_request','pending_disbursement','pending_accountant','pending_transfer_approval','completed') then
      perform public.qy_push_enqueue(array[new.created_by_id], 'اعتُمد طلبك', new.number, 'ok', new.id, new.status, now());
    elsif new.status = 'completed' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'تم صرف طلبك', new.number, 'paid', new.id, new.status, now());
    elsif new.status = 'rejected' then
      perform public.qy_push_enqueue(array[new.created_by_id], 'رُفض طلبك', new.number, 'rej', new.id, new.status, now());
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qy_push_req_t on public.requests;
create trigger qy_push_req_t after update of status, is_cancelled on public.requests for each row execute function public.qy_push_req();

create or replace function public.qy_push_overrun() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare n text;
begin
  select number into n from public.requests where id = new.request_id;
  perform public.qy_push_enqueue(public.qy_push_admins('overrun'), 'تجاوز ميزانية في طلب', n, 'adm_over', new.request_id, new.id::text, now());
  return new;
end $$;
drop trigger if exists qy_push_overrun_t on public.budget_overrun_log;
create trigger qy_push_overrun_t after insert on public.budget_overrun_log for each row execute function public.qy_push_overrun();

create or replace function public.qy_push_pwreset() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  perform public.qy_push_enqueue(public.qy_push_admins('pwreset'), 'طلب إعادة تعيين كلمة مرور', null, 'adm_pw', null, new.id::text, now());
  return new;
end $$;
drop trigger if exists qy_push_pwreset_t on public.password_reset_requests;
create trigger qy_push_pwreset_t after insert on public.password_reset_requests for each row execute function public.qy_push_pwreset();

create or replace function public.qy_push_alert() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  perform public.qy_push_enqueue(public.qy_push_admins('security'), 'تنبيه أمان في النظام', null, 'adm_sec', null, new.id::text, now());
  return new;
end $$;
drop trigger if exists qy_push_alert_t on public.qy_audit_alerts;
create trigger qy_push_alert_t after insert on public.qy_audit_alerts for each row execute function public.qy_push_alert();

create or replace function public.qy_push_clientev() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.kind in ('login_failed','login_suspended') then
    perform public.qy_push_enqueue(public.qy_push_admins('login_fail'), case when new.kind='login_suspended' then 'محاولة دخول بحساب موقوف' else 'محاولة دخول فاشلة' end, null, 'adm_login', null, new.id::text, now());
  elsif new.kind in ('js_error','db_error') then
    perform public.qy_push_enqueue(public.qy_push_admins('error'), 'خطأ في النظام عند أحد المستخدمين', null, 'adm_err', null, new.id::text, now());
  end if;
  return new;
end $$;
drop trigger if exists qy_push_clientev_t on public.qy_client_events;
create trigger qy_push_clientev_t after insert on public.qy_client_events for each row execute function public.qy_push_clientev();

create or replace function public.qy_push_userchg() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.role is distinct from old.role then
    perform public.qy_push_enqueue(public.qy_push_admins('userchange'), 'تغيير صلاحية مستخدم', null, 'adm_user', null, new.id||':role', now());
  elsif coalesce(new.is_suspended,false) is distinct from coalesce(old.is_suspended,false) then
    perform public.qy_push_enqueue(public.qy_push_admins('userchange'), case when new.is_suspended then 'إيقاف مستخدم' else 'إعادة تفعيل مستخدم' end, null, 'adm_user', null, new.id||':susp', now());
  end if;
  return new;
end $$;
drop trigger if exists qy_push_userchg_t on public.users;
create trigger qy_push_userchg_t after update of role, is_suspended on public.users for each row execute function public.qy_push_userchg();

-- مشاكل الهيكل (مرة في اليوم لكل طلب): طلب ينتظر قراراً بلا خطوة منتظرة، أو خطوة منتظرة صاحبها محذوف أو موقوف
create or replace function public.qy_push_scan() returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r record; v_ids text[]; u text;
begin
  v_ids := public.qy_push_admins('structure');
  if coalesce(array_length(v_ids,1),0) = 0 then return; end if;
  for r in
    select q.id, q.number, q.why from (
      select rq.id, rq.number, 'no_step' why from public.requests rq
       where rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false) and (rq.review_until is null or rq.review_until <= now())
         and not exists (select 1 from public.request_approval_steps s where s.request_id = rq.id and s.status = 'pending')
      union all
      select rq.id, rq.number, 'bad_approver' from public.requests rq join public.request_approval_steps s on s.request_id = rq.id and s.status = 'pending' and s.activated_at is not null
       left join public.users ap on ap.id = s.approver_id
       where rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false) and (ap.id is null or coalesce(ap.is_suspended,false))
    ) q limit 50
  loop
    foreach u in array v_ids loop
      continue when exists (select 1 from public.push_outbox o where o.user_id = u and o.kind = 'adm_struct' and o.ref = r.id||':'||r.why||':'||current_date::text);
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      values (u, 'مشكلة في مسار طلب', r.number, '?req='||r.id, 'qy-adm_struct-'||r.id, 'adm_struct', r.id, r.id||':'||r.why||':'||current_date::text, now(), 'adm_struct:'||r.id||':'||r.why||':'||current_date::text)
      on conflict (user_id, dedupe) do nothing;
    end loop;
  end loop;
end $$;
revoke all on function public.qy_push_scan() from public, anon, authenticated;

create or replace function public.qy_push_flush() returns int
language plpgsql security definer set search_path to 'public','pg_temp','extensions' as $$
declare v_url text; v_secret text; v_items jsonb; v_n int := 0;
begin
  select value into v_url from public.push_config where key = 'push_url';
  select value into v_secret from public.push_config where key = 'push_secret';
  if v_url is null or v_secret is null then return 0; end if;
  perform public.qy_push_scan();
  delete from public.push_outbox where created_at < now() - interval '7 days';
  create temp table if not exists _qy_due(id bigint) on commit drop;
  truncate _qy_due;
  insert into _qy_due select id from public.push_outbox where sent_at is null and send_after <= now() order by id limit 200 for update skip locked;
  update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and (
    o.send_after < now() - interval '6 hours'
    or (o.kind = 'step' and not exists (select 1 from public.request_approval_steps s join public.requests r on r.id = s.request_id
         where s.id = split_part(o.ref,':',1) and s.status = 'pending' and not coalesce(r.is_cancelled,false) and r.status = 'pending_decision'
           and (r.review_until is null or r.review_until <= now())))
    or (o.kind = 'new' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)))
    or (o.kind = 'acc' and not exists (select 1 from public.requests r where r.id = o.request_id and not coalesce(r.is_cancelled,false)
         and r.status = o.ref and (r.review_until is null or r.review_until <= now()))));
  update public.push_outbox o set body = r.number from _qy_due d, public.requests r where o.id = d.id and o.kind = 'new' and o.sent_at is null and r.id = o.request_id;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',o.user_id,'title',o.title,'body',o.body,'url',o.url,'tag',o.tag)), '[]'::jsonb), count(*)
    into v_items, v_n from public.push_outbox o join _qy_due d on d.id = o.id where o.sent_at is null;
  if v_n > 0 then
    perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type','application/json','x-push-secret',v_secret), body := jsonb_build_object('items', v_items));
    update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and o.sent_at is null;
  end if;
  return v_n;
end $$;
revoke all on function public.qy_push_flush() from public, anon, authenticated;
