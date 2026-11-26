-- Task 3 (SSIS): bảng và thủ tục dùng chung cho Master, Transform, Load, Test (Full và Incremental Load).
-- Chạy sau 01_audit.sql, 05, 06. Chạy lại nhiều lần vẫn an toàn.
USE OlistDW;
GO

-- LSET / CET của từng nguồn có mốc thời gian (Incremental Extract).
--   LSET: mốc dữ liệu đã lấy tới ở lần chạy thành công trước. CET: mốc của lần chạy hiện tại (đọc từ _cutoff.txt của batch).
--   Chỉ đẩy LSET = CET khi CẢ pipeline thành công (usp_finish_run), để lỗi giữa chừng không làm mất dữ liệu.
IF OBJECT_ID(N'audit.etl_metadata', N'U') IS NULL
CREATE TABLE audit.etl_metadata (
    source_name      sysname       NOT NULL CONSTRAINT PK_etl_metadata PRIMARY KEY,
    watermark_column nvarchar(400) NOT NULL,
    lset             datetime2(0)  NULL,
    cet              datetime2(0)  NULL,
    current_batch_id varchar(100)  NULL,
    last_batch_id    varchar(100)  NULL,
    updated_at       datetime2(0)  NULL
);
IF NOT EXISTS (SELECT 1 FROM audit.etl_metadata)
    INSERT audit.etl_metadata (source_name, watermark_column) VALUES
        (N'orders', N'order_purchase_timestamp, order_approved_at, order_delivered_carrier_date, order_delivered_customer_date'),
        (N'order_reviews', N'review_answer_timestamp');

-- Kết quả trích xuất của từng file trong mỗi LẦN CHẠY (bằng chứng Full / Incremental Load).
-- Khoá có run_id: chạy lại một batch không ghi đè thống kê của lần chạy trước.
IF OBJECT_ID(N'audit.extract_stat', N'U') IS NOT NULL AND COL_LENGTH(N'audit.extract_stat', N'run_id') IS NULL
    DROP TABLE audit.extract_stat;
IF OBJECT_ID(N'audit.extract_stat', N'U') IS NULL
CREATE TABLE audit.extract_stat (
    batch_id                    varchar(100) NOT NULL,
    run_id                      int          NOT NULL,
    table_name                  sysname      NOT NULL,
    load_mode                   varchar(20)  NULL,
    lset                        datetime2(0) NULL,
    cet                         datetime2(0) NULL,
    file_sha256                 char(64)     NULL,
    file_skipped                bit          NOT NULL,
    rows_read                   bigint       NULL,   -- số dòng trong file
    rows_in_window              bigint       NULL,   -- có mốc thời gian trong (LSET, CET]
    rows_changed_outside_window bigint       NULL,   -- mới / đổi nội dung nhưng không có mốc mới (chỉ mã băm bắt được)
    rows_extracted              bigint       NULL,   -- số dòng chuyển vào staging
    rows_unchanged              bigint       NULL,   -- giống batch trước, không chuyển
    logged_at                   datetime2(0) NOT NULL CONSTRAINT DF_extract_stat_at DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_extract_stat PRIMARY KEY (batch_id, run_id, table_name)
);

-- Khoá thay thế đã cấp ở lần chạy thành công gần nhất: Test_DW kiểm tra khoá không bị đổi.
IF OBJECT_ID(N'audit.dim_key_snapshot', N'U') IS NULL
CREATE TABLE audit.dim_key_snapshot (
    dim_name      sysname       NOT NULL,
    business_key  nvarchar(255) COLLATE Latin1_General_100_BIN2 NOT NULL,
    surrogate_key int           NOT NULL,
    CONSTRAINT PK_dim_key_snapshot PRIMARY KEY (dim_name, business_key)
);

