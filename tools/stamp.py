#!/usr/bin/env python3
# يختم index.html برقم نسخة app.js (بصمة المحتوى) حتى لا يعلق المتصفح على نسخة قديمة
import hashlib, re, pathlib, sys
root = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parent.parent)
h = hashlib.sha1((root/'app.js').read_bytes()).hexdigest()[:10]
p = root/'index.html'; s = p.read_text(encoding='utf-8')
s2 = re.sub(r'app\.js\?v=[0-9a-f]+', 'app.js?v='+h, s)
p.write_text(s2, encoding='utf-8'); print('app.js?v='+h)
