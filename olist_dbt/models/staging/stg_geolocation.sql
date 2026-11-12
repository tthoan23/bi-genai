-- Bảng toạ độ có khoảng 26% dòng trùng hoàn toàn: bỏ trùng ngay ở đây.
-- Việc gộp về một dòng cho mỗi mã bưu chính làm ở bước sau (intermediate).
select distinct
  {{ norm_zip('geolocation_zip_code_prefix') }} as zip_prefix,
  {{ safe_num('geolocation_lat', 7) }}          as lat,
  {{ safe_num('geolocation_lng', 7) }}          as lng,
  {{ norm_city('geolocation_city') }}           as city,
  nullif(upper(trim(geolocation_state)), '')    as state
from {{ source('olist', 'geolocation') }}
