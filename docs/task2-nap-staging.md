# Task 2: dựng package SSIS `Ingest_Staging.dtsx`

> **Tóm tắt 5 dòng để kiểm tra hiểu đúng:** (1) Thay block `ingest_csv.py` bằng một package SSIS, nạp 9 CSV vào 9 bảng `staging.*`, mọi cột giữ dạng chữ + 5 cột truy vết. (2) Mỗi file có 9 Data Flow riêng (không dùng Foreach chung vì cột khác nhau), đặt tên `DFT <bang>`. (3) Trước Data Flow: Script Task kiểm tra tồn tại/tiêu đề và Script Task tính SHA-256. (4) Sau Data Flow: Execute SQL Task chuyển từ bảng tạm sang bảng chính trong **một** transaction T-SQL, rồi ghi `source_manifest` + `etl_step_log`. (5) Chạy lại cùng batch không trùng dòng; lỗi thì dừng để Master ghi `FAILED`.

File này là phần việc còn lại của Task 2. Các file C# và T-SQL đã được chuẩn bị sẵn trong repo:

| File | Dùng cho |
|---|---|
| `sql_server/03_staging_load.sql` | Tạo 9 bảng `staging.<bang>_load` (dọn dòng cũ) |
| `sql_server/04_ingest_helpers.sql` | 4 thủ tục `audit.usp_*` gọi từ Execute SQL Task |
| `sql_server/check_ingest.sql` | Truy vấn đối chiếu sau khi chạy |
| `ssis/OlistETL/Scripts/CheckCsvHeader.cs` | Script Task kiểm tra file + tiêu đề |
| `ssis/OlistETL/Scripts/ComputeSha256.cs` | Script Task tính SHA-256 + đếm số dòng cả file |
| `ssis/OlistETL/Scripts/RowNumberScriptComponent.cs` | Script Component đánh số dòng từ 1 |

---

## 0. Điều kiện cần (làm một lần)

1. Nhánh `ssis/t2-nap-staging`, máy **Windows x64**, đã cài xong theo `docs/cai-dat-windows.md`.
2. Trong SSMS chạy lần lượt: `sql_server/00_database.sql`, `01_audit.sql`, `02_staging.sql`, `03_staging_load.sql`, `04_ingest_helpers.sql`.
3. Giải nén `data/olist-brazilian-ecommerce.zip` vào `data/raw` (đúng 9 file CSV). Giá trị `RawDir` của project là đường dẫn tuyệt đối tới thư mục này, **không kết thúc bằng `\`**.
4. Mở solution `ssis/OlistETL/OlistETL.slnx` bằng Visual Studio 2022 + extension SSIS Projects 2022+.

Chạy thử `sql_server/check_ingest.sql` lúc này sẽ chưa có dữ liệu — đó là bình thường.

---

## 1. Cấu trúc package đề xuất

### 1.1. Tham số package `Ingest_Staging.dtsx`

Tạo package mới (`SSIS Package`, Protection level = `Don't save sensitive`), đổi tên thành `Ingest_Staging.dtsx`, rồi vào tab **Parameters** thêm:

| Tên | Kiểu | Giá trị / biểu thức mặc định | Ghi chú |
|---|---|---|---|
| `run_id` | Int32 | `-1` | Master.dtsx truyền xuống. Chạy riêng thì sửa tay bằng `run_id` lấy ở mục 1.3 |
| `batch_id` | String | `@[$Project::BatchId]` | `FULL_001` |
| `batch_type` | String | `@[$Project::BatchType]` | `FULL` / `INCREMENTAL` |
| `raw_dir` | String | `@[$Project::RawDir]` | Không ghi cứng đường dẫn máy |
| `is_simulated` | Boolean | `@[$Project::IsSimulated]` | Để sẵn cho Task 4 |

### 1.2. Biến package

| Tên | Kiểu | Biểu thức / giá trị | Dùng cho |
|---|---|---|---|
| `var_run_id` | Int32 | `@[$Package::run_id]` | tham số Execute SQL |
| `var_batch_id` | String | `@[$Package::batch_id]` | tham số Execute SQL, Derived Column |
| `var_batch_type` | String | `@[$Package::batch_type]` | giữ sẵn cho Task 4 |
| `var_raw_dir` | String | `@[$Package::raw_dir]` | Script Task |
| `current_table` | String | `orders` | Script Task + Execute SQL |
| `current_file` | String | `olist_orders_dataset.csv` | Script Task + FF connection |
| `checksum` | String | rỗng | Script Task → Derived Column → audit |
| `column_list` | String | rỗng | Script Task → audit |
| `file_rows` | Int64 | `0` | số dòng cả file → `source_manifest.row_count` |
| `rows_read` | Int64 | `0` | Row Count transformation |
| `rows_loaded` | Int64 | `0` | kết quả `usp_swap_staging` |

