-- ================= ملف نقل الإنتاج (مسودة) — 16 نوفمبر 2026 =================
-- يُطبَّق على الإنتاج ricnftouvkidfqllnybl بعد: نسخة احتياطية + مقارنة مخطط التجربة بالإنتاج (للقراءة فقط) لالتقاط أي تعديل نُفّذ على التجربة دون ملف.
-- الترتيب زمني حسب إنشاء الملفات منذ آخر نقل (upgrade-prod-2026-11-10). مستبعد: catalog_seed_qa.sql (بيانات خدمات تجريبية).
-- بعده يدوياً: إشعارات الجهاز تحتاج دالة الإرسال (Edge Function) وإعدادات push_config (مفاتيح VAPID والرابط والسر) في الإنتاج.

-- ######## push_notifications.sql ########
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

-- (مطبَّق على القاعدتين بنسخة بلا أوامر حذف: العمود القديم all_requests متروك) خيارات إشعارات مدير النظام (لكل جهاز): admin_events
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

-- ######## push_late.sql ########
-- تذكيرات الطلبات المتأخرة (تجربة فقط) — بلا أوامر حذف
alter table public.companies
  add column if not exists late_on boolean not null default true,
  add column if not exists late_from_hour int not null default 8,
  add column if not exists late_to_hour int not null default 20,
  add column if not exists late_repeat_hours int not null default 8,
  add column if not exists late_copy_days int not null default 3,
  add column if not exists late_max_days int not null default 10,
  add column if not exists late_weekend text not null default 'fri_sat';
grant select, update (late_on,late_from_hour,late_to_hour,late_repeat_hours,late_copy_days,late_max_days,late_weekend) on public.companies to authenticated;

create or replace function public.qy_push_late() returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r record; v_k timestamp := now() at time zone 'Asia/Kuwait'; v_h int := extract(hour from v_k); v_dow int := extract(dow from v_k);
        v_slot text; v_adm text[]; v_late numeric; u text; v_users text[]; v_cfo text[];
begin
  v_adm := public.qy_push_admins('late');
  for r in
    select s.id sid, s.approver_id, s.activated_at, rq.id rid, rq.number, rq.created_by_id, rq.company_id,
           c.late_from_hour, c.late_to_hour, c.late_repeat_hours, c.late_copy_days, c.late_max_days, c.late_weekend, c.deadline_day_mode,
           case when coalesce(a.approval_deadline_days,-1) >= 0 then a.approval_deadline_days else greatest(coalesce(c.default_deadline_days,0),0) end dl
      from public.request_approval_steps s
      join public.requests rq on rq.id = s.request_id
      join public.companies c on c.id = rq.company_id
      left join public.users a on a.id = s.approver_id
     where s.status = 'pending' and s.activated_at is not null and c.late_on
       and rq.status = 'pending_decision' and not coalesce(rq.is_cancelled,false)
       and (rq.review_until is null or rq.review_until <= now())
     limit 200
  loop
    continue when r.dl = 0;
    if r.late_weekend = 'fri_sat' and v_dow in (5,6) then continue; end if;
    if r.late_weekend = 'fri' and v_dow = 5 then continue; end if;
    continue when v_h < r.late_from_hour or v_h >= r.late_to_hour;
    v_late := extract(epoch from (now() - r.activated_at))/86400.0 - r.dl;
    if r.deadline_day_mode <> 'calendar' then
      v_late := v_late - (select count(*) from generate_series(r.activated_at::date, current_date - 1, interval '1 day') g(d) where extract(dow from g.d) in (5,6));
    end if;
    continue when v_late < 0 or v_late > r.late_max_days;
    v_slot := current_date::text || ':' || (v_h / greatest(r.late_repeat_hours,1))::text;
    v_users := array[r.approver_id];
    insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
    select x, 'طلب متأخر بانتظار إجراءك', r.number, '?req='||r.rid, 'qy-late-'||r.rid, 'late', r.rid, r.sid, now(), 'late:'||r.sid||':'||v_slot
      from unnest(v_users) x where exists (select 1 from public.push_subscriptions p where p.user_id = x)
    on conflict (user_id, dedupe) do nothing;
    -- نسخة لمدير النظام فور التأخر
    if v_adm is not null then
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      select x, 'طلب متأخر عند '||coalesce((select name from public.users where id=r.approver_id),''), r.number, '?req='||r.rid, 'qy-lateadm-'||r.rid, 'late', r.rid, r.sid, now(), 'lateadm:'||r.sid||':'||v_slot
        from unnest(v_adm) x where x <> r.approver_id
      on conflict (user_id, dedupe) do nothing;
    end if;
    -- نسخة للمالي ومنشئ الطلب بعد عدد الأيام المحدد
    if v_late >= r.late_copy_days then
      v_users := public.qy_push_role_users(r.company_id, array['cfo']) || array[r.created_by_id];
      insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
      select distinct x, 'طلب متأخر عند '||coalesce((select name from public.users where id=r.approver_id),''), r.number, '?req='||r.rid, 'qy-latecopy-'||r.rid, 'late', r.rid, r.sid, now(), 'latecopy:'||r.sid||':'||v_slot
        from unnest(v_users) x where x is not null and x <> r.approver_id and not (x = any(coalesce(v_adm,'{}')))
         and exists (select 1 from public.push_subscriptions p where p.user_id = x)
      on conflict (user_id, dedupe) do nothing;
    end if;
  end loop;
end $$;
revoke all on function public.qy_push_late() from public, anon, authenticated;

create or replace function public.qy_push_set_events(p_endpoint text, p_events text[]) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error','note','late'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_events(text,text[]) from public, anon;
grant execute on function public.qy_push_set_events(text,text[]) to authenticated;

create or replace function public.qy_push_flush() returns int
language plpgsql security definer set search_path to 'public','pg_temp','extensions' as $$
declare v_url text; v_secret text; v_items jsonb; v_n int := 0;
begin
  select value into v_url from public.push_config where key = 'push_url';
  select value into v_secret from public.push_config where key = 'push_secret';
  if v_url is null or v_secret is null then return 0; end if;
  perform public.qy_push_scan();
  perform public.qy_push_late();
  delete from public.push_outbox where created_at < now() - interval '7 days';
  create temp table if not exists _qy_due(id bigint) on commit drop;
  truncate _qy_due;
  insert into _qy_due select id from public.push_outbox where sent_at is null and send_after <= now() order by id limit 200 for update skip locked;
  update public.push_outbox o set sent_at = now() from _qy_due d where o.id = d.id and (
    o.send_after < now() - interval '6 hours'
    or (o.kind = 'step' and not exists (select 1 from public.request_approval_steps s join public.requests r on r.id = s.request_id
         where s.id = split_part(o.ref,':',1) and s.status = 'pending' and not coalesce(r.is_cancelled,false) and r.status = 'pending_decision'
           and (r.review_until is null or r.review_until <= now())))
    or (o.kind = 'late' and not exists (select 1 from public.request_approval_steps s where s.id = o.ref and s.status = 'pending'))
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

-- إرسال الآن: تُفرج الإشعارات المؤجلة للطلب فور انتهاء نافذة المراجعة (بالإرسال النهائي أو انتهاء المدة)
create or replace function public.qy_push_release() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.review_until is not null and new.review_until <= now() and (old.review_until is null or old.review_until > now()) then
    update public.push_outbox set send_after = now() where request_id = new.id and sent_at is null and send_after > now();
  end if;
  return new;
end $$;
revoke all on function public.qy_push_release() from public, anon, authenticated;
create or replace trigger qy_push_release_t after update of review_until on public.requests for each row execute function public.qy_push_release();

-- ######## push_review.sql ########
-- إشعارات المدير: «طلب قيد المراجعة» (إنشاء/حذف داخل المدة) + «أبلغني حتى بما أفعله أنا»
create or replace function public.qy_push_enqueue(p_users text[], p_title text, p_body text, p_kind text, p_req text, p_ref text, p_after timestamptz) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_me text := public.qy_me(); u text;
begin
  foreach u in array coalesce(p_users,'{}') loop
    continue when u is null;
    continue when u = v_me and not exists (select 1 from public.push_subscriptions s join public.users us on us.id = s.user_id
                                            where s.user_id = u and us.role = 'admin' and 'self' = any(s.admin_events));
    continue when not exists (select 1 from public.push_subscriptions s where s.user_id = u);
    insert into public.push_outbox(user_id,title,body,url,tag,kind,request_id,ref,send_after,dedupe)
    values (u, p_title, p_body, case when p_req is null then null else '?req='||p_req end, 'qy-'||p_kind||'-'||coalesce(p_req,''), p_kind, p_req, p_ref, coalesce(p_after, now()),
            p_kind||':'||coalesce(p_ref,p_req,'')||':'||floor(extract(epoch from now()))::text)
    on conflict (user_id, dedupe) do nothing;
  end loop;
end $$;
revoke all on function public.qy_push_enqueue(text[],text,text,text,text,text,timestamptz) from public, anon, authenticated;

create or replace function public.qy_push_set_events(p_endpoint text, p_events text[]) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error','note','late','review','self'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_events(text,text[]) from public, anon;
grant execute on function public.qy_push_set_events(text,text[]) to authenticated;

create or replace function public.qy_push_new() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_who text;
begin
  perform public.qy_push_enqueue(public.qy_push_admins('new'), 'طلب جديد في النظام', null, 'new', new.id, new.id, greatest(now(), coalesce(new.review_until, now())));
  if new.number is null then
    select name into v_who from public.users where id = new.created_by_id;
    perform public.qy_push_enqueue(public.qy_push_admins('review'), 'طلب قيد المراجعة', 'أنشأه '||coalesce(v_who,'مستخدم'), 'adm_review', new.id, 'c:'||new.id, now());
  end if;
  return new;
end $$;

create or replace function public.qy_push_review_del() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_who text;
begin
  if old.number is null then
    select name into v_who from public.users where id = old.created_by_id;
    perform public.qy_push_enqueue(public.qy_push_admins('review'), 'حُذف طلب قبل إرساله', 'حذفه '||coalesce(v_who,'مستخدم')||' أثناء المراجعة', 'adm_review_del', null, 'd:'||old.id, now());
  end if;
  return old;
end $$;
create or replace trigger qy_push_review_del_t after delete on public.requests for each row execute function public.qy_push_review_del();

-- ######## centers_clients.sql ########
-- العملاء + دفتر المراكز + استيراد بوابة الدفع + رؤية المراكز (12 نوفمبر 2026) — للتجربة أولاً
-- قابل لإعادة التشغيل. لا يمسّ بيانات قائمة: الأعمدة الجديدة لها قيم افتراضية آمنة، وضبط الرصيد مطفأ افتراضياً.

-- ============ الإعدادات الافتراضية للشركة ============
alter table public.companies add column if not exists gateway_company_pct numeric not null default 5;   -- حصة الشركة من الاشتراكات (بعد رسوم البوابة)
alter table public.companies add column if not exists support_company_pct numeric not null default 10;  -- حصة الشركة من الدعم
alter table public.companies add column if not exists import_stale_days int not null default 7;         -- تحوّل تنبيه آخر رفع إلى الأحمر بعد هذا العدد من الأيام
grant select (gateway_company_pct, support_company_pct, import_stale_days) on public.companies to authenticated;

-- ============ العملاء (جمعية ← فرع ← …) ============
create table if not exists public.clients (
  id text primary key default gen_random_uuid()::text,
  company_id text not null,
  parent_id text references public.clients(id) on delete restrict,
  name text not null, name_en text,
  kind text not null default 'association',
  status text not null default 'active',
  address text, email text, website text, tax_no text,
  phones jsonb not null default '[]'::jsonb,      -- [{number, type}]
  contacts jsonb not null default '[]'::jsonb,    -- [{name, title, phone, email}]
  notes text,
  created_by text, created_at timestamptz not null default now());
create index if not exists clients_company on public.clients(company_id);
alter table public.clients enable row level security;
drop policy if exists clients_all on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));
grant select, insert, update, delete on public.clients to authenticated;

-- ============ أعمدة المركز ============
alter table public.centers add column if not exists client_id text references public.clients(id) on delete set null;
alter table public.centers add column if not exists stage text not null default 'operation';          -- creation | finance | operation | closed
alter table public.centers add column if not exists balance_control boolean not null default false;   -- تفعيل ضبط الرصيد والحد السالب
alter table public.centers add column if not exists overdraft_limit numeric not null default 0;       -- مبلغ محدد يسمح بالسالب إلى حدّه
alter table public.centers add column if not exists company_share_pct numeric;                         -- null = افتراضي الشركة
alter table public.centers add column if not exists support_share_pct numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'centers_stage_chk') then
    alter table public.centers add constraint centers_stage_chk check (stage in ('creation','finance','operation','closed'));
  end if;
end $$;
grant select (client_id, stage, balance_control, overdraft_limit, company_share_pct, support_share_pct) on public.centers to authenticated;

-- ============ رؤية المراكز ============
create table if not exists public.center_access (
  center_id text not null references public.centers(id) on delete cascade,
  user_id text not null,
  mode text not null check (mode in ('allow','deny')),
  primary key (center_id, user_id));
alter table public.center_access enable row level security;
drop policy if exists center_access_sel on public.center_access;
drop policy if exists center_access_wrt on public.center_access;
create policy center_access_sel on public.center_access for select to authenticated using (public.is_admin() or user_id = public.qy_me());
create policy center_access_wrt on public.center_access for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.center_access to authenticated;

create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and (u.role in ('accountant','cfo','executive_manager') or u.center_id = p_center))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ============ من يرفع ملفات البوابة ============
create table if not exists public.gateway_import_users (
  company_id text not null, user_id text not null, primary key (company_id, user_id));
alter table public.gateway_import_users enable row level security;
drop policy if exists giu_sel on public.gateway_import_users;
drop policy if exists giu_wrt on public.gateway_import_users;
create policy giu_sel on public.gateway_import_users for select to authenticated using (public.is_admin() or public.is_finance() or user_id = public.qy_me());
create policy giu_wrt on public.gateway_import_users for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.gateway_import_users to authenticated;