-- Dòng bị loại (không làm dừng cả bảng): giữ nội dung gốc và lý do để sửa rồi nạp lại.
--   stage 'extract'  : Flat File Source không đọc được dòng (sai cấu trúc, giá trị dài quá cột) -> Error Output
--   stage 'transform': dòng thiếu khoá nghiệp vụ, không đưa được vào tầng làm sạch
IF OBJECT_ID(N'audit.reject_row', N'U') IS NULL
CREATE TABLE audit.reject_row (
    reject_id         bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_reject_row PRIMARY KEY,
    batch_id          varchar(100)   NOT NULL,
    run_id            int            NULL,          -- điền khi bước Load Staging chốt
    table_name        nvarchar(128)  NOT NULL,
    stage             varchar(20)    NOT NULL,
    source_row_number int            NULL,
    error_code        int            NULL,          -- mã lỗi SSIS
    error_column      int            NULL,          -- lineage ID của cột lỗi trong Data Flow
    error_description nvarchar(400)  NULL,
    raw_data          nvarchar(max)  NULL,
    rejected_at       datetime2(0)   NULL
);
IF COL_LENGTH(N'audit.extract_stat', N'rows_rejected') IS NULL
    ALTER TABLE audit.extract_stat ADD rows_rejected bigint NULL;   -- dòng Flat File Source chuyển sang reject_row
GO

-- Khoá thay thế hiện tại của 4 dimension cấp khoá IDENTITY.
CREATE OR ALTER VIEW audit.v_dim_keys
AS
SELECT N'dim_customer' AS dim_name, customer_unique_id COLLATE Latin1_General_100_BIN2 AS business_key, customer_key AS surrogate_key
FROM dwh.dim_customer
UNION ALL SELECT N'dim_seller', seller_id COLLATE Latin1_General_100_BIN2, seller_key FROM dwh.dim_seller
UNION ALL SELECT N'dim_product', product_id COLLATE Latin1_General_100_BIN2, product_key FROM dwh.dim_product
UNION ALL SELECT N'dim_geography', zip_prefix COLLATE Latin1_General_100_BIN2, geography_key FROM dwh.dim_geography;
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

-- Master.dtsx và Ingest_Staging.dtsx gọi đầu tiên.
--   Chế độ: FULL nếu chưa có batch nào khác thành công (lần nạp đầu), ngược lại INCREMENTAL.
--   Batch đã SUCCESS được chạy lại thì giữ chế độ cũ.
--   CET: đọc từ <thư mục batch>\_cutoff.txt; không có file thì CET = 9999-12-31 (lấy hết).
--   Đã có lần chạy dở (RUNNING/INGESTED) thì dùng tiếp; không thì mở lần chạy mới, attempt + 1.
CREATE OR ALTER PROC audit.usp_start_run
    @batch_id  varchar(100),
    @batch_dir nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mode varchar(20) = CASE WHEN EXISTS (SELECT 1 FROM audit.etl_batch
                                                  WHERE status = 'SUCCESS' AND batch_id <> @batch_id)
                                     THEN 'INCREMENTAL' ELSE 'FULL' END;
    IF NOT EXISTS (SELECT 1 FROM audit.etl_batch WHERE batch_id = @batch_id)
        INSERT audit.etl_batch (batch_id, batch_type, status, started_at)
        VALUES (@batch_id, @mode, 'RUNNING', SYSDATETIME());
    ELSE
        UPDATE audit.etl_batch SET batch_type = @mode WHERE batch_id = @batch_id AND status <> 'SUCCESS';

    IF audit.fn_current_run_id(@batch_id) IS NULL
        INSERT audit.etl_run (batch_id, attempt, status, started_at)
        SELECT @batch_id, ISNULL(MAX(attempt), 0) + 1, 'RUNNING', SYSDATETIME()
        FROM audit.etl_run WHERE batch_id = @batch_id;
    ELSE
        UPDATE audit.etl_run SET status = 'RUNNING' WHERE run_id = audit.fn_current_run_id(@batch_id);
    UPDATE audit.etl_batch SET status = 'RUNNING' WHERE batch_id = @batch_id;

    DECLARE @cet datetime2(0), @txt varchar(100), @sql nvarchar(max);
    IF @batch_dir IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @t = BulkColumn FROM OPENROWSET(BULK N'''
            + REPLACE(@batch_dir + N'\_cutoff.txt', N'''', N'''''') + N''', SINGLE_CLOB) f';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@t varchar(100) OUTPUT', @t = @txt OUTPUT;
            SET @cet = TRY_CONVERT(datetime2(0), LTRIM(RTRIM(REPLACE(REPLACE(@txt, CHAR(13), ''), CHAR(10), ''))), 120);
        END TRY
        BEGIN CATCH
            SET @cet = NULL;   -- không có _cutoff.txt
        END CATCH
    END
    UPDATE audit.etl_metadata
       SET cet = ISNULL(@cet, '9999-12-31 23:59:59'), current_batch_id = @batch_id, updated_at = SYSDATETIME();
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

