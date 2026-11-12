# Phương án chuyển sang SSIS (mới ghi lại, chưa làm)

Course plan tuần 5 ghi "Mini project làm với SSIS". Đề mini project thì yêu cầu Mage để nạp dữ liệu (mục 3.1), dbt để biến đổi (mục 3.2), và cho chọn SQL Server, PostgreSQL hoặc DuckDB (mục 2). Nhóm đang làm theo đề. Tài liệu này ghi lại những gì phải đổi và phải làm thêm nếu giảng viên hoặc TA yêu cầu dùng SSIS.

## 1. Hai mức chuyển

| Mức | SSIS làm gì | dbt | Ghi chú |
|---|---|---|---|
| **A (đề xuất)** | Thay Mage: nạp Nguồn → Staging, ghi audit, gọi dbt | Giữ nguyên vai trò Staging → DDS, chạy trên SQL Server bằng adapter `dbt-sqlserver` | Vẫn đủ mục 3.2 của đề (dbt test, dbt docs) |
| B | Làm cả Staging → DDS (Lookup, Slowly Changing Dimension, MERGE) | Bỏ | Mất phần dbt test và dbt docs của đề; chỉ làm khi được yêu cầu rõ |

## 2. Những gì giữ nguyên

- Mô hình dữ liệu: grain, 2 fact, 7 dimension, bảng khoá `km_*`, dòng Unknown khoá 0, khoá ngày -1/0/-2, các quy tắc nghiệp vụ.
- Dữ liệu nguồn và các số kiểm chứng: 1.550.922 dòng staging, 99.441 đơn, 112.650 dòng hàng, tỷ lệ trễ 6,77%, điểm trung bình 4,09, 303 đơn lệch thanh toán.
- Thiết kế 4 bảng audit và vòng đời trạng thái RUNNING → INGESTED → SUCCESS / FAILED.
- Logic các model dbt (chỉ đổi cú pháp SQL, mục 5).

## 3. Những gì phải đổi

| Thành phần | Hiện tại | Khi dùng SSIS |
|---|---|---|
| Máy chạy | Docker, chạy được trên Windows, macOS, Linux | **Chỉ Windows x64.** macOS và Linux chạy được SQL Server trong Docker nhưng không mở được trình thiết kế SSIS |
| Kho dữ liệu | File `warehouse/olist.duckdb` | SQL Server Developer (2022 hoặc 2025, miễn phí cho phát triển và kiểm thử), một database gồm 4 schema `staging`, `intermediate`, `dwh`, `audit` |
| Nạp dữ liệu | `olist_bi/custom/ingest_csv.py` (Mage) | Các package `.dtsx` trong một project SSIS mới (ví dụ thư mục `ssis/`) |
| Điều phối | Pipeline Mage 2 block | Package chính: gọi package nạp, rồi Execute Process Task chạy `dbt build`; lịch chạy bằng SQL Server Agent nếu cần |
| Biến đổi | `dbt-duckdb` | `dbt-sqlserver` và sửa SQL sang T-SQL |
| Kiểm tra kết quả | `scripts/query.py` + `sql/check_*.sql` | SSMS hoặc `sqlcmd`; viết lại các file `sql/` bằng T-SQL |
| Power BI | Đọc file DuckDB qua ODBC (dự kiến) | Kết nối thẳng SQL Server, đơn giản hơn |
| README | 3 hệ điều hành | Chỉ Windows |

## 4. Việc phải làm thêm

### 4.1. Cài đặt trên mỗi máy Windows

- SQL Server Developer và SSMS 22.
- Visual Studio 2022 Community và extension **SQL Server Integration Services Projects 2022+**. Visual Studio 2026 dùng chung extension này nhưng vẫn có người báo lỗi khi triển khai, nên dùng bản 2022 cho chắc.
- Python, `dbt-sqlserver` (chọn bản ổn định khớp phiên bản dbt-core) và ODBC Driver 18 for SQL Server.
- Máy 7,6 GB RAM chạy cùng lúc SQL Server, Visual Studio và Power BI sẽ chậm. Nên giới hạn bộ nhớ SQL Server (mục *max server memory*, ví dụ 2 GB).

