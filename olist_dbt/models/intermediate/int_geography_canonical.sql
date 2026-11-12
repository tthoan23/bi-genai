-- Một dòng cho mỗi mã bưu chính.
-- Thành phố, bang: lấy cặp xuất hiện nhiều nhất (gộp từ khách, người bán, bảng toạ độ);
-- bằng nhau thì ưu tiên khách, rồi người bán. Toạ độ: trung vị các toạ độ hợp lệ.
with decl as (
  select zip_prefix, state, city, 1 as src_rank from {{ ref('stg_customers') }}
  union all
  select zip_prefix, state, city, 2 from {{ ref('stg_sellers') }}
  union all
  select zip_prefix, state, city, 3 from {{ ref('stg_geolocation') }}
),
zips as (
  select distinct zip_prefix from decl where zip_prefix is not null
),
pairs as (
  select zip_prefix, state, city, count(*) as n, min(src_rank) as best_src
  from decl
  where zip_prefix is not null and state is not null and city is not null
  group by zip_prefix, state, city
),
ranked as (
  select
    p.*,
    row_number() over (partition by zip_prefix order by n desc, best_src, state, city) as rk,
    count(*) over (partition by zip_prefix) as variant_count
  from pairs p
),
state_variants as (
  select zip_prefix, count(distinct state) as state_count from pairs group by zip_prefix
),
coords as (
  -- Chỉ lấy toạ độ nằm trong khung gần đúng của Brazil (không phải đường biên giới chính xác)
  select zip_prefix, median(lat) as lat, median(lng) as lng
  from {{ ref('stg_geolocation') }}
  where zip_prefix is not null
    and lat between -34 and 6 and lng between -74 and -34
  group by zip_prefix
)
select
  z.zip_prefix,
  'BR'                                as country_code,
  r.state                             as state_code,
  r.city                              as city_normalized,
  r.city || ' - ' || r.state          as city_state_label,
  round(c.lat, 7)::decimal(10, 7)     as latitude,
  round(c.lng, 7)::decimal(10, 7)     as longitude,
  coalesce(r.variant_count, 0)::int   as variant_count,
  (case when r.variant_count > 1 then 1 else 0 end)::smallint as location_conflict_flag,
  (case when sv.state_count > 1 then 1 else 0 end)::smallint  as state_conflict_flag,
  case when c.zip_prefix is null then 'NO_VALID_COORD' else 'MEDIAN_OF_VALID' end as coordinate_quality_code
from zips z
left join ranked r          on r.zip_prefix = z.zip_prefix and r.rk = 1
left join state_variants sv on sv.zip_prefix = z.zip_prefix
left join coords c          on c.zip_prefix = z.zip_prefix
