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
