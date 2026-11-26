-- Task 3 (SSIS): bảng kho dữ liệu (schema dwh), galaxy schema: 7 dimension, 2 fact.
-- Chạy sau 05. Dimension GIỮ dữ liệu qua các lần chạy (khoá thay thế không đổi), nên chỉ tạo khi chưa có.
--   Khoá thay thế = cột IDENTITY. Package Load_Dimensions chỉ CHÈN khoá nghiệp vụ mới (Lookup không khớp)
--   và CẬP NHẬT thuộc tính (SCD Type 1): khoá đã cấp không bao giờ đổi. Thay cho 6 bảng km_* của bản dbt.
--   Mỗi dimension có dòng Unknown khoá 0; dim_date có thêm 0, -1, -2.
-- Fact nạp lại toàn bộ mỗi lần chạy (TRUNCATE rồi nạp); khoá chính là khoá nghiệp vụ.
-- Muốn làm lại từ đầu (cấp khoá lại): chạy 06_dwh_reset.sql rồi chạy lại file này.
USE OlistDW;
GO
IF OBJECT_ID(N'dwh.dim_date', N'U') IS NULL
CREATE TABLE dwh.dim_date (
    date_key           int          NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,
    full_date          date         NULL,
    day_of_month       smallint     NULL,
    day_of_week_number smallint     NULL,   -- ISO: 1 = thứ Hai ... 7 = Chủ nhật
    day_of_week_name   nvarchar(10) NULL,
    month_number       smallint     NULL,
    month_name         nvarchar(10) NULL,
    year_month         char(7)      NULL,
    quarter_number     smallint     NULL,
    year_quarter       char(7)      NULL,
    calendar_year      smallint     NULL,
    member_type        nvarchar(20) NOT NULL
);

IF OBJECT_ID(N'dwh.dim_order_status', N'U') IS NULL
CREATE TABLE dwh.dim_order_status (
    status_key   smallint      NOT NULL CONSTRAINT PK_dim_order_status PRIMARY KEY,
    order_status nvarchar(255) NOT NULL CONSTRAINT UQ_dim_order_status UNIQUE,
    status_label nvarchar(50)  NOT NULL,
    status_group nvarchar(50)  NOT NULL
);

IF OBJECT_ID(N'dwh.dim_delivery_outcome', N'U') IS NULL
CREATE TABLE dwh.dim_delivery_outcome (
    outcome_key   smallint     NOT NULL CONSTRAINT PK_dim_delivery_outcome PRIMARY KEY,
    outcome_code  nvarchar(20) NOT NULL CONSTRAINT UQ_dim_delivery_outcome UNIQUE,
    outcome_label nvarchar(50) NOT NULL,
    sort_order    smallint     NOT NULL
);

