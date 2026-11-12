-- T05: eligible <= delivered <= order_count; reviewed/low nhất quán
select order_id
from {{ ref('fact_order_experience') }}
where delivery_eligible_count > delivered_count
   or delivered_count > order_count
   or low_review_order_count > reviewed_order_count
   or (late_count = 1 and (late_days is null or late_days < 1))
   or (on_time_count = 1 and late_days <> 0)
   or (delivery_eligible_count = 0 and late_days is not null)