### 1.3. Tạo batch/run để chạy riêng (không cần Master)

Nếu chưa có `Master.dtsx`, chạy trong SSMS:

```sql
USE OlistDW;
GO
DECLARE @batch_id varchar(50) = 'FULL_001';
DECLARE @ids TABLE (run_id int);

MERGE audit.etl_batch AS t
USING (SELECT @batch_id AS batch_id, 'FULL' AS batch_type, CAST(0 AS bit) AS is_simulated) AS s
   ON t.batch_id = s.batch_id
 WHEN MATCHED THEN UPDATE SET status = 'RUNNING', started_at = SYSDATETIME(), ended_at = NULL
 WHEN NOT MATCHED THEN
    INSERT (batch_id, batch_type, is_simulated, status, started_at)
    VALUES (s.batch_id, s.batch_type, s.is_simulated, 'RUNNING', SYSDATETIME());

DECLARE @attempt int = ISNULL((SELECT MAX(attempt) FROM audit.etl_run WHERE batch_id = @batch_id), 0) + 1;

INSERT INTO audit.etl_run (batch_id, attempt, status, started_at)
OUTPUT inserted.run_id INTO @ids (run_id)
VALUES (@batch_id, @attempt, 'RUNNING', SYSDATETIME());

SELECT run_id FROM @ids;   -- điền số này vào tham số run_id của package
GO
```

### 1.4. Control Flow

```
SCR Check orders → SCR Hash orders → DFT orders → SQL Swap orders → SQL Audit orders
                                                                                      ↓
SCR Check customers → SCR Hash customers → DFT customers → SQL Swap customers → SQL Audit customers
                                                                                      ↓
                                          ... (8 bảng còn lại) ...
                                                                                      ↓
                                                            SQL Finish (usp_mark_ingested)
```

Mỗi nhóm 5 task để trong một **Sequence Container** (`SEQ orders`, `SEQ customers`, ...). Nối các Sequence Container bằng precedence constraint kiểu **Success** để chạy tuần tự. Đặt Expression Task đầu mỗi container:

```
@[User::current_table] = "orders"
@[User::current_file]  = "olist_orders_dataset.csv"
```

---

## 2. Làm riêng file `orders` cho chạy đúng

### 2.1. `SCR Check orders` (Script Task)

- Kéo **Script Task**, tên `SCR Check orders`.
- `ReadOnlyVariables`: `User::var_raw_dir`, `User::current_file`, `User::current_table`
- `ReadWriteVariables`: `User::column_list`, `User::rows_read`, `User::rows_loaded`
- Language: `C#`. Mở **Edit Script**, thay toàn bộ nội dung bằng `ssis/OlistETL/Scripts/CheckCsvHeader.cs`.

Script báo đúng hai thông điệp yêu cầu:

- `Không tìm thấy <đường dẫn>` (kèm gợi ý giải nén zip).
- `<file> thiếu cột [cột1, cột2, ...]`.

Đồng thời reset `rows_read = rows_loaded = 0` và lưu danh sách cột vào `column_list`.

### 2.2. `SCR Hash orders` (Script Task)

- Tên `SCR Hash orders`.
- `ReadOnlyVariables`: `User::var_raw_dir`, `User::current_file`
- `ReadWriteVariables`: `User::checksum`, `User::file_rows`
- Dán `ssis/OlistETL/Scripts/ComputeSha256.cs`.
- Kết quả: `checksum` là chuỗi hex 64 ký tự; `file_rows` = 99441 (đã trừ dòng tiêu đề; script đếm theo ký tự nên bình luận có xuống dòng nằm trong ngoặc kép vẫn tính là 1 dòng).

### 2.3. Flat File Connection Manager `FF orders`

New Connection Manager → **Flat File** → tên `FF orders`.

