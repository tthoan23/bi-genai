-- Lịch liên tục từ ngày nhỏ nhất đến lớn nhất xuất hiện trong dữ liệu, cộng 3 dòng đặc biệt (0, -1, -2).
-- SCD Type 0: thuộc tính của một ngày không bao giờ đổi.
with all_dates as (
  select purchase_ts::date  as d from {{ ref('stg_orders') }}
  union all select approved_ts::date  from {{ ref('stg_orders') }}
  union all select carrier_ts::date   from {{ ref('stg_orders') }}
  union all select delivered_ts::date from {{ ref('stg_orders') }}
  union all select estimated_ts::date from {{ ref('stg_orders') }}
  union all select review_creation_ts::date from {{ ref('stg_order_reviews') }}
  union all select review_answer_ts::date   from {{ ref('stg_order_reviews') }}
  union all select shipping_limit_ts::date  from {{ ref('stg_order_items') }}
),
bounds as (
  select min(d) as mn, max(d) as mx from all_dates where d is not null
),
cal as (
  select unnest(generate_series(mn::timestamp, mx::timestamp, interval 1 day))::date as full_date from bounds
)
select
  strftime(full_date, '%Y%m%d')::int as date_key,
  full_date,
  day(full_date)::smallint            as day_of_month,
  isodow(full_date)::smallint         as day_of_week_number,
  strftime(full_date, '%A')           as day_of_week_name,
  month(full_date)::smallint          as month_number,
  strftime(full_date, '%B')           as month_name,
  strftime(full_date, '%Y-%m')        as year_month,
  quarter(full_date)::smallint        as quarter_number,
  year(full_date)::varchar || '-Q' || quarter(full_date)::varchar as year_quarter,
  year(full_date)::smallint           as calendar_year,
  'Calendar'                          as member_type
from cal
union all
select v.date_key, null, null, null, null, null, null, null, null, null, null, v.member_type
from (values (0, 'Unknown'), (-1, 'Not yet happened'), (-2, 'Invalid date')) as v(date_key, member_type)
