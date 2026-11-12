-- T06: duration hợp lệ không âm; delivery = approval + handling + transit khi đủ mọi mốc
select order_id
from {{ ref('fact_order_experience') }}
where approval_seconds < 0 or handling_seconds < 0 or transit_seconds < 0 or delivery_seconds < 0
   or (approval_seconds is not null and handling_seconds is not null and transit_seconds is not null
       and delivery_seconds <> approval_seconds + handling_seconds + transit_seconds)