| Thuộc tính | Giá trị |
|---|---|
| Format | Delimited |
| Connection string (biểu thức) | `@[$Project::RawDir] + "\\olist_orders_dataset.csv"` |
| Code page | `65001` (UTF-8) |
| Text qualifier | `"` |
| Column names in first data row | True |
| Header row delimiter | `{CR}{LF}` |
| Row delimiter | `{CR}{LF}` |
| Column delimiter | `,` |
| `AlwaysCheckForRowDelimiters` | `False` (cửa sổ Properties; quan trọng cho `order_reviews`) |

Danh sách cột (tất cả `DT_WSTR`, `TextQualified = True`, độ dài 255):

```
order_id
customer_id
order_status
order_purchase_timestamp
order_approved_at
order_delivered_carrier_date
order_delivered_customer_date
order_estimated_delivery_date
```

> Nút phải chuột connection manager → **Edit** → tab **Columns** để kiểm tra tên cột đầu tiên không dính ký tự BOM (đặc biệt với `FF category_translation`).

### 2.4. `DFT orders` (Data Flow Task)

Kéo **Data Flow Task**, vào tab Data Flow và dựng:

**Flat File Source `SRC orders`** → dùng `FF orders`, giữ nguyên 8 cột đầu ra kiểu `DT_WSTR`.

**Script Component `SCR Row No`** (kiểu Transformation):
- Chọn input `Flat File Source Output`.
- Trong **Inputs and Outputs** → `Output 0` → `Output Columns` → Add Column: `source_row_number`, Data Type `DT_I4`.
- Language `C#`, dán `ssis/OlistETL/Scripts/RowNumberScriptComponent.cs`.

**Derived Column `DER Trace`** → thêm 4 cột:

| Cột | Kiểu | Expression |
|---|---|---|
| `source_file` | `DT_WSTR`, 260 | `@[User::current_file]` |
| `source_checksum` | `DT_STR`, 64 | `(DT_STR,64,1252)@[User::checksum]` |
| `source_batch_id` | `DT_STR`, 100 | `(DT_STR,100,1252)@[User::var_batch_id]` |
| `ingested_at` | `DT_DBTIMESTAMP` | `(DT_DBTIMESTAMP)GETDATE()` |

**Row Count `CNT rows`** →Variable name = `User::rows_read`.

**OLE DB Destination `DEST orders_load`** → Connection `OlistDW`:
- Data access mode: **Table or view - fast load**
- Table: `[staging].[orders_load]`
- Mapping: ghép theo tên (13 cột: 8 cột nguồn + 5 cột truy vết). Bỏ tick **Keep identity**, **Check constraints**.
- Rows per batch: `10000`; Maximum insert commit size: `100000`.
- Nối dây từng bước theo thứ tự trên.

### 2.5. `SQL Swap orders` (Execute SQL Task)

Connection `OlistDW`, ResultSet = **Single row**, SQL statement:

```sql
EXEC audit.usp_swap_staging @table_name = ?, @batch_id = ?;
```

| Parameter | Variable | Kiểu |
|---|---|---|
| `0` | `User::current_table` | VARCHAR |
| `1` | `User::var_batch_id` | VARCHAR |

Tab **Result Set**: Result Name `0` → `User::rows_loaded` (Int64).

Thủ tục thực hiện đúng yêu cầu: `BEGIN TRAN` → `DELETE staging.orders WHERE source_batch_id = ?` → `INSERT ... SELECT` từ `orders_load` → lấy `@@ROWCOUNT` → `TRUNCATE orders_load` → `COMMIT`. Có `TRY/CATCH` + `ROLLBACK` nếu lỗi, nên không cần bật MSDTC.

### 2.6. `SQL Audit orders` (Execute SQL Task)

```sql
EXEC audit.usp_write_ingest_audit ?, ?, ?, ?, ?, ?, ?, ?, ?;
```

Thứ tự tham số đúng trong `04_ingest_helpers.sql`:

| # | Biến | Ý nghĩa |
|---|---|---|
| 0 | `User::var_run_id` | run_id |
| 1 | `User::var_batch_id` | batch_id |
| 2 | `User::current_table` | `orders` |
| 3 | `User::current_file` | tên file |
| 4 | `User::checksum` | SHA-256 |
| 5 | `User::file_rows` | số dòng cả file |
| 6 | `User::column_list` | danh sách cột |
| 7 | `User::rows_read` | Row Count đếm được |
| 8 | `User::rows_loaded` | từ `usp_swap_staging` |

