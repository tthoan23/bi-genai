-- Vòng đời của mỗi đơn: cờ sai thứ tự mốc, đủ điều kiện xét giao, đúng hạn hay trễ, thời gian từng bước.
with o as (
  select * from {{ ref('stg_orders') }}
),
flags as (
  select
    o.*,
    (case when order_status = 'delivered' then 1 else 0 end)::smallint as delivered_count,
    (case when approved_ts  < purchase_ts then 1 else 0 end)::smallint as invalid_approval_sequence,
    (case when carrier_ts   < approved_ts then 1 else 0 end)::smallint as invalid_handling_sequence,
    (case when delivered_ts < carrier_ts  then 1 else 0 end)::smallint as invalid_transit_sequence,
    (case when delivered_ts < purchase_ts then 1 else 0 end)::smallint as invalid_delivery_sequence,
    (case when estimated_ts::date < purchase_ts::date then 1 else 0 end)::smallint as invalid_estimated_date
  from o
),
elig as (
  select
    f.*,
    -- Đủ điều kiện xét giao: đã giao, có đủ ngày mua, ngày nhận, ngày dự kiến, và hai ngày sau không trước ngày mua
    (case when delivered_count = 1
           and purchase_ts is not null and delivered_ts is not null and estimated_ts is not null
           and delivered_ts::date >= purchase_ts::date
           and estimated_ts::date >= purchase_ts::date
          then 1 else 0 end)::smallint as delivery_eligible_count
  from flags f
)
select
  e.*,
  -- So theo ngày (ngày dự kiến trong dữ liệu luôn là 00:00:00): ngày nhận sau ngày dự kiến là trễ
  (case when delivery_eligible_count = 1 and delivered_ts::date >  estimated_ts::date then 1 else 0 end)::smallint as late_count,
  (case when delivery_eligible_count = 1 and delivered_ts::date <= estimated_ts::date then 1 else 0 end)::smallint as on_time_count,
  case when delivery_eligible_count = 1
       then greatest(0, date_diff('day', estimated_ts::date, delivered_ts::date)) end as late_days,
  -- Thời gian từng bước (giây). Thiếu mốc hoặc sai thứ tự thì để trống, không thay bằng 0.
  case when approved_ts  >= purchase_ts then date_diff('second', purchase_ts, approved_ts)  end as approval_seconds,
  case when carrier_ts   >= approved_ts then date_diff('second', approved_ts, carrier_ts)   end as handling_seconds,
  case when delivered_ts >= carrier_ts  then date_diff('second', carrier_ts, delivered_ts)  end as transit_seconds,
  case when delivered_ts >= purchase_ts then date_diff('second', purchase_ts, delivered_ts) end as delivery_seconds,
  case
    when delivery_eligible_count = 0 then 'NOT_ELIGIBLE'
    when delivered_ts::date <= estimated_ts::date then 'ON_TIME'
    when date_diff('day', estimated_ts::date, delivered_ts::date) <= 3 then 'LATE_1_3'
    when date_diff('day', estimated_ts::date, delivered_ts::date) <= 7 then 'LATE_4_7'
    else 'LATE_GT7'
  end as outcome_code,
  -- Số quy tắc chất lượng bị vi phạm của đơn (không phải số đơn lỗi)
  (invalid_approval_sequence + invalid_handling_sequence + invalid_transit_sequence
   + invalid_delivery_sequence + invalid_estimated_date
   + purchase_ts_parse_error + approved_ts_parse_error + carrier_ts_parse_error
   + delivered_ts_parse_error + estimated_ts_parse_error)::int as quality_issue_count
from elig e
