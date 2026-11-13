#!/usr/bin/env python3
# يحسب ساعات العمل التقريبية من سجل التحديثات (git) ويكتبها في app.js
# الجلسة = تحديثات متتابعة لا يفصلها أكثر من ساعتين، ويُضاف نصف ساعة قبل كل جلسة للنقاش والتحضير.
import subprocess, re, pathlib, sys, datetime
root = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parent.parent)
if not (root/'.git').exists(): sys.exit(0)
ts = sorted(int(x) for x in subprocess.check_output(['git','-C',str(root),'log','--all','--format=%at']).split())
if not ts: sys.exit(0)
GAP, LEAD = 2*3600, 1800
tot, sess = 0, 1
for a, b in zip(ts, ts[1:]):
    if b - a <= GAP: tot += b - a
    else: sess += 1
tot += sess*LEAD
kw = datetime.timezone(datetime.timedelta(hours=3))
days = len({datetime.datetime.fromtimestamp(t, kw).date() for t in ts})
since = datetime.datetime.fromtimestamp(ts[0], kw).date().isoformat()
line = f"const APP_WORK = {{hours:{round(tot/3600)}, since:'{since}', days:{days}, updates:{len(ts)}}};"
p = root/'app.js'; s = p.read_text(encoding='utf-8')
s2 = re.sub(r"const APP_WORK = \{[^\n]*\};", line, s, count=1)
if s2 == s and 'const APP_WORK = ' not in s: sys.exit('APP_WORK line missing')
p.write_text(s2, encoding='utf-8'); print(line)
