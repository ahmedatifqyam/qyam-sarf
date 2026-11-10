#!/usr/bin/env python3
# يفحص أن لا أوامر مضمّنة (onclick=...) وأن كل data-on-*="fn" تشير إلى دالة موجودة
import re, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
js = (root/'app.js').read_text(encoding='utf-8'); html = (root/'index.html').read_text(encoding='utf-8')
bad = re.findall(r'\son(?:click|change|input|submit|keydown|keyup|load|error)\s*=\s*["\']', js+html)
names = set(re.findall(r'data-on-[a-z]+="([A-Za-z_$][\w$]*)"', js+html))
defined = set(re.findall(r'(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(', js)) | set(re.findall(r'window\.([A-Za-z_$][\w$]*)\s*=', js))
missing = sorted(n for n in names if n not in defined)
if bad or missing:
    print('مشاكل:', 'أوامر مضمّنة' if bad else '', 'دوال مفقودة: '+', '.join(missing) if missing else ''); sys.exit(1)
print('سليم: لا أوامر مضمّنة، وكل الأوامر تشير إلى دوال موجودة')
