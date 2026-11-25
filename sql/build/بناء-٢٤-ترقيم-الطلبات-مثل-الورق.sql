-- ═══════════════════════════════════════════════════════════════════════════
-- بناء-٢٤ (1.57.0): ترقيم الطلبات مثل الورق
-- ما يفعله هذا الملف بالعربي:
--   الرقم الجديد للطلب يُكتب بلا أصفار قبل التسلسل: «ش.ق.ك 52/2026» بدل «ش.ق.ك-أ-052/2026»
--   (شكل البداية نفسه — رمز الشركة أو رمز المركز ثم مسافة — تصنعه الواجهة من الإصدار 1.57.0).
--   والعدّاد يكمل بعد أعلى رقم موجود بالبداية نفسها في السنة نفسها، ولو كانت الطلبات
--   السابقة مستوردة من الورق ولم تمر بالعدّاد، فلا يبدأ من 1 من جديد.
-- الجزء (أ) بنية تُشغَّل على أي قاعدة جديدة. الجزء (ب) بيانات تجريبية لقاعدة التجربة فقط.
-- يُشغَّل بعد بناء-١..٢٣. آمن للتكرار.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ (أ) دالة الرقم التالي: بلا أصفار، وتكمل بعد أعلى رقم موجود ═══
CREATE OR REPLACE FUNCTION public.next_request_number(p_prefix text, p_suffix text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n int; mx int;
begin
  -- أعلى تسلسل مكتوب فعلاً بالبداية واللاحقة نفسيهما (يشمل المستورد من الورق والمكتوب بأصفار)
  select coalesce(max(substr(number, length(p_prefix)+1, length(number)-length(p_prefix)-length(p_suffix))::int), 0)
    into mx
    from public.requests
   where number is not null
     and left(number, length(p_prefix)) = p_prefix
     and right(number, length(p_suffix)) = p_suffix
     and length(number) > length(p_prefix) + length(p_suffix)
     and substr(number, length(p_prefix)+1, length(number)-length(p_prefix)-length(p_suffix)) ~ '^[0-9]{1,9}$';
  insert into public.request_number_counters(prefix, suffix, last_n)
  values (p_prefix, p_suffix, mx + 1)
  on conflict (prefix, suffix) do update
    set last_n = greatest(public.request_number_counters.last_n, mx) + 1
  returning last_n into n;
  return p_prefix || n::text || p_suffix;
end;
$function$;
revoke all on function public.next_request_number(p_prefix text, p_suffix text) from public, anon, authenticated;
grant execute on function public.next_request_number(p_prefix text, p_suffix text) to service_role;

-- ═══ (ب) بيانات تجريبية — قاعدة التجربة فقط ═══
-- الطلبان المُدخلان 25-11-2026 من ورقتي ش.ق.ك 52 و53 أخذا البداية القديمة «ش.ق.ك-أ-».
-- يُعاد ترقيمهما مثل الورق. لا أثر له إن لم يوجد الطلبان.
update public.requests
   set number = 'ش.ق.ك 52/2026', number_prefix = 'ش.ق.ك ', number_suffix = '/2026'
 where id = 'r1795602147821' and number = 'ش.ق.ك-أ-001/2026';
update public.requests
   set number = case when number is null then null else 'ش.ق.ك 53/2026' end,
       number_prefix = 'ش.ق.ك ', number_suffix = '/2026'
 where id = 'r1795602232925' and coalesce(number, 'ش.ق.ك-أ-002/2026') = 'ش.ق.ك-أ-002/2026';
-- عدّاد «ش.ق.ك » لسنة 2026 يقف عند أعلى رقم بعد التصحيح
insert into public.request_number_counters(prefix, suffix, last_n)
select 'ش.ق.ك ', '/2026', coalesce(max(substr(number, 7, length(number)-11)::int), 0)
  from public.requests
 where left(number, 6) = 'ش.ق.ك ' and right(number, 5) = '/2026' and substr(number, 7, length(number)-11) ~ '^[0-9]+$'
on conflict (prefix, suffix) do update set last_n = greatest(public.request_number_counters.last_n, excluded.last_n);
