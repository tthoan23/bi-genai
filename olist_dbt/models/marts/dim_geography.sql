-- Một dòng cho mỗi mã bưu chính (5 chữ số), dùng cho cả địa chỉ khách và địa chỉ người bán. SCD Type 1.
select 0 as geography_key, 'UNK' as zip_prefix, 'BR' as country_code, 'UN' as state_code,
       'unknown' as city_normalized, 'Unknown' as city_state_label,
       null::decimal(10, 7) as latitude, null::decimal(10, 7) as longitude,
       0 as variant_count, 0::smallint as location_conflict_flag, 0::smallint as state_conflict_flag,
       'UNKNOWN_MEMBER' as coordinate_quality_code, current_timestamp::timestamp as dw_updated_at
union all
select k.geography_key::int, g.zip_prefix, g.country_code, g.state_code, g.city_normalized, g.city_state_label,
       g.latitude, g.longitude, g.variant_count, g.location_conflict_flag, g.state_conflict_flag,
       g.coordinate_quality_code, current_timestamp::timestamp
from {{ ref('km_geography') }} k
join {{ ref('int_geography_canonical') }} g on g.zip_prefix = k.zip_prefix