create or replace function public.qy_can_import(p_company text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select public.can_see_company(p_company) and (public.is_admin() or public.is_finance()
     or exists (select 1 from public.gateway_import_users g where g.company_id = p_company and g.user_id = public.qy_me()));
$$;
revoke all on function public.qy_can_import(text) from public, anon;
grant execute on function public.qy_can_import(text) to authenticated;

-- ============ حسابات البوابة وربط منشئ الفاتورة بالمركز ============
create table if not exists public.gateway_accounts (
  id text primary key default gen_random_uuid()::text, company_id text not null,
  name text not null, merchant_id text, active boolean not null default true);
create table if not exists public.gateway_agents (
  id bigserial primary key, company_id text not null, account_id text references public.gateway_accounts(id) on delete cascade,
  agent_name text not null, center_id text references public.centers(id) on delete set null,
  unique (company_id, account_id, agent_name));
alter table public.gateway_accounts enable row level security;
alter table public.gateway_agents enable row level security;
drop policy if exists gwa_all on public.gateway_accounts;
drop policy if exists gwg_all on public.gateway_agents;
create policy gwa_all on public.gateway_accounts for all to authenticated using (public.qy_can_import(company_id)) with check (public.is_admin() or public.is_finance());
create policy gwg_all on public.gateway_agents for all to authenticated using (public.qy_can_import(company_id)) with check (public.qy_can_import(company_id));
grant select, insert, update, delete on public.gateway_accounts, public.gateway_agents to authenticated;
grant usage on sequence public.gateway_agents_id_seq to authenticated;

-- ============ الملفات المرفوعة (تُحفظ كاملة ويمكن تنزيلها) ============
create table if not exists public.gateway_imports (
  id bigserial primary key, company_id text not null, account_id text references public.gateway_accounts(id) on delete set null,
  kind text not null check (kind in ('statement','bills')),
  file_name text, date_from date, date_to date, rows_count int not null default 0,
  content text, uploaded_by text, uploaded_at timestamptz not null default now());
create index if not exists gateway_imports_co on public.gateway_imports(company_id, kind, date_to);
alter table public.gateway_imports enable row level security;
drop policy if exists gwi_sel on public.gateway_imports;
create policy gwi_sel on public.gateway_imports for select to authenticated using (public.qy_can_import(company_id));
grant select on public.gateway_imports to authenticated;

-- ============ دفتر المركز ============
create table if not exists public.center_ledger (
  id bigserial primary key, company_id text not null,
  center_id text references public.centers(id) on delete restrict,       -- null = دفعة معلّقة التصنيف (خارج الرصيد)
  kind text not null check (kind in ('opening','subscription','support','manual','adjust')),
  entry_date date not null default current_date,                            -- تاريخ الدفع الفعلي
  period_from date, period_to date,
  gross numeric not null default 0, gateway_fee numeric not null default 0,
  company_pct numeric, company_share numeric, net numeric,
  method text, purpose text, agent text, receipt text, note text,
  source text not null default 'manual', request_id text, import_id bigint,
  voided boolean not null default false,
  created_by text, created_at timestamptz not null default now());
create unique index if not exists center_ledger_receipt_u on public.center_ledger(company_id, receipt) where receipt is not null;
create index if not exists center_ledger_center on public.center_ledger(center_id, entry_date);
alter table public.center_ledger enable row level security;
drop policy if exists cl_sel on public.center_ledger;
create policy cl_sel on public.center_ledger for select to authenticated
  using (case when center_id is null then public.qy_can_import(company_id) else public.qy_center_can_see(center_id) end);
grant select on public.center_ledger to authenticated;

-- بيانات الدافع (حساسة): للمحاسب ومن يرفع الملفات ومدير النظام فقط
create table if not exists public.center_ledger_payers (
  ledger_id bigint primary key references public.center_ledger(id) on delete cascade,
  company_id text not null, payer_name text, payer_phone text);
create index if not exists clp_company on public.center_ledger_payers(company_id);
alter table public.center_ledger_payers enable row level security;
drop policy if exists clp_sel on public.center_ledger_payers;
create policy clp_sel on public.center_ledger_payers for select to authenticated using (public.qy_can_import(company_id));
grant select on public.center_ledger_payers to authenticated;

-- ============ مسار مبلغ الطلب (دعم) ============
alter table public.requests add column if not exists amount_route text not null default 'normal';
alter table public.requests add column if not exists route_center_id text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'requests_amount_route_chk') then
    alter table public.requests add constraint requests_amount_route_chk check (amount_route in ('normal','center','revenue'));
  end if;
end $$;
grant select (amount_route, route_center_id) on public.requests to authenticated;
grant insert (amount_route, route_center_id), update (amount_route, route_center_id) on public.requests to authenticated;

-- ============ حسابات ============
create or replace function public.qy_round3(x numeric) returns numeric language sql immutable as $$ select round(coalesce(x,0), 3) $$;

-- نسبة الشركة لحركة: دعم أو اشتراك
create or replace function public.qy_center_pct(p_center text, p_support boolean) returns numeric
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select case when p_support then coalesce(ce.support_share_pct, co.support_company_pct, 10)
              else coalesce(ce.company_share_pct, co.gateway_company_pct, 5) end
  from public.centers ce join public.companies co on co.id = ce.company_id where ce.id = p_center;
$$;
revoke all on function public.qy_center_pct(text, boolean) from public, anon, authenticated;

-- الرصيد: صافي الدخل المقيّد ناقص المصروف المكتمل (الطلبات العادية فقط)
create or replace function public.qy_center_balance(p_center text) returns numeric
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select qy_round3(coalesce((select sum(net) from public.center_ledger where center_id = p_center and not voided), 0)
        - coalesce((select sum(total_amount) from public.requests where center_id = p_center and status = 'completed' and not coalesce(is_cancelled,false) and amount_route = 'normal'), 0));
$$;
revoke all on function public.qy_center_balance(text) from public, anon, authenticated;

create or replace function public.qy_center_balances(p_company text) returns table(center_id text, income numeric, expense numeric, balance numeric, pending_requests numeric, pending_payments int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select ce.id,
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided),0)),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status = 'completed' and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    public.qy_center_balance(ce.id),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    0
  from public.centers ce where ce.company_id = p_company and public.qy_center_can_see(ce.id);
$$;
revoke all on function public.qy_center_balances(text) from public, anon;
grant execute on function public.qy_center_balances(text) to authenticated;

-- ============ إدخال يدوي (رصيد افتتاحي / اشتراك / إيراد) ============
create or replace function public.qy_ledger_add(p_center text, p_kind text, p_date date, p_from date, p_to date, p_gross numeric, p_fee numeric,
   p_share_pct numeric, p_purpose text, p_note text) returns bigint
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_pct numeric; v_share numeric; v_net numeric; v_id bigint; v_me text := public.qy_me();
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_kind not in ('opening','subscription','support','manual','adjust') then raise exception 'نوع غير صالح'; end if;
  if ce.stage = 'closed' and p_kind <> 'adjust' then raise exception 'المركز مغلق'; end if;
  if p_kind = 'opening' then
    if exists (select 1 from public.center_ledger where center_id = p_center and kind = 'opening' and not voided) then raise exception 'للمركز رصيد افتتاحي مسجّل، ألغِه أولاً ثم أدخل الجديد'; end if;
    v_pct := 0;
  elsif p_kind = 'manual' or p_kind = 'adjust' then v_pct := coalesce(p_share_pct, 0);
  else v_pct := coalesce(p_share_pct, public.qy_center_pct(p_center, p_kind = 'support')); end if;
  v_share := public.qy_round3((coalesce(p_gross,0) - coalesce(p_fee,0)) * v_pct / 100);
  v_net := public.qy_round3(coalesce(p_gross,0) - coalesce(p_fee,0) - v_share);
  insert into public.center_ledger(company_id, center_id, kind, entry_date, period_from, period_to, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by)
  values (ce.company_id, p_center, p_kind, coalesce(p_date, current_date), p_from, p_to, coalesce(p_gross,0), coalesce(p_fee,0), v_pct, v_share, v_net, p_purpose, p_note, 'manual', v_me)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.qy_ledger_add(text,text,date,date,date,numeric,numeric,numeric,text,text) from public, anon;
grant execute on function public.qy_ledger_add(text,text,date,date,date,numeric,numeric,numeric,text,text) to authenticated;

create or replace function public.qy_ledger_void(p_id bigint, p_void boolean) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare l public.center_ledger%rowtype;
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(l.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  update public.center_ledger set voided = coalesce(p_void, true) where id = p_id;
end $$;
revoke all on function public.qy_ledger_void(bigint, boolean) from public, anon;
grant execute on function public.qy_ledger_void(bigint, boolean) to authenticated;

-- إسناد دفعات معلّقة إلى مركز
create or replace function public.qy_ledger_assign(p_ids bigint[], p_center text) returns int
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; n int := 0; l public.center_ledger%rowtype; v_pct numeric; v_share numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not public.qy_can_import(ce.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  v_pct := public.qy_center_pct(p_center, false);
  for l in select * from public.center_ledger where id = any(p_ids) and center_id is null and company_id = ce.company_id loop
    v_share := public.qy_round3((l.gross - l.gateway_fee) * v_pct / 100);
    update public.center_ledger set center_id = p_center, company_pct = v_pct, company_share = v_share, net = public.qy_round3(l.gross - l.gateway_fee - v_share) where id = l.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.qy_ledger_assign(bigint[], text) from public, anon;
grant execute on function public.qy_ledger_assign(bigint[], text) to authenticated;

-- ============ اعتماد استيراد البوابة ============
-- p_rows: [{receipt, txn_date 'YYYY-MM-DD', gross, fee, method, center_id|null, purpose, agent, payer_name, payer_phone}]
-- p_files: [{kind, file_name, date_from, date_to, rows_count, content}]
create or replace function public.qy_gateway_commit(p_company text, p_account text, p_rows jsonb, p_files jsonb) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r jsonb; f jsonb; v_imp bigint; v_first bigint; v_ins int := 0; v_dup int := 0; v_pend int := 0; v_id bigint;
  v_center text; v_pct numeric; v_gross numeric; v_fee numeric; v_share numeric; v_me text := public.qy_me();
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
      v_pct := public.qy_center_pct(v_center, false); v_share := public.qy_round3((v_gross - v_fee) * v_pct / 100);
    else v_pct := null; v_share := null; v_pend := v_pend + 1; end if;
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, method, purpose, agent, receipt, source, import_id, created_by)
    values (p_company, v_center, 'subscription', (r->>'txn_date')::date, v_gross, v_fee, v_pct, v_share,
            case when v_center is null then null else public.qy_round3(v_gross - v_fee - v_share) end,
            r->>'method', r->>'purpose', r->>'agent', r->>'receipt', 'import', v_first, v_me)
    returning id into v_id;
    if coalesce(r->>'payer_name','') <> '' or coalesce(r->>'payer_phone','') <> '' then
      insert into public.center_ledger_payers(ledger_id, company_id, payer_name, payer_phone) values (v_id, p_company, r->>'payer_name', r->>'payer_phone');
    end if;
    v_ins := v_ins + 1;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'pending', v_pend);
end $$;
revoke all on function public.qy_gateway_commit(text,text,jsonb,jsonb) from public, anon;
grant execute on function public.qy_gateway_commit(text,text,jsonb,jsonb) to authenticated;

-- تنزيل ملف مرفوع
create or replace function public.qy_gateway_file(p_id bigint) returns table(file_name text, content text)
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare g public.gateway_imports%rowtype;
begin
  select * into g from public.gateway_imports where id = p_id;
  if not found or not public.qy_can_import(g.company_id) then raise exception 'ليست لديك صلاحية'; end if;
  return query select g.file_name, g.content;
end $$;
revoke all on function public.qy_gateway_file(bigint) from public, anon;
grant execute on function public.qy_gateway_file(bigint) to authenticated;

-- ============ مراحل المركز ============
create or replace function public.qy_center_set_stage(p_center text, p_stage text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('creation','finance','operation','closed') then raise exception 'مرحلة غير صالحة'; end if;
  if p_stage = 'closed' then
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'للمركز طلبات مفتوحة، أنجزها أو ألغها قبل الإغلاق'; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'رصيد المركز غير مسوّى (%). سوِّ الرصيد بحركة تسوية قبل الإغلاق', v_bal; end if;
  end if;
  update public.centers set stage = p_stage where id = p_center;
end $$;
revoke all on function public.qy_center_set_stage(text, text) from public, anon;
grant execute on function public.qy_center_set_stage(text, text) to authenticated;

-- ============ منع طلب جديد يتجاوز الحد، أو لمركز مغلق ============
create or replace function public.qy_center_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_avail numeric;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception 'المركز مغلق ولا تُنشأ له طلبات جديدة'; end if;
  if ce.balance_control then
    v_avail := public.qy_center_balance(ce.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if coalesce(new.total_amount,0) > v_avail + coalesce(ce.overdraft_limit,0) then
      raise exception 'يتجاوز الطلب الرصيد المتاح للمركز (%) مع حد السالب (%)', v_avail, coalesce(ce.overdraft_limit,0);
    end if;
  end if;
  return new;
end $$;
create or replace trigger qy_center_guard_t before insert on public.requests for each row execute function public.qy_center_guard();

-- ============ تحويل مبلغ الدعم إلى دخل مركز عند اكتمال الصرف ============
create or replace function public.qy_route_income() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_pct numeric; v_share numeric;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.amount_route in ('center','revenue') and new.route_center_id is not null
     and not exists (select 1 from public.center_ledger where request_id = new.id and not voided) then
    v_pct := case when new.amount_route = 'center' then public.qy_center_pct(new.route_center_id, true) else 0 end;
    v_share := public.qy_round3(coalesce(new.total_amount,0) * v_pct / 100);
    insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, company_pct, company_share, net, purpose, note, source, request_id, created_by)
    values (new.company_id, new.route_center_id, case when new.amount_route = 'center' then 'support' else 'manual' end, current_date,
            coalesce(new.total_amount,0), v_pct, v_share, public.qy_round3(coalesce(new.total_amount,0) - v_share),
            'من الطلب '||coalesce(new.number,new.id), case when new.amount_route = 'revenue' then 'إيراد يدوي عبر الطلب' else 'دعم' end, 'request', new.id, public.qy_me());
  end if;
  return new;
end $$;
create or replace trigger qy_route_income_t after update of status on public.requests for each row execute function public.qy_route_income();

-- ============ تنبيه تأخر رفع الملفات: إشعار المدير يومياً ============
create or replace function public.qy_gateway_stale() returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare c record; v_last date; v_days int;
begin
  for c in select id, import_stale_days from public.companies loop
    select max(date_to) into v_last from public.gateway_imports where company_id = c.id and kind = 'statement';
    if v_last is null then continue; end if;
    v_days := current_date - v_last;
    if v_days > coalesce(c.import_stale_days, 7) then
      perform public.qy_push_enqueue(public.qy_push_admins('import_stale'), 'ملفات بوابة الدفع متأخرة', 'آخر كشف مرفوع حتى '||to_char(v_last,'DD/MM/YYYY')||' ('||v_days||' يوماً)', 'import_stale', null, c.id||':'||to_char(current_date,'YYYYMMDD'), now());
    end if;
  end loop;
end $$;
revoke all on function public.qy_gateway_stale() from public, anon, authenticated;

create or replace function public.qy_push_set_events(p_endpoint text, p_events text[]) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ok text[] := array['new','approve','reject','login_fail','structure','paid','cancel','overrun','pwreset','security','userchange','error','note','late','review','self','import_stale'];
begin
  if not exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'admin') then raise exception 'للمدير فقط'; end if;
  update public.push_subscriptions set admin_events = coalesce((select array_agg(distinct e) from unnest(coalesce(p_events,'{}')) e where e = any(ok)), '{}')
   where endpoint = p_endpoint and user_id = public.qy_me();