-- Master.dtsx gọi cuối cùng (SUCCESS, sau Test_DW) hoặc trong OnError (FAILED).
-- Chỉ khi SUCCESS: đẩy LSET = CET và lưu ảnh chụp khoá thay thế. FAILED thì LSET giữ nguyên để chạy lại.
CREATE OR ALTER PROC audit.usp_finish_run
    @batch_id      varchar(100),
    @status        varchar(20),
    @error_message nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @run_id int = audit.fn_current_run_id(@batch_id);
    BEGIN TRAN;
        IF @status = 'SUCCESS'
        BEGIN
            -- LSET chỉ tiến, không lùi (chạy lại một batch cũ không kéo LSET về mốc cũ)
            UPDATE audit.etl_metadata
               SET lset = cet, last_batch_id = @batch_id, updated_at = SYSDATETIME()
             WHERE current_batch_id = @batch_id AND cet IS NOT NULL AND (lset IS NULL OR cet > lset);
            INSERT audit.dim_key_snapshot (dim_name, business_key, surrogate_key)
            SELECT k.dim_name, k.business_key, k.surrogate_key FROM audit.v_dim_keys k
            WHERE NOT EXISTS (SELECT 1 FROM audit.dim_key_snapshot s
                              WHERE s.dim_name = k.dim_name AND s.business_key = k.business_key);
        END
        UPDATE audit.etl_run
           SET status = @status, ended_at = SYSDATETIME(), error_message = LEFT(@error_message, 4000)
         WHERE run_id = @run_id;
        UPDATE audit.etl_batch SET status = @status, ended_at = SYSDATETIME() WHERE batch_id = @batch_id;
    COMMIT;
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

    -- T11: khoá nghiệp vụ của bảng làm sạch không trùng (bảng không có khoá chính trong database)
    INSERT #r SELECT 'T11', 'ERROR', N'khoá không trùng: cln_order_items, cln_order_payments, cln_category_translation',
        (SELECT COUNT_BIG(*) FROM (SELECT order_id, order_item_id FROM intermediate.cln_order_items
                                   GROUP BY order_id, order_item_id HAVING COUNT(*) > 1) x)
      + (SELECT COUNT_BIG(*) FROM (SELECT order_id, payment_sequential FROM intermediate.cln_order_payments
                                   GROUP BY order_id, payment_sequential HAVING COUNT(*) > 1) x)
      + (SELECT COUNT_BIG(*) FROM (SELECT category_name FROM intermediate.cln_category_translation
                                   GROUP BY category_name HAVING COUNT(*) > 1) x);
    -- T12: cột bắt buộc không trống
    INSERT #r SELECT 'T12', 'ERROR', N'không trống: order_item_id, customer_unique_id, mã sản phẩm và người bán của dòng hàng',
        (SELECT COUNT_BIG(*) FROM intermediate.cln_order_items WHERE order_item_id IS NULL OR product_id IS NULL OR seller_id IS NULL)
      + (SELECT COUNT_BIG(*) FROM intermediate.cln_customers WHERE customer_unique_id IS NULL);
    -- T14: giá trị hợp lệ
    INSERT #r SELECT 'T14', 'ERROR', N'giá trị hợp lệ: trạng thái đơn (8 giá trị), điểm đánh giá 1–5',
        (SELECT COUNT_BIG(*) FROM intermediate.cln_orders
         WHERE order_status NOT IN (N'delivered', N'shipped', N'canceled', N'unavailable', N'invoiced', N'processing', N'created', N'approved'))
      + (SELECT COUNT_BIG(*) FROM intermediate.cln_order_reviews WHERE review_score NOT BETWEEN 1 AND 5);
    -- T15 (WARN): đơn không tìm thấy khách (fact dùng khách Unknown khoá 0)
    INSERT #r SELECT 'T15', 'WARN', N'đơn không tìm thấy khách (gán khách Unknown)', COUNT_BIG(*)
    FROM intermediate.int_order_customer_map WHERE missing_customer_flag = 1;
    -- T16 (WARN): dòng bị loại trong lần chạy này (xem audit.reject_row)
    INSERT #r SELECT 'T16', 'WARN', N'dòng bị loại vào audit.reject_row trong lần chạy này', COUNT_BIG(*)
    FROM audit.reject_row WHERE batch_id = @batch_id AND run_id = ISNULL(audit.fn_current_run_id(@batch_id), 0);

    -- T08: khoá thay thế không đổi so với lần chạy thành công trước (chạy lại, nạp tăng thêm)
    INSERT #r SELECT 'T08', 'ERROR', N'khoá thay thế của dimension không đổi qua các lần nạp', COUNT_BIG(*)
    FROM audit.dim_key_snapshot s
    WHERE NOT EXISTS (SELECT 1 FROM audit.v_dim_keys k
                      WHERE k.dim_name = s.dim_name AND k.business_key = s.business_key
                        AND k.surrogate_key = s.surrogate_key);
    -- T09: đối chiếu trích xuất của lần chạy này: đọc = lấy + không đổi
    INSERT #r SELECT 'T09', 'ERROR', N'đối chiếu số dòng trích xuất (đọc = lấy + không đổi)', COUNT_BIG(*)
    FROM audit.extract_stat
    WHERE batch_id = @batch_id AND run_id = ISNULL(audit.fn_current_run_id(@batch_id), 0)
      AND file_skipped = 0 AND rows_read <> rows_extracted + rows_unchanged;
    -- T10: số dòng staging của batch = số dòng đã lấy ở lần nạp gần nhất (không tính lần bị bỏ qua)
    INSERT #r SELECT 'T10', 'ERROR', N'số dòng staging của batch khớp số dòng đã lấy', COUNT(*)
    FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY table_name ORDER BY run_id DESC) AS rn
          FROM audit.extract_stat WHERE batch_id = @batch_id AND file_skipped = 0) e
    CROSS APPLY (SELECT CASE e.table_name
        WHEN N'orders' THEN (SELECT COUNT_BIG(*) FROM staging.orders WHERE source_batch_id = @batch_id)
        WHEN N'customers' THEN (SELECT COUNT_BIG(*) FROM staging.customers WHERE source_batch_id = @batch_id)
        WHEN N'order_items' THEN (SELECT COUNT_BIG(*) FROM staging.order_items WHERE source_batch_id = @batch_id)
        WHEN N'order_reviews' THEN (SELECT COUNT_BIG(*) FROM staging.order_reviews WHERE source_batch_id = @batch_id)
        WHEN N'order_payments' THEN (SELECT COUNT_BIG(*) FROM staging.order_payments WHERE source_batch_id = @batch_id)
        WHEN N'products' THEN (SELECT COUNT_BIG(*) FROM staging.products WHERE source_batch_id = @batch_id)
        WHEN N'sellers' THEN (SELECT COUNT_BIG(*) FROM staging.sellers WHERE source_batch_id = @batch_id)
        WHEN N'geolocation' THEN (SELECT COUNT_BIG(*) FROM staging.geolocation WHERE source_batch_id = @batch_id)
        WHEN N'category_translation' THEN (SELECT COUNT_BIG(*) FROM staging.category_translation WHERE source_batch_id = @batch_id)
        END AS n) c
    WHERE e.rn = 1 AND c.n <> e.rows_extracted;

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
-- Transform_Clean gọi đầu tiên: ghi lại các dòng staging CỦA BATCH NÀY thiếu khoá nghiệp vụ.
-- Các dòng này bị câu SQL nguồn của Transform_Clean loại; trước đây bị bỏ âm thầm.
CREATE OR ALTER PROC audit.usp_log_missing_keys
    @batch_id varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id int = ISNULL(audit.fn_current_run_id(@batch_id), 0);
    DELETE audit.reject_row WHERE batch_id = @batch_id AND run_id = @run_id AND stage = 'transform';
    DECLARE @k TABLE (table_name sysname, key_col sysname);
    INSERT @k VALUES (N'orders', N'order_id'), (N'customers', N'customer_id'), (N'order_items', N'order_id'),
                     (N'order_payments', N'order_id'), (N'products', N'product_id'), (N'sellers', N'seller_id'),
                     (N'category_translation', N'product_category_name');
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'INSERT audit.reject_row (batch_id, run_id, table_name, stage, source_row_number, error_description, raw_data, rejected_at)
        SELECT @batch, @run, N''' + k.table_name + N''', ''transform'', s.source_row_number,
               N''Thiếu khoá nghiệp vụ (' + k.key_col + N'): không đưa vào tầng làm sạch'',
               CONCAT_WS(N''|'', ' +
               (SELECT STRING_AGG(CAST(N's.' + QUOTENAME(c.name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY c.column_id)
                FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'staging.' + k.table_name)
                  AND c.name NOT IN (N'source_file', N'source_checksum', N'source_row_number', N'source_batch_id', N'ingested_at'))
               + N'), SYSDATETIME()
        FROM staging.' + QUOTENAME(k.table_name) + N' s
        WHERE s.source_batch_id = @batch AND NULLIF(TRIM(s.' + QUOTENAME(k.key_col) + N'), N'''') IS NULL;
        '
    FROM @k k;
    EXEC sys.sp_executesql @sql, N'@batch varchar(100), @run int', @batch = @batch_id, @run = @run_id;
END
GO

-- Transform_Business: các đơn cần tính lại fact trong batch này.
--   FULL: mọi đơn. INCREMENTAL: đơn có dòng mới / đổi ở orders, order_items, order_reviews, order_payments,
--   đơn của khách đổi thông tin, đơn có dòng hàng của người bán đổi thông tin.
CREATE OR ALTER PROC audit.usp_build_affected_orders
    @batch_id varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE intermediate.affected_orders;
    IF (SELECT batch_type FROM audit.etl_batch WHERE batch_id = @batch_id) = 'FULL'
        INSERT intermediate.affected_orders (order_id, reason)
        SELECT order_id, 'FULL' FROM intermediate.cln_orders;
    ELSE
        INSERT intermediate.affected_orders (order_id, reason)
        SELECT o.order_id, MIN(x.reason)
        FROM (
            SELECT TRIM(order_id) AS order_id, 'orders' AS reason FROM staging.orders WHERE source_batch_id = @batch_id
            UNION ALL SELECT TRIM(order_id), 'order_items' FROM staging.order_items WHERE source_batch_id = @batch_id
            UNION ALL SELECT TRIM(order_id), 'order_reviews' FROM staging.order_reviews WHERE source_batch_id = @batch_id
            UNION ALL SELECT TRIM(order_id), 'order_payments' FROM staging.order_payments WHERE source_batch_id = @batch_id
            UNION ALL SELECT o2.order_id, 'customers' FROM intermediate.cln_orders o2
                      JOIN staging.customers c ON TRIM(c.customer_id) = o2.customer_id WHERE c.source_batch_id = @batch_id
            UNION ALL SELECT i.order_id, 'sellers' FROM intermediate.cln_order_items i
                      JOIN staging.sellers s ON TRIM(s.seller_id) = i.seller_id WHERE s.source_batch_id = @batch_id
        ) x
        JOIN intermediate.cln_orders o ON o.order_id = x.order_id
        GROUP BY o.order_id;
END
GO

-- Load_Facts: đưa bảng stage vào fact trong MỘT transaction.
--   Đơn đã có: cập nhật khi nội dung đổi (giữ dw_created_at, đổi dw_updated_at); đơn mới: chèn.
--   Dòng hàng của đơn bị ảnh hưởng mà không còn trong stage: xoá.
CREATE OR ALTER PROC audit.usp_merge_facts
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @sql nvarchar(max) = N'';
    DECLARE @f TABLE (fact sysname, stage sysname, keys nvarchar(200));
    INSERT @f VALUES (N'fact_order_experience', N'fact_order_experience_stage', N'order_id'),
                     (N'fact_order_item', N'fact_order_item_stage', N'order_id,order_item_id');
    DECLARE @fact sysname, @stage sysname, @keys nvarchar(200);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT fact, stage, keys FROM @f;
    OPEN c;
    FETCH NEXT FROM c INTO @fact, @stage, @keys;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @cols nvarchar(max), @set nvarchar(max), @on nvarchar(max), @t nvarchar(max), @s nvarchar(max);
        SELECT @cols = STRING_AGG(CAST(QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY column_id),
               @t = STRING_AGG(CAST(N't.' + QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY column_id),
               @s = STRING_AGG(CAST(N's.' + QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY column_id)
        FROM sys.columns WHERE object_id = OBJECT_ID(N'dwh.' + @fact) AND name NOT IN (N'dw_created_at', N'dw_updated_at');
        SELECT @set = STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = s.' + QUOTENAME(name) AS nvarchar(max)), N', ')
        FROM sys.columns WHERE object_id = OBJECT_ID(N'dwh.' + @fact)
          AND name NOT IN (N'dw_created_at', N'dw_updated_at') AND CHARINDEX(N',' + name + N',', N',' + @keys + N',') = 0;
        SELECT @on = STRING_AGG(CAST(N't.' + value + N' = s.' + value AS nvarchar(max)), N' AND ') FROM STRING_SPLIT(@keys, N',');

        IF @fact = N'fact_order_item'
            SET @sql += N'DELETE t FROM dwh.fact_order_item t
                WHERE t.order_id IN (SELECT order_id FROM intermediate.affected_orders)
                  AND NOT EXISTS (SELECT 1 FROM dwh.fact_order_item_stage s WHERE ' + @on + N');
                ';
        SET @sql += N'MERGE dwh.' + QUOTENAME(@fact) + N' AS t USING dwh.' + QUOTENAME(@stage) + N' AS s ON ' + @on + N'
            WHEN MATCHED AND EXISTS (SELECT ' + @s + N' EXCEPT SELECT ' + @t + N')
                THEN UPDATE SET ' + @set + N', t.dw_updated_at = SYSDATETIME()
            WHEN NOT MATCHED BY TARGET
                THEN INSERT (' + @cols + N', dw_created_at, dw_updated_at) VALUES (' + @s + N', SYSDATETIME(), SYSDATETIME());
            ';
        FETCH NEXT FROM c INTO @fact, @stage, @keys;
    END
    CLOSE c; DEALLOCATE c;

    BEGIN TRAN;
        EXEC sys.sp_executesql @sql;
    COMMIT;
END
GO

-- CHỈ DÙNG KHI PHÁT TRIỂN / DEMO: xoá toàn bộ dữ liệu (staging, intermediate, kho, audit) để chạy lại từ FULL_001.
-- Khoá thay thế được cấp lại từ 1. Cấu trúc bảng, dòng Unknown và 3 ngày đặc biệt giữ nguyên.
CREATE OR ALTER PROC audit.usp_reset_all
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'TRUNCATE TABLE ' + QUOTENAME(SCHEMA_NAME(schema_id)) + N'.' + QUOTENAME(name) + N';'
    FROM sys.tables WHERE SCHEMA_NAME(schema_id) IN (N'staging', N'intermediate')
       OR (SCHEMA_NAME(schema_id) = N'dwh' AND name LIKE N'fact[_]%');
    EXEC sys.sp_executesql @sql;
    DELETE dwh.dim_customer WHERE customer_key <> 0;   DBCC CHECKIDENT ('dwh.dim_customer', RESEED, 0) WITH NO_INFOMSGS;
    DELETE dwh.dim_seller WHERE seller_key <> 0;       DBCC CHECKIDENT ('dwh.dim_seller', RESEED, 0) WITH NO_INFOMSGS;
    DELETE dwh.dim_product WHERE product_key <> 0;     DBCC CHECKIDENT ('dwh.dim_product', RESEED, 0) WITH NO_INFOMSGS;
    DELETE dwh.dim_geography WHERE geography_key <> 0; DBCC CHECKIDENT ('dwh.dim_geography', RESEED, 0) WITH NO_INFOMSGS;
    DELETE dwh.dim_date WHERE date_key > 0;
    DELETE dwh.dim_order_status WHERE status_key <> 0;
    DELETE dwh.dim_delivery_outcome WHERE outcome_key <> 0;
    DELETE audit.etl_step_log; DELETE audit.source_manifest; DELETE audit.extract_stat; DELETE audit.ingest_file;
    DELETE audit.reject_row;
    DELETE audit.dim_key_snapshot; DELETE audit.etl_run; DELETE audit.etl_batch;
    UPDATE audit.etl_metadata SET lset = NULL, cet = NULL, current_batch_id = NULL, last_batch_id = NULL, updated_at = NULL;
END
GO
PRINT N'Đã tạo các thủ tục audit cho package Transform, Load, Test.';
GO
