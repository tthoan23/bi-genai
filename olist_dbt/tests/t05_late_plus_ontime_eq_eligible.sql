-- T05: late + on_time = eligible trên mỗi dòng
select order_id
from {{ ref('fact_order_experience') }}
where late_count + on_time_count <> delivery_eligible_count
