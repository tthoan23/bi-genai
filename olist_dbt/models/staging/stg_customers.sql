-- Một dòng cho mỗi customer_id (mỗi đơn có một customer_id riêng; khách thật là customer_unique_id).
with src as (
  select s.*,
         row_number() over (partition by trim(s.customer_id)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'customers') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.customer_id), '') is not null
)
select
  trim(customer_id)                          as customer_id,
  trim(customer_unique_id)                   as customer_unique_id,
  {{ norm_zip('customer_zip_code_prefix') }} as zip_prefix,
  {{ norm_city('customer_city') }}           as city,
  nullif(upper(trim(customer_state)), '')    as state,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
