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
