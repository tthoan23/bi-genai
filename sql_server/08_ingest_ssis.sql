-- Task 3 (SSIS): phần SQL của Ingest_Staging.dtsx (Extract, Validate, Load Staging), hỗ trợ Full và Incremental Load.
-- Chạy sau 01, 02, 04, 07. Chạy lại nhiều lần vẫn an toàn.
--
-- Luồng của mỗi file (một Sequence trong package):
--   1. usp_validate_source : file đọc được, tiêu đề đúng, tính SHA-256. File đã nạp ở batch thành công -> bỏ qua.
--                            Trả về skip, LSET, CET cho package (biến SSIS).
--   2. Data Flow           : đọc CSV, gắn cột truy vết và cờ in_window (LSET < mốc thời gian <= CET), ghi vào _load.
--   3. usp_finish_ingest   : kiểm tra số dòng TRƯỚC khi ghi; FULL: chuyển mọi dòng sang staging;
--                            INCREMENTAL: chỉ chuyển dòng trong cửa sổ LSET/CET HOẶC dòng mới / đổi nội dung
--                            (so mã băm với bản mới nhất của batch trước). Một transaction.
-- source_row_number = cột IDENTITY của _load (thứ tự dòng trong file). SQL Server phải đọc được thư mục dữ liệu.
USE OlistDW;
GO

-- 9 bảng _load: cùng cột với bảng staging chính (source_row_number là IDENTITY) và thêm cột in_window.
DECLARE @t sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM (VALUES (N'orders'), (N'customers'), (N'order_items'), (N'order_reviews'), (N'order_payments'),
                             (N'products'), (N'sellers'), (N'geolocation'), (N'category_translation')) v(name);
OPEN c;
FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @sql = N'DROP TABLE IF EXISTS staging.' + QUOTENAME(@t + N'_load') + N'; CREATE TABLE staging.'
        + QUOTENAME(@t + N'_load') + N' (' +
        STRING_AGG(CAST(QUOTENAME(c.name) + N' ' +
            CASE WHEN c.name = N'source_row_number' THEN N'int IDENTITY(1,1) NOT NULL'
                 ELSE ty.name +
                      CASE WHEN ty.name IN (N'nvarchar', N'nchar') THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS nvarchar(10)) END + N')'
                           WHEN ty.name IN (N'varchar', N'char') THEN N'(' + CAST(c.max_length AS nvarchar(10)) + N')'
                           WHEN ty.name = N'datetime2' THEN N'(' + CAST(c.scale AS nvarchar(10)) + N')'
                           ELSE N'' END + N' NULL'
            END AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY c.column_id)
        + N', [in_window] bit NULL);'
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'staging.' + @t);
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO

-- SHA-256 của file tính ở bước Validate, dùng lại ở bước Load Staging (không đọc file hai lần).
IF OBJECT_ID(N'audit.ingest_file', N'U') IS NULL
CREATE TABLE audit.ingest_file (
    batch_id   varchar(100)  NOT NULL,
    table_name sysname       NOT NULL,
    file_path  nvarchar(400) NOT NULL,
    sha256     char(64)      NOT NULL,
    CONSTRAINT PK_ingest_file PRIMARY KEY (batch_id, table_name)
);
GO

-- Khoá nghiệp vụ của từng bảng nguồn (dùng để so phiên bản giữa các batch). NULL = không có khoá:
-- so cả dòng (dòng có nội dung chưa từng thấy là dòng mới).
CREATE OR ALTER FUNCTION audit.fn_source_key (@table sysname, @alias sysname)
RETURNS nvarchar(400)
AS
BEGIN
    RETURN CASE @table
        WHEN N'orders'               THEN N'TRIM(' + @alias + N'.order_id)'
        WHEN N'customers'            THEN N'TRIM(' + @alias + N'.customer_id)'
        WHEN N'order_items'          THEN N'CONCAT(TRIM(' + @alias + N'.order_id), N''|'', TRIM(' + @alias + N'.order_item_id))'
        WHEN N'order_payments'       THEN N'CONCAT(TRIM(' + @alias + N'.order_id), N''|'', TRIM(' + @alias + N'.payment_sequential))'
        WHEN N'order_reviews'        THEN N'CONCAT(TRIM(' + @alias + N'.review_id), N''|'', TRIM(' + @alias + N'.order_id))'
        WHEN N'products'             THEN N'TRIM(' + @alias + N'.product_id)'
        WHEN N'sellers'              THEN N'TRIM(' + @alias + N'.seller_id)'
        WHEN N'category_translation' THEN N'LOWER(TRIM(' + @alias + N'.product_category_name))'
    END;   -- geolocation: NULL
END
GO