end $$;
revoke all on function public.qy_push_set_events(text,text[]) from public, anon;
grant execute on function public.qy_push_set_events(text,text[]) to authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'qy_gateway_stale';
    perform cron.schedule('qy_gateway_stale', '0 6 * * *', 'select public.qy_gateway_stale()');
  end if;
end $$;

-- 13 نوفمبر: منع ربط جهة بمركز من شركة أخرى، وحذف ما رُبط خطأً
delete from public.gateway_agents g using public.centers c where c.id = g.center_id and c.company_id <> g.company_id;
create or replace function public.qy_gateway_agent_guard() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.center_id is not null and not exists(select 1 from public.centers where id = new.center_id and company_id = new.company_id) then
    raise exception 'المركز المختار لا يتبع هذه الشركة';
  end if;
  return new;
end $$;
drop trigger if exists trg_gateway_agent_guard on public.gateway_agents;
create trigger trg_gateway_agent_guard before insert or update on public.gateway_agents for each row execute function public.qy_gateway_agent_guard();

-- 13 نوفمبر: وصف الوحدة/المركز (يُطبَّق على التجربة عند عودة الاتصال)
alter table public.centers add column if not exists description text;

-- ######## center_items.sql ########
-- بنود المركز (نادي، معرض، مشروع…) + حالة الوحدة + ترحيل الرصيد بين البنود (13 نوفمبر 2026) — للتجربة أولاً
-- البند = وحدة تابعة للمركز في الشجرة نفسها (centers.parent_id)، ولها دفترها في center_ledger.
-- قابل لإعادة التشغيل.

alter table public.centers add column if not exists description text;   -- وصف الوحدة (إن لم يُضف سابقاً)

-- ============ الحالة بدل المرحلة ============
-- potential محتمل · open مفتوح · active شغال · closed مغلق
alter table public.centers drop constraint if exists centers_stage_chk;
update public.centers set stage = case stage when 'creation' then 'potential' when 'finance' then 'active' when 'operation' then 'active' else stage end
 where stage in ('creation','finance','operation');
alter table public.centers alter column stage set default 'active';
alter table public.centers add constraint centers_stage_chk check (stage in ('potential','open','active','closed'));

alter table public.centers add column if not exists pre_pay boolean not null default false;      -- يُصرف له قبل الدفع (في حالة «مفتوح»)
alter table public.centers add column if not exists continuous boolean not null default false;   -- مستمر: لا يُقترح إغلاقه بانتهاء المدة
alter table public.centers add column if not exists period_from date;
alter table public.centers add column if not exists period_to date;
alter table public.centers add column if not exists item_budget numeric;                          -- ميزانية البند لمرة واحدة (اختياري)
alter table public.centers add column if not exists transfer_user_ids text[] not null default '{}'; -- من يرحّل الرصيد بين بنود المركز (غير المالية ومدير النظام)
grant select (pre_pay, continuous, period_from, period_to, item_budget, transfer_user_ids) on public.centers to authenticated;

-- ============ الشجرة: أسلاف الوحدة وجذر المركز ============
create or replace function public.qy_unit_up(p_center text) returns table(id text, kind text, depth int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  with recursive up(id, kind, parent_id, depth) as (
    select c.id, c.kind, c.parent_id, 0 from public.centers c where c.id = p_center
    union all
    select c.id, c.kind, c.parent_id, up.depth + 1 from public.centers c join up on c.id = up.parent_id where up.depth < 50)
  select id, kind, depth from up;
$$;
revoke all on function public.qy_unit_up(text) from public, anon, authenticated;

-- الجذر: أعلى وحدة من نوع «مركز» في السلسلة، وإلا الوحدة نفسها
create or replace function public.qy_unit_root(p_center text) returns text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select coalesce((select id from public.qy_unit_up(p_center) where kind = 'center' order by depth desc limit 1), p_center);
$$;
revoke all on function public.qy_unit_root(text) from public, anon, authenticated;

-- الرؤية: من يعمل في المركز يرى بنوده، ومن يعمل في بند يرى بنده فقط
create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and (u.role in ('accountant','cfo','executive_manager')
                          or u.center_id in (select id from public.qy_unit_up(p_center))))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ============ الدفتر: نوع «ترحيل» وربط طرفيه ============
alter table public.center_ledger drop constraint if exists center_ledger_kind_check;
alter table public.center_ledger add constraint center_ledger_kind_check check (kind in ('opening','subscription','support','manual','adjust','transfer'));
alter table public.center_ledger add column if not exists pair_id bigint;

-- هل يرحّل المستخدم بين بنود هذا الجذر؟ المالية ومدير النظام، ومن اختاره مدير النظام للمركز
create or replace function public.qy_can_transfer(p_root text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers r where r.id = p_root and public.can_see_company(r.company_id)
     and (public.is_admin() or public.is_finance() or public.qy_me() = any(coalesce(r.transfer_user_ids,'{}'))));
$$;
revoke all on function public.qy_can_transfer(text) from public, anon;
grant execute on function public.qy_can_transfer(text) to authenticated;

-- الرصيد: صافي الدخل والترحيلات ناقص المصروف المكتمل (الدالة السابقة تجمع net لكل الأنواع فتشمل الترحيل)
drop function if exists public.qy_center_balances(text);
create or replace function public.qy_center_balances(p_company text) returns table(center_id text, income numeric, transfers numeric, expense numeric, balance numeric, pending_requests numeric, pending_payments int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select ce.id,
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind <> 'transfer'),0)),
    qy_round3(coalesce((select sum(net) from public.center_ledger l where l.center_id = ce.id and not l.voided and l.kind = 'transfer'),0)),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status = 'completed' and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    public.qy_center_balance(ce.id),
    qy_round3(coalesce((select sum(total_amount) from public.requests r where r.center_id = ce.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0)),
    0
  from public.centers ce where ce.company_id = p_company and public.qy_center_can_see(ce.id);
$$;
revoke all on function public.qy_center_balances(text) from public, anon;
grant execute on function public.qy_center_balances(text) to authenticated;

-- ============ ترحيل رصيد بين بندين من المركز نفسه ============
create or replace function public.qy_ledger_transfer(p_from text, p_to text, p_amount numeric, p_date date, p_reason text) returns bigint
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare a public.centers%rowtype; b public.centers%rowtype; v_root text; v_amt numeric := public.qy_round3(p_amount); v_out bigint; v_in bigint; v_avail numeric; v_me text := public.qy_me();
begin
  select * into a from public.centers where id = p_from;
  select * into b from public.centers where id = p_to;
  if a.id is null or b.id is null then raise exception 'البند غير موجود'; end if;
  if a.id = b.id then raise exception 'اختر بندين مختلفين'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'أدخل مبلغاً أكبر من صفر'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'اكتب سبب الترحيل'; end if;
  v_root := public.qy_unit_root(a.id);
  if v_root <> public.qy_unit_root(b.id) or a.company_id <> b.company_id then raise exception 'الترحيل بين بنود المركز نفسه فقط'; end if;
  if not public.qy_can_transfer(v_root) then raise exception 'ليست لديك صلاحية ترحيل الرصيد في هذا المركز'; end if;
  if b.stage = 'closed' then raise exception 'البند «%» مغلق ولا يُرحَّل إليه', b.name; end if;
  if a.balance_control then
    v_avail := public.qy_center_balance(a.id)
      - coalesce((select sum(total_amount) from public.requests r where r.center_id = a.id and r.status not in ('completed','rejected') and not coalesce(r.is_cancelled,false) and r.amount_route = 'normal'),0);
    if v_amt > v_avail + coalesce(a.overdraft_limit,0) then raise exception 'المبلغ يتجاوز الرصيد المتاح في «%» (%)', a.name, v_avail; end if;
  end if;
  insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by)
  values (a.company_id, a.id, 'transfer', coalesce(p_date, current_date), -v_amt, 0, 0, 0, -v_amt, 'ترحيل إلى «'||b.name||'»', trim(p_reason), 'transfer', v_me) returning id into v_out;
  insert into public.center_ledger(company_id, center_id, kind, entry_date, gross, gateway_fee, company_pct, company_share, net, purpose, note, source, created_by, pair_id)
  values (b.company_id, b.id, 'transfer', coalesce(p_date, current_date), v_amt, 0, 0, 0, v_amt, 'ترحيل من «'||a.name||'»', trim(p_reason), 'transfer', v_me, v_out) returning id into v_in;
  update public.center_ledger set pair_id = v_in where id = v_out;
  return v_out;
end $$;
revoke all on function public.qy_ledger_transfer(text,text,numeric,date,text) from public, anon;
grant execute on function public.qy_ledger_transfer(text,text,numeric,date,text) to authenticated;

-- الحذف/الاسترجاع: الترحيل يُحذف بطرفيه معاً
create or replace function public.qy_ledger_void(p_id bigint, p_void boolean) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare l public.center_ledger%rowtype;
begin
  select * into l from public.center_ledger where id = p_id;
  if not found then raise exception 'الحركة غير موجودة'; end if;
  if l.kind = 'transfer' then
    if not public.qy_can_transfer(public.qy_unit_root(l.center_id)) then raise exception 'ليست لديك صلاحية'; end if;
    update public.center_ledger set voided = coalesce(p_void, true) where id = p_id or (l.pair_id is not null and id = l.pair_id);
    return;
  end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(l.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  update public.center_ledger set voided = coalesce(p_void, true) where id = p_id;
end $$;
revoke all on function public.qy_ledger_void(bigint, boolean) from public, anon;
grant execute on function public.qy_ledger_void(bigint, boolean) to authenticated;

-- ============ تغيير الحالة ============
drop function if exists public.qy_center_set_stage(text, text);
create or replace function public.qy_center_set_stage(p_center text, p_stage text) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_bal numeric; v_open numeric;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_stage not in ('potential','open','active','closed') then raise exception 'حالة غير صالحة'; end if;
  if p_stage = 'closed' then
    if exists (select 1 from public.centers x where x.parent_id = p_center and x.stage <> 'closed') then raise exception 'تحته بنود غير مغلقة، أغلقها أولاً'; end if;
    select coalesce(sum(total_amount),0) into v_open from public.requests where center_id = p_center and status not in ('completed','rejected') and not coalesce(is_cancelled,false) and amount_route = 'normal';
    if v_open > 0 then raise exception 'له طلبات مفتوحة، أنجزها أو ألغها قبل الإغلاق'; end if;
    v_bal := public.qy_center_balance(p_center);
    if abs(v_bal) > 0.0005 then raise exception 'الرصيد غير مسوّى (%). رحّله لبند آخر أو سوِّه بحركة تسوية قبل الإغلاق', v_bal; end if;
  end if;
  update public.centers set stage = p_stage where id = p_center;
end $$;
revoke all on function public.qy_center_set_stage(text, text) from public, anon;
grant execute on function public.qy_center_set_stage(text, text) to authenticated;

-- ============ خصائص البند (المالية ومدير النظام) ============
create or replace function public.qy_unit_item_set(p_center text, p_pre_pay boolean, p_continuous boolean, p_from date, p_to date, p_budget numeric,
   p_monthly numeric, p_annual numeric) returns void
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype;
begin
  select * into ce from public.centers where id = p_center;
  if not found then raise exception 'الوحدة غير موجودة'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(ce.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'نهاية المدة قبل بدايتها'; end if;
  update public.centers set pre_pay = coalesce(p_pre_pay,false), continuous = coalesce(p_continuous,false), period_from = p_from, period_to = p_to,
    item_budget = p_budget, monthly_budget = p_monthly, annual_budget = p_annual where id = p_center;
end $$;
revoke all on function public.qy_unit_item_set(text,boolean,boolean,date,date,numeric,numeric,numeric) from public, anon;
grant execute on function public.qy_unit_item_set(text,boolean,boolean,date,date,numeric,numeric,numeric) to authenticated;

-- ============ إضافة بند تحت مركز (المالية ومدير النظام) ============
create or replace function public.qy_unit_item_add(p_parent text, p_name text, p_kind text, p_stage text, p_pre_pay boolean, p_continuous boolean,
   p_from date, p_to date, p_budget numeric, p_desc text) returns text
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare pa public.centers%rowtype; v_id text := 'c_' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text;
begin
  select * into pa from public.centers where id = p_parent;
  if not found then raise exception 'المركز غير موجود'; end if;
  if not (public.is_admin() or (public.is_finance() and public.can_see_company(pa.company_id))) then raise exception 'للمالية ومدير النظام فقط'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'اكتب اسم البند'; end if;
  if coalesce(p_stage,'active') not in ('potential','open','active') then raise exception 'حالة غير صالحة'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'نهاية المدة قبل بدايتها'; end if;
  insert into public.centers(id, name, code, company_id, kind, scope, parent_id, stage, pre_pay, continuous, period_from, period_to, item_budget, description)
  values (v_id, trim(p_name), '', pa.company_id, coalesce(nullif(p_kind,''),'section'), coalesce(pa.scope,'company'), p_parent, coalesce(p_stage,'active'),
          coalesce(p_pre_pay,false), coalesce(p_continuous,false), p_from, p_to, p_budget, nullif(trim(coalesce(p_desc,'')),''));
  return v_id;
end $$;
revoke all on function public.qy_unit_item_add(text,text,text,text,boolean,boolean,date,date,numeric,text) from public, anon;
grant execute on function public.qy_unit_item_add(text,text,text,text,boolean,boolean,date,date,numeric,text) to authenticated;

-- ============ منع الطلب حسب الحالة والرصيد ============
create or replace function public.qy_center_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare ce public.centers%rowtype; v_avail numeric;
begin
  if new.center_id is null or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into ce from public.centers where id = new.center_id;
  if not found then return new; end if;
  if ce.stage = 'closed' then raise exception '«%» مغلق ولا تُنشأ له طلبات جديدة', ce.name; end if;
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

-- ######## center_suspend.sql ########
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

-- ######## system_owner.sql ########
-- مالك النظام (13 نوفمبر 2026): حساب مدير النظام صاحب الهاتف 98937472 مثبَّت
-- لا يُحذف، ولا يغيّر غيرُه دوره أو إيقافه أو هاتفه أو اسمه أو شركته أو ربط دخوله. وساعات العمل تظهر له وحده.
-- قابل لإعادة التشغيل: يُثبَّت معرّف الحساب وقت التطبيق (يختلف بين التجربة والإنتاج).
do $do$
declare v_id text;
begin
  select id into v_id from public.users where regexp_replace(coalesce(phone,''),'\D','','g') like '%98937472' order by (role='admin') desc limit 1;
  if v_id is null then raise exception 'لم يُعثر على حساب الهاتف 98937472'; end if;
  execute format('create or replace function public.qy_owner_id() returns text language sql immutable as %L', 'select ' || quote_literal(v_id) || '::text');
end $do$;
revoke all on function public.qy_owner_id() from public, anon;
grant execute on function public.qy_owner_id() to authenticated;

create or replace function public.qy_owner_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $fn$
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
end $fn$;
drop trigger if exists qy_owner_guard_t on public.users;
create trigger qy_owner_guard_t before update or delete on public.users for each row execute function public.qy_owner_guard();

-- ######## gateway_rematch_lock.sql ########
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

-- ######## center_staff.sql ########
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

-- ######## catalog_contracts.sql ########
-- خدمات الشركة (الكتالوج) وعقود العملاء وأسعارها (14 نوفمبر 2026) — للتجربة أولاً
-- الكتالوج شجرة: 1 خدمة رئيسية ← 2 خدمة فرعية ← 3 بند مسعّر. لكل شركة كتالوجها.
create table if not exists public.svc_catalog (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  parent_id uuid references public.svc_catalog(id) on delete cascade,
  level smallint not null check (level in (1,2,3)),
  name text not null,
  description text,
  unit text,
  price numeric,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists svc_catalog_company_idx on public.svc_catalog(company_id, parent_id);
alter table public.svc_catalog enable row level security;
drop policy if exists svc_catalog_sel on public.svc_catalog;
create policy svc_catalog_sel on public.svc_catalog for select to authenticated using (public.can_see_company(company_id));
drop policy if exists svc_catalog_wrt on public.svc_catalog;
create policy svc_catalog_wrt on public.svc_catalog for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));

-- عقد العميل وشروطه
create table if not exists public.client_contracts (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text not null references public.clients(id) on delete cascade,
  title text not null,
  contract_date date,
  start_date date,
  end_date date,
  auto_renew boolean not null default true,
  renew_notice_months int default 2,
  free_revisions int default 3,
  revision_pct numeric default 10,
  late_pct_day numeric default 2,
  late_pct_max numeric default 20,
  billing text not null default 'monthly' check (billing in ('monthly','per_project','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.client_contracts enable row level security;
drop policy if exists client_contracts_all on public.client_contracts;
create policy client_contracts_all on public.client_contracts for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));

-- جدول أسعار العقد (يُنسخ من الكتالوج ويُعدَّل، أو يُدخل كما في العقد)
create table if not exists public.contract_prices (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.client_contracts(id) on delete cascade,
  catalog_id uuid references public.svc_catalog(id) on delete set null,
  section text,
  name text not null,
  spec text,
  unit text,
  price numeric,
  sort int not null default 0
);
create index if not exists contract_prices_contract_idx on public.contract_prices(contract_id);
alter table public.contract_prices enable row level security;
drop policy if exists contract_prices_all on public.contract_prices;
create policy contract_prices_all on public.contract_prices for all to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.is_finance() and public.can_see_company(c.company_id)))
  with check (exists (select 1 from public.client_contracts c where c.id = contract_id and public.is_finance() and public.can_see_company(c.company_id)));