IF OBJECT_ID(N'dwh.dim_customer', N'U') IS NULL
CREATE TABLE dwh.dim_customer (
    customer_key       int IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_customer PRIMARY KEY,
    customer_unique_id nvarchar(255) NOT NULL CONSTRAINT UQ_dim_customer UNIQUE,
    source_system      nvarchar(20)  NOT NULL,
    dw_created_at      datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at      datetime2(0)  NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID(N'dwh.dim_seller', N'U') IS NULL
CREATE TABLE dwh.dim_seller (
    seller_key    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_seller PRIMARY KEY,
    seller_id     nvarchar(255) NOT NULL CONSTRAINT UQ_dim_seller UNIQUE,
    source_system nvarchar(20)  NOT NULL,
    dw_created_at datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at datetime2(0)  NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID(N'dwh.dim_product', N'U') IS NULL
CREATE TABLE dwh.dim_product (
    product_key              int IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_product PRIMARY KEY,
    product_id               nvarchar(255) NOT NULL CONSTRAINT UQ_dim_product UNIQUE,
    category_name_original   nvarchar(255) NOT NULL,
    category_name_english    nvarchar(255) NOT NULL,
    product_weight_g         decimal(18,3) NULL,
    product_length_cm        decimal(18,3) NULL,
    product_height_cm        decimal(18,3) NULL,
    product_width_cm         decimal(18,3) NULL,
    missing_category_flag    smallint      NOT NULL,
    missing_translation_flag smallint      NOT NULL,
    dw_created_at            datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at            datetime2(0)  NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID(N'dwh.dim_geography', N'U') IS NULL
CREATE TABLE dwh.dim_geography (
    geography_key           int IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_geography PRIMARY KEY,
    zip_prefix              nvarchar(5)   NOT NULL CONSTRAINT UQ_dim_geography UNIQUE,
    country_code            nvarchar(2)   NOT NULL,
    state_code              nvarchar(255) NULL,
    city_normalized         nvarchar(255) NULL,
    city_state_label        nvarchar(520) NULL,
    latitude                decimal(10,7) NULL,
    longitude               decimal(10,7) NULL,
    variant_count           int           NOT NULL,
    location_conflict_flag  smallint      NOT NULL,
    state_conflict_flag     smallint      NOT NULL,
    coordinate_quality_code nvarchar(20)  NOT NULL,
    dw_created_at           datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at           datetime2(0)  NULL DEFAULT SYSDATETIME()
);
GO

-- Dòng Unknown khoá 0 (và 3 ngày đặc biệt). Chỉ chèn khi chưa có.
IF NOT EXISTS (SELECT 1 FROM dwh.dim_date WHERE date_key = 0)
    INSERT dwh.dim_date (date_key, member_type) VALUES (0, N'Unknown'), (-1, N'Not yet happened'), (-2, N'Invalid date');
IF NOT EXISTS (SELECT 1 FROM dwh.dim_order_status WHERE status_key = 0)
    INSERT dwh.dim_order_status VALUES (0, N'unknown', N'Unknown', N'Unknown');
IF NOT EXISTS (SELECT 1 FROM dwh.dim_delivery_outcome WHERE outcome_key = 0)
    INSERT dwh.dim_delivery_outcome VALUES (0, N'UNKNOWN', N'Không xác định', 99);
IF NOT EXISTS (SELECT 1 FROM dwh.dim_customer WHERE customer_key = 0)
BEGIN
    SET IDENTITY_INSERT dwh.dim_customer ON;
    INSERT dwh.dim_customer (customer_key, customer_unique_id, source_system) VALUES (0, N'UNKNOWN', N'olist_kaggle');
    SET IDENTITY_INSERT dwh.dim_customer OFF;
END
IF NOT EXISTS (SELECT 1 FROM dwh.dim_seller WHERE seller_key = 0)
BEGIN
    SET IDENTITY_INSERT dwh.dim_seller ON;
    INSERT dwh.dim_seller (seller_key, seller_id, source_system) VALUES (0, N'UNKNOWN', N'olist_kaggle');
    SET IDENTITY_INSERT dwh.dim_seller OFF;
END
IF NOT EXISTS (SELECT 1 FROM dwh.dim_product WHERE product_key = 0)
BEGIN
    SET IDENTITY_INSERT dwh.dim_product ON;
    INSERT dwh.dim_product (product_key, product_id, category_name_original, category_name_english,
                            missing_category_flag, missing_translation_flag)
    VALUES (0, N'UNKNOWN', N'Unknown', N'Unknown', 1, 1);
    SET IDENTITY_INSERT dwh.dim_product OFF;
END
IF NOT EXISTS (SELECT 1 FROM dwh.dim_geography WHERE geography_key = 0)
BEGIN
    SET IDENTITY_INSERT dwh.dim_geography ON;
    INSERT dwh.dim_geography (geography_key, zip_prefix, country_code, state_code, city_normalized, city_state_label,
                              variant_count, location_conflict_flag, state_conflict_flag, coordinate_quality_code)
    VALUES (0, N'UNK', N'BR', N'UN', N'unknown', N'Unknown', 0, 0, 0, N'UNKNOWN_MEMBER');
    SET IDENTITY_INSERT dwh.dim_geography OFF;
END
GO

-- ---------- Fact ----------
IF OBJECT_ID(N'dwh.fact_order_experience', N'U') IS NULL
CREATE TABLE dwh.fact_order_experience (
    order_id                        nvarchar(255) NOT NULL CONSTRAINT PK_fact_order_experience PRIMARY KEY,
    customer_key                    int           NOT NULL,
    customer_geography_key          int           NOT NULL,
    status_key                      smallint      NOT NULL,
    outcome_key                     smallint      NOT NULL,
    purchase_date_key               int           NOT NULL,
    approved_date_key               int           NOT NULL,
    carrier_date_key                int           NOT NULL,
    delivered_date_key              int           NOT NULL,
    estimated_date_key              int           NOT NULL,
    review_answer_date_key          int           NOT NULL,
    purchase_ts                     datetime2(0)  NULL,
    approved_ts                     datetime2(0)  NULL,
    carrier_ts                      datetime2(0)  NULL,
    delivered_ts                    datetime2(0)  NULL,
    estimated_ts                    datetime2(0)  NULL,
    order_count                     smallint      NOT NULL,
    delivered_count                 smallint      NOT NULL,
    delivery_eligible_count         smallint      NOT NULL,
    late_count                      smallint      NOT NULL,
    on_time_count                   smallint      NOT NULL,
    approval_seconds                int           NULL,
    handling_seconds                int           NULL,
    transit_seconds                 int           NULL,
    delivery_seconds                int           NULL,
    late_days                       int           NULL,
    representative_review_score     smallint      NULL,
    reviewed_order_count            smallint      NOT NULL,
    low_review_order_count          smallint      NOT NULL,
    review_record_count             int           NOT NULL,
    representative_review_id        nvarchar(255) NULL,
    representative_review_source_id nvarchar(300) NULL,
    review_creation_ts              datetime2(0)  NULL,
    review_answer_ts                datetime2(0)  NULL,
    review_before_delivery_flag     smallint      NULL,
    item_line_count                 int           NOT NULL,
    seller_count                    int           NOT NULL,
    invalid_approval_sequence       smallint      NOT NULL,
    invalid_handling_sequence       smallint      NOT NULL,
    invalid_transit_sequence        smallint      NOT NULL,
    invalid_delivery_sequence       smallint      NOT NULL,
    invalid_estimated_date          smallint      NOT NULL,
    quality_issue_count             int           NOT NULL,
    source_batch_id                 varchar(100)  NULL,
    dw_created_at                   datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at                   datetime2(0)  NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID(N'dwh.fact_order_item', N'U') IS NULL
CREATE TABLE dwh.fact_order_item (
    order_id                nvarchar(255) NOT NULL,
    order_item_id           int           NOT NULL,
    purchase_date_key       int           NOT NULL,
    shipping_limit_date_key int           NOT NULL,
    customer_key            int           NOT NULL,
    customer_geography_key  int           NOT NULL,
    product_key             int           NOT NULL,
    seller_key              int           NOT NULL,
    seller_geography_key    int           NOT NULL,
    shipping_limit_ts       datetime2(0)  NULL,
    item_line_count         smallint      NOT NULL,
    price_amount            decimal(18,2) NULL,
    freight_amount          decimal(18,2) NULL,
    item_total_amount       decimal(18,2) NULL,
    source_batch_id         varchar(100)  NULL,
    dw_created_at           datetime2(0)  NULL DEFAULT SYSDATETIME(),
    dw_updated_at           datetime2(0)  NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_order_item PRIMARY KEY (order_id, order_item_id)
);
GO

-- Bảng stage của fact: Load_Facts ghi dòng của các đơn bị ảnh hưởng vào đây, rồi usp_merge_facts MERGE vào fact.
IF OBJECT_ID(N'dwh.fact_order_experience_stage', N'U') IS NULL
    SELECT TOP (0) * INTO dwh.fact_order_experience_stage FROM dwh.fact_order_experience;
IF OBJECT_ID(N'dwh.fact_order_item_stage', N'U') IS NULL
    SELECT TOP (0) * INTO dwh.fact_order_item_stage FROM dwh.fact_order_item;
GO
PRINT N'Đã tạo 7 dimension (có dòng Unknown), 2 fact và 2 bảng stage trong schema dwh.';
GO
