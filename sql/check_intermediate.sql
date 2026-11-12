-- Kiểm tra bước 4a: tầng intermediate và các bảng khoá thay thế.

-- 1) Số dòng các bảng khoá (mỗi khoá nghiệp vụ một khoá thay thế)
select 'km_order' as bang, count(*) as so_dong from dwh.km_order
union all select 'km_order_item', count(*) from dwh.km_order_item
union all select 'km_customer', count(*) from dwh.km_customer
union all select 'km_product', count(*) from dwh.km_product
union all select 'km_seller', count(*) from dwh.km_seller
union all select 'km_geography', count(*) from dwh.km_geography;

-- 2) Giao hàng: số đơn đã giao, đủ điều kiện xét, trễ, tỷ lệ trễ (mong đợi 96.478 / 96.470 / 6.534 / 6,77%)
select sum(delivered_count) as da_giao,
       sum(delivery_eligible_count) as du_dieu_kien,
       sum(late_count) as tre,
       round(100.0 * sum(late_count) / sum(delivery_eligible_count), 2) as ty_le_tre_pct
from intermediate.int_order_timeline;

-- 3) Phân bố kết quả giao
select outcome_code, count(*) as so_don from intermediate.int_order_timeline group by 1 order by 2 desc;

-- 4) Đánh giá đại diện (mong đợi 98.673 đơn có đánh giá) và lệch thanh toán (mong đợi 303 và 249)
select (select count(*) from intermediate.int_order_review_representative) as don_co_danh_gia,
       (select round(avg(representative_review_score), 2) from intermediate.int_order_review_representative) as diem_tb,
       (select sum(mismatch_gt_threshold) from intermediate.int_order_payment_reconciliation) as lech_tren_001_brl,
       (select sum(mismatch_gt_1brl) from intermediate.int_order_payment_reconciliation) as lech_tren_1_brl;

-- 5) Mã bưu chính: tổng số, số mã có nhiều tên thành phố, nhiều bang (mong đợi 19.177 / 682 / 41)
select count(*) as so_ma, sum(location_conflict_flag) as ma_nhieu_ten_tp, sum(state_conflict_flag) as ma_nhieu_bang
from intermediate.int_geography_canonical;
