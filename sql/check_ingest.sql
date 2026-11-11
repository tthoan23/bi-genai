-- Kiểm tra bước 2: dữ liệu đã nạp vào DuckDB chưa, có đúng số dòng không.

-- 1) Trạng thái các batch
select batch_id, batch_seq, batch_type, status, started_at from audit.etl_batch order by batch_seq;

-- 2) Các lần chạy (chạy lại cùng batch thì attempt tăng)
select run_id, batch_id, attempt, status, error_message from audit.etl_run order by run_id;

-- 3) Lần chạy gần nhất: số dòng đọc, nạp, bị loại của từng bảng
select l.table_name, l.rows_read, l.rows_loaded, l.rows_rejected, l.status
from audit.etl_step_log l
where l.run_id = (select max(run_id) from audit.etl_run) and l.step = 'ingest'
order by l.log_id;

-- 4) Số dòng thật trong từng bảng staging (tổng phải là 1.550.922)
select 'orders' as bang, count(*) as so_dong from staging.orders
union all select 'customers', count(*) from staging.customers
union all select 'order_items', count(*) from staging.order_items
union all select 'order_reviews', count(*) from staging.order_reviews
union all select 'order_payments', count(*) from staging.order_payments
union all select 'products', count(*) from staging.products
union all select 'sellers', count(*) from staging.sellers
union all select 'geolocation', count(*) from staging.geolocation
union all select 'category_translation', count(*) from staging.category_translation;