-- ######## centers_sort.sql ########
-- ترتيب يدوي للوحدات (المراكز والبنود) بالسحب والإفلات بين الإخوة؛ الفارغ يأتي آخراً بالترتيب الأبجدي
alter table public.centers add column if not exists sort integer;

-- ######## projects_docs_invoices.sql ########
-- المشاريع: ملاحق العقود، الوثائق (عرض سعر / نموذج خدمة / مقترح خدمة)، المشروع، الفواتير والتحصيل (14 نوفمبر 2026) — للتجربة أولاً
-- الكتابة: المالية دائماً، أو دور صلاحيته في صفحة «المشاريع» تعديل/تحكم كامل. القراءة: المالية، المدير التنفيذي، أو دور له صلاحية قراءة فأعلى.

create or replace function public.qy_prj_level_ok(p_company text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = 'projects' and p.level = any(p_levels));
$fn$;
create or replace function public.qy_prj_can_read(p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select public.can_see_company(p_company) and (
    public.is_finance()
    or exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'executive_manager')
    or public.qy_prj_level_ok(p_company, array['read','edit','full']));
$fn$;
create or replace function public.qy_prj_can_write(p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select public.can_see_company(p_company) and (public.is_finance() or public.qy_prj_level_ok(p_company, array['edit','full']));
$fn$;

-- إعدادات الشركة: من يصله تنبيه «اعمل فاتورة» مع المحاسب، والنسبة الافتراضية للصرف قبل الدفع
alter table public.companies add column if not exists invoice_alert_user_ids jsonb not null default '[]'::jsonb;
alter table public.companies add column if not exists prepay_default_pct numeric not null default 80;

-- العقد وملاحقه: الملحق صف في الجدول نفسه أبوه العقد، وله ملفه وجدول أسعاره (خدمات ليست في العقد)
alter table public.client_contracts add column if not exists parent_id uuid references public.client_contracts(id) on delete cascade;
alter table public.client_contracts add column if not exists file_path text;
alter table public.client_contracts add column if not exists file_name text;
alter table public.client_contracts add column if not exists created_by text;
alter table public.client_contracts alter column billing drop not null;
drop policy if exists client_contracts_all on public.client_contracts;
drop policy if exists client_contracts_sel on public.client_contracts;
drop policy if exists client_contracts_wrt on public.client_contracts;
create policy client_contracts_sel on public.client_contracts for select to authenticated using (public.qy_prj_can_read(company_id));
create policy client_contracts_wrt on public.client_contracts for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));
drop policy if exists contract_prices_all on public.contract_prices;
drop policy if exists contract_prices_sel on public.contract_prices;
drop policy if exists contract_prices_wrt on public.contract_prices;
create policy contract_prices_sel on public.contract_prices for select to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_read(c.company_id)));
create policy contract_prices_wrt on public.contract_prices for all to authenticated
  using (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_write(c.company_id)))
  with check (exists (select 1 from public.client_contracts c where c.id = contract_id and public.qy_prj_can_write(c.company_id)));

-- الوثيقة: تُرفع PDF جاهزة الآن؛ وحقول lines/sections محجوزة لبنائها من داخل النظام لاحقاً
create table if not exists public.prj_documents (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text references public.clients(id) on delete set null,
  doc_type text not null check (doc_type in ('quote','service_form','proposal')),
  seq int not null,
  year int not null,
  doc_no text not null,
  title text not null,
  doc_date date,
  contract_id uuid references public.client_contracts(id) on delete set null,
  amount numeric not null default 0 check (amount >= 0),
  amount_kind text not null default 'total' check (amount_kind in ('total','monthly')),
  months int check (months is null or months > 0),
  open_ended boolean not null default false,
  start_date date,
  status text not null default 'sent' check (status in ('sent','approved','rejected','cancelled')),
  file_path text, file_name text,
  signed_path text, signed_name text,
  decided_at timestamptz, decided_by text, decision_note text,
  lines jsonb not null default '[]'::jsonb,
  sections jsonb not null default '[]'::jsonb,
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  unique (company_id, year, seq)
);
create index if not exists prj_documents_company_idx on public.prj_documents(company_id, created_at desc);
alter table public.prj_documents enable row level security;
drop policy if exists prj_documents_sel on public.prj_documents;
drop policy if exists prj_documents_wrt on public.prj_documents;
create policy prj_documents_sel on public.prj_documents for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_documents_wrt on public.prj_documents for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- المشروع: يُفتح عند اعتماد العميل للوثيقة، ويرتبط ببند ميزانية (الصرف من البند، والدخل إليه عند التحصيل)
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  client_id text references public.clients(id) on delete set null,
  document_id uuid unique references public.prj_documents(id) on delete set null,
  name text not null,
  budget_item_id text,
  status text not null default 'active' check (status in ('active','closed')),
  value numeric not null default 0,
  invoice_mode text not null default 'single' check (invoice_mode in ('single','monthly')),
  monthly_amount numeric,
  months int check (months is null or months > 0),
  open_ended boolean not null default false,
  start_date date,
  prepay boolean not null default false,
  prepay_pct numeric not null default 80 check (prepay_pct >= 0 and prepay_pct <= 100),
  report_path text, report_name text,
  closed_at timestamptz, closed_by text,
  notes text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists projects_company_idx on public.projects(company_id, status);
alter table public.projects enable row level security;
drop policy if exists projects_sel on public.projects;
drop policy if exists projects_wrt on public.projects;
create policy projects_sel on public.projects for select to authenticated using (public.can_see_company(company_id));
create policy projects_wrt on public.projects for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- الفاتورة: صورتان (الفاتورة المقدّمة، وعلم الوصول من العميل)، والفترة للفواتير الشهرية
create table if not exists public.prj_invoices (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  inv_no text,
  inv_date date not null default current_date,
  period text,
  amount numeric not null check (amount > 0),
  invoice_path text, invoice_name text,
  receipt_path text, receipt_name text,
  status text not null default 'issued' check (status in ('issued','cancelled')),
  notes text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists prj_invoices_project_idx on public.prj_invoices(project_id);
alter table public.prj_invoices enable row level security;
drop policy if exists prj_invoices_sel on public.prj_invoices;
drop policy if exists prj_invoices_wrt on public.prj_invoices;
create policy prj_invoices_sel on public.prj_invoices for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_invoices_wrt on public.prj_invoices for all to authenticated using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));

-- التحصيل: دفعة أو أكثر لكل فاتورة؛ كل دفعة تُسجَّل إيراداً على بند المشروع (budget_revenues)
create table if not exists public.prj_collections (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  invoice_id uuid not null references public.prj_invoices(id) on delete cascade,
  amount numeric not null check (amount > 0),
  paid_on date not null default current_date,
  method text,
  revenue_id text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists prj_collections_invoice_idx on public.prj_collections(invoice_id);
alter table public.prj_collections enable row level security;
drop policy if exists prj_collections_sel on public.prj_collections;
drop policy if exists prj_collections_wrt on public.prj_collections;
create policy prj_collections_sel on public.prj_collections for select to authenticated using (public.qy_prj_can_read(company_id));
create policy prj_collections_wrt on public.prj_collections for all to authenticated using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));

-- ######## projects_execution.sql ########
-- مرحلة «التنفيذ» في المشروع: المنفذ (الشركة / جهة خارجية / الاثنان) وبيانات الجهة الخارجية وحالة التنفيذ (15 نوفمبر 2026)
alter table public.projects add column if not exists exec_by text check (exec_by is null or exec_by in ('company','external','both'));
alter table public.projects add column if not exists exec_party text;
alter table public.projects add column if not exists exec_amount numeric check (exec_amount is null or exec_amount >= 0);
alter table public.projects add column if not exists exec_file_path text;
alter table public.projects add column if not exists exec_file_name text;
alter table public.projects add column if not exists exec_status text not null default 'not_started' check (exec_status in ('not_started','in_progress','done'));
alter table public.projects add column if not exists exec_done_at timestamptz;

-- ######## projects_amount_route.sql ########
-- مسار مبلغ المشروع (15 نوفمبر 2026): مشروع عادي (الصرف بطلبات صرف) أو تحويل لمركز
-- في «تحويل لمركز» يُحوَّل المحصّل بطلب صرف مسار «تحويل لمركز»، وعند اكتمال صرفه يسجّل المشغّل qy_route_income الصافي في دفتر المركز بعد نسبة الشركة
alter table public.projects add column if not exists amount_route text not null default 'normal' check (amount_route in ('normal','center'));
alter table public.projects add column if not exists route_center_id text;

-- ######## worker_contracts.sql ########
-- عقود العاملين (15 نوفمبر 2026): لكل عامل عقده مع الشركة أو أحد مراكزها — أساس قاعدة «لا يُصرف لأحد بلا عقد» لاحقاً
-- الصلاحية: صفحة «العقود» (contracts): المالية دائماً، أو دور له في الصفحة قراءة/تعديل/تحكم كامل
create or replace function public.qy_page_level_ok(p_company text, p_key text, p_levels text[])
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.page_permissions p join public.users u on u.id = public.qy_me()
                 where p.company_id = p_company and p.role = u.role and p.page_key = p_key and p.level = any(p_levels));
$fn$;
create table if not exists public.worker_contracts (
  id uuid primary key default gen_random_uuid(),
  company_id text not null references public.companies(id) on delete cascade,
  unit_id text references public.centers(id) on delete set null,
  user_id text references public.users(id) on delete set null,
  person_name text, civil_id text, phone text, iban text,
  contract_type text not null default 'employment' check (contract_type in ('employment','reward','freelance')),
  job_title text,
  start_date date, end_date date,
  amount numeric check (amount is null or amount >= 0),
  pay_cycle text not null default 'monthly' check (pay_cycle in ('monthly','per_task','lump')),
  file_path text, file_name text,
  status text not null default 'active' check (status in ('active','ended')),
  notes text, created_by text, created_at timestamptz not null default now(),
  check (user_id is not null or coalesce(trim(person_name),'') <> '')
);
create index if not exists worker_contracts_company_idx on public.worker_contracts(company_id, status);
alter table public.worker_contracts enable row level security;
drop policy if exists worker_contracts_sel on public.worker_contracts;
drop policy if exists worker_contracts_wrt on public.worker_contracts;
create policy worker_contracts_sel on public.worker_contracts for select to authenticated
  using (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['read','edit','full'])));
create policy worker_contracts_wrt on public.worker_contracts for all to authenticated
  using (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['edit','full'])))
  with check (public.can_see_company(company_id) and (public.is_finance() or public.qy_page_level_ok(company_id, 'contracts', array['edit','full'])));

-- ######## payroll_requests.sql ########
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

-- ######## gl_accounting_stage0.sql ########
-- المحاسبة (المرحلة 0): مستخرجة من قاعدة التجربة في 16 نوفمبر 2026 (أنشأتها جلسة أخرى مباشرة على التجربة دون ملف)
create table if not exists public.gl_accounts (
  company_id text not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null check (kind in ('asset','liability','equity','income','expense')),
  parent_code text,
  is_group boolean not null default false,
  is_active boolean not null default true,
  note text,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (company_id, code));
