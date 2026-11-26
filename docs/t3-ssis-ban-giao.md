# Bàn giao Task 3 (Mini project Olist): dựng ETL bằng SSIS

Tài liệu này để dán vào Claude trong Visual Studio (hoặc trợ lý khác) khi làm tiếp. Đọc hết trước khi làm.
Cập nhật: 26/11/2026, nhánh `ssis/t3-ssis-etl`.

## 1. Mục tiêu

Dùng **chỉ SSIS** để đi từ file nguồn CSV đến kho dữ liệu (fact, dimension), theo đúng quy trình:

```
Extract → Validate → Load Staging → Transform → Load Dimensions → Load Facts → Test
```

Cách dựng giống bài HW4 (`HW4/HW4-23127038`): Control Flow gồm các Data Flow Task nối nhau; mỗi Data Flow là
`Source → Derived Column (và các thành phần khác) → OLE DB Destination`. **Nguồn là 9 file CSV trong `data/raw/`**,
đọc bằng **Flat File Source**. Không dùng Python hay dbt để nạp hay biến đổi dữ liệu.

## 2. Môi trường trên máy

| Thành phần | Giá trị |
|---|---|
| SQL Server | `localhost\SQLEXPRESS` (thực chất SQL Server 2025 Developer), đăng nhập Windows |
| Database | `OlistDW`, collation `SQL_Latin1_General_CP1_CI_AS` (không phân biệt hoa thường) |
| Visual Studio | 2022 Community, có extension SSIS. Mở `ssis/OlistETL/OlistETL.sln` (VS 17.11 không mở được `.slnx`) |
| Project SSIS | `ssis/OlistETL/OlistETL/OlistETL.dtproj` (Task 1 tạo). Project deployment model, `DontSaveSensitive`, target SQL Server 2025 |
| Connection project | `OlistDW.conmgr` (OLE DB, MSOLEDBSQL), server và database lấy từ project parameter |
| Project parameter | `SqlServerName`=`localhost\SQLEXPRESS`, `DatabaseName`=`OlistDW`, `RawDir`=`D:\uni\nam4ky1\IS_for_BI\minipro\repo_code\data\raw`, `BatchId`=`FULL_001`, `BatchType` |
| Chạy package | **Chỉ chạy được trong Visual Studio (F5)**. Máy chưa cài tính năng Integration Services nên DTExec từ dòng lệnh báo lỗi bản quyền; nhóm đã quyết định không cài |

## 3. Quy ước nhóm (không tự đổi)

- 4 schema: `staging` (bảng thô), `intermediate` (bảng trung gian), `dwh` (kho), `audit` (nhật ký).
- Bảng thô `staging.<bang>`: cột nguồn giữ nguyên tên, kiểu `nvarchar`, thêm 5 cột truy vết `source_file`, `source_checksum`, `source_row_number`, `source_batch_id`, `ingested_at` (đã tạo bởi `sql_server/02_staging.sql`).
- 4 bảng audit: `etl_batch`, `etl_run`, `etl_step_log`, `source_manifest` (`sql_server/01_audit.sql`). Vòng đời batch: `RUNNING → INGESTED → SUCCESS` hoặc `FAILED`.
- Mô hình kho giữ nguyên bản đã chốt: galaxy schema, 2 fact, 7 dimension, dòng Unknown khoá 0, `dim_date` có khoá đặc biệt 0 (thiếu), -1 (chưa xảy ra), -2 (ngày lỗi).
- Mỗi task một nhánh `ssis/t1…t4`, mở Pull Request vào `main`, không đẩy thẳng `main`, không commit mật khẩu.

## 4. Đã có gì, của ai

| Ở đâu | Nội dung | Dùng tiếp? |
|---|---|---|
| Task 1 (`sql_server/00, 01, 02`, khung project) | Database, schema, bảng audit, 9 bảng staging, project SSIS rỗng | Có |
| Task 2 (`sql_server/03, 04`, `ssis/OlistETL/Scripts/*.cs`, `docs/task2-nap-staging.md`) | Thiết kế package `Ingest_Staging.dtsx` (CSV → staging), bảng `*_load`, thủ tục `audit.usp_swap_staging`, `usp_write_ingest_audit`, `usp_mark_ingested`, `usp_mark_failed`; code C# Script Task kiểm tra tiêu đề và tính SHA-256. **Package chưa được dựng** | Có: đây chính là bước Extract, Validate, Load Staging |
| Task 4 (đã gộp) | Mô tả cho mô hình dbt, ảnh lineage | Chỉ để tham khảo |
| Task 3 nhánh `ssis/t3-dbt` | Toàn bộ logic biến đổi đã viết lại bằng T-SQL và **đã kiểm chứng khớp bản DuckDB từng dòng** (`olist_dbt/models/`) | Dùng làm **đặc tả logic** cho Derived Column và câu SQL nguồn |

