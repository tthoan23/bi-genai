-- Kiểm tra bước 4b: pipeline chạy liền từ CSV tới kho, kho có đủ dimension và fact.

-- 1) Batch và lần chạy gần nhất: mong đợi SUCCESS
select batch_id, batch_seq, status from audit.etl_batch order by batch_seq;
select run_id, attempt, status, error_message from audit.etl_run order by run_id desc limit 1;

-- 2) Các bước của lần chạy gần nhất: 9 bước nạp và 163 bước dbt
select step, status, count(*) as so_buoc
from audit.etl_step_log
where run_id = (select max(run_id) from audit.etl_run)
group by 1, 2 order by 1, 2;

-- 3) Số dòng của dimension và fact (dimension có thêm 1 dòng Unknown, dim_date thêm 3 dòng đặc biệt)
select 'dim_date' as bang, count(*) as so_dong from dwh.dim_date
union all select 'dim_customer', count(*) from dwh.dim_customer
union all select 'dim_geography', count(*) from dwh.dim_geography
union all select 'dim_order_status', count(*) from dwh.dim_order_status
union all select 'dim_delivery_outcome', count(*) from dwh.dim_delivery_outcome
union all select 'dim_product', count(*) from dwh.dim_product
union all select 'dim_seller', count(*) from dwh.dim_seller
union all select 'fact_order_experience', count(*) from dwh.fact_order_experience
union all select 'fact_order_item', count(*) from dwh.fact_order_item;

-- 4) KPI tính trên fact (mong đợi: 99.441 đơn, tỷ lệ trễ 6,77%, điểm đánh giá 4,09, tiền hàng 13.591.643,70 BRL)
select sum(order_count) as tong_don,
       round(100.0 * sum(late_count) / sum(delivery_eligible_count), 2) as ty_le_tre_pct,
       round(avg(representative_review_score), 2) as diem_tb,
       (select sum(price_amount) from dwh.fact_order_item) as tien_hang_brl
from dwh.fact_order_experience;
