-- Task 3 (SSIS): thủ tục dùng chung cho các package Transform, Load và Test.
-- Chạy sau 01_audit.sql, 05, 06. Chạy lại nhiều lần vẫn an toàn (CREATE OR ALTER).
USE OlistDW;
GO

-- Lần chạy hiện tại của một batch: lần mới nhất còn RUNNING hoặc INGESTED.
CREATE OR ALTER FUNCTION audit.fn_current_run_id (@batch_id varchar(100))
RETURNS int
AS
BEGIN
    RETURN (SELECT TOP (1) run_id FROM audit.etl_run
            WHERE batch_id = @batch_id AND status IN ('RUNNING', 'INGESTED')
            ORDER BY run_id DESC);
END
GO

-- Master.dtsx gọi đầu tiên. Batch chưa có thì tạo (FULL). Đã có lần chạy dở (RUNNING/INGESTED,
-- ví dụ Ingest_Staging vừa nạp xong) thì dùng tiếp lần đó; không thì mở lần chạy mới, attempt + 1.
CREATE OR ALTER PROC audit.usp_start_run
    @batch_id varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM audit.etl_batch WHERE batch_id = @batch_id)
        INSERT audit.etl_batch (batch_id, batch_type, status, started_at)
        VALUES (@batch_id, CASE WHEN @batch_id LIKE 'INC%' THEN 'INCREMENTAL' ELSE 'FULL' END, 'RUNNING', SYSDATETIME());

    IF audit.fn_current_run_id(@batch_id) IS NULL
        INSERT audit.etl_run (batch_id, attempt, status, started_at)
        SELECT @batch_id, ISNULL(MAX(attempt), 0) + 1, 'RUNNING', SYSDATETIME()
        FROM audit.etl_run WHERE batch_id = @batch_id;
    ELSE
        UPDATE audit.etl_run SET status = 'RUNNING' WHERE run_id = audit.fn_current_run_id(@batch_id);

    UPDATE audit.etl_batch SET status = 'RUNNING' WHERE batch_id = @batch_id;
END
GO

-- Ghi một bước vào etl_step_log: số dòng hiện có của bảng đích sau khi package nạp xong.
-- @table_name dạng 'schema.bang'.
CREATE OR ALTER PROC audit.usp_log_step
    @batch_id   varchar(100),
    @step       varchar(20),
    @table_name varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @rows bigint, @obj int = OBJECT_ID(@table_name, N'U');
    IF @obj IS NULL THROW 50020, N'usp_log_step: không tìm thấy bảng.', 1;
    DECLARE @sql nvarchar(400) = N'SELECT @n = COUNT_BIG(*) FROM '
        + QUOTENAME(OBJECT_SCHEMA_NAME(@obj)) + N'.' + QUOTENAME(OBJECT_NAME(@obj));
    EXEC sys.sp_executesql @sql, N'@n bigint OUTPUT', @n = @rows OUTPUT;

    INSERT audit.etl_step_log (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status)
    VALUES (ISNULL(audit.fn_current_run_id(@batch_id), 0), @step, @table_name, @rows, @rows, 0, 'SUCCESS');
END
GO

-- Master.dtsx gọi cuối cùng (SUCCESS) hoặc trong OnError (FAILED).
CREATE OR ALTER PROC audit.usp_finish_run
    @batch_id      varchar(100),
    @status        varchar(20),
    @error_message nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id int = audit.fn_current_run_id(@batch_id);
    UPDATE audit.etl_run
       SET status = @status, ended_at = SYSDATETIME(), error_message = LEFT(@error_message, 4000)
     WHERE run_id = @run_id;
    UPDATE audit.etl_batch SET status = @status, ended_at = SYSDATETIME() WHERE batch_id = @batch_id;
END
GO

