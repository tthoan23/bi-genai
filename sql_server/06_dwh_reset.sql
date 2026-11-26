-- Xoá toàn bộ bảng kho (dwh) để làm lại từ đầu: khoá thay thế sẽ được cấp lại.
-- Chỉ dùng khi phát triển. Sau đó chạy lại 06_dwh_tables.sql.
USE OlistDW;
GO
DROP TABLE IF EXISTS dwh.fact_order_item, dwh.fact_order_experience,
    dwh.dim_geography, dwh.dim_product, dwh.dim_seller, dwh.dim_customer,
    dwh.dim_delivery_outcome, dwh.dim_order_status, dwh.dim_date;
GO