Thủ tục `MERGE` vào `source_manifest`, `INSERT` vào `etl_step_log` (`status = SUCCESS` hoặc `MISMATCH`, `rows_rejected = rows_read - rows_loaded`). Nếu `MISMATCH` thì `THROW`, task dừng ngay.

### 2.7. Kiểm tra riêng `orders`

Chạy package đến hết nhóm `orders`, rồi trong SSMS:

```sql
SELECT COUNT(*) FROM staging.orders WHERE source_batch_id = 'FULL_001';  -- 99441
SELECT * FROM audit.etl_step_log WHERE step = 'ingest' AND table_name = 'orders';
-- rows_read = rows_loaded = 99441, rows_rejected = 0, status = SUCCESS
SELECT source_checksum, row_count FROM audit.source_manifest WHERE batch_id = 'FULL_001'
  AND source_file = 'olist_orders_dataset.csv';  -- row_count = 99441
```

---

## 3. Nhân bản cho 8 file còn lại

Không dùng chung một Data Flow: mỗi file có số cột khác nhau. Copy Sequence Container `SEQ orders`, đổi tên các task (`SCR Check customers`, `SCR Hash customers`, `DFT customers`, ...), đổi Expression Task, đổi Files/Columns trong Flat File connection, đổi bảng đích `_load`, rồi nối tiếp sau container trước.

| File trong `raw_dir` | `current_table` | Số cột | Cột bắt buộc phải có | Dòng đúng |
|---|---|---:|---|---:|
| `olist_orders_dataset.csv` | `orders` | 8 | 8 cột như mục 2.3 | 99.441 |
| `olist_customers_dataset.csv` | `customers` | 5 | `customer_id`, `customer_unique_id`, `customer_zip_code_prefix` | 99.441 |
| `olist_order_items_dataset.csv` | `order_items` | 7 | `order_id`, `order_item_id`, `product_id`, `seller_id`, `price`, `freight_value` | 112.650 |
| `olist_order_reviews_dataset.csv` | `order_reviews` | 7 | `review_id`, `order_id`, `review_score`, `review_creation_date`, `review_answer_timestamp` | 99.224 |
| `olist_order_payments_dataset.csv` | `order_payments` | 5 | không kiểm tra | 103.886 |
| `olist_products_dataset.csv` | `products` | 9 | không kiểm tra | 32.951 |
| `olist_sellers_dataset.csv` | `sellers` | 4 | không kiểm tra | 3.095 |
| `olist_geolocation_dataset.csv` | `geolocation` | 5 | không kiểm tra | 1.000.163 |
| `product_category_name_translation.csv` | `category_translation` | 2 | không kiểm tra | 71 |

Danh sách cột (theo đúng thứ tự trong file, đều `DT_WSTR`):

- **customers** (255): `customer_id`, `customer_unique_id`, `customer_zip_code_prefix`, `customer_city`, `customer_state`
- **order_items** (255): `order_id`, `order_item_id`, `product_id`, `seller_id`, `shipping_limit_date`, `price`, `freight_value`
- **order_reviews**: `review_id` (255), `order_id` (255), `review_score` (255), `review_comment_title` (**4000**), `review_comment_message` (**4000**), `review_creation_date` (255), `review_answer_timestamp` (255)
- **order_payments** (255): `order_id`, `payment_sequential`, `payment_type`, `payment_installments`, `payment_value`
- **products** (255): `product_id`, `product_category_name`, `product_name_lenght`, `product_description_lenght`, `product_photos_qty`, `product_weight_g`, `product_length_cm`, `product_height_cm`, `product_width_cm`
- **sellers** (255): `seller_id`, `seller_zip_code_prefix`, `seller_city`, `seller_state`
- **geolocation** (255): `geolocation_zip_code_prefix`, `geolocation_lat`, `geolocation_lng`, `geolocation_city`, `geolocation_state`
- **category_translation** (255): `product_category_name`, `product_category_name_english`

Riêng `DFT geolocation`: đặt Rows per batch và Maximum insert commit size đều `100000` để chạy nhanh hơn.

---

## 4. Kết thúc và xử lý lỗi

### 4.1. `SQL Finish`

Task cuối cùng (sau `SQL Audit category_translation`):

```sql
EXEC audit.usp_mark_ingested @run_id = ?, @batch_id = ?;
```

