-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-١٩ (1.50.0): طلب نيابةً عن موظف (لمدير النظام).
--   الطلب يُنسب للموظف (منشئه created_by_id، ومساره من مديره، وبند وحدته)، لكن يبقى أثر واضح:
--   on_behalf_by_id/name = من أنشأه فعلاً. يضبطهما الخادم وحده عند الإنشاء، ولا يتغيران بعده.
--   ويصل إشعار للموظف بأن طلباً أُنشئ باسمه.
--   (إنشاء طلب باسم غيرك مسموح أصلاً لمدير النظام فقط في qy_requests_ins_guard.)
-- يُشغَّل بعد بناء-١..١٨. آمن للتكرار (idempotent).
-- الحالة: جاهز وغير مُطبَّق بعد على قاعدة التجربة (ينتظر موافقة المستخدم).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.requests add column if not exists on_behalf_by_id text;
alter table public.requests add column if not exists on_behalf_by_name text;

create or replace function public.qy_req_onbehalf_set()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare me text;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then return new; end if;        -- استيراد من الخادم: كما أُرسل
    me := public.qy_me();
    if new.created_by_id is distinct from me then
      new.on_behalf_by_id := me;
      new.on_behalf_by_name := (select name from public.users where id = me);
    else
      new.on_behalf_by_id := null; new.on_behalf_by_name := null;
    end if;
  else
    new.on_behalf_by_id := old.on_behalf_by_id; new.on_behalf_by_name := old.on_behalf_by_name;   -- لا يتغير بعد الإنشاء
  end if;
  return new;
end $$;
drop trigger if exists qy_req_onbehalf_t on public.requests;
create trigger qy_req_onbehalf_t before insert or update on public.requests for each row execute function public.qy_req_onbehalf_set();

create or replace function public.qy_req_onbehalf_notify()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.on_behalf_by_id is not null then
    perform public.qy_push_enqueue(array[new.created_by_id], 'أُنشئ طلب باسمك',
      coalesce(new.on_behalf_by_name,'مدير النظام') || ' أنشأ نيابةً عنك: ' || coalesce(new.reason,''), 'onbehalf', new.id, 'onbehalf', now());
  end if;
  return new;
end $$;
drop trigger if exists qy_req_onbehalf_notify_t on public.requests;
create trigger qy_req_onbehalf_notify_t after insert on public.requests for each row execute function public.qy_req_onbehalf_notify();