-- Mã băm nội dung một dòng: mọi cột nguồn, NULL phân biệt với chuỗi rỗng.
CREATE OR ALTER FUNCTION audit.fn_row_hash_expr (@table sysname, @alias sysname)
RETURNS nvarchar(max)
AS
BEGIN
    RETURN N'HASHBYTES(''SHA2_256'', CONCAT_WS(NCHAR(31), ' +
        (SELECT STRING_AGG(CAST(N'ISNULL(' + @alias + N'.' + QUOTENAME(name) + N', NCHAR(30))' AS nvarchar(max)), N', ')
                WITHIN GROUP (ORDER BY column_id)
         FROM sys.columns
         WHERE object_id = OBJECT_ID(N'staging.' + @table)
           AND name NOT IN (N'source_file', N'source_checksum', N'source_row_number', N'source_batch_id', N'ingested_at'))
        + N'))';
END
GO

-- Bước 1 (Validate). Trả về MỘT dòng: skip (1 = file đã nạp, bỏ qua), lset, cet (chuỗi yyyy-mm-dd hh:mm:ss).
CREATE OR ALTER PROC audit.usp_validate_source
    @table     sysname,
    @file_path nvarchar(400),
    @batch_id  varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    IF @table NOT IN (N'orders', N'customers', N'order_items', N'order_reviews', N'order_payments',
                      N'products', N'sellers', N'geolocation', N'category_translation')
        THROW 50001, N'Tên bảng staging không hợp lệ.', 1;

    DECLARE @head varbinary(4000), @sha char(64), @msg nvarchar(2000);
    DECLARE @sql nvarchar(max) = N'SELECT @h = SUBSTRING(BulkColumn, 1, 2000), '
        + N'@s = LOWER(CONVERT(char(64), HASHBYTES(''SHA2_256'', BulkColumn), 2)) FROM OPENROWSET(BULK N'''
        + REPLACE(@file_path, N'''', N'''''') + N''', SINGLE_BLOB) f';
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@h varbinary(4000) OUTPUT, @s char(64) OUTPUT', @h = @head OUTPUT, @s = @sha OUTPUT;
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'Không đọc được file ', @file_path, N': ', ERROR_MESSAGE());
        THROW 50030, @msg, 1;
    END CATCH

    IF SUBSTRING(@head, 1, 3) = 0xEFBBBF SET @head = SUBSTRING(@head, 4, 3997);   -- bỏ BOM
    DECLARE @text varchar(2000) = CAST(@head AS varchar(2000));
    DECLARE @header varchar(2000) = REPLACE(REPLACE(LEFT(@text, CHARINDEX(CHAR(10), @text + CHAR(10)) - 1), CHAR(13), ''), '"', '');
    DECLARE @expected varchar(2000) =
        (SELECT STRING_AGG(CAST(name AS varchar(200)), ',') WITHIN GROUP (ORDER BY column_id)
         FROM sys.columns
         WHERE object_id = OBJECT_ID(N'staging.' + @table)
           AND name NOT IN (N'source_file', N'source_checksum', N'source_row_number', N'source_batch_id', N'ingested_at'));
    IF @header IS NULL OR @header <> @expected
    BEGIN
        SET @msg = CONCAT(N'Sai tiêu đề file ', @file_path, N'. Mong đợi: ', @expected, N' | Thực tế: ', @header);
        THROW 50031, @msg, 1;
    END

    DELETE audit.ingest_file WHERE batch_id = @batch_id AND table_name = @table;
    -- Dòng lỗi còn sót của lần chạy trước bị ngắt giữa chừng (chưa được chốt run_id)
    DELETE audit.reject_row WHERE batch_id = @batch_id AND table_name = @table AND stage = 'extract' AND run_id IS NULL;
    INSERT audit.ingest_file (batch_id, table_name, file_path, sha256) VALUES (@batch_id, @table, @file_path, @sha);
    SET @sql = N'TRUNCATE TABLE staging.' + QUOTENAME(@table + N'_load');
    EXEC sys.sp_executesql @sql;

    -- Không nạp lại file cũ: cùng tên và cùng nội dung (SHA-256) đã được nạp ở một batch từng chạy thành công
    -- (kể cả chính batch này ở lần chạy trước: usp_start_run đã đổi trạng thái batch sang RUNNING, nên xét etl_run).
    DECLARE @file nvarchar(260) = RIGHT(@file_path, CHARINDEX(N'\', REVERSE(N'\' + @file_path)) - 1);
    DECLARE @skip int = CASE WHEN EXISTS (
        SELECT 1 FROM audit.source_manifest m
        WHERE m.source_file = @file AND m.source_checksum = @sha
          AND EXISTS (SELECT 1 FROM audit.etl_run r WHERE r.batch_id = m.batch_id AND r.status = 'SUCCESS'))
        THEN 1 ELSE 0 END;

    -- Bảng có mốc thời gian (orders, order_reviews) mới có LSET/CET; bảng khác chỉ so mã băm
    DECLARE @mode varchar(20) = (SELECT batch_type FROM audit.etl_batch WHERE batch_id = @batch_id);
    DECLARE @lset_m datetime2(0), @cet_m datetime2(0);
    SELECT @lset_m = CASE WHEN @mode = 'FULL' THEN NULL ELSE lset END, @cet_m = cet
    FROM audit.etl_metadata WHERE source_name = @table;
    DECLARE @lset datetime2(0) = ISNULL(@lset_m, '1900-01-01 00:00:00'),
            @cet  datetime2(0) = ISNULL(@cet_m, '9999-12-31 23:59:59');

    IF @skip = 1
    BEGIN
        DECLARE @run_id int = ISNULL(audit.fn_current_run_id(@batch_id), 0);
        DELETE audit.extract_stat WHERE batch_id = @batch_id AND run_id = @run_id AND table_name = @table;
        INSERT audit.extract_stat (batch_id, run_id, table_name, load_mode, lset, cet, file_sha256, file_skipped)
        VALUES (@batch_id, @run_id, @table, @mode, @lset_m, @cet_m, @sha, 1);
        INSERT audit.etl_step_log (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status, error_message)
        VALUES (ISNULL(audit.fn_current_run_id(@batch_id), 0), 'ingest', N'staging.' + @table, 0, 0, 0, 'SKIPPED',
                N'File đã nạp ở batch thành công trước (cùng SHA-256)');
    END

    SELECT @skip AS skip, CONVERT(varchar(19), @lset, 120) AS lset, CONVERT(varchar(19), @cet, 120) AS cet;
END
GO

-- Bước 3 (Load Staging). @rows_read = số dòng Data Flow đọc từ file (Row Count).
CREATE OR ALTER PROC audit.usp_finish_ingest
    @batch_id  varchar(100),
    @table     sysname,
    @file_path nvarchar(400),
    @rows_read bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @sql nvarchar(max), @msg nvarchar(2000), @n bigint;
    DECLARE @load nvarchar(300) = N'staging.' + QUOTENAME(@table + N'_load');
    DECLARE @main nvarchar(300) = N'staging.' + QUOTENAME(@table);
    DECLARE @sha char(64) = (SELECT sha256 FROM audit.ingest_file WHERE batch_id = @batch_id AND table_name = @table);
    DECLARE @mode varchar(20) = (SELECT batch_type FROM audit.etl_batch WHERE batch_id = @batch_id);
    DECLARE @lset datetime2(0), @cet datetime2(0);
    SELECT @lset = lset, @cet = cet FROM audit.etl_metadata WHERE source_name = @table;
    IF @mode = 'FULL' SET @lset = NULL;
    DECLARE @run_id int = ISNULL(audit.fn_current_run_id(@batch_id), 0);

    -- Dòng Flat File Source không đọc được đã được Data Flow chuyển sang audit.reject_row (Error Output):
    -- chốt lần chạy cho chúng và đếm. File có rows_read + rows_rejected dòng.
    UPDATE audit.reject_row SET run_id = @run_id, rejected_at = SYSDATETIME(),
           error_description = ISNULL(error_description, N'Flat File Source không đọc được dòng (sai cấu trúc hoặc giá trị dài quá độ rộng cột)')
    WHERE batch_id = @batch_id AND table_name = @table AND stage = 'extract' AND run_id IS NULL;
    DECLARE @rejected bigint = @@ROWCOUNT;

    -- Đối chiếu số dòng TRƯỚC khi ghi vào staging
    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM ' + @load;
    EXEC sys.sp_executesql @sql, N'@c bigint OUTPUT', @c = @n OUTPUT;
    IF @n <> @rows_read
    BEGIN
        SET @msg = CONCAT(@table, N': Data Flow đọc ', @rows_read, N' dòng nhưng bảng _load có ', @n, N' dòng. Không nạp.');
        THROW 50002, @msg, 1;
    END

    DECLARE @cols nvarchar(max) =
        (SELECT STRING_AGG(CAST(QUOTENAME(name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY column_id)
         FROM sys.columns WHERE object_id = OBJECT_ID(@main));
    DECLARE @key nvarchar(400) = audit.fn_source_key(@table, N'x');
    DECLARE @hash nvarchar(max) = audit.fn_row_hash_expr(@table, N'x');
    DECLARE @in_window bigint, @changed_only bigint, @extracted bigint;

    -- Đánh dấu dòng cần lấy: FULL lấy tất cả; INCREMENTAL lấy dòng trong cửa sổ LSET/CET hoặc dòng mới / đổi nội dung
    CREATE TABLE #pick (source_row_number int PRIMARY KEY, in_window bit NOT NULL, changed bit NOT NULL);
    IF @mode = 'FULL'
        SET @sql = N'INSERT #pick SELECT x.source_row_number, ISNULL(x.in_window, 0), 1 FROM ' + @load + N' x';
    ELSE
        SET @sql = N'
        WITH cur AS (SELECT x.source_row_number, ISNULL(x.in_window, 0) AS in_window, '
            + ISNULL(@key, @hash) + N' AS k, ' + @hash + N' AS h FROM ' + @load + N' x),
        prev AS (SELECT k, h FROM (
                    SELECT ' + ISNULL(@key, @hash) + N' AS k, ' + @hash + N' AS h,
                           ROW_NUMBER() OVER (PARTITION BY ' + ISNULL(@key, @hash) + N'
                                              ORDER BY b.batch_seq DESC, x.source_row_number DESC) AS rn
                    FROM ' + @main + N' x LEFT JOIN audit.etl_batch b ON b.batch_id = x.source_batch_id
                    WHERE x.source_batch_id <> @batch) p WHERE rn = 1)
        INSERT #pick
        SELECT cur.source_row_number, cur.in_window,
               CASE WHEN prev.h IS NULL OR prev.h <> cur.h THEN 1 ELSE 0 END
        FROM cur LEFT JOIN prev ON prev.k = cur.k;';
    EXEC sys.sp_executesql @sql, N'@batch varchar(100)', @batch = @batch_id;

    SELECT @in_window = SUM(CAST(in_window AS int)),
           @changed_only = SUM(CASE WHEN changed = 1 AND in_window = 0 THEN 1 ELSE 0 END),
           @extracted = SUM(CASE WHEN in_window = 1 OR changed = 1 THEN 1 ELSE 0 END)
    FROM #pick;

    BEGIN TRAN;
        SET @sql = N'UPDATE ' + @load + N' SET source_checksum = @s, ingested_at = SYSDATETIME();
                     DELETE ' + @main + N' WHERE source_batch_id = @batch;
                     INSERT ' + @main + N' (' + @cols + N')
                     SELECT ' + @cols + N' FROM ' + @load + N' l
                     WHERE EXISTS (SELECT 1 FROM #pick p WHERE p.source_row_number = l.source_row_number
                                     AND (p.in_window = 1 OR p.changed = 1));';
        EXEC sys.sp_executesql @sql, N'@s char(64), @batch varchar(100)', @s = @sha, @batch = @batch_id;

        DECLARE @file nvarchar(260) = RIGHT(@file_path, CHARINDEX(N'\', REVERSE(N'\' + @file_path)) - 1);
        DECLARE @col_list nvarchar(max) =
            (SELECT STRING_AGG(CAST(name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY column_id)
             FROM sys.columns WHERE object_id = OBJECT_ID(@main)
               AND name NOT IN (N'source_file', N'source_checksum', N'source_row_number', N'source_batch_id', N'ingested_at'));
        MERGE audit.source_manifest AS t
        USING (SELECT @batch_id AS batch_id, @file AS source_file) AS s
           ON t.batch_id = s.batch_id AND t.source_file = s.source_file
        WHEN MATCHED THEN UPDATE SET source_checksum = @sha, row_count = @rows_read + @rejected, column_list = @col_list
        WHEN NOT MATCHED THEN INSERT (batch_id, source_file, source_checksum, row_count, column_list)
                              VALUES (@batch_id, @file, @sha, @rows_read + @rejected, @col_list);

        INSERT audit.etl_step_log (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status)
        VALUES (@run_id, 'ingest', N'staging.' + @table,
                @rows_read + @rejected, ISNULL(@extracted, 0), @rejected, 'SUCCESS');

        DELETE audit.extract_stat WHERE batch_id = @batch_id AND run_id = @run_id AND table_name = @table;
        INSERT audit.extract_stat (batch_id, run_id, table_name, load_mode, lset, cet, file_sha256, file_skipped,
                                   rows_read, rows_in_window, rows_changed_outside_window, rows_extracted, rows_unchanged,
                                   rows_rejected)
        VALUES (@batch_id, @run_id, @table, @mode, @lset, @cet, @sha, 0, @rows_read, ISNULL(@in_window, 0),
                ISNULL(@changed_only, 0), ISNULL(@extracted, 0), @rows_read - ISNULL(@extracted, 0), @rejected);

        SET @sql = N'TRUNCATE TABLE ' + @load;
        EXEC sys.sp_executesql @sql;
    COMMIT;
END
GO

-- Cuối Ingest_Staging: batch đã nạp xong staging.
CREATE OR ALTER PROC audit.usp_finish_staging
    @batch_id varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id int = audit.fn_current_run_id(@batch_id);
    EXEC audit.usp_mark_ingested @run_id = @run_id, @batch_id = @batch_id;
END
GO
PRINT N'Đã tạo 9 bảng _load và thủ tục cho Ingest_Staging (Full và Incremental).';
GO
