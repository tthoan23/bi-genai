USE OlistDW;
GO
IF OBJECT_ID(N'audit.seq_batch', N'SO') IS NULL
    CREATE SEQUENCE audit.seq_batch AS INT START WITH 1 INCREMENT BY 1;
GO
-- Mỗi đợt nạp (batch). batch_seq cấp một lần khi batch xuất hiện lần đầu, chạy lại không đổi.
IF OBJECT_ID(N'audit.etl_batch', N'U') IS NULL
CREATE TABLE audit.etl_batch (
    batch_id     VARCHAR(100) NOT NULL CONSTRAINT PK_etl_batch PRIMARY KEY,
    batch_seq    INT          NOT NULL CONSTRAINT DF_etl_batch_seq DEFAULT (NEXT VALUE FOR audit.seq_batch),
    batch_type   VARCHAR(20)  NOT NULL,                 -- FULL hoặc INCREMENTAL
    is_simulated BIT          NOT NULL CONSTRAINT DF_etl_batch_sim DEFAULT (0),
    status       VARCHAR(20)  NOT NULL,                 -- RUNNING, INGESTED, SUCCESS, FAILED
    started_at   DATETIME2(0) NULL,
    ended_at     DATETIME2(0) NULL
);

-- Mỗi lần chạy một batch (chạy lại cùng batch thì attempt tăng thêm 1).
IF OBJECT_ID(N'audit.etl_run', N'U') IS NULL
CREATE TABLE audit.etl_run (
    run_id        INT           IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_run PRIMARY KEY,
    batch_id      VARCHAR(100)  NOT NULL,
    attempt       INT           NOT NULL,
    status        VARCHAR(20)   NOT NULL,
    started_at    DATETIME2(0)  NOT NULL,
    ended_at      DATETIME2(0)  NULL,
    error_message NVARCHAR(MAX) NULL
);

-- Mỗi bước trong một lần chạy: nạp từng bảng, sau này thêm từng model và test của dbt.
IF OBJECT_ID(N'audit.etl_step_log', N'U') IS NULL
CREATE TABLE audit.etl_step_log (
    log_id        INT           IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_step_log PRIMARY KEY,
    run_id        INT           NOT NULL,
    step          VARCHAR(20)   NOT NULL,               -- ingest hoặc dbt
    table_name    VARCHAR(200)  NULL,
    rows_read     BIGINT        NULL,
    rows_loaded   BIGINT        NULL,
    rows_rejected BIGINT        NULL,
    status        VARCHAR(20)   NOT NULL,
    error_message NVARCHAR(MAX) NULL,
    logged_at     DATETIME2(0)  NOT NULL CONSTRAINT DF_etl_step_log_at DEFAULT (SYSDATETIME())
);

-- Thông tin từng file nguồn của mỗi batch, để đối chiếu lại sau.
IF OBJECT_ID(N'audit.source_manifest', N'U') IS NULL
CREATE TABLE audit.source_manifest (
    batch_id        VARCHAR(100)  NOT NULL,
    source_file     NVARCHAR(260) NOT NULL,
    source_checksum VARCHAR(64)   NOT NULL,             -- SHA-256 của file
    row_count       BIGINT        NOT NULL,
    column_list     NVARCHAR(MAX) NULL,
    CONSTRAINT PK_source_manifest PRIMARY KEY (batch_id, source_file)
);
GO