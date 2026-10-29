-- صاحب الطلب يرى ويعدّل طلباته في أي شركة (حتى بعد نقله منها). طُبّق على الإنتاج والاختبار.
create or replace function public.can_see_request(p_request_id text) returns boolean language sql stable security definer set search_path to 'public','pg_temp' as $$
  select exists (select 1 from public.requests r where r.id = p_request_id
    and (public.can_see_company(r.company_id) or r.created_by_id = public.qy_me()));
$$;
create policy qy_sel_requests_own on public.requests for select using (created_by_id = public.qy_me());
create policy qy_upd_requests_own on public.requests for update using (created_by_id = public.qy_me()) with check (created_by_id = public.qy_me());
