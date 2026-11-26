-- Task 2: bảng tạm *_load dùng nạp theo từng batch.
-- Chạy file này sau 00_database.sql, 01_audit.sql, 02_staging.sql.
-- Mỗi bảng tạm có đúng cấu trúc bảng staging chính (kể cả 5 cột truy vết).
USE OlistDW;
GO

DECLARE @tables TABLE (name sysname NOT NULL);
INSERT @tables (name) VALUES
    (N'orders'), (N'customers'), (N'order_items'), (N'order_reviews'),
    (N'order_payments'), (N'products'), (N'sellers'),
    (N'geolocation'), (N'category_translation');

DECLARE @name sysname, @sql nvarchar(max);

WHILE EXISTS (SELECT 1 FROM @tables)
BEGIN
    SELECT TOP (1) @name = name FROM @tables ORDER BY name;

    -- Tạo bảng tạm nếu chưa có; nếu có rồi thì giữ nguyên cấu trúc hiện tại.
    SET @sql = N'
        IF OBJECT_ID(N''staging.' + @name + N'_load'', N''U'') IS NULL
            SELECT TOP (0) *
            INTO staging.' + QUOTENAME(@name + N'_load') + N'
            FROM staging.' + QUOTENAME(@name) + N';
    ';
    EXEC sys.sp_executesql @sql;

    -- Dọn dòng sót lại từ lần chạy trước bị ngắt (Data Flow ghi vào đây trước khi swap).
    SET @sql = N'TRUNCATE TABLE staging.' + QUOTENAME(@name + N'_load') + N';';
    EXEC sys.sp_executesql @sql;

    DELETE FROM @tables WHERE name = @name;
END
GO

-- Kiểm tra nhanh: phải có 9 bảng *_load, cột giống bảng chính.
SELECT
    t.name AS base_table,
    l.name AS load_table,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS base_cols,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = l.object_id) AS load_cols
FROM sys.tables t
JOIN sys.tables l ON l.name = t.name + N'_load'
WHERE t.schema_id = SCHEMA_ID(N'staging')
ORDER BY t.name;
GO
