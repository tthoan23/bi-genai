-- Một dòng cho mỗi danh mục: tên tiếng Bồ Đào Nha và tiếng Anh.
with src as (
  select s.*,
         row_number() over (partition by lower(trim(s.product_category_name))
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'category_translation') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.product_category_name), '') is not null
)
select
  lower(trim(product_category_name))               as category_name,
  nullif(trim(product_category_name_english), '') as category_name_english
from src
where rn = 1