create table if not exists public.gl_custody_accounts (
  company_id text not null references public.companies(id) on delete cascade,
  holder_id text not null,
  code text not null,
  primary key (company_id, holder_id));
create table if not exists public.gl_exports (
  id bigserial primary key,
  company_id text not null references public.companies(id) on delete cascade,
  month date not null,
  entries integer not null default 0,
  total numeric not null default 0,
  unlinked integer not null default 0,
  exported_by text,
  exported_by_name text,
  exported_at timestamptz not null default now());
alter table public.gl_accounts enable row level security;
alter table public.gl_custody_accounts enable row level security;
alter table public.gl_exports enable row level security;
drop policy if exists gl_acc_sel on public.gl_accounts;
drop policy if exists gl_cust_sel on public.gl_custody_accounts;
drop policy if exists gl_exp_sel on public.gl_exports;
create policy gl_acc_sel on public.gl_accounts for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
create policy gl_cust_sel on public.gl_custody_accounts for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
create policy gl_exp_sel on public.gl_exports for select to authenticated using (public.is_admin() or (public.is_finance() and public.can_see_company(company_id)));
grant select, insert, update, delete on public.gl_accounts, public.gl_custody_accounts, public.gl_exports to authenticated;
alter table public.budget_items add column if not exists gl_expense text;
alter table public.budget_items add column if not exists gl_income text;
alter table public.companies add column if not exists gl_cash text default '120101';
alter table public.companies add column if not exists gl_custody_parent text default '120201';
alter table public.companies add column if not exists gl_opening text default '2901';
alter table public.companies add column if not exists gl_share text default '4402';
alter table public.companies add column if not exists gl_unlinked_mode text default 'warn';
alter table public.centers add column if not exists gl_expense text;
alter table public.centers add column if not exists gl_trust text;

CREATE OR REPLACE FUNCTION public.qy_gl_block_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare m text; r public.requests; holder text; acct text;
begin
  if new.source_type <> 'request' or new.direction <> 'out' or new.reverses_id is not null then return new; end if;
  select gl_unlinked_mode into m from public.companies where id = new.company_id;
  if coalesce(m,'warn') <> 'block' then return new; end if;
  select * into r from public.requests where id = new.source_id;
  if coalesce(r.amount_route,'normal') <> 'normal' then return new; end if;
  select holder_id into holder from public.custodies where request_id = new.source_id limit 1;
  if r.request_type = 'custody' or holder is not null then
    select code into acct from public.gl_custody_accounts where company_id = new.company_id and holder_id = holder;
    if acct is null then raise exception 'لا يُصرف قبل ربط صاحب العهدة بحساب عهدة في «المحاسبة ← ربط الحسابات»'; end if;
    return new;
  end if;
  acct := coalesce(public.qy_gl_trust_of(coalesce(new.center_id, r.center_id)), public.qy_gl_exp_of(new.budget_item_id, coalesce(new.center_id, r.center_id)));
  if acct is null then raise exception 'لا يُصرف قبل ربط بند الطلب أو وحدته بحساب في «المحاسبة ← ربط الحسابات» (إعداد الشركة: منع الصرف حتى الربط)'; end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_can(p_company text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.is_admin() or (public.is_finance() and public.can_see_company(p_company));
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_copy_chart(p_from text, p_to text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n int;
begin
  if not (public.qy_gl_can(p_from) and public.qy_gl_can(p_to)) then raise exception 'للمالية ومدير النظام'; end if;
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, is_active, note, updated_by)
  select p_to, code, name, kind, parent_code, is_group, is_active, note, public.qy_me() from public.gl_accounts where company_id=p_from
  on conflict do nothing;
  get diagnostics n = row_count; return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_delete_account(p_company text, p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.qy_gl_can(p_company) then raise exception 'دليل الحسابات للمالية ومدير النظام'; end if;
  if exists (select 1 from public.gl_accounts where company_id=p_company and parent_code=p_code) then raise exception 'للحساب حسابات تتبعه، انقلها أولاً'; end if;
  if exists (select 1 from public.budget_items where company_id=p_company and (gl_expense=p_code or gl_income=p_code))
     or exists (select 1 from public.centers where company_id=p_company and (gl_trust=p_code or gl_expense=p_code))
     or exists (select 1 from public.gl_custody_accounts where company_id=p_company and code=p_code)
     or exists (select 1 from public.companies where id=p_company and p_code in (gl_cash, gl_share, gl_opening, gl_custody_parent)) then
    raise exception 'الحساب مربوط ببند أو مركز أو إعداد؛ أوقفه بدل حذفه'; end if;
  delete from public.gl_accounts where company_id=p_company and code=p_code;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_exp_of(p_item text, p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select gl_expense from public.budget_items where id=p_item),
                  (select gl_expense from public.centers where id=p_center),
                  (select c.gl_expense from public.qy_unit_up(p_center) u join public.centers c on c.id=u.id where c.gl_expense is not null order by u.depth limit 1));
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_inc_of(p_item text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select gl_income from public.budget_items where id=p_item;
$function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_journal(p_company text, p_from date, p_to date)
 RETURNS TABLE(entry_key text, entry_date date, ref text, source text, description text, account_code text, account_name text, debit numeric, credit numeric, flag text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare co public.companies;
begin
  if not public.qy_gl_can(p_company) then raise exception 'كشف الحركات للمالية ومدير النظام'; end if;
  select * into co from public.companies where id=p_company;
  return query
  with
  tx as (
    select t.*, r.request_type, coalesce(r.amount_route,'normal') as route, r.number as req_no,
           coalesce(t.center_id, r.center_id) as ctr,
           k.holder_id as c_holder, k.remaining_action as c_action
    from public.transactions t
    left join public.requests r on r.id = t.source_id and t.source_type in ('request','refund')
    left join public.custodies k on (t.source_type='custody' and k.id::text = t.source_id) or (t.source_type='request' and k.request_id = t.source_id)
    where t.company_id=p_company and t.tx_date between p_from and p_to
  ),
  lines as (
    select 'tx:'||t.id::text k, t.tx_date d, coalesce(t.req_no, t.source_id) rf, 'صرف طلب'::text src, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,'') ds,
      case when t.direction='out' then
        case when t.request_type='custody' or t.c_holder is not null then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder)
             when public.qy_gl_trust_of(t.ctr) is not null then public.qy_gl_trust_of(t.ctr)
             else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end
      else co.gl_cash end ac,
      t.amount dr, 0::numeric cr, case when t.request_type='custody' or t.c_holder is not null then 'عهدة' else null end fl
    from tx t where t.source_type='request' and t.route='normal'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'صرف طلب', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='out' then co.gl_cash
        else case when t.request_type='custody' or t.c_holder is not null then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder)
             when public.qy_gl_trust_of(t.ctr) is not null then public.qy_gl_trust_of(t.ctr)
             else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end end,
      0, t.amount, null
    from tx t where t.source_type='request' and t.route='normal'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'استرداد', coalesce(t.description,''),
      case when t.direction='in' then co.gl_cash else coalesce(public.qy_gl_trust_of(t.ctr), public.qy_gl_exp_of(t.budget_item_id, t.ctr)) end, t.amount, 0, null
    from tx t where t.source_type='refund'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.req_no, t.source_id), 'استرداد', coalesce(t.description,''),
      case when t.direction='in' then coalesce(public.qy_gl_trust_of(t.ctr), public.qy_gl_exp_of(t.budget_item_id, t.ctr)) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type='refund'
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.source_id,''), case t.source_type when 'revenue' then 'إيراد' when 'recurring' then 'قيد دوري' else 'قيد يدوي' end, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then co.gl_cash else public.qy_gl_exp_of(t.budget_item_id, t.ctr) end, t.amount, 0, null
    from tx t where t.source_type not in ('request','refund','custody')
    union all
    select 'tx:'||t.id::text, t.tx_date, coalesce(t.source_id,''), case t.source_type when 'revenue' then 'إيراد' when 'recurring' then 'قيد دوري' else 'قيد يدوي' end, coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then coalesce(public.qy_gl_inc_of(t.budget_item_id), public.qy_gl_trust_of(t.ctr)) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type not in ('request','refund','custody')
    union all
    select 'tx:'||t.id::text, t.tx_date, 'عهدة '||t.source_id, 'إقفال عهدة', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then co.gl_cash else (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder) end, t.amount, 0, null
    from tx t where t.source_type='custody' and coalesce(t.c_action,'') not in ('carry','carry_debt')
    union all
    select 'tx:'||t.id::text, t.tx_date, 'عهدة '||t.source_id, 'إقفال عهدة', coalesce(t.description,'')||coalesce(' — '||t.beneficiary,''),
      case when t.direction='in' then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=t.c_holder) else co.gl_cash end, 0, t.amount, null
    from tx t where t.source_type='custody' and coalesce(t.c_action,'') not in ('carry','carry_debt')
    union all
    select 'cl:'||l.id::text, k.closed_at::date, 'عهدة '||k.id::text, 'مصروف عهدة', coalesce(l.description,'')||coalesce(' — فاتورة '||nullif(l.invoice_no,''),''),
      case when l.kind='expense' then public.qy_gl_exp_of(k.budget_item_id, null) else (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=k.holder_id) end,
      l.amount, 0, case when l.no_doc then 'بلا مستند' else null end
    from public.custody_lines l join public.custodies k on k.id=l.custody_id
    where k.company_id=p_company and k.status='closed' and l.status='accepted' and k.closed_at::date between p_from and p_to
    union all
    select 'cl:'||l.id::text, k.closed_at::date, 'عهدة '||k.id::text, 'مصروف عهدة', coalesce(l.description,'')||coalesce(' — فاتورة '||nullif(l.invoice_no,''),''),
      case when l.kind='expense' then (select code from public.gl_custody_accounts g where g.company_id=p_company and g.holder_id=k.holder_id) else coalesce(public.qy_gl_inc_of(k.budget_item_id), public.qy_gl_exp_of(k.budget_item_id, null)) end,
      0, l.amount, null
    from public.custody_lines l join public.custodies k on k.id=l.custody_id
    where k.company_id=p_company and k.status='closed' and l.status='accepted' and k.closed_at::date between p_from and p_to
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'opening' then 'رصيد افتتاحي لمركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      case when e.kind='opening' then co.gl_opening
           when e.request_id is not null then (select public.qy_gl_exp_of(r.budget_item_id, r.center_id) from public.requests r where r.id=e.request_id)
           else co.gl_cash end,
      case when e.gross - coalesce(e.gateway_fee,0) >= 0 then e.gross - coalesce(e.gateway_fee,0) else 0 end,
      case when e.gross - coalesce(e.gateway_fee,0) < 0 then -(e.gross - coalesce(e.gateway_fee,0)) else 0 end,
      case when e.kind='opening' then 'افتتاحي' else null end
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind <> 'transfer' and e.entry_date between p_from and p_to
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'opening' then 'رصيد افتتاحي لمركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      public.qy_gl_trust_of(e.center_id),
      case when e.net < 0 then -e.net else 0 end, case when e.net >= 0 then e.net else 0 end, null
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind <> 'transfer' and e.entry_date between p_from and p_to and e.net <> 0
    union all
    select 'cb:'||e.id::text, e.entry_date, coalesce(e.order_ref, e.request_id, ''), case e.kind when 'subscription' then 'اشتراكات مركز' when 'support' then 'دعم مركز' when 'adjust' then 'تسوية مركز' else 'إيراد مركز' end,
      coalesce(e.purpose,'')||' — حصة الشركة', co.gl_share,
      case when e.company_share < 0 then -e.company_share else 0 end, case when e.company_share >= 0 then e.company_share else 0 end, null
    from public.center_ledger e
    where e.company_id=p_company and not e.voided and e.kind not in ('transfer','opening') and e.entry_date between p_from and p_to and coalesce(e.company_share,0) <> 0
    union all
    select 'cb:'||least(e.id, coalesce(e.pair_id, e.id))::text, e.entry_date, '', 'ترحيل بين مراكز', coalesce(e.purpose,'')||coalesce(' — '||nullif(e.note,''),''),
      public.qy_gl_trust_of(e.center_id), case when e.net < 0 then -e.net else 0 end, case when e.net > 0 then e.net else 0 end, null
    from public.center_ledger e left join public.center_ledger p on p.id = e.pair_id
    where e.company_id=p_company and not e.voided and e.kind='transfer' and e.entry_date between p_from and p_to
      and public.qy_gl_trust_of(e.center_id) is distinct from public.qy_gl_trust_of(p.center_id)
  )
  select l.k, l.d, l.rf, l.src, l.ds, l.ac, a.name,
         round(l.dr, 3), round(l.cr, 3),
         nullif(concat_ws(' · ', case when l.ac is null then 'بلا حساب' end, l.fl), '')
  from lines l left join public.gl_accounts a on a.company_id=p_company and a.code=l.ac
  where coalesce(l.dr,0) <> 0 or coalesce(l.cr,0) <> 0
  order by l.d, l.k, (l.dr = 0), l.ac;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_link(p_company text, p_target text, p_id text, p_field text, p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c text := nullif(btrim(coalesce(p_code,'')),'');
begin
  if not public.qy_gl_can(p_company) then raise exception 'الربط للمالية ومدير النظام'; end if;
  if p_target = 'company' and p_field = 'unlinked_mode' then
    if p_code not in ('warn','block') then raise exception 'قيمة غير صالحة'; end if;
    update public.companies set gl_unlinked_mode=p_code where id=p_company; return;
  end if;
  if c is not null and not exists (select 1 from public.gl_accounts where company_id=p_company and code=c) then raise exception 'الحساب % غير موجود في الدليل', c; end if;
  if p_target = 'item' then
    if p_field = 'expense' then update public.budget_items set gl_expense=c where id=p_id and company_id=p_company;
    elsif p_field = 'income' then update public.budget_items set gl_income=c where id=p_id and company_id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  elsif p_target = 'unit' then
    if p_field = 'trust' then update public.centers set gl_trust=c where id=p_id and company_id=p_company;
    elsif p_field = 'expense' then update public.centers set gl_expense=c where id=p_id and company_id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  elsif p_target = 'holder' then
    if c is null then delete from public.gl_custody_accounts where company_id=p_company and holder_id=p_id;
    else insert into public.gl_custody_accounts(company_id, holder_id, code) values (p_company, p_id, c)
         on conflict (company_id, holder_id) do update set code=excluded.code; end if;
  elsif p_target = 'company' then
    if p_field = 'cash' then update public.companies set gl_cash=c where id=p_company;
    elsif p_field = 'share' then update public.companies set gl_share=c where id=p_company;
    elsif p_field = 'opening' then update public.companies set gl_opening=c where id=p_company;
    elsif p_field = 'custody_parent' then update public.companies set gl_custody_parent=c where id=p_company;
    else raise exception 'حقل غير صالح'; end if;
  else raise exception 'هدف غير صالح'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_mark_exported(p_company text, p_month date, p_entries integer, p_total numeric, p_unlinked integer)
 RETURNS gl_exports
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare x public.gl_exports;
begin
  if not public.qy_gl_can(p_company) then raise exception 'للمالية ومدير النظام'; end if;
  insert into public.gl_exports(company_id, month, entries, total, unlinked, exported_by, exported_by_name)
  values (p_company, date_trunc('month', p_month)::date, coalesce(p_entries,0), coalesce(p_total,0), coalesce(p_unlinked,0), public.qy_me(), (select name from public.users where id=public.qy_me()))
  returning * into x;
  return x;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_new_custody_account(p_company text, p_holder text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare par text; nm text; nxt text; n int;
begin
  if not public.qy_gl_can(p_company) then raise exception 'للمالية ومدير النظام'; end if;
  select gl_custody_parent into par from public.companies where id=p_company;
  if par is null or not exists (select 1 from public.gl_accounts where company_id=p_company and code=par) then raise exception 'حدد مجموعة حسابات العهد في الإعدادات أولاً'; end if;
  select name into nm from public.users where id=p_holder;
  if nm is null then raise exception 'صاحب العهدة غير موجود'; end if;
  select coalesce(max(substr(code, length(par)+1)::int), 0) + 1 into n from public.gl_accounts
   where company_id=p_company and parent_code=par and code ~ ('^'||par||'[0-9]{3}$');
  nxt := par || lpad(n::text, 3, '0');
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, updated_by) values (p_company, nxt, 'عهدة '||nm, 'asset', par, false, public.qy_me());
  insert into public.gl_custody_accounts(company_id, holder_id, code) values (p_company, p_holder, nxt)
    on conflict (company_id, holder_id) do update set code=excluded.code;
  return nxt;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_save_account(p_company text, p_old_code text, p_code text, p_name text, p_kind text, p_parent text, p_is_group boolean, p_active boolean, p_note text)
 RETURNS gl_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.gl_accounts;
begin
  if not public.qy_gl_can(p_company) then raise exception 'دليل الحسابات للمالية ومدير النظام'; end if;
  p_code := btrim(coalesce(p_code,'')); p_name := btrim(coalesce(p_name,''));
  if p_code = '' or p_name = '' then raise exception 'رقم الحساب واسمه مطلوبان'; end if;
  if p_code !~ '^[0-9]+$' then raise exception 'رقم الحساب أرقام فقط'; end if;
  if p_kind not in ('asset','liability','equity','income','expense') then raise exception 'نوع الحساب غير صالح'; end if;
  if nullif(btrim(coalesce(p_parent,'')),'') is not null and not exists (select 1 from public.gl_accounts where company_id=p_company and code=btrim(p_parent)) then
    raise exception 'الحساب الأب % غير موجود', p_parent; end if;
  if btrim(coalesce(p_parent,'')) = p_code then raise exception 'الحساب لا يتبع نفسه'; end if;
  if coalesce(p_old_code,'') <> '' and p_old_code <> p_code then
    if exists (select 1 from public.gl_accounts where company_id=p_company and code=p_code) then raise exception 'الرقم % مستخدم لحساب آخر', p_code; end if;
    update public.gl_accounts set code=p_code where company_id=p_company and code=p_old_code;
    update public.gl_accounts set parent_code=p_code where company_id=p_company and parent_code=p_old_code;
    update public.budget_items set gl_expense=p_code where company_id=p_company and gl_expense=p_old_code;
    update public.budget_items set gl_income=p_code where company_id=p_company and gl_income=p_old_code;
    update public.centers set gl_trust=p_code where company_id=p_company and gl_trust=p_old_code;
    update public.centers set gl_expense=p_code where company_id=p_company and gl_expense=p_old_code;
    update public.gl_custody_accounts set code=p_code where company_id=p_company and code=p_old_code;
    update public.companies set gl_cash = case when gl_cash=p_old_code then p_code else gl_cash end,
      gl_share = case when gl_share=p_old_code then p_code else gl_share end,
      gl_opening = case when gl_opening=p_old_code then p_code else gl_opening end,
      gl_custody_parent = case when gl_custody_parent=p_old_code then p_code else gl_custody_parent end
      where id=p_company;
  end if;
  insert into public.gl_accounts(company_id, code, name, kind, parent_code, is_group, is_active, note, updated_by, updated_at)
  values (p_company, p_code, p_name, p_kind, nullif(btrim(coalesce(p_parent,'')),''), coalesce(p_is_group,false), coalesce(p_active,true), nullif(btrim(coalesce(p_note,'')),''), public.qy_me(), now())
  on conflict (company_id, code) do update set name=excluded.name, kind=excluded.kind, parent_code=excluded.parent_code,
    is_group=excluded.is_group, is_active=excluded.is_active, note=excluded.note, updated_by=excluded.updated_by, updated_at=now()
  returning * into a;
  return a;
end $function$
;

CREATE OR REPLACE FUNCTION public.qy_gl_trust_of(p_center text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select gl_trust from public.centers where id=p_center),
                  (select gl_trust from public.centers where id=public.qy_unit_root(p_center)));
