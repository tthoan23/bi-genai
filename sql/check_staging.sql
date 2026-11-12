-- Kiểm tra bước 3: các view stg_* do dbt tạo đã đúng chưa.

-- 1) Số dòng: bảng thô (Mage nạp) so với view stg_* (dbt làm sạch)
select 'orders' as bang, (select count(*) from staging.orders) as dong_tho, (select count(*) from staging.stg_orders) as dong_stg
union all select 'customers', (select count(*) from staging.customers), (select count(*) from staging.stg_customers)
union all select 'order_items', (select count(*) from staging.order_items), (select count(*) from staging.stg_order_items)
union all select 'order_reviews', (select count(*) from staging.order_reviews), (select count(*) from staging.stg_order_reviews)
union all select 'order_payments', (select count(*) from staging.order_payments), (select count(*) from staging.stg_order_payments)
union all select 'products', (select count(*) from staging.products), (select count(*) from staging.stg_products)
union all select 'sellers', (select count(*) from staging.sellers), (select count(*) from staging.stg_sellers)
union all select 'geolocation', (select count(*) from staging.geolocation), (select count(*) from staging.stg_geolocation)
union all select 'category_translation', (select count(*) from staging.category_translation), (select count(*) from staging.stg_category_translation);

-- 2) Kiểu dữ liệu đã đổi: một đơn hàng mẫu (thời điểm là timestamp, không còn là chữ)
select order_id, order_status, purchase_ts, delivered_ts, estimated_ts
from staging.stg_orders order by purchase_ts limit 3;

-- 3) Số giá trị đọc không được (mong đợi 0)
select sum(purchase_ts_parse_error) as loi_ngay_mua,
       sum(delivered_ts_parse_error) as loi_ngay_nhan,
       (select sum(price_parse_error) from staging.stg_order_items) as loi_gia
from staging.stg_orders;
