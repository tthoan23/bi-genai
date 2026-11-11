-- Tạo các schema và 4 bảng audit trong DuckDB. Chạy lại nhiều lần vẫn an toàn (if not exists).
-- Block ingest_csv của Mage tự chạy file này trước mỗi lần nạp.

create schema if not exists staging;       -- bảng thô (mọi cột dạng text) và các view stg_* của dbt
create schema if not exists intermediate;  -- model trung gian của dbt
create schema if not exists dwh;           -- kho dữ liệu: dimension và fact
create schema if not exists audit;         -- nhật ký các lần nạp

create sequence if not exists audit.seq_batch start 1;
create sequence if not exists audit.seq_run start 1;
create sequence if not exists audit.seq_log start 1;

-- Mỗi đợt nạp (batch). batch_seq được cấp một lần khi batch xuất hiện lần đầu, chạy lại không đổi.
create table if not exists audit.etl_batch (
    batch_id     varchar primary key,
    batch_seq    integer not null default nextval('audit.seq_batch'),
    batch_type   varchar not null,                 -- FULL hoặc INCREMENTAL
    is_simulated boolean not null default false,   -- true nếu là batch mô phỏng
    status       varchar not null,                 -- RUNNING, INGESTED, SUCCESS, FAILED
    started_at   timestamp,
    ended_at     timestamp
);

-- Mỗi lần chạy một batch (chạy lại cùng batch thì attempt tăng thêm 1).
create table if not exists audit.etl_run (
    run_id        integer primary key default nextval('audit.seq_run'),
    batch_id      varchar not null,
    attempt       integer not null,
    status        varchar not null,
    started_at    timestamp not null,
    ended_at      timestamp,
    error_message varchar
);

-- Mỗi bước trong một lần chạy: nạp từng bảng, sau này thêm từng model và test của dbt.
create table if not exists audit.etl_step_log (
    log_id        integer primary key default nextval('audit.seq_log'),
    run_id        integer not null,
    step          varchar not null,                -- ingest hoặc dbt
    table_name    varchar,
    rows_read     bigint,
    rows_loaded   bigint,
    rows_rejected bigint,
    status        varchar not null,
    error_message varchar,
    logged_at     timestamp not null default current_timestamp
);

-- Thông tin từng file nguồn của mỗi batch, để đối chiếu lại sau.
create table if not exists audit.source_manifest (
    batch_id        varchar not null,
    source_file     varchar not null,
    source_checksum varchar not null,              -- SHA-256 của file
    row_count       bigint not null,
    column_list     varchar,
    primary key (batch_id, source_file)
);
