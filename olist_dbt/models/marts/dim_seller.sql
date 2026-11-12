-- Một dòng cho mỗi người bán. Địa chỉ người bán nằm trên fact_order_item (seller_geography_key). SCD Type 1.
select 0 as seller_key, 'UNKNOWN' as seller_id, 'olist_kaggle' as source_system, current_timestamp::timestamp as dw_updated_at
union all
select k.seller_key::int, k.seller_id, 'olist_kaggle', current_timestamp::timestamp
from {{ ref('km_seller') }} k
