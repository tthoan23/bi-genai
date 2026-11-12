-- Một dòng cho mỗi sản phẩm. Tên cột gốc "lenght" bị sai chính tả nên không dùng; kích thước lấy theo cm, gram.
with src as (
  select s.*,
         row_number() over (partition by trim(s.product_id)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'products') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.product_id), '') is not null
)
select
  trim(product_id)                               as product_id,
  nullif(lower(trim(product_category_name)), '') as category_name,
  {{ safe_num('product_weight_g', 3) }}  as product_weight_g,
  {{ safe_num('product_length_cm', 3) }} as product_length_cm,
  {{ safe_num('product_height_cm', 3) }} as product_height_cm,
  {{ safe_num('product_width_cm', 3) }}  as product_width_cm,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
