#!/usr/bin/env python3
# ساعات العمل المعروضة لمالك النظام (تُكتب في app.js عند كل نشر):
#   350 ساعة حتى 14-11-2026 00:24 (بتوقيت الكويت) باتفاق المالك،
#   + وقت كل محادثة عمل بعدها × 1.25 (25% زيادة لوقت التجربة).
# وقت المحادثة يُقاس من سجل الجلسة المحلي (~/.claude/projects/*/*.jsonl): الوقت بين الرسالة والرد محسوب كاملاً (حتى 3 ساعات)،
# وبين الرد والرسالة التالية إن لم يتجاوز 45 دقيقة. ويُحفظ قياس كل جلسة في tools/work_log.json فيبقى عبر الجلسات.
import json, re, pathlib, sys, glob, os, datetime
root = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parent.parent)
logp = root/'tools'/'work_log.json'
log = json.loads(logp.read_text(encoding='utf-8')) if logp.exists() else {}
log.setdefault('baseline', {'hours':350, 'at':'2026-11-13T21:24:00+00:00', 'since':'2026-09-05'})
log.setdefault('factor', 1.25); log.setdefault('sessions', {})
B = datetime.datetime.fromisoformat(log['baseline']['at']).timestamp()
GAP, CAP = 45*60, 3*3600
for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
    ms = []
    for line in open(f, encoding='utf-8', errors='ignore'):
        try: o = json.loads(line)
        except Exception: continue
        t = o.get('timestamp'); k = o.get('type')
        if not t or k not in ('user','assistant'): continue
        ts = datetime.datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()
        if ts >= B: ms.append((ts, k))
    ms.sort()
    tot = sum(b[0]-a[0] for a, b in zip(ms, ms[1:]) if (b[0]-a[0] <= GAP) or (a[1]=='user' and b[1]=='assistant' and b[0]-a[0] <= CAP))
    if tot > 0: log['sessions'][pathlib.Path(f).stem] = round(tot/3600, 2)
extra = round(sum(log['sessions'].values()) * log['factor'], 1)
total = round(log['baseline']['hours'] + extra)
logp.write_text(json.dumps(log, ensure_ascii=False, indent=1), encoding='utf-8')
line = f"const APP_WORK = {{hours:{total}, base:{log['baseline']['hours']}, extra:{extra}, at:'{log['baseline'].get('label', log['baseline']['at'][:10])}', since:'{log['baseline']['since']}'}};"
p = root/'app.js'; s = p.read_text(encoding='utf-8')
s2 = re.sub(r"const APP_WORK = \{[^\n]*\};", line, s, count=1)
if 'const APP_WORK = ' not in s: sys.exit('APP_WORK line missing')
p.write_text(s2, encoding='utf-8'); print(line)