-- Lịch liên tục từ ngày nhỏ nhất đến lớn nhất xuất hiện trong dữ liệu đã làm sạch.
-- SCD Type 0: chỉ chèn ngày còn thiếu, không sửa ngày đã có. Tên thứ, tháng viết cố định (không phụ thuộc ngôn ngữ máy chủ).
CREATE OR ALTER PROC audit.usp_build_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mn date, @mx date;
    SELECT @mn = MIN(d), @mx = MAX(d)
    FROM (
        SELECT CAST(purchase_ts AS date) FROM intermediate.cln_orders UNION ALL
        SELECT CAST(approved_ts AS date) FROM intermediate.cln_orders UNION ALL
        SELECT CAST(carrier_ts AS date) FROM intermediate.cln_orders UNION ALL
        SELECT CAST(delivered_ts AS date) FROM intermediate.cln_orders UNION ALL
        SELECT CAST(estimated_ts AS date) FROM intermediate.cln_orders UNION ALL
        SELECT CAST(review_creation_ts AS date) FROM intermediate.cln_order_reviews UNION ALL
        SELECT CAST(review_answer_ts AS date) FROM intermediate.cln_order_reviews UNION ALL
        SELECT CAST(shipping_limit_ts AS date) FROM intermediate.cln_order_items
    ) x(d);
    IF @mn IS NULL RETURN;

    WITH n AS (
        SELECT TOP (DATEDIFF(day, @mn, @mx) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), cal AS (
        SELECT DATEADD(day, i, @mn) AS d,
               -- ISO: thứ Hai = 1; 2001-01-01 là thứ Hai
               DATEDIFF(day, '20010101', DATEADD(day, i, @mn)) % 7 + 1 AS iso_dow
        FROM n
    )
    INSERT dwh.dim_date (date_key, full_date, day_of_month, day_of_week_number, day_of_week_name,
                         month_number, month_name, year_month, quarter_number, year_quarter,
                         calendar_year, member_type)
    SELECT YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d), d, DAY(d), iso_dow,
           CHOOSE(iso_dow, N'Monday', N'Tuesday', N'Wednesday', N'Thursday', N'Friday', N'Saturday', N'Sunday'),
           MONTH(d),
           CHOOSE(MONTH(d), N'January', N'February', N'March', N'April', N'May', N'June', N'July',
                  N'August', N'September', N'October', N'November', N'December'),
           CONVERT(char(7), d, 126),
           DATEPART(quarter, d),
           CONCAT(YEAR(d), '-Q', DATEPART(quarter, d)),
           YEAR(d), N'Calendar'
    FROM cal
    WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date dd WHERE dd.date_key = YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d));
END
GO