### Việc Task 3 đã làm trên nhánh này (chưa commit)

| File | Nội dung |
|---|---|
| `ssis/OlistETL/OlistETL/*.dtsx` | 7 package: `Master`, `Ingest_Staging`, `Transform_Clean`, `Transform_Business`, `Load_Dimensions`, `Load_Facts`, `Test_DW` (đã đăng ký trong `.dtproj`). `Package.dtsx` rỗng của Task 1 giữ nguyên |
| `ssis/OlistETL/OlistETL.sln` | Solution cho VS 17.11 |
| `sql_server/05_transform_tables.sql` | 9 bảng `intermediate.cln_*`, 7 bảng `intermediate.int_*`. Xoá và tạo lại mọi bảng trong schema `intermediate` |
| `sql_server/06_dwh_tables.sql`, `06_dwh_reset.sql` | 7 dimension (khoá `IDENTITY`, dòng Unknown), 2 fact |
| `sql_server/07_etl_procs.sql` | Thủ tục audit, dựng `dim_date`, kiểm thử kho `usp_check_dw` |
| `sql_server/08_ingest_ssis.sql` | Bảng `_load` có `source_row_number` IDENTITY (thay `03`), thủ tục kiểm tra file, SHA-256, swap |
| `ssis/OlistETL/queries/` | Câu SQL dùng trong OLE DB Source (nội dung đã nhúng vào package) |
| `ssis/tools/` | Công cụ phát triển: `build.ps1` (sinh package từ `BuildOlistEtl.cs`), `register_packages.py`, `validate_ispac.ps1`, `verify_dw.py`, `make_queries.py` |

Đã kiểm tra: 7 package Validate đạt với database thật; Visual Studio build project thành công; thủ tục ingest,
`usp_build_dim_date` (1.317 dòng, khớp bản tham chiếu) và các câu SQL nguồn đã chạy thử.
Kết quả chạy thật (26/11, Master batch `FULL_001`, 3 lần): mọi tầng khớp bản tham chiếu từng dòng
(`verify_dw.py`); KPI 99.441 đơn, trễ 6,77%, điểm 4,09, tiền hàng 13.591.643,70 BRL; Test_DW 10 PASS, 1 WARN (T13, 303 đơn);
chạy lại không đổi số dòng và 151.323 khoá thay thế của dimension. Còn thiếu: incremental load, reject theo dòng.

## 5. Kiến trúc đã dựng

Giữ bước staging theo quy ước nhóm: CSV → `staging` → `intermediate` → `dwh`.

| Package | Công đoạn | Nguồn → đích | Thành phần chính |
|---|---|---|---|
| `Ingest_Staging` | Extract, Validate, Load Staging | CSV `data/raw` → `staging.*` | Mỗi file một Sequence: Execute SQL (kiểm tra tiêu đề) → Data Flow (Flat File Source, Row Count, Derived Column, OLE DB Destination vào `_load`) → Execute SQL (SHA-256, swap, audit) |
| `Transform_Clean` | Transform (làm sạch) | `staging.*` → `cln_*` | OLE DB Source (bản mới nhất theo batch), Derived Column, Data Conversion, Sort bỏ trùng toạ độ |
| `Transform_Business` | Transform (nghiệp vụ) | `cln_*` → `int_*` | Lookup, Aggregate, Derived Column; trung vị toạ độ, đánh giá đại diện, full outer join bằng SQL nguồn |
| `Load_Dimensions` | Load Dimensions | `cln_*`, `int_*`, CSV seed → `dim_*` | Lookup (không khớp thì chèn), Conditional Split và OLE DB Command (SCD 1); `dim_date` bằng thủ tục |
| `Load_Facts` | Load Facts | `int_*`, `cln_*` → `fact_*` | TRUNCATE, chuỗi Lookup, Derived Column (khoá ngày, measure) |
| `Test_DW` | Test | kho | `audit.usp_check_dw` (T02–T13) |
| `Master` | Điều phối | | Execute Package Task theo thứ tự; trạng thái batch SUCCESS/FAILED |

Khác thiết kế Task 2: kiểm tra file, SHA-256 và số thứ tự dòng làm bằng SQL, không dùng Script Task/Script Component
(các file `ssis/OlistETL/Scripts/*.cs` chưa dùng). Khác bản dbt: không có bảng `km_*`.

### Cài đặt database (một lần, theo đúng thứ tự)

`00_database` → `01_audit` → `02_staging` → `04_ingest_helpers` → `05_transform_tables` → `06_dwh_tables` →
`07_etl_procs` → `08_ingest_ssis` (SSMS, hoặc `sqlcmd -S localhost\SQLEXPRESS -E -C -b -I -f 65001 -i <file>`).
Máy khác: chạy `python ssis/tools/register_packages.py --server <máy chủ>` để đặt lại `SqlServerName`, `RawDir`.