$function$
;

drop trigger if exists trg_qy_gl_block on public.transactions;
create trigger trg_qy_gl_block before insert on public.transactions for each row execute function public.qy_gl_block_guard();

-- ######## suppliers.sql ########
-- الموردون (16 نوفمبر 2026) — للتجربة أولاً
-- المورد صف في جدول العملاء نفسه: party = client | supplier | both (جهة واحدة قد تكون عميلاً ومورداً)
alter table public.clients add column if not exists party text not null default 'client';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'clients_party_chk') then
    alter table public.clients add constraint clients_party_chk check (party in ('client','supplier','both'));
  end if;
end $$;
alter table public.clients add column if not exists activity text;        -- نوع النشاط: طباعة، تجهيزات، نقل…
alter table public.clients add column if not exists bank_name text;
alter table public.clients add column if not exists iban text;
alter table public.clients add column if not exists account_name text;    -- اسم صاحب الحساب
alter table public.clients add column if not exists license_no text;      -- رقم الرخصة التجارية
alter table public.clients add column if not exists files jsonb not null default '[]'::jsonb;  -- [{kind: iban|license|other, path, name}]

-- القراءة والكتابة: المالية دائماً، أو دور صلاحيته في صفحة «الموردون» (قراءة/تعديل/تحكم) للموردين
drop policy if exists clients_all on public.clients;
drop policy if exists clients_sel on public.clients;
drop policy if exists clients_wrt on public.clients;
drop policy if exists clients_sup_ins on public.clients;
drop policy if exists clients_sup_upd on public.clients;
drop policy if exists clients_sup_del on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (public.is_finance() and public.can_see_company(company_id)) with check (public.is_finance() and public.can_see_company(company_id));
create policy clients_sel on public.clients for select to authenticated
  using (party <> 'client' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['read','edit','full']));
create policy clients_sup_ins on public.clients for insert to authenticated
  with check (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']));
create policy clients_sup_upd on public.clients for update to authenticated
  using (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']))
  with check (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['edit','full']));
create policy clients_sup_del on public.clients for delete to authenticated
  using (party = 'supplier' and public.can_see_company(company_id) and public.qy_page_level_ok(company_id, 'suppliers', array['full']));

-- قائمة الاختيار في طلب الصرف: كل من يرى الشركة يختار مورداً نشطاً (الاسم والآيبان فقط) دون فتح صفحة الموردين
create or replace function public.qy_supplier_pick(p_company text)
returns table (id text, name text, name_en text, iban text, bank_name text, account_name text, activity text)
language sql stable security definer set search_path = public as $fn$
  select c.id, c.name, c.name_en, c.iban, c.bank_name, c.account_name, c.activity
  from public.clients c
  where c.company_id = p_company and c.party in ('supplier','both') and c.status = 'active' and public.can_see_company(p_company)
  order by c.name;
$fn$;
grant execute on function public.qy_supplier_pick(text) to authenticated;

-- ربط المستفيد بالمورد: تظهر مدفوعات المورد في صفحته
alter table public.request_beneficiaries add column if not exists supplier_id text references public.clients(id) on delete set null;
create index if not exists request_beneficiaries_supplier_idx on public.request_beneficiaries(supplier_id) where supplier_id is not null;

-- نوع الطلب: عادي، عهدة، راتب، مكافأة
alter table public.requests drop constraint if exists requests_request_type_chk;
alter table public.requests add constraint requests_request_type_chk check (request_type = any (array['normal','custody','payroll','reward']));

-- ######## org_depts_payroll.sql ########
-- أقسام المستخدمين العامّين + صلاحيات طلب الراتب والمكافأة + اعتماد الموارد البشرية في مسار الراتب (16 نوفمبر 2026) — للتجربة أولاً

-- 1) أقسام العامّين (على مستوى المؤسسة، تخدم كل الشركات): لكل قسم وظيفة يفهمها النظام
create table if not exists public.org_departments (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  func text not null default 'none' check (func in ('none','hr','secretary','finance')),
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.org_departments enable row level security;
drop policy if exists org_departments_sel on public.org_departments;
drop policy if exists org_departments_wrt on public.org_departments;
create policy org_departments_sel on public.org_departments for select to authenticated using (true);
create policy org_departments_wrt on public.org_departments for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.org_departments to authenticated;

alter table public.users add column if not exists org_dept_id text references public.org_departments(id) on delete set null;
grant select (org_dept_id) on public.users to authenticated;

create or replace function public.qy_user_dept_func(p_user text)
returns text language sql stable security definer set search_path = public as $fn$
  select d.func from public.users u join public.org_departments d on d.id = u.org_dept_id where u.id = p_user and coalesce(u.is_general,false);
$fn$;

-- 2) من يُنشئ طلب راتب: قسم الموارد البشرية أو السكرتارية، أو دور له الصلاحية صراحة (تعديل/تحكم)، وإلا افتراضياً المالية
create or replace function public.qy_can_payroll(p_user text, p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce(public.qy_user_dept_func(p_user) in ('hr','secretary'), false)
      or coalesce((select p.level in ('edit','full') from public.page_permissions p join public.users u on u.id = p_user
                   where p.company_id = p_company and p.role = u.role and p.page_key = 'payroll' limit 1),
                  (select u.role in ('accountant','cfo','admin') from public.users u where u.id = p_user), false);
$fn$;

create or replace function public.qy_requests_ins_guard()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
declare v_key text := case coalesce(new.request_type,'normal') when 'custody' then 'custody' when 'reward' then 'reward' when 'payroll' then 'payroll' else 'newreq' end;
begin
  if auth.uid() is null or public.qy_mode() = 'off' or public.is_admin() then return new; end if;
  if new.created_by_id is distinct from public.qy_me() then
    perform public.qy_deny('req_ins_owner', new.id, 'لا تُنشئ طلباً باسم غيرك');
  end if;
  if v_key = 'payroll' then
    if not public.qy_can_payroll(new.created_by_id, new.company_id) then
      perform public.qy_deny('req_ins_page', new.id, 'ليست لديك صلاحية إنشاء طلب راتب في هذه الشركة');
    end if;
  -- صلاحية الصفحة لدور المستخدم في هذه الشركة (لا يرى / قراءة فقط = لا إنشاء)
  elsif exists (select 1 from public.page_permissions p join public.users u on u.id = new.created_by_id
             where p.company_id = new.company_id and p.role = u.role and p.page_key = v_key and p.level in ('none','read')) then
    perform public.qy_deny('req_ins_page', new.id, 'ليست لديك صلاحية إنشاء هذا النوع من الطلبات في هذه الشركة');
  end if;
  if coalesce(new.is_cancelled,false) or coalesce(new.status,'') not in ('pending_decision','pending_transfer_request') then
    perform public.qy_deny('req_ins_status', new.id, 'لا يُنشأ طلب بحالة متقدمة');
  end if;
  if new.status = 'pending_transfer_request'
     and not public.qy_transfer_ok(new.created_by_id, new.company_id, new.total_amount) then
    perform public.qy_deny('req_ins_skip', new.id, 'لا يبدأ الطلب في مرحلة التحويل بلا معتمدين إلا لمن فُعّل له الانتقال المباشر أو ضمن الحد الأدنى لمبلغ المركز');
  end if;
  return new;
end $function$;

-- 3) معتمد الموارد البشرية: مدير القسم (عضو مديره ليس في القسم)، وإلا أول عضو — ويُستبعد الموقوف
create or replace function public.qy_hr_approver(p_company text)
returns text language sql stable security definer set search_path = public as $fn$
  with m as (
    select u.* from public.users u join public.org_departments d on d.id = u.org_dept_id
    where d.func = 'hr' and coalesce(u.is_general,false) and not coalesce(u.is_suspended,false)
      and (p_company is null or public.qy_user_in_company(u.id, p_company)))
  select id from m order by (case when m.manager_id is null or m.manager_id not in (select id from m) then 0 else 1 end), m.name limit 1;
$fn$;

-- 4) مسار الراتب: بعد المدراء وقبل المحاسب تُضاف خطوة الموارد البشرية
create or replace function public.qy_set_chain(p_req text, p_reset boolean default false)
 returns setof request_approval_steps language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
declare r public.requests%rowtype; v_me text := public.qy_me(); ch jsonb; ids text[]; i int; stamp text; v_staff boolean; v_hr text; v_hr_note boolean := false;
  v_time text := to_char(now() at time zone 'Asia/Kuwait', 'DD') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'MM') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'YYYY')
          || ' ' || ltrim(to_char(now() at time zone 'Asia/Kuwait', 'HH12'), '0') || ':' || to_char(now() at time zone 'Asia/Kuwait', 'MI')
          || ' ' || case when extract(hour from now() at time zone 'Asia/Kuwait') >= 12 then 'م' else 'ص' end;