Map `User::var_run_id`, `User::var_batch_id`. Batch chuyển `RUNNING → INGESTED`. Chuyển sang `SUCCESS` là việc của `Master.dtsx` sau khi dbt build (Task 3).

### 4.2. Event Handler `OnError` của package

Chọn tab **Event Handlers** → `OnError` → thêm **Execute SQL Task** `SQL OnError`:

```sql
EXEC audit.usp_mark_failed @run_id = ?, @batch_id = ?, @table_name = ?, @error_message = ?;
```

Map lần lượt: `User::var_run_id`, `User::var_batch_id`, `User::current_table`, `System::ErrorDescription`. Tuỳ chọn: thêm Script Task ghi `Dts.Events.FireError` ra log SSIS Catalog để báo cáo.

---

## 5. Kiểm chứng (tiêu chí hoàn thành)

Chạy `FULL_001`, rồi chạy `sql_server/check_ingest.sql`. Kết quả phải là:

1. Batch `FULL_001` và run gần nhất: `INGESTED`.
2. 9 dòng `etl_step_log` với `step = 'ingest'`, `rows_rejected = 0`, `status = SUCCESS`.
3. 9 dòng `source_manifest`, checksum dài 64 ký tự.
4. Số dòng đúng như bảng mục 3; tổng **1.550.922**.
5. Truy vấn trùng lặp toàn số `0`.
6. Có dòng `customer_city` chứa `são paulo`; có dòng review chứa `CHAR(10)`.

**Chạy lại cùng batch:** chạy package thêm lần nữa, `attempt` tăng lên 1, số dòng các bảng không đổi, không có `(batch_id, source_row_number)` nào trùng.

**Thử lỗi (trên bản sao `data/raw`):**

- Xoá `olist_orders_dataset.csv` → package dừng với `Không tìm thấy <đường dẫn>`.
- Xoá cột `order_status` khỏi header → package dừng với `olist_orders_dataset.csv thiếu cột [order_status]`.

Trong SSMS kiểm tra thêm: `etl_batch.status = 'FAILED'`, `etl_run.error_message` chứa nội dung lỗi, và `etl_step_log` có dòng `FAILED`.

---

## 6. Ảnh cho báo cáo

- Ảnh chụp Control Flow: 9 Sequence Container + `SQL Finish` + Event Handler `OnError`.
- Ảnh chụp một Data Flow (nên dùng `DFT orders` hoặc `DFT order_reviews` vì có Script Component + cột dài).
- Ảnh kết quả `sql_server/check_ingest.sql`: phần step log và phần tổng số dòng.

---

## 7. Lưu ý dễ sai (đã gặp khi chuyển từ `ingest_csv.py`)

| Hiện tượng | Cách sửa |
|---|---|
| Số dòng `order_reviews` lệch 99.224 | Kiểm tra text qualifier `"`, và đặt `AlwaysCheckForRowDelimiters = False` trên `FF order_reviews` |
| Lỗi cắt chuỗi ở bình luận/tên thành phố | Tăng MaximumWidth của `review_comment_*` lên 4000; các cột còn lại tối thiểu 255 |
| Cột đầu tiên của `product_category_name_translation` có ký tự lạ | BOM UTF-8: Script Task đọc header với `UTF8Encoding(false, true)` + `TrimStart('\uFEFF')`; kiểm tra lại tên cột trong Flat File Editor |
| `geolocation` nạp chậm | Fast load + `Rows per batch = 100000`, `Maximum insert commit size = 100000` |
| Đường dẫn cứng máy cá nhân | Luôn dùng biểu thức `@[$Project::RawDir] + "\\<tên file>"` |
| Chạy lại bị trùng dòng | `usp_swap_staging` xoá theo `source_batch_id` trước khi chèn, trong cùng transaction |
| Batch vẫn `RUNNING` sau khi lỗi | Đã có Event Handler `OnError` gọi `usp_mark_failed`; kiểm tra lại tham số `run_id` truyền vào package |

## 8. Phối hợp với Task 3 / Task 4

- Task 3 (`Master.dtsx`) sẽ tạo batch/run và truyền `run_id` xuống, sau đó gọi dbt build và chuyển batch sang `SUCCESS`. Package này chỉ dừng ở `INGESTED`.
- Task 4 sẽ thêm nhánh `INCREMENTAL` (LSET/CET). Giữ nguyên biến `var_batch_type` và 5 cột truy vết; chưa gộp cứng logic `FULL` vào Data Flow.
