-- Task 2: các thủ tục dùng chung cho 9 Data Flow của Ingest_Staging.dtsx.
-- Chạy sau 01_audit.sql và 03_staging_load.sql.
-- Mục đích: Execute SQL Task trong SSIS chỉ cần gọi thủ tục, không phải dán lại
-- cùng một đoạn T-SQL 9 lần (và không phải nhớ mã kiểu dữ liệu SCID của tham số).
USE OlistDW;
GO

-- -----------------------------------------------------------------------------
-- 1) Chuyển dữ liệu từ staging.<bang>_load sang staging.<bang> trong 1 transaction.
--    Xoá phần cũ của cùng batch, chèn phần mới, lấy @@ROWCOUNT, dọn bảng tạm, COMMIT.
--    Kết quả trả về một cột rows_loaded để Execute SQL Task map vào User::rows_loaded.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROC audit.usp_swap_staging
    @table_name sysname,
    @batch_id   varchar(100)
AS
BEGIN
    SET NOCOUNT ON;

    IF @table_name NOT IN (
        N'orders', N'customers', N'order_items', N'order_reviews',
        N'order_payments', N'products', N'sellers',
        N'geolocation', N'category_translation')
    BEGIN
        THROW 50001, N'Tên bảng staging không hợp lệ.', 1;
    END;

    DECLARE @sql nvarchar(max) = N'
        BEGIN TRY
            BEGIN TRAN;

            DELETE FROM staging.' + QUOTENAME(@table_name) + N'
            WHERE source_batch_id = @batch_id;

            INSERT INTO staging.' + QUOTENAME(@table_name) + N'
            SELECT * FROM staging.' + QUOTENAME(@table_name + N'_load') + N';

            DECLARE @rows_loaded bigint = @@ROWCOUNT;

            TRUNCATE TABLE staging.' + QUOTENAME(@table_name + N'_load') + N';

            COMMIT TRAN;
            SELECT @rows_loaded AS rows_loaded;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
            THROW;
        END CATCH
    ';

    EXEC sys.sp_executesql
        @sql,
        N'@batch_id varchar(100)',
        @batch_id = @batch_id;
END
GO

-- -----------------------------------------------------------------------------
-- 2) Ghi audit cho một bảng: MERGE source_manifest + INSERT etl_step_log.
--    row_count của manifest là số dòng CẢ file (không phải số dòng sau lọc LSET).
--    Nếu rows_read <> rows_loaded thì ghi MISMATCH rồi THROW để package dừng lại.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROC audit.usp_write_ingest_audit
    @run_id          int,
    @batch_id        varchar(100),
    @table_name      varchar(200),
    @source_file     nvarchar(260),
    @source_checksum char(64),
    @row_count       bigint,
    @column_list     nvarchar(max),
    @rows_read       bigint,
    @rows_loaded     bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status varchar(20) =
        CASE WHEN @rows_read = @rows_loaded THEN 'SUCCESS' ELSE 'MISMATCH' END;

    BEGIN TRY
        BEGIN TRAN;

        MERGE audit.source_manifest AS t
        USING (
            SELECT @batch_id        AS batch_id,
                   @source_file     AS source_file,
                   @source_checksum AS source_checksum,
                   @row_count       AS row_count,
                   @column_list     AS column_list
        ) AS s
          ON t.batch_id = s.batch_id AND t.source_file = s.source_file
        WHEN MATCHED THEN
            UPDATE SET t.source_checksum = s.source_checksum,
                       t.row_count = s.row_count,
                       t.column_list = s.column_list
        WHEN NOT MATCHED THEN
            INSERT (batch_id, source_file, source_checksum, row_count, column_list)
            VALUES (s.batch_id, s.source_file, s.source_checksum, s.row_count, s.column_list);

        INSERT INTO audit.etl_step_log
            (run_id, step, table_name, rows_read, rows_loaded, rows_rejected, status)
        VALUES
            (@run_id, 'ingest', @table_name, @rows_read, @rows_loaded,
             @rows_read - @rows_loaded, @status);

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        THROW;
    END CATCH

    IF @status <> 'SUCCESS'
    BEGIN
        DECLARE @msg nvarchar(4000) = CONCAT(
            @table_name, N': đọc ', @rows_read, N' dòng nhưng nạp ', @rows_loaded, N' dòng.');
        THROW 50002, @msg, 1;
    END
END
GO

-- -----------------------------------------------------------------------------
-- 3) Đánh dấu đã nạp xong staging. Chuyển Sang SUCCESS chỉ sau khi dbt build xong
--    (việc của Master.dtsx / Task 3), nên ở đây chỉ dừng ở INGESTED.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROC audit.usp_mark_ingested
    @run_id   int,
    @batch_id varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE audit.etl_run
       SET status = 'INGESTED'
     WHERE run_id = @run_id;

    UPDATE audit.etl_batch
       SET status = 'INGESTED'
     WHERE batch_id = @batch_id;
END
GO

-- -----------------------------------------------------------------------------
-- 4) Dùng trong Event Handler OnError của Ingest_Staging.dtsx.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROC audit.usp_mark_failed
    @run_id       int,
    @batch_id     varchar(100),
    @table_name   varchar(200),
    @error_message nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg nvarchar(max) = LEFT(@error_message, 2000);

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO audit.etl_step_log (run_id, step, table_name, status, error_message)
        VALUES (@run_id, 'ingest', @table_name, 'FAILED', @msg);

        UPDATE audit.etl_run
           SET status = 'FAILED', ended_at = SYSDATETIME(), error_message = @msg
         WHERE run_id = @run_id;

        UPDATE audit.etl_batch
           SET status = 'FAILED', ended_at = SYSDATETIME()
         WHERE batch_id = @batch_id;

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        THROW;
    END CATCH
END
GO

PRINT N'Đã tạo 4 thủ tục hỗ trợ Task 2 trong schema audit.';
GO
