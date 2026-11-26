-- Vòng đời của mỗi đơn: cờ sai thứ tự mốc, đủ điều kiện xét giao, đúng hạn hay trễ, thời gian từng bước.
with o as (
  select * from {{ ref('stg_orders') }}
),
flags as (
  select
    o.*,
    cast(case when order_status = 'delivered' then 1 else 0 end as smallint) as delivered_count,
    cast(case when approved_ts  < purchase_ts then 1 else 0 end as smallint) as invalid_approval_sequence,
    cast(case when carrier_ts   < approved_ts then 1 else 0 end as smallint) as invalid_handling_sequence,
    cast(case when delivered_ts < carrier_ts  then 1 else 0 end as smallint) as invalid_transit_sequence,
    cast(case when delivered_ts < purchase_ts then 1 else 0 end as smallint) as invalid_delivery_sequence,
    cast(case when cast(estimated_ts as date) < cast(purchase_ts as date) then 1 else 0 end as smallint) as invalid_estimated_date
  from o
),
elig as (
  select
    f.*,
    -- Đủ điều kiện xét giao: đã giao, có đủ ngày mua, ngày nhận, ngày dự kiến, và hai ngày sau không trước ngày mua
    cast(case when delivered_count = 1
           and purchase_ts is not null and delivered_ts is not null and estimated_ts is not null
           and cast(delivered_ts as date) >= cast(purchase_ts as date)
           and cast(estimated_ts as date) >= cast(purchase_ts as date)
          then 1 else 0 end as smallint) as delivery_eligible_count
  from flags f
)
select
  e.*,
  -- So theo ngày (ngày dự kiến trong dữ liệu luôn là 00:00:00): ngày nhận sau ngày dự kiến là trễ
  cast(case when delivery_eligible_count = 1 and cast(delivered_ts as date) >  cast(estimated_ts as date) then 1 else 0 end as smallint) as late_count,
  cast(case when delivery_eligible_count = 1 and cast(delivered_ts as date) <= cast(estimated_ts as date) then 1 else 0 end as smallint) as on_time_count,
  case when delivery_eligible_count = 1
       then case when datediff(day, cast(estimated_ts as date), cast(delivered_ts as date)) > 0
                 then datediff(day, cast(estimated_ts as date), cast(delivered_ts as date)) else 0 end end as late_days,
  -- Thời gian từng bước (giây). Thiếu mốc hoặc sai thứ tự thì để trống, không thay bằng 0.
  case when approved_ts  >= purchase_ts then datediff(second, purchase_ts, approved_ts)  end as approval_seconds,
  case when carrier_ts   >= approved_ts then datediff(second, approved_ts, carrier_ts)   end as handling_seconds,
  case when delivered_ts >= carrier_ts  then datediff(second, carrier_ts, delivered_ts)  end as transit_seconds,
  case when delivered_ts >= purchase_ts then datediff(second, purchase_ts, delivered_ts) end as delivery_seconds,
  case
    when delivery_eligible_count = 0 then 'NOT_ELIGIBLE'
    when cast(delivered_ts as date) <= cast(estimated_ts as date) then 'ON_TIME'
    when datediff(day, cast(estimated_ts as date), cast(delivered_ts as date)) <= 3 then 'LATE_1_3'
    when datediff(day, cast(estimated_ts as date), cast(delivered_ts as date)) <= 7 then 'LATE_4_7'
    else 'LATE_GT7'
  end as outcome_code,
  -- Số quy tắc chất lượng bị vi phạm của đơn (không phải số đơn lỗi)
  -- smallint cộng nhau: T-SQL trả về int
  (0 + invalid_approval_sequence + invalid_handling_sequence + invalid_transit_sequence
   + invalid_delivery_sequence + invalid_estimated_date
   + purchase_ts_parse_error + approved_ts_parse_error + carrier_ts_parse_error
   + delivered_ts_parse_error + estimated_ts_parse_error) as quality_issue_count
from elig e
