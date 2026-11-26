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
    -- BIN2: xếp tên theo mã ký tự như DuckDB, để chọn cùng một thành phố khi hoà
    row_number() over (partition by zip_prefix
                       order by n desc, best_src, state, city collate Latin1_General_100_BIN2) as rk,
    count(*) over (partition by zip_prefix) as variant_count
  from pairs p
),
state_variants as (
  select zip_prefix, count(distinct state) as state_count from pairs group by zip_prefix
),
coords as (
  -- Chỉ lấy toạ độ nằm trong khung gần đúng của Brazil (không phải đường biên giới chính xác)
  -- PERCENTILE_CONT(0.5) là trung vị; T-SQL chỉ có dạng hàm cửa sổ nên dùng distinct để còn một dòng mỗi mã
  select distinct zip_prefix,
         percentile_cont(0.5) within group (order by lat) over (partition by zip_prefix) as lat,
         percentile_cont(0.5) within group (order by lng) over (partition by zip_prefix) as lng
  from {{ ref('stg_geolocation') }}
  where zip_prefix is not null
    and lat between -34 and 6 and lng between -74 and -34
)
select
  z.zip_prefix,
  'BR'                                as country_code,
  r.state                             as state_code,
  r.city                              as city_normalized,
  r.city + N' - ' + r.state            as city_state_label,
  cast(round(c.lat, 7) as decimal(10, 7)) as latitude,
  cast(round(c.lng, 7) as decimal(10, 7)) as longitude,
  coalesce(r.variant_count, 0)        as variant_count,
  cast(case when r.variant_count > 1 then 1 else 0 end as smallint) as location_conflict_flag,
  cast(case when sv.state_count > 1 then 1 else 0 end as smallint)  as state_conflict_flag,
  case when c.zip_prefix is null then 'NO_VALID_COORD' else 'MEDIAN_OF_VALID' end as coordinate_quality_code
from zips z
left join ranked r          on r.zip_prefix = z.zip_prefix and r.rk = 1
left join state_variants sv on sv.zip_prefix = z.zip_prefix
left join coords c          on c.zip_prefix = z.zip_prefix