### Chạy và kiểm chứng

1. Trong Solution Explorer, nhấp phải package → **Execute Package**. Thứ tự: `Ingest_Staging`, `Transform_Clean`,
   `Transform_Business`, `Load_Dimensions`, `Load_Facts`, `Test_DW`. Dừng gỡ lỗi (Shift+F5) trước khi chạy package tiếp.
2. Sau mỗi package: `.venv\Scripts\python.exe -X utf8 ssis\tools\verify_dw.py <staging|cln|int|dim|fact>`.
3. Cuối cùng chạy `Master.dtsx` hai lần: số dòng và khoá thay thế không đổi.
4. Lỗi xem ở tab **Progress** (hoặc **Output**) của Visual Studio và `audit.etl_run.error_message`.

Sửa package: sửa trực tiếp trong Visual Studio. Chạy lại `build.ps1` sẽ ghi đè mọi chỉnh sửa tay.

## 6. Đặc điểm file CSV (để cấu hình Flat File Connection)

- 9 file, phân cách `,`, dòng đầu là tên cột. Ngày giờ dạng `2017-10-02 10:56:33`; số thập phân dùng dấu `.`.
- Mã hoá UTF-8 (code page **65001**). `product_category_name_translation.csv` có **BOM** và xuống dòng CRLF; các file khác xuống dòng LF.
- Một số ô bọc trong dấu nháy kép (`"9ef432eb..."`): đặt **Text qualifier = `"`**.
- `olist_order_reviews_dataset.csv`: bình luận có **xuống dòng bên trong dấu nháy** và có emoji. Cột bình luận dài nhất 208 ký tự: đặt độ rộng 1000 (mặc định 50 sẽ lỗi cắt chuỗi).
- Đọc mọi cột dạng chuỗi (`DT_WSTR`), đổi kiểu ở bước Transform.

| File | Bảng | Số dòng |
|---|---|---|
| olist_orders_dataset.csv | orders | 99.441 |
| olist_customers_dataset.csv | customers | 99.441 |
| olist_order_items_dataset.csv | order_items | 112.650 |
| olist_order_reviews_dataset.csv | order_reviews | 99.224 |
| olist_order_payments_dataset.csv | order_payments | 103.886 |
| olist_products_dataset.csv | products | 32.951 |
| olist_sellers_dataset.csv | sellers | 3.095 |
| olist_geolocation_dataset.csv | geolocation | 1.000.163 |
| product_category_name_translation.csv | category_translation | 71 |

## 7. Logic biến đổi (đặc tả, đã kiểm chứng)

Nguồn chuẩn: các model trong `olist_dbt/models/` trên nhánh `ssis/t3-dbt` (bản T-SQL). Tóm tắt:

- **Làm sạch chung:** `TRIM`; ô trống thành NULL **trước khi** đổi kiểu (SQL Server và SSIS đổi `''` thành 0 hoặc 1900-01-01); giá trị không đổi được thì NULL và gắn cờ `*_parse_error = 1` (không loại dòng).
- **Bản mới nhất:** mỗi khoá giữ dòng của batch có `batch_seq` lớn nhất (`audit.etl_batch`), hoà thì `source_row_number` lớn hơn.
- **Mã bưu chính:** 1–5 chữ số, thêm 0 bên trái cho đủ 5; giá trị khác thành NULL.
- **Thành phố:** chữ thường, bỏ dấu `áàâãäéèêëíìîïóòôõöúùûüç` → `aaaaaeeeeiiiiooooouuuuc`, gộp nhiều khoảng trắng thành một.
- **order_status:** chữ thường. **review_score:** chỉ nhận `1`–`5`, khác thì NULL và `invalid_score_flag = 1`.
- **Bình luận:** chuỗi rỗng thành NULL, nhưng chuỗi chỉ có emoji hoặc dấu cách **phải giữ** (trong SQL Server dùng `DATALENGTH > 0`, không dùng `NULLIF(x, '')`).
- **Đánh giá:** bỏ dòng trùng hoàn toàn mọi cột (so bình luận phân biệt hoa thường).
- **Toạ độ:** bỏ dòng trùng sau khi chuẩn hoá (còn 720.460 dòng); trung vị theo mã bưu chính, chỉ lấy toạ độ trong khung Brazil (lat −34…6, lng −74…−34).
- **Vòng đời đơn:** đủ điều kiện xét giao khi `delivered`, đủ ngày mua, ngày nhận, ngày dự kiến, và hai ngày sau không trước ngày mua (so theo ngày). Trễ khi ngày nhận > ngày dự kiến. Nhóm kết quả `ON_TIME`, `LATE_1_3`, `LATE_4_7`, `LATE_GT7`, `NOT_ELIGIBLE`.
- **Đánh giá đại diện:** điểm hợp lệ, `review_answer_ts` mới nhất, rồi `review_creation_ts`, `review_id`, vị trí dòng.
- **Đối chiếu thanh toán:** lệch quá 0,01 BRL thì gắn cờ (cảnh báo, không loại đơn).
- **Khoá ngày trên fact:** `YYYYMMDD`; −2 nếu ngày lỗi; −1 nếu mốc chưa xảy ra theo trạng thái đơn; 0 nếu thiếu.

