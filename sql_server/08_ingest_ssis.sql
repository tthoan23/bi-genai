-- Task 3 (SSIS): phần SQL phục vụ package Ingest_Staging.dtsx (Extract, Validate, Load Staging).
-- Chạy sau 01, 02, 04 (dùng lại usp_swap_staging, usp_write_ingest_audit của Task 2) và 07.
-- Khác bản thiết kế Task 2: kiểm tra file, SHA-256 và số thứ tự dòng làm bằng SQL thay cho Script Task/Script Component.
--   - source_row_number: cột IDENTITY của bảng _load, tăng theo thứ tự dòng Data Flow ghi vào (đúng thứ tự file).
--   - source_checksum: thủ tục tính SHA-256 của cả file rồi điền vào bảng _load trước khi chuyển sang bảng chính.
-- SQL Server phải đọc được thư mục data/raw (OPENROWSET BULK).
USE OlistDW;
GO

-- Tạo lại 9 bảng _load: cùng thứ tự cột với bảng chính, riêng source_row_number là IDENTITY.
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
        + N');'
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'staging.' + @t);
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO

-- Validate: file đọc được, dòng tiêu đề đúng tên và thứ tự cột, rồi dọn bảng _load (đặt lại số dòng về 1).
CREATE OR ALTER PROC audit.usp_validate_source
    @table     sysname,
    @file_path nvarchar(400)
AS
BEGIN
    SET NOCOUNT ON;
    IF @table NOT IN (N'orders', N'customers', N'order_items', N'order_reviews', N'order_payments',
                      N'products', N'sellers', N'geolocation', N'category_translation')
        THROW 50001, N'Tên bảng staging không hợp lệ.', 1;

    DECLARE @head varbinary(4000), @msg nvarchar(2000);
    DECLARE @sql nvarchar(max) = N'SELECT @h = SUBSTRING(BulkColumn, 1, 2000) FROM OPENROWSET(BULK N'''
        + REPLACE(@file_path, N'''', N'''''') + N''', SINGLE_BLOB) f';
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@h varbinary(4000) OUTPUT', @h = @head OUTPUT;
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

    SET @sql = N'TRUNCATE TABLE staging.' + QUOTENAME(@table + N'_load');
    EXEC sys.sp_executesql @sql;
END
GO

-- Load Staging: điền SHA-256 và thời điểm nạp, chuyển _load sang bảng chính trong một transaction, ghi manifest và step log.
-- @rows_read là số dòng Data Flow đọc được từ file (Row Count).
CREATE OR ALTER PROC audit.usp_finish_ingest
    @batch_id  varchar(100),
    @table     sysname,
    @file_path nvarchar(400),
    @rows_read bigint
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sha char(64), @sql nvarchar(max);
    SET @sql = N'SELECT @s = LOWER(CONVERT(char(64), HASHBYTES(''SHA2_256'', BulkColumn), 2)) FROM OPENROWSET(BULK N'''
        + REPLACE(@file_path, N'''', N'''''') + N''', SINGLE_BLOB) f';
    EXEC sys.sp_executesql @sql, N'@s char(64) OUTPUT', @s = @sha OUTPUT;

    -- ingested_at do SQL Server điền: SSIS coi việc cắt phần lẻ giây của GETDATE() là lỗi truncation
    SET @sql = N'UPDATE staging.' + QUOTENAME(@table + N'_load') + N' SET source_checksum = @s, ingested_at = SYSDATETIME()';
    EXEC sys.sp_executesql @sql, N'@s char(64)', @s = @sha;

    DECLARE @r TABLE (rows_loaded bigint);
    INSERT @r EXEC audit.usp_swap_staging @table_name = @table, @batch_id = @batch_id;
    DECLARE @loaded bigint = (SELECT TOP (1) rows_loaded FROM @r);

    DECLARE @file nvarchar(260) = RIGHT(@file_path, CHARINDEX(N'\', REVERSE(N'\' + @file_path)) - 1);
    DECLARE @cols nvarchar(max) =
        (SELECT STRING_AGG(CAST(name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY column_id)
         FROM sys.columns
         WHERE object_id = OBJECT_ID(N'staging.' + @table)
           AND name NOT IN (N'source_file', N'source_checksum', N'source_row_number', N'source_batch_id', N'ingested_at'));
    DECLARE @run_id int = ISNULL(audit.fn_current_run_id(@batch_id), 0);
    DECLARE @full nvarchar(200) = N'staging.' + @table;

    EXEC audit.usp_write_ingest_audit @run_id = @run_id, @batch_id = @batch_id, @table_name = @full,
         @source_file = @file, @source_checksum = @sha, @row_count = @rows_read, @column_list = @cols,
         @rows_read = @rows_read, @rows_loaded = @loaded;
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
PRINT N'Đã tạo 9 bảng _load và thủ tục cho Ingest_Staging.';
GO
