import re, os
os.chdir('/tmp/claude-0/-home-claude/812b2f5d-a9cd-59fb-aa6b-9fd761132019/scratchpad')
D='ddl/'
txt=open(D+'01_tables.sql',encoding='utf-8').read()
cons=open(D+'02_cons.sql',encoding='utf-8').read()
funcs=open(D+'03_funcs.sql',encoding='utf-8').read()
rest=open(D+'04_rest.sql',encoding='utf-8').read()
create_blocks=re.findall(r'create table if not exists public\.[^\n]+\n(?:  [^\n]*\n)*\);', txt)
addcols=re.findall(r'^alter table public\.[^\n]+;$', txt, re.M)
print('tables',len(create_blocks),'addcols',len(addcols))
owns=[('beneficiaries_master','id'),('request_beneficiaries','id'),('request_history','id'),('push_outbox','id'),('gateway_agents','id'),('gateway_imports','id'),('center_ledger','id'),('gl_exports','id')]
seqs=[t+'_'+c+'_seq' for t,c in owns]
fparts=funcs.split('\n--FUNCACL\n')
fdefs=fparts[0].replace('--DDL3 functions\n','')
facl=fparts[1]
qyme=re.search(r'CREATE OR REPLACE FUNCTION public\.qy_me\(\).*?\$function\$\n;', fdefs, re.S).group(0)
cons_body=cons.replace('--DDL2\n','')
pk_uc, rest_c = cons_body.split('\n--FK\n')
fk, idx = rest_c.split('\n--IDX\n')
def hdr(n,d): return f'''-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — بناء قاعدة البيانات من الصفر — الجزء {n} من ٣
-- ║  {d}
-- ║  مستخرج آلياً من قاعدة التجربة في 16 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
'''
p1=hdr('١','الإضافات والجداول والأعمدة والقيود والفهارس')+'''-- شغّله في قاعدة Supabase فارغة (أو قائمة لتحديثها). لا يحتوي أي بيانات.
set check_function_bodies = off;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
do $n$ begin create extension if not exists pg_net; exception when others then raise notice 'تعذر تفعيل pg_net (إشعارات الجهاز): %', sqlerrm; end $n$;
do $e$ begin create extension if not exists pg_cron; exception when others then raise notice 'فعّل pg_cron من Database ← Extensions ثم أعد تشغيل الجزء ٣: %', sqlerrm; end $e$;

-- دالة هوية المستخدم الحالي (تحتاجها قيمة افتراضية في بعض الجداول)
'''+qyme+'\n\n-- ═══ التسلسلات ═══\n'+'\n'.join(f'create sequence if not exists public.{s};' for s in seqs)+'\n\n-- ═══ الجداول ═══\n'+'\n'.join(create_blocks)+'\n\n-- ═══ الأعمدة (لتحديث قاعدة قائمة: تضيف الناقص فقط) ═══\n'+'\n'.join(addcols)+'\n\n'+'\n'.join(f'alter sequence public.{s} owned by public.{t}.{c};' for s,(t,c) in zip(seqs,owns))+'\n\n-- ═══ المفاتيح والقيود ═══\n'+pk_uc+'\n\n-- ═══ المفاتيح الأجنبية ═══\n'+fk+'\n\n-- ═══ الفهارس ═══\n'+idx+'\n'
nf=fdefs.count('CREATE OR REPLACE FUNCTION')
p2=hdr('٢','الدوال ('+str(nf)+' دالة)')+'set check_function_bodies = off;\n\n'+fdefs+'\n\n-- ═══ صلاحيات تنفيذ الدوال ═══\n'+facl+'\n'
r=rest.replace('--DDL4 triggers\n','')
trg, r = r.split('\n--RLS\n'); rls, r = r.split('\n--POLICIES\n'); pol, r = r.split('\n--GRANTS\n'); gr, r = r.split('\n--STORAGE\n'); sto, r = r.split('\n--CRON\n'); cron, r = r.split('\n--SETTINGS_KEYS')
boot=open('/root/.claude/projects/-home-claude/812b2f5d-a9cd-59fb-aa6b-9fd761132019/tool-results/mcp-Google_Drive-blob-1794850314832-1bxbwl.txt',encoding='utf-8').read()
boot=boot[boot.index('-- ═════════════ ١٢)'):boot.index('-- ═════════════ تحقق نهائي')]
cronlines=[]
for l in cron.strip().split('\n'):
    a,b=l.split('; select cron.schedule')
    cronlines.append('  perform '+a[len('select '):]+';\n  perform cron.schedule'+b)
p3=hdr('٣','المشغّلات والحماية والسياسات والصلاحيات والتخزين والمهام والإعدادات')+'set check_function_bodies = off;\n\n-- ═══ المشغّلات ═══\n'+trg+'\n\n-- ═══ حماية الصفوف ═══\n'+rls+'\n\n-- ═══ السياسات ═══\n'+pol+'\n\n-- ═══ صلاحيات الجداول ═══\n'+gr+'\n\n-- ═══ مجلد المرفقات الخاص ═══\n'+sto+'\n\n-- ═══ المهام المجدولة (بتوقيت UTC) ═══\ndo $cr$ begin\n'+'\n'.join(cronlines)+'''
exception when others then raise notice 'تعذرت جدولة المهام (فعّل pg_cron ثم أعد تشغيل هذا القسم): %', sqlerrm; end $cr$;

-- ═══ الإعدادات الافتراضية ═══
insert into public.app_settings(key, value) values
  ('system_name', 'ميزان القيم'),
  ('unit_types', '[{"id":"center","name":"مركز","icon":"🏫"},{"id":"department","name":"إدارة","icon":"🗂"},{"id":"section","name":"قسم","icon":"📂"},{"id":"branch","name":"فرع","icon":"🏢"}]'),
  ('rec_categories', '{"out":[],"in":[]}'),
  ('server_rules', 'on'),
  ('verify_level', '4'),
  ('migr_gm', '1')
on conflict (key) do nothing;
insert into public.bottom_bar_toggles(button_key, visible) values ('rebuild_path', true) on conflict (button_key) do nothing;

'''+boot.replace('القسم ١٢','قسم أول مدير')+'''
-- ═══ تحقق نهائي ═══
-- المتوقع (كقاعدة التجربة في 16 نوفمبر): tables=58 ، tables_without_rls=0 ، functions='''+str(nf)+''' ، triggers=46 ، policies=120 ، cron_jobs=6
select
  (select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r') as tables,
  (select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r' and not c.relrowsecurity) as tables_without_rls,
  (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')) as functions,
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid where c.relnamespace='public'::regnamespace and not t.tgisinternal) as triggers,
  (select count(*) from pg_policies where schemaname in ('public','storage')) as policies;
'''
os.makedirs('build',exist_ok=True)
for name,body in [('p1.sql',p1),('p2.sql',p2),('p3.sql',p3)]:
    open('build/'+name,'w',encoding='utf-8').write(body); print(name,len(body))