begin
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.is_cancelled then raise exception 'الطلب ملغى'; end if;
  v_staff := public.is_admin() or (public.is_finance() and public.can_see_company(r.company_id));
  if not (v_staff or coalesce(r.created_by_id = v_me, false)) then
    raise exception 'غير مصرّح: بناء المسار لصاحب الطلب أو المالية أو مدير النظام';
  end if;
  if p_reset and not v_staff then raise exception 'غير مصرّح: إعادة المسار وإلغاء الاعتمادات للمالية أو مدير النظام'; end if;
  if not p_reset and exists (select 1 from public.request_approval_steps s where s.request_id = p_req and s.status <> 'pending') then
    raise exception 'بدأ اعتماد الطلب؛ إعادة البناء تكون بـ«إعادة المسار والاعتماد»';
  end if;
  if not v_staff and r.status not in ('pending_decision','pending_transfer_request','rejected') then
    raise exception 'لا يُعاد بناء مسار طلب تجاوز مرحلة القرار';
  end if;
  ch := case when coalesce(r.request_type,'normal') = 'custody' then public.qy_custody_chain(r.id)
              else public.qy_decision_chain(r.created_by_id, r.company_id, r.total_amount) end;
  if ch->>'error' is not null then raise exception 'تعذّر بناء المسار: %', ch->>'error'; end if;
  select coalesce(array_agg(e), '{}') into ids from jsonb_array_elements_text(ch->'ids') e;
  if coalesce(r.request_type,'normal') = 'payroll' then
    v_hr := public.qy_hr_approver(r.company_id);
    if v_hr is null then v_hr_note := true;
    elsif v_hr <> r.created_by_id and not (v_hr = any(ids)) then ids := ids || v_hr;
    end if;
  end if;
  perform set_config('qy.sys', '1', true);
  delete from public.request_approval_steps where request_id = p_req;
  stamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  for i in 1 .. coalesce(array_length(ids,1),0) loop
    insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, note)
    values ('as_' || p_req || '_s' || stamp || '_' || i, p_req, ids[i], i, 'pending_decision', 'pending', 'primary', case when i = 1 then now() end,
            case when v_hr is not null and ids[i] = v_hr then 'الموارد البشرية' end);
  end loop;
  if v_hr_note and not exists (select 1 from public.request_history h where h.request_id = p_req and h.note like 'لم يُحدَّد قسم الموارد البشرية%') then
    insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      values (p_req, 'pending_decision', 'النظام', null, 'ملاحظة', 'لم يُحدَّد قسم الموارد البشرية للمستخدمين العامّين — مضى طلب الراتب على المسار العادي', v_time);
  end if;
  if coalesce(array_length(ids,1),0) = 0 then
    if coalesce((ch->>'self')::boolean, false)
       or coalesce((select u.direct_to_transfer from public.users u where u.id = r.created_by_id), false) then
      insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, acted_at, note)
        values ('as_' || p_req || '_s' || stamp || '_self', p_req, r.created_by_id, 1, 'pending_decision', 'approved', 'primary', now(), now(), 'بإنشائه الطلب');
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
        values (p_req, 'pending_decision', (select u.name from public.users u where u.id = r.created_by_id), r.created_by_id, 'اعتماد', 'بإنشائه الطلب — في أعلى السلسلة', v_time);
      update public.requests set status = 'pending_transfer_request' where id = p_req and status in ('pending_decision','rejected');
    else
      raise exception 'لا يوجد معتمِد لهذا الطلب، ولا يصل طلب للمالية قبل اعتماد واحد على الأقل. حدّد مديراً لصاحب الطلب، أو فعّل «الانتقال المباشر إلى التحويل» لمن هو في أعلى السلسلة';
    end if;
  end if;
  update public.requests set fast_tracked = coalesce((ch->>'fast')::boolean, false)
    where id = p_req and fast_tracked is distinct from coalesce((ch->>'fast')::boolean, false);
  perform set_config('qy.sys', '', true);
  return query select * from public.request_approval_steps where request_id = p_req order by sequence_order;
end $function$;

-- 5) (16 نوفمبر، 1.17.1) الدور الوظيفي «يُنشئ طلبات الرواتب»، ومعتمد الموارد البشرية بالاسم: الشركة ← المؤسسة ← مدير القسم
alter table public.custom_roles add column if not exists can_payroll boolean not null default false;
alter table public.companies add column if not exists hr_approver_id text references public.users(id) on delete set null;
create or replace function public.qy_can_payroll(p_user text, p_company text)
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce(public.qy_user_dept_func(p_user) in ('hr','secretary'), false)
      or exists (select 1 from public.users u join public.custom_roles cr on cr.id = u.role where u.id = p_user and cr.can_payroll)
      or coalesce((select p.level in ('edit','full') from public.page_permissions p join public.users u on u.id = p_user
                   where p.company_id = p_company and p.role = u.role and p.page_key = 'payroll' limit 1),
                  (select u.role in ('accountant','cfo','admin') from public.users u where u.id = p_user), false);
$fn$;
create or replace function public.qy_hr_approver(p_company text)
returns text language sql stable security definer set search_path = public as $fn$
  with ok as (select u.id from public.users u where not coalesce(u.is_suspended,false) and (p_company is null or public.qy_user_in_company(u.id, p_company))),
  m as (
    select u.* from public.users u join public.org_departments d on d.id = u.org_dept_id
    where d.func = 'hr' and coalesce(u.is_general,false) and u.id in (select id from ok)),
  head as (select id from m order by (case when m.manager_id is null or m.manager_id not in (select id from m) then 0 else 1 end), m.name limit 1)
  select coalesce(
    (select c.hr_approver_id from public.companies c where c.id = p_company and c.hr_approver_id in (select id from ok)),
    (select s.value from public.app_settings s where s.key = 'hr_approver_id' and s.value in (select id from ok)),
    (select id from head));
$fn$;


-- ═════ 20) user_units_login_email.sql (17 نوفمبر) ═════
-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — الوحدات الإضافية للمستخدم + الدخول بالبريد
-- ║  17 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
-- ١) جدول الوحدات الإضافية: للمستخدم وحدة أساسية (users.center_id) ووحدات إضافية هنا،
--    ولكل وحدة إضافية مديره المباشر فيها (اختياري؛ فارغ = مديره المعتاد)
create table if not exists public.user_units (
  user_id    text not null references public.users(id) on delete cascade,
  center_id  text not null references public.centers(id) on delete cascade,
  manager_id text references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, center_id)
);
create index if not exists user_units_center_idx on public.user_units(center_id);
alter table public.user_units enable row level security;
drop policy if exists user_units_sel on public.user_units;
drop policy if exists user_units_wrt on public.user_units;
create policy user_units_sel on public.user_units for select to authenticated
  using (public.is_admin() or user_id = public.qy_me()
         or exists (select 1 from public.centers c where c.id = user_units.center_id and public.can_see_company(c.company_id)));
create policy user_units_wrt on public.user_units for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.user_units to authenticated;

-- كل وحدات المستخدم: الأساسية ثم الإضافية
create or replace function public.qy_user_units(p_user text) returns setof text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select center_id from public.users where id = p_user and center_id is not null
  union
  select center_id from public.user_units where user_id = p_user;
$$;
revoke all on function public.qy_user_units(text) from public, anon;
grant execute on function public.qy_user_units(text) to authenticated;

-- ٢) رؤية المركز: من يعمل فيه أو في وحدة فوقه، أساسية كانت أو إضافية
create or replace function public.qy_center_can_see(p_center text) returns boolean
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.centers ce where ce.id = p_center and public.can_see_company(ce.company_id))
     and (public.is_admin() or case
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'deny') then false
            when exists (select 1 from public.center_access a where a.center_id = p_center and a.user_id = public.qy_me() and a.mode = 'allow') then true
            else exists (select 1 from public.users u where u.id = public.qy_me() and u.role in ('accountant','cfo','executive_manager'))
              or exists (select 1 from public.qy_user_units(public.qy_me()) x(id) where x.id in (select id from public.qy_unit_up(p_center)))
          end);
$$;
revoke all on function public.qy_center_can_see(text) from public, anon;
grant execute on function public.qy_center_can_see(text) to authenticated;

-- ٣) طلب موظف المركز: على إحدى وحداته (أساسية أو إضافية) أو ما تحتها
create or replace function public.qy_center_staff_guard() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare u public.users%rowtype;
begin
  if coalesce(new.request_type,'') = 'custody' or coalesce(new.amount_route,'normal') <> 'normal' then return new; end if;
  select * into u from public.users where id = public.qy_me();
  if u.id is null or u.role in ('admin','accountant','cfo','executive_manager') then return new; end if;
  -- ليس من موظفي المراكز في أي من وحداته: لا قيد
  if not exists (select 1 from public.qy_user_units(u.id) x(id) join public.qy_unit_up(x.id) up on true where up.kind = 'center') then return new; end if;
  if new.center_id is null or not exists (
       select 1 from public.qy_user_units(u.id) x(id) where x.id in (select id from public.qy_unit_up(new.center_id))) then
    raise exception 'الطلب يكون على إحدى وحداتك أو ما تحتها فقط';
  end if;
  if new.budget_item_id is not null and exists (select 1 from public.qy_unit_up(new.center_id) where kind = 'center') then
    raise exception 'طلب المركز يُصرف من رصيد المركز، فلا يُختار له بند من ميزانية الشركة';
  end if;
  return new;
end $function$;

-- ٤) مسار القرار: إن كان الطلب على وحدة إضافية لها مدير محدد، يبدأ المسار منه
create or replace function public.qy_decision_chain(p_creator text, p_company text, p_total numeric, p_start text, p_center text)
 returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare
  r public.users%rowtype; a public.users%rowtype; c public.centers%rowtype;
  cur text; ids text[] := '{}'; seen text[]; err text := null;
  skip text[] := '{}'; kept text[] := '{}'; fast boolean := false; x text; xr text;
begin
  select * into r from public.users where id = p_creator;
  if not found then return jsonb_build_object('ids','[]'::jsonb,'error','مستخدم غير موجود','fast',false); end if;
  seen := array[p_creator];
  cur := case when nullif(p_start,'') is not null then p_start
              when coalesce(r.no_request_approver,false) then null
              else coalesce(nullif(r.request_approver_id,''), case when p_company is not null then public._get_manager_for_company(r.id, p_company) else r.manager_id end) end;
  while nullif(cur,'') is not null loop
    if cur = any(seen) then err := 'حلقة دائرية: تكرر "' || coalesce((select u.name from public.users u where u.id = cur), cur) || '"'; exit; end if;
    if coalesce(array_length(ids,1),0) >= 20 then err := 'مسار طويل جداً (٢٠ خطوة فأكثر) — يُشتبه بحلقة دائرية'; exit; end if;
    seen := seen || cur;
    select * into a from public.users where id = cur;
    if not found then exit; end if;
    if coalesce(a.is_suspended,false) then err := 'المعتمِد «' || a.name || '» موقوف الحساب — أسند معاملاته أو غيّر مدير صاحب الطلب'; exit; end if;
    if p_company is not null and not public.qy_user_in_company(a.id, p_company) then
      err := 'المعتمِد «' || a.name || '» غير مرتبط بشركة الطلب — حدّد مديراً لصاحب الطلب في هذه الشركة (المدير المباشر لكل شركة)'; exit;
    end if;
    ids := ids || a.id;
    cur := case when coalesce(a.no_next_approver,false) then null
                else coalesce(nullif(a.next_approver_id,''), case when p_company is not null then public._get_manager_for_company(a.id, p_company) else a.manager_id end) end;
  end loop;
  if err is null and coalesce(array_length(ids,1),0) > 0 and p_total is not null then
    select * into c from public.centers where id = coalesce(nullif(p_center,''), r.center_id);
    if found and c.min_threshold is not null and p_total <= c.min_threshold then
      if coalesce(c.skip_dept_manager,false) then skip := skip || 'dept_manager'::text; end if;
      if coalesce(c.skip_senior_manager,false) then skip := skip || 'senior_manager'::text; end if;
      if coalesce(c.skip_executive_manager,false) then skip := skip || 'executive_manager'::text; end if;
      if coalesce(array_length(skip,1),0) > 0 then
        foreach x in array ids loop
          select u.role into xr from public.users u where u.id = x;
          if xr is null or not (xr = any(skip)) then kept := kept || x; end if;
        end loop;
        if coalesce(array_length(kept,1),0) <> array_length(ids,1) then
          fast := true;
          if coalesce(array_length(kept,1),0) = 0 then
            xr := coalesce(c.min_single_approver, 'exec');
            x := null;
            if xr in ('exec','senior') then
              select t.i2 into x from unnest(ids) with ordinality t(i2, o) join public.users u on u.id = t.i2
               where u.role = case xr when 'exec' then 'executive_manager' else 'senior_manager' end order by t.o limit 1;
            end if;
            kept := array[coalesce(x, ids[1])];
          end if;
          ids := kept;
        end if;
      end if;
    end if;
  end if;
  return jsonb_build_object('ids', to_jsonb(ids), 'error', err, 'fast', fast);
end $function$;
revoke all on function public.qy_decision_chain(text,text,numeric,text,text) from public, anon;
grant execute on function public.qy_decision_chain(text,text,numeric,text,text) to authenticated;

-- الصيغة القديمة (ثلاثة مدخلات) تبقى كما هي لمن يستدعيها
create or replace function public.qy_decision_chain(p_creator text, p_company text, p_total numeric)
 returns jsonb language sql stable security definer set search_path to 'public','pg_temp' as $$
  select public.qy_decision_chain(p_creator, p_company, p_total, null::text, null::text);
$$;

-- مدير الوحدة الإضافية التي عليها الطلب (أو التي فوقها)، إن وُجد
create or replace function public.qy_unit_start(p_creator text, p_center text) returns text
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select uu.manager_id from public.user_units uu
   join public.qy_unit_up(p_center) up on up.id = uu.center_id
   where uu.user_id = p_creator and uu.manager_id is not null
     and not exists (select 1 from public.users u where u.id = p_creator and u.center_id in (select id from public.qy_unit_up(p_center)))
   order by up.depth limit 1;
$$;
revoke all on function public.qy_unit_start(text,text) from public, anon;

-- ٥) بناء المسار: يمرّر مدير الوحدة الإضافية (إن وُجد) لدالة القرار
create or replace function public.qy_set_chain(p_req text, p_reset boolean default false)
 returns setof request_approval_steps language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare r public.requests%rowtype; v_me text := public.qy_me(); ch jsonb; ids text[]; i int; stamp text; v_staff boolean; v_hr text; v_hr_note boolean := false; v_start text;
  v_time text := to_char(now() at time zone 'Asia/Kuwait', 'DD') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'MM') || chr(8207) || '-' || chr(8207) || to_char(now() at time zone 'Asia/Kuwait', 'YYYY')
          || ' ' || ltrim(to_char(now() at time zone 'Asia/Kuwait', 'HH12'), '0') || ':' || to_char(now() at time zone 'Asia/Kuwait', 'MI')
          || ' ' || case when extract(hour from now() at time zone 'Asia/Kuwait') >= 12 then 'م' else 'ص' end;
