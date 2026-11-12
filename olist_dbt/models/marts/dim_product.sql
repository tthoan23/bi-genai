-- Một dòng cho mỗi sản phẩm; danh mục gộp thẳng vào đây (star, không snowflake). SCD Type 1.
-- Không có danh mục -> 'Missing Category'; có danh mục nhưng chưa có bản dịch -> giữ tên gốc và gắn cờ.
select 0 as product_key, 'UNKNOWN' as product_id,
       'Unknown' as category_name_original, 'Unknown' as category_name_english,
       null::decimal(18, 3) as product_weight_g, null::decimal(18, 3) as product_length_cm,
       null::decimal(18, 3) as product_height_cm, null::decimal(18, 3) as product_width_cm,
       1::smallint as missing_category_flag, 1::smallint as missing_translation_flag,
       current_timestamp::timestamp as dw_updated_at
union all
select
  k.product_key::int,
  p.product_id,
  coalesce(p.category_name, 'Missing Category'),
  case when p.category_name is null then 'Missing Category'
       when t.category_name_english is null then p.category_name
       else t.category_name_english end,
  p.product_weight_g, p.product_length_cm, p.product_height_cm, p.product_width_cm,
  (case when p.category_name is null then 1 else 0 end)::smallint,
  (case when p.category_name is not null and t.category_name_english is null then 1 else 0 end)::smallint,
  current_timestamp::timestamp
from {{ ref('km_product') }} k
join {{ ref('stg_products') }} p on p.product_id = k.product_id
left join {{ ref('stg_category_translation') }} t on t.category_name = p.category_name