## 8. Số đối chiếu (kết quả đúng phải ra)

| Mục | Số |
|---|---|
| Staging | tổng 1.550.922 dòng (bảng ở mục 6) |
| Sau làm sạch | orders 99.441; geolocation còn 720.460; mọi cột `*_parse_error` tổng bằng 0 |
| Giao hàng | 96.478 đã giao; 96.470 đủ điều kiện; 6.534 trễ; tỷ lệ trễ 6,77% |
| Đánh giá | 98.673 đơn có đánh giá đại diện; điểm trung bình 4,09 |
| Thanh toán | 303 đơn lệch > 0,01 BRL; 249 đơn lệch > 1 BRL |
| Mã bưu chính | 19.177 mã; 682 mã nhiều tên thành phố; 41 mã nhiều bang |
| Dimension | dim_customer 96.097; dim_geography 19.178; dim_product 32.952; dim_seller 3.096; dim_order_status 9; dim_delivery_outcome 6; dim_date 1.317 (gồm 3 dòng đặc biệt) |
| Fact | fact_order_experience 99.441; fact_order_item 112.650; tiền hàng 13.591.643,70 BRL |
| Chạy lại | số dòng không đổi, khoá thay thế của dimension không đổi |

Lưu ý: toạ độ trong file DuckDB cũ (`warehouse/olist.duckdb`, ngày 13/11) **sai ở 9.061 mã bưu chính**. Đừng dùng file đó để đối chiếu toạ độ.

## 9. Lỗi dễ gặp (đã gặp khi làm)

- **Collation không phân biệt hoa thường** của SQL Server: `DISTINCT`, `GROUP BY`, `NULLIF(x, '')` có thể gộp giá trị khác nhau. Thêm `COLLATE Latin1_General_100_BIN2` khi cần so đúng từng ký tự. Lookup trong SSIS (chế độ Full cache) thì lại so phân biệt hoa thường.
- **Locale:** máy dùng tiếng Việt (dấu thập phân là `,`). Đặt `LocaleID = English (United States)` cho package và Data Flow, hoặc bật `FastParse` cho Data Conversion, để `58.90` không bị đọc sai.
- **Unicode và non-Unicode:** bảng dùng `nvarchar` thì cột trong luồng phải là `DT_WSTR`; `source_batch_id` là `varchar` nên cần `DT_STR`.
- **NULL trong biểu thức SSIS:** điều kiện có NULL cho ra NULL. Viết dạng `!ISNULL(a) && !ISNULL(b) && a < b ? 1 : 0`, hoặc dùng `REPLACENULL`.
- **Derived Column** không dùng được cột vừa tạo trong cùng thành phần: tách thành nhiều Derived Column nối tiếp.
- **Truncation làm dừng package:** `(DT_DBTIMESTAMP2,0)GETDATE()` bị coi là cắt dữ liệu và lỗi khi chạy. Cột thời gian nạp (`ingested_at`, `dw_*`) để SQL Server điền; không ép ngày giờ sang `DT_DBDATE`, so ngày bằng `DATEDIFF("day", ...)`. Validate chỉ báo cảnh báo "static truncation", nên phải đọc cả cảnh báo.
- **Data Flow đọc bảng do bước trước tạo:** bật `DelayValidation = True`.
- Chạy package con trong Master bằng Execute Package Task (Project reference).

## 10. Prompt mẫu

```
Đọc docs/t3-ssis-ban-giao.md trong repo này. Tôi đang làm Task 3 mini project Olist bằng SSIS, mở project
ssis/OlistETL/OlistETL.sln trong Visual Studio 2022.
1. Tóm tắt lại mục tiêu và kiến trúc trong 5 dòng.
2. Hướng dẫn tôi dựng package [tên package] từng bước trên giao diện (bấm vào đâu, đặt thuộc tính gì),
   bắt đầu với một bảng (orders) trước.
3. Không đổi quy ước ở mục 3. Cần đổi thì nói lý do và hỏi tôi trước.
4. Sau mỗi bước, cho tôi câu SQL kiểm tra và con số đúng phải ra (mục 8).
Tôi đang ở bước: [...]
```