begin
  select * into r from public.requests where id = p_req for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.is_cancelled then raise exception 'الطلب ملغى'; end if;
  v_staff := public.is_admin() or (public.is_finance() and public.can_see_company(r.company_id));
  if not (v_staff or coalesce(r.created_by_id = v_me, false)) then
    raise exception 'غير مصرّح: بناء المسار لصاحب الطلب أو المالية أو مدير النظام';
  end if;
  if p_reset and not v_staff then raise exception 'غير مصرّح: إعادة المسار وإلغاء الاعتمادات للمالية أو مدير النظام'; end if;
  if not p_reset and exists (select 1 from public.request_approval_steps s where s.request_id = p_req and s.status <> 'pending') then
    raise exception 'بدأ اعتماد الطلب؛ إعادة البناء تكون بـ«إعادة المسار والاعتماد»';
  end if;
  if not v_staff and r.status not in ('pending_decision','pending_transfer_request','rejected') then
    raise exception 'لا يُعاد بناء مسار طلب تجاوز مرحلة القرار';
  end if;
  v_start := case when r.center_id is not null then public.qy_unit_start(r.created_by_id, r.center_id) end;
  ch := case when coalesce(r.request_type,'normal') = 'custody' then public.qy_custody_chain(r.id)
              else public.qy_decision_chain(r.created_by_id, r.company_id, r.total_amount, v_start, case when v_start is not null then r.center_id end) end;
  if ch->>'error' is not null then raise exception 'تعذّر بناء المسار: %', ch->>'error'; end if;
  select coalesce(array_agg(e), '{}') into ids from jsonb_array_elements_text(ch->'ids') e;
  if coalesce(r.request_type,'normal') = 'payroll' then
    v_hr := public.qy_hr_approver(r.company_id);
    if v_hr is null then v_hr_note := true;
    elsif v_hr <> r.created_by_id and not (v_hr = any(ids)) then ids := ids || v_hr;
    end if;
  end if;
  perform set_config('qy.sys', '1', true);
  delete from public.request_approval_steps where request_id = p_req;
  stamp := floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  for i in 1 .. coalesce(array_length(ids,1),0) loop
    insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, note)
    values ('as_' || p_req || '_s' || stamp || '_' || i, p_req, ids[i], i, 'pending_decision', 'pending', 'primary', case when i = 1 then now() end,
            case when v_hr is not null and ids[i] = v_hr then 'الموارد البشرية' end);
  end loop;
  if v_hr_note and not exists (select 1 from public.request_history h where h.request_id = p_req and h.note like 'لم يُحدَّد قسم الموارد البشرية%') then
    insert into public.request_history(request_id, step, actor, user_id, action, note, time)
      values (p_req, 'pending_decision', 'النظام', null, 'ملاحظة', 'لم يُحدَّد قسم الموارد البشرية للمستخدمين العامّين — مضى طلب الراتب على المسار العادي', v_time);
  end if;
  if coalesce(array_length(ids,1),0) = 0 then
    if coalesce((ch->>'self')::boolean, false)
       or coalesce((select u.direct_to_transfer from public.users u where u.id = r.created_by_id), false) then
      insert into public.request_approval_steps(id, request_id, approver_id, sequence_order, role_label, status, kind, activated_at, acted_at, note)
        values ('as_' || p_req || '_s' || stamp || '_self', p_req, r.created_by_id, 1, 'pending_decision', 'approved', 'primary', now(), now(), 'بإنشائه الطلب');
      insert into public.request_history(request_id, step, actor, user_id, action, note, time)
        values (p_req, 'pending_decision', (select u.name from public.users u where u.id = r.created_by_id), r.created_by_id, 'اعتماد', 'بإنشائه الطلب — في أعلى السلسلة', v_time);
      update public.requests set status = 'pending_transfer_request' where id = p_req and status in ('pending_decision','rejected');
    else
      raise exception 'لا يوجد معتمِد لهذا الطلب، ولا يصل طلب للمالية قبل اعتماد واحد على الأقل. حدّد مديراً لصاحب الطلب، أو فعّل «الانتقال المباشر إلى التحويل» لمن هو في أعلى السلسلة';
    end if;
  end if;
  update public.requests set fast_tracked = coalesce((ch->>'fast')::boolean, false)
    where id = p_req and fast_tracked is distinct from coalesce((ch->>'fast')::boolean, false);
  perform set_config('qy.sys', '', true);
  return query select * from public.request_approval_steps where request_id = p_req order by sequence_order;
end $function$;

-- ٦) الدخول بالبريد الإلكتروني المسجّل للمستخدم (إضافة إلى رقم الهاتف)
--    البريد المسجّل في بيانات المستخدم يُحوَّل إلى حساب الدخول المرتبط برقمه.
--    أي بريد آخر يُعاد كما هو (لحسابات الدخول الحقيقية بالبريد).
create or replace function public.resolve_login_email(p_login text) returns text
language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare v text; v_phone text;
begin
  v := lower(trim(coalesce(p_login,'')));
  if v = '' then return ''; end if;
  if position('@' in v) > 0 then
    if v like '%@qyam.local' or exists (select 1 from auth.users au where lower(au.email) = v) then return v; end if;
    select phone into v_phone from public.users where lower(trim(email)) = v and coalesce(phone,'') <> '' order by is_suspended nulls first limit 1;
    if v_phone is not null then return lower(v_phone) || '@qyam.local'; end if;
    return v;
  end if;
  select phone into v_phone from public.users where lower(phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;
  select u.phone into v_phone
    from public.login_aliases a join public.users u on u.id = a.user_id
   where lower(a.phone) = v limit 1;
  if v_phone is not null then return v_phone || '@qyam.local'; end if;
  return v || '@qyam.local';
end;
$function$;

-- ٧) تحقق
select (select count(*) from pg_tables where schemaname='public' and tablename='user_units') as user_units_table,
       (select count(*) from pg_proc where proname='qy_decision_chain') as decision_chain_versions;


-- ════ 2026-11-18: بناء-٥ ════
-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٥ (1.26.0): معالجة المبالغ غير المحصّلة عند إغلاق المشروع،
--                  ومستفيدو المراكز لا يراهم إلا من يرى المركز.
-- يُشغَّل بعد بناء-١..٤. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── ١) من يعالج المبالغ عند الإغلاق (مع مدير النظام والمدير المالي) ───
alter table public.companies add column if not exists settle_user_ids jsonb not null default '[]'::jsonb;

create or replace function public.qy_prj_can_settle(p_company text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.can_see_company(p_company) and (
       public.is_admin()
    or exists (select 1 from public.users u where u.id = public.qy_me() and u.role = 'cfo')
    or exists (select 1 from public.companies c where c.id = p_company
               and coalesce(c.settle_user_ids, '[]'::jsonb) ? public.qy_me()));
$$;

-- ─── ٢) الفاتورة المرحّلة لعميل آخر ───
alter table public.prj_invoices add column if not exists client_id text references public.clients(id) on delete set null;
alter table public.prj_invoices add column if not exists transferred_from uuid references public.prj_invoices(id) on delete set null;

-- ─── ٣) معالجات المبالغ غير المحصّلة ───
create table if not exists public.prj_settlements (
  id          uuid primary key default gen_random_uuid(),
  company_id  text not null references public.companies(id) on delete cascade,
  project_id  uuid not null references public.projects(id) on delete cascade,
  invoice_id  uuid not null references public.prj_invoices(id) on delete cascade,
  kind        text not null check (kind in ('later','bad_debt','discount','transfer','waive')),
  amount      numeric(14,3) not null check (amount > 0),
  due_date    date,
  reason      text,
  transfer_client_id  text references public.clients(id) on delete set null,
  transfer_invoice_id uuid references public.prj_invoices(id) on delete set null,
  created_by  text,
  created_at  timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by text,
  constraint prj_settle_later_date check (kind <> 'later' or due_date is not null),
  constraint prj_settle_reason check (kind = 'later' or length(trim(coalesce(reason,''))) > 0),
  constraint prj_settle_transfer check (kind <> 'transfer' or transfer_client_id is not null)
);
create index if not exists prj_settlements_inv_idx on public.prj_settlements(invoice_id);
create index if not exists prj_settlements_prj_idx on public.prj_settlements(project_id);
alter table public.prj_settlements enable row level security;
drop policy if exists prj_settlements_sel on public.prj_settlements;
create policy prj_settlements_sel on public.prj_settlements for select using (public.qy_prj_can_read(company_id));
drop policy if exists prj_settlements_wrt on public.prj_settlements;
create policy prj_settlements_wrt on public.prj_settlements for all
  using (public.qy_prj_can_settle(company_id)) with check (public.qy_prj_can_settle(company_id));

-- ─── ٤) لا يُغلق مشروع وفيه مبلغ غير محصّل ولم يُعالَج ───
create or replace function public.qy_prj_open_amount(p_project uuid)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(greatest(0,
           i.amount
         - coalesce((select sum(c.amount) from public.prj_collections c where c.invoice_id = i.id), 0)
         - coalesce((select sum(s.amount) from public.prj_settlements s where s.invoice_id = i.id
                       and s.cancelled_at is null and s.kind <> 'later'), 0))), 0)
  from public.prj_invoices i where i.project_id = p_project and i.status = 'issued';
$$;
create or replace function public.qy_prj_close_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'closed' and coalesce(old.status,'') <> 'closed' then
    if public.qy_prj_open_amount(new.id) > 0.0005 then
      raise exception 'لا يُغلق المشروع: فيه مبلغ غير محصّل لم يُعالَج (%)', round(public.qy_prj_open_amount(new.id), 3)
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qy_prj_close_guard on public.projects;
create trigger qy_prj_close_guard before update of status on public.projects
  for each row execute function public.qy_prj_close_guard();

-- ─── ٥) مستفيدو المراكز: لكل مستفيد وحدته (فارغة = الشركة) ───
alter table public.beneficiaries_master add column if not exists center_id text references public.centers(id) on delete set null;
alter table public.beneficiaries_master add column if not exists scope_key text generated always as (coalesce(center_id, '')) stored;

-- موظف المركز: ليس من المالية أو الإدارة العليا، وإحدى وحداته مركز أو تحت مركز
create or replace function public.qy_is_center_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select not public.is_admin()
     and not exists (select 1 from public.users u where u.id = public.qy_me()
                     and u.role in ('accountant','cfo','executive_manager'))
     and exists (select 1 from public.qy_user_units(public.qy_me()) x(id)
                 join lateral public.qy_unit_up(x.id) up on true where up.kind = 'center');
$$;

-- تعبئة المستفيدين القدامى: من ظهر في طلبات مركز واحد فقط (وحدة مركز أو تحته) يُنسب إليه
update public.beneficiaries_master bm set center_id = t.cid
from (
  select rb.name, r.company_id, min(r.center_id) cid
  from public.request_beneficiaries rb join public.requests r on r.id = rb.request_id
  group by rb.name, r.company_id
  having count(distinct coalesce(r.center_id,'')) = 1 and min(r.center_id) is not null
) t
where bm.center_id is null and bm.name = t.name and bm.company_id = t.company_id
  and exists (select 1 from public.qy_unit_up(t.cid) up where up.kind = 'center');

-- التفرّد: الاسم مرة واحدة لكل شركة ولكل وحدة
alter table public.beneficiaries_master drop constraint if exists beneficiaries_master_co_name_key;
drop index if exists public.beneficiaries_master_co_name_key;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'beneficiaries_master_co_scope_name_key') then
    alter table public.beneficiaries_master add constraint beneficiaries_master_co_scope_name_key unique (company_id, scope_key, name);
  end if;
end $$;

create or replace function public.qy_bene_can_see(p_company text, p_center text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_company is null then true
    when not public.can_see_company(p_company) then false
    when p_center is null then not public.qy_is_center_staff()
    else public.qy_center_can_see(p_center) end;
$$;
drop policy if exists qyam_sel_beneficiaries on public.beneficiaries_master;
create policy qyam_sel_beneficiaries on public.beneficiaries_master for select
  using (public.qy_bene_can_see(company_id, center_id));
drop policy if exists qyam_wrt_beneficiaries on public.beneficiaries_master;
create policy qyam_wrt_beneficiaries on public.beneficiaries_master for all
  using (company_id is not null and public.qy_bene_can_see(company_id, center_id))
  with check (company_id is not null and public.qy_bene_can_see(company_id, center_id));

grant execute on function public.qy_prj_can_settle(text),
  public.qy_is_center_staff(), public.qy_bene_can_see(text, text) to authenticated;


-- ════ 2026-11-18: بناء-٧ ════
-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٧ (1.27.0): طلب العميل — ما يشرح فيه العميل المطلوب في المشروع.
-- اختياري. قد يأتي قبل الوثيقة (يظهر «طلب جديد — بانتظار الوثيقة») ثم يُربط بها.
-- يُشغَّل بعد بناء-١..٥. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.prj_client_requests (
  id          uuid primary key default gen_random_uuid(),
  company_id  text not null references public.companies(id) on delete cascade,
  client_id   text references public.clients(id) on delete set null,
  req_date    date not null default current_date,
  channel     text not null default 'other' check (channel in ('letter','email','whatsapp','meeting','phone','other')),
  description text not null check (length(trim(description)) > 0),
  files       jsonb not null default '[]'::jsonb check (jsonb_typeof(files) = 'array' and jsonb_array_length(files) <= 3),
  status      text not null default 'new' check (status in ('new','linked','cancelled')),
  doc_id      uuid references public.prj_documents(id) on delete set null,
  created_by  text,
  created_at  timestamptz not null default now(),
  constraint prj_creq_linked check (status <> 'linked' or doc_id is not null)
);
create index if not exists prj_creq_company_idx on public.prj_client_requests(company_id, status);
create index if not exists prj_creq_doc_idx on public.prj_client_requests(doc_id);
alter table public.prj_client_requests enable row level security;
drop policy if exists prj_creq_sel on public.prj_client_requests;
create policy prj_creq_sel on public.prj_client_requests for select using (public.qy_prj_can_read(company_id));
drop policy if exists prj_creq_wrt on public.prj_client_requests;
create policy prj_creq_wrt on public.prj_client_requests for all
  using (public.qy_prj_can_write(company_id)) with check (public.qy_prj_can_write(company_id));


-- ════ 2026-11-18: بناء-٨ ════
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


-- ════ 2026-11-18: بناء-٩ ════
-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٩ (1.31.0): تفضيلات واجهة المستخدم — عرض أعمدة الجداول لكل مستخدم (يجدها في أي جهاز).
-- يُشغَّل بعد بناء-١..٨. آمن للتكرار (idempotent).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.user_ui_prefs (
  user_id    text primary key references public.users(id) on delete cascade,
  col_widths jsonb not null default '{}'::jsonb check (jsonb_typeof(col_widths) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.user_ui_prefs enable row level security;
drop policy if exists user_ui_prefs_own on public.user_ui_prefs;
create policy user_ui_prefs_own on public.user_ui_prefs for all
  using (user_id = public.qy_me()) with check (user_id = public.qy_me());