-- Test_DW.dtsx: kiểm thử kho sau khi nạp. Ghi từng kiểm tra vào etl_step_log (step = 'test'),
-- trả bảng kết quả, và báo lỗi (THROW) nếu có kiểm tra mức ERROR không đạt. WARN chỉ ghi lại.
CREATE OR ALTER PROC audit.usp_check_dw
    @batch_id    varchar(100),
    @show_result bit = 0   -- 1: trả bảng kết quả (khi chạy tay trong SSMS). Package để 0: nếu trả bảng
                           -- trước khi THROW, Execute SQL Task có thể bỏ qua lỗi.
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #r (check_code varchar(10), severity varchar(5), description nvarchar(300), failed_rows bigint);

    -- T02: không mất, không nhân dòng
    INSERT #r SELECT 'T02a', 'ERROR', N'fact_order_experience có đúng số đơn của cln_orders',
        ABS((SELECT COUNT_BIG(*) FROM dwh.fact_order_experience) - (SELECT COUNT_BIG(*) FROM intermediate.cln_orders));
    INSERT #r SELECT 'T02b', 'ERROR', N'fact_order_item có đúng số dòng hàng của cln_order_items',
        ABS((SELECT COUNT_BIG(*) FROM dwh.fact_order_item) - (SELECT COUNT_BIG(*) FROM intermediate.cln_order_items));
    -- T03: đủ khoá đặc biệt của dim_date và dòng Unknown khoá 0 ở mọi dimension
    INSERT #r SELECT 'T03a', 'ERROR', N'dim_date có đủ khoá 0, -1, -2',
        3 - (SELECT COUNT(*) FROM dwh.dim_date WHERE date_key IN (0, -1, -2));
    INSERT #r SELECT 'T03b', 'ERROR', N'mọi dimension có dòng Unknown khoá 0',
        7 - ((SELECT COUNT(*) FROM dwh.dim_customer WHERE customer_key = 0) + (SELECT COUNT(*) FROM dwh.dim_seller WHERE seller_key = 0)
           + (SELECT COUNT(*) FROM dwh.dim_product WHERE product_key = 0) + (SELECT COUNT(*) FROM dwh.dim_geography WHERE geography_key = 0)
           + (SELECT COUNT(*) FROM dwh.dim_order_status WHERE status_key = 0) + (SELECT COUNT(*) FROM dwh.dim_delivery_outcome WHERE outcome_key = 0)
           + (SELECT COUNT(*) FROM dwh.dim_date WHERE date_key = 0));
    -- T04: khoá ngoại của fact đều có trong dimension (không có khoá mồ côi)
    INSERT #r SELECT 'T04a', 'ERROR', N'fact_order_experience: khoá dimension đều tồn tại', COUNT_BIG(*)
    FROM dwh.fact_order_experience f
    WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_customer d WHERE d.customer_key = f.customer_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_geography d WHERE d.geography_key = f.customer_geography_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_order_status d WHERE d.status_key = f.status_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_delivery_outcome d WHERE d.outcome_key = f.outcome_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.purchase_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.approved_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.carrier_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.delivered_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.estimated_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.review_answer_date_key);
    INSERT #r SELECT 'T04b', 'ERROR', N'fact_order_item: khoá dimension đều tồn tại', COUNT_BIG(*)
    FROM dwh.fact_order_item f
    WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_customer d WHERE d.customer_key = f.customer_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_geography d WHERE d.geography_key = f.customer_geography_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_geography d WHERE d.geography_key = f.seller_geography_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_product d WHERE d.product_key = f.product_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_seller d WHERE d.seller_key = f.seller_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.purchase_date_key)
       OR NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.date_key = f.shipping_limit_date_key);
    -- T05: các cờ đếm nhất quán trên từng đơn
    INSERT #r SELECT 'T05a', 'ERROR', N'late + on_time = delivery_eligible', COUNT_BIG(*)
    FROM dwh.fact_order_experience WHERE late_count + on_time_count <> delivery_eligible_count;
    INSERT #r SELECT 'T05b', 'ERROR', N'eligible <= delivered <= order; low_review <= reviewed; late_days khớp cờ', COUNT_BIG(*)
    FROM dwh.fact_order_experience
    WHERE delivery_eligible_count > delivered_count OR delivered_count > order_count
       OR low_review_order_count > reviewed_order_count
       OR (late_count = 1 AND (late_days IS NULL OR late_days < 1))
       OR (on_time_count = 1 AND late_days <> 0)
       OR (delivery_eligible_count = 0 AND late_days IS NOT NULL);
    -- T06: thời gian không âm; tổng 3 bước bằng thời gian giao khi đủ mốc
    INSERT #r SELECT 'T06', 'ERROR', N'thời gian từng bước không âm và cộng đúng', COUNT_BIG(*)
    FROM dwh.fact_order_experience
    WHERE approval_seconds < 0 OR handling_seconds < 0 OR transit_seconds < 0 OR delivery_seconds < 0
       OR (approval_seconds IS NOT NULL AND handling_seconds IS NOT NULL AND transit_seconds IS NOT NULL
           AND delivery_seconds <> approval_seconds + handling_seconds + transit_seconds);
    -- T07: điểm đánh giá hợp lệ
    INSERT #r SELECT 'T07', 'ERROR', N'điểm đánh giá đại diện thuộc 1–5', COUNT_BIG(*)
    FROM dwh.fact_order_experience WHERE representative_review_score NOT BETWEEN 1 AND 5;
    -- T13 (WARN): đơn lệch thanh toán so với tiền hàng + phí vận chuyển; chỉ gắn cờ, không loại đơn
    INSERT #r SELECT 'T13', 'WARN', N'đơn lệch thanh toán quá 0,01 BRL (có chủ đích, mong đợi 303)', COUNT_BIG(*)
    FROM intermediate.int_order_payment_reconciliation WHERE mismatch_gt_threshold = 1;

    DECLARE @run_id int = ISNULL(audit.fn_current_run_id(@batch_id), 0);
    INSERT audit.etl_step_log (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status, error_message)
    SELECT @run_id, 'test', check_code, NULL, NULL, failed_rows,
           CASE WHEN failed_rows = 0 THEN 'PASS' WHEN severity = 'WARN' THEN 'WARN' ELSE 'FAIL' END,
           CASE WHEN failed_rows > 0 THEN description END
    FROM #r;

    IF @show_result = 1
        SELECT check_code, severity, description, failed_rows,
               CASE WHEN failed_rows = 0 THEN 'PASS' WHEN severity = 'WARN' THEN 'WARN' ELSE 'FAIL' END AS result
        FROM #r ORDER BY check_code;

    IF EXISTS (SELECT 1 FROM #r WHERE severity = 'ERROR' AND failed_rows > 0)
    BEGIN
        DECLARE @msg nvarchar(2000) = (SELECT STRING_AGG(check_code, ', ') FROM #r WHERE severity = 'ERROR' AND failed_rows > 0);
        SET @msg = N'Kiểm thử kho không đạt: ' + @msg;
        THROW 50010, @msg, 1;
    END
END
GO
PRINT N'Đã tạo các thủ tục audit cho package Transform, Load, Test.';
GO