### 4.2. Package nạp Nguồn → Staging (thay `ingest_csv.py`)

| `ingest_csv.py` đang làm | Cách làm trong SSIS |
|---|---|
| Tạo schema và 4 bảng audit | Execute SQL Task chạy bản T-SQL của `sql/00_schemas_audit.sql` |
| Ghi batch RUNNING, tạo lần chạy mới (attempt + 1) | Execute SQL Task, trả `run_id` vào biến của package |
| Tham số `batch_id`, `batch_type`, `raw_dir`, `is_simulated` | Project parameter hoặc package parameter |
| Đọc 9 file CSV, mọi cột giữ dạng chữ | Foreach Loop (File Enumerator) hoặc 9 Data Flow; Flat File Source với code page 65001 (UTF-8); mọi cột kiểu `DT_WSTR`, bảng đích `nvarchar` vì tên thành phố có dấu |
| Kiểm tra đủ cột bắt buộc | Script Task (C#) đọc dòng tiêu đề trước khi nạp |
| 5 cột truy vết | Derived Column cho tên file, mã batch, thời điểm nạp; Script Component đánh số thứ tự dòng; Script Task tính SHA-256 của file (SSIS không có sẵn) |
| Đếm dòng đọc và nạp | Row Count transformation ghi vào biến, rồi ghi vào `etl_step_log` |
| Chạy lại không sinh dòng trùng | Execute SQL Task `DELETE … WHERE source_batch_id = ?` trước Data Flow. Muốn xoá và nạp trong cùng một transaction thì phải bật `TransactionOption` (cần dịch vụ MSDTC), hoặc nạp vào bảng tạm rồi chuyển sang bảng chính bằng một câu SQL có transaction |
| Lỗi thì ghi FAILED và lý do | Event handler `OnError`: Execute SQL Task cập nhật `etl_run`, `etl_batch` và lưu `System::ErrorDescription` |

Khi triển khai package lên SSIS Catalog (SSISDB), SQL Server tự lưu lịch sử chạy. Báo cáo có thể nêu thêm phần này như một nguồn metadata audit có sẵn.

### 4.3. Chuyển SQL từ DuckDB sang T-SQL

| DuckDB (đang dùng) | T-SQL |
|---|---|
| `try_strptime(x, '%Y-%m-%d %H:%M:%S')` | `TRY_CONVERT(datetime2(0), x, 120)` |
| `try_cast(x as decimal(18, 2))` | `TRY_CAST(x AS decimal(18, 2))` (giống) |
| `regexp_full_match(x, '[0-9]{1,5}')` | SQL Server 2025: `REGEXP_LIKE(x, '^[0-9]{1,5}$')`, cần compatibility level 170. Bản cũ hơn: `x NOT LIKE '%[^0-9]%' AND LEN(x) BETWEEN 1 AND 5` |
| `lpad(x, 5, '0')` | `RIGHT(REPLICATE('0', 5) + x, 5)` |
| `translate(x, from, to)` | `TRANSLATE` (hai chuỗi phải dài bằng nhau) |
| `median(x)` | `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x) OVER (…)`; đây là hàm cửa sổ nên phải viết lại câu truy vấn |
| `date_diff('second', a, b)` | `DATEDIFF(second, a, b)` |
| `strftime(ts, '%Y%m%d')::int` | `YEAR(ts) * 10000 + MONTH(ts) * 100 + DAY(ts)` |
| `generate_series` (dựng `dim_date`) | `GENERATE_SERIES` (từ SQL Server 2022) hoặc CTE đệ quy |
| `x::int` (18 file) | `CAST(x AS int)` |
| `a \|\| b` | `CONCAT(a, b)` |
| `bool_and(x)` | `MIN(CASE WHEN x THEN 1 ELSE 0 END) = 1` |
| `interval`, `greatest` | `DATEADD`; `GREATEST` chỉ có từ SQL Server 2022 |
| Kiểu `boolean` | `bit` |
| Sequence + `nextval`, `INSERT … ON CONFLICT DO UPDATE`, `INSERT … BY NAME`, `RETURNING` (trong `ingest_csv.py` và `sql/`) | `SEQUENCE` hoặc `IDENTITY`; `MERGE`; ghi rõ danh sách cột; `OUTPUT inserted.*` |

Với dbt cần kiểm tra thêm:
- `dbt-sqlserver` có hỗ trợ chiến lược incremental `delete+insert` của 2 fact không; nếu không thì đổi sang `merge`.
- T-SQL không cho lồng `WITH` (CTE) bên trong truy vấn con và không cho `ORDER BY` trong view. Model nào viết kiểu đó phải sửa.

### 4.4. Kiểm chứng lại

- Chạy FULL_001 và so với bản DuckDB: số dòng staging, số dòng dim và fact, KPI trong `sql/check_warehouse.sql`.
- Chạy lại cùng batch không sinh dòng trùng. Cố ý làm lỗi thì batch thành FAILED. Batch incremental và kiểm tra T10 (bước 6).
- **Collation:** SQL Server mặc định không phân biệt chữ hoa và chữ thường, còn DuckDB thì có. Test `unique`, phép `distinct` và thứ tự sắp xếp có thể cho kết quả khác. Vì vậy khoá thay thế có thể được đánh số khác: chỉ so khoá nghiệp vụ và measure giữa hai bản, không so khoá thay thế.

### 4.5. Tài liệu, báo cáo, video

- Viết lại README cho Windows: cài đặt, mở project SSIS, chạy package, chạy dbt, kiểm tra.
- Báo cáo: sửa mục Kiến trúc, Triển khai, Metadata (thêm log của SSIS Catalog), chèn ảnh Control Flow và Data Flow.
- Quay video demo trên Windows.

## 5. Ước lượng công sức (thô, cho một người đã quen công cụ)

| Việc | Mức A | Mức B |
|---|---|---|
| Cài đặt | Nửa ngày mỗi máy | Như mức A |
| Package nạp và audit | 1–2 ngày | 1–2 ngày |
| Staging → DDS | 2–3 ngày (chuyển SQL dbt, chạy lại test) | 4–6 ngày (dựng lại bằng SSIS, tự viết kiểm thử) |
| Kiểm chứng, README, báo cáo | 1–2 ngày | 2 ngày |

## 6. Câu hỏi cần hỏi TA trước khi làm

1. Mini project bắt buộc SSIS hay làm theo đề (Mage và dbt)?
2. Nếu dùng SSIS: chỉ phần Nguồn → Staging (tuần 5) hay cả Staging → DDS?
3. Có bắt buộc SQL Server không, hay dùng DuckDB như mục 2 của đề được?

## Nguồn

- [Microsoft: SQL Server Integration Services Projects 2022+ GA](https://techcommunity.microsoft.com/blog/ssis/sql-server-integration-services-projects-2022-ga/4507575)
- [Microsoft Learn: Tải SQL Server Data Tools (SSDT)](https://learn.microsoft.com/sql/ssdt/download-sql-server-data-tools-ssdt)
- [Microsoft Q&A: lỗi khi dùng extension SSIS với Visual Studio 2026](https://learn.microsoft.com/en-us/answers/questions/5932788/problem-with-installation-of-ssis-projects-extensi)
- [dbt Docs: Kết nối Microsoft SQL Server với dbt Core](https://docs.getdbt.com/reference/warehouse-setups/mssql-setup)
- [PyPI: dbt-sqlserver](https://pypi.org/project/dbt-sqlserver)
- [Microsoft Learn: REGEXP_LIKE (Transact-SQL)](https://learn.microsoft.com/sql/t-sql/functions/regexp-like-transact-sql)
- [Microsoft: Regex trong SQL Server 2025 đã GA](https://devblogs.microsoft.com/azure-sql/general-availability-announcement-regex-support-in-sql-server-2025-azure-sql/)
- [MSSQLTips: Cài SQL Server 2025 Standard Developer Edition](https://www.mssqltips.com/sqlservertip/11453/install-sql-server-2025-standard-developer-edition/)
