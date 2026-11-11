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
