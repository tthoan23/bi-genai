-- Một dòng cho mỗi khách thật (customer_unique_id). Địa chỉ không đặt ở đây mà gắn theo từng đơn trên fact.
-- Dòng khoá 0 là "Unknown" cho fact không tìm được khách. SCD Type 1.
select 0::bigint as customer_key, 'UNKNOWN' as customer_unique_id, 'olist_kaggle' as source_system,
       null::timestamp as dw_created_at, current_timestamp::timestamp as dw_updated_at
union all
select k.customer_key, k.customer_unique_id, 'olist_kaggle', k.dw_created_at, current_timestamp::timestamp
from {{ ref('km_customer') }} k
