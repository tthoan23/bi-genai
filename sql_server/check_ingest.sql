-- Task 2: kiểm tra kết quả nạp Nguồn -> Staging trên SQL Server.
-- Chạy trong SSMS sau khi Ingest_Staging.dtsx chạy xong.
USE OlistDW;
GO

DECLARE @batch_id varchar(50) = 'FULL_001';
DECLARE @run_id int = (
    SELECT TOP (1) run_id
    FROM audit.etl_run
    WHERE batch_id = @batch_id
    ORDER BY run_id DESC
);

-- 1) Batch và lần chạy gần nhất. Batch phải ở INGESTED (SUCCESS là sau dbt).
SELECT b.batch_id, b.batch_type, b.status AS batch_status,
       r.run_id, r.attempt, r.status AS run_status, r.started_at, r.ended_at, r.error_message
FROM audit.etl_batch b
JOIN audit.etl_run r ON r.batch_id = b.batch_id
WHERE b.batch_id = @batch_id
ORDER BY r.run_id DESC;

-- 2) 9 dòng ingest của lần chạy gần nhất: rows_rejected = 0, status = SUCCESS.
SELECT step, table_name, rows_read, rows_loaded, rows_rejected, status, error_message
FROM audit.etl_step_log
WHERE run_id = @run_id AND step = 'ingest'
ORDER BY log_id;

-- 3) source_manifest: 9 file, checksum là SHA-256 (64 ký tự), row_count là số dòng cả file.
SELECT source_file, source_checksum, row_count, LEN(column_list) AS column_list_len
FROM audit.source_manifest
WHERE batch_id = @batch_id
ORDER BY source_file;

-- 4) Số dòng staging. Phải khớp bản DuckDB: tổng 1.550.922.
SELECT table_name, expected_rows, actual_rows,
       CASE WHEN actual_rows = expected_rows THEN N'OK' ELSE N'SAI' END AS ket_luan
FROM (
    SELECT N'orders'               AS table_name,  99441 AS expected_rows, COUNT(*) AS actual_rows FROM staging.orders
    UNION ALL SELECT N'customers',                  99441, COUNT(*) FROM staging.customers
    UNION ALL SELECT N'order_items',               112650, COUNT(*) FROM staging.order_items
    UNION ALL SELECT N'order_reviews',              99224, COUNT(*) FROM staging.order_reviews
    UNION ALL SELECT N'order_payments',            103886, COUNT(*) FROM staging.order_payments
    UNION ALL SELECT N'products',                   32951, COUNT(*) FROM staging.products
    UNION ALL SELECT N'sellers',                     3095, COUNT(*) FROM staging.sellers
    UNION ALL SELECT N'geolocation',              1000163, COUNT(*) FROM staging.geolocation
    UNION ALL SELECT N'category_translation',          71, COUNT(*) FROM staging.category_translation
) q
UNION ALL
SELECT N'TONG', 1550922, SUM(actual_rows),
       CASE WHEN SUM(actual_rows) = 1550922 THEN N'OK' ELSE N'SAI' END
FROM (
    SELECT COUNT(*) AS actual_rows FROM staging.orders
    UNION ALL SELECT COUNT(*) FROM staging.customers
    UNION ALL SELECT COUNT(*) FROM staging.order_items
    UNION ALL SELECT COUNT(*) FROM staging.order_reviews
    UNION ALL SELECT COUNT(*) FROM staging.order_payments
    UNION ALL SELECT COUNT(*) FROM staging.products
    UNION ALL SELECT COUNT(*) FROM staging.sellers
    UNION ALL SELECT COUNT(*) FROM staging.geolocation
    UNION ALL SELECT COUNT(*) FROM staging.category_translation
) t;

-- 5) Chạy lại cùng batch không được sinh dòng trùng: mỗi (batch, source_row_number)
--    phải xuất hiện đúng 1 lần trong mỗi bảng. Kết quả phải toàn 0.
SELECT 'orders' AS table_name, COUNT(*) AS dup_rows FROM (
    SELECT source_row_number FROM staging.orders WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'customers', COUNT(*) FROM (
    SELECT source_row_number FROM staging.customers WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'order_items', COUNT(*) FROM (
    SELECT source_row_number FROM staging.order_items WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'order_reviews', COUNT(*) FROM (
    SELECT source_row_number FROM staging.order_reviews WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'order_payments', COUNT(*) FROM (
    SELECT source_row_number FROM staging.order_payments WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'products', COUNT(*) FROM (
    SELECT source_row_number FROM staging.products WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'sellers', COUNT(*) FROM (
    SELECT source_row_number FROM staging.sellers WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'geolocation', COUNT(*) FROM (
    SELECT source_row_number FROM staging.geolocation WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x
UNION ALL SELECT 'category_translation', COUNT(*) FROM (
    SELECT source_row_number FROM staging.category_translation WHERE source_batch_id = @batch_id
    GROUP BY source_row_number HAVING COUNT(*) > 1) x;

-- 6) Tiếng Việt và bình luận nhiều dòng phải còn nguyên sau khi đọc bằng SSIS.
SELECT TOP (5) customer_city
FROM staging.customers
WHERE source_batch_id = @batch_id AND customer_city LIKE N'%sao%'
ORDER BY customer_city;

SELECT TOP (5) review_id, review_comment_message
FROM staging.order_reviews
WHERE source_batch_id = @batch_id
  AND (review_comment_message LIKE N'%' + CHAR(10) + N'%' OR review_comment_message LIKE N'%' + CHAR(13) + N'%');
GO
