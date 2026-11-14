-- ترتيب يدوي للوحدات (المراكز والبنود) بالسحب والإفلات بين الإخوة؛ الفارغ يأتي آخراً بالترتيب الأبجدي
alter table public.centers add column if not exists sort integer;
