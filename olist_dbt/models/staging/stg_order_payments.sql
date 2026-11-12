-- Một dòng cho mỗi lần thanh toán của đơn (order_id, payment_sequential).
with src as (
  select s.*,
         row_number() over (partition by trim(s.order_id), trim(s.payment_sequential)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'order_payments') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.order_id), '') is not null
)
select
  trim(order_id)                         as order_id,
  {{ safe_int('payment_sequential') }}   as payment_sequential,
  nullif(trim(payment_type), '')         as payment_type,
  {{ safe_int('payment_installments') }} as payment_installments,
  {{ safe_num('payment_value') }}        as payment_value,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
