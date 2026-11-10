#!/usr/bin/env python3
# يبني موقع الاختبار من المصدر: يبدّل قاعدة البيانات إلى الاختبار واسم التطبيق، ثم يختم النسخة
import pathlib, shutil, subprocess, sys
src = pathlib.Path(__file__).resolve().parent.parent; dst = pathlib.Path(sys.argv[1])
for f in ['app.js','index.html','sw.js','user-guide.html','manifest.webmanifest']: shutil.copy2(src/f, dst/f)
shutil.copytree(src/'icons', dst/'icons', dirs_exist_ok=True)
a = (dst/'app.js').read_text(encoding='utf-8').split('\n')
a[0] = "const SUPABASE_URL = 'https://xisaigwntqeowathxpsr.supabase.co';"
a[1] = "const SUPABASE_ANON_KEY = 'sb_publishable_xjXn7s_Jn8U3uVttzEgUFw_pGK5XJwH';"
(dst/'app.js').write_text('\n'.join(a), encoding='utf-8')
m = (dst/'manifest.webmanifest').read_text(encoding='utf-8').replace('"name": "نظام الصرف"','"name": "نظام الصرف — تجريبي"').replace('"short_name": "نظام الصرف"','"short_name": "صرف تجريبي"')
(dst/'manifest.webmanifest').write_text(m, encoding='utf-8')
out = subprocess.run([sys.executable, str(src/'tools'/'stamp.py'), str(dst)], capture_output=True, text=True).stdout.strip()
print('test site written,', out)
