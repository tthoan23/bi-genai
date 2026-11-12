-- Một dòng cho mỗi người bán.
with src as (
  select s.*,
         row_number() over (partition by trim(s.seller_id)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'sellers') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.seller_id), '') is not null
)
select
  trim(seller_id)                          as seller_id,
  {{ norm_zip('seller_zip_code_prefix') }} as zip_prefix,
  {{ norm_city('seller_city') }}           as city,
  nullif(upper(trim(seller_state)), '')    as state,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
