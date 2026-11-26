# Hướng dẫn cài đặt và chạy demo project SSIS `OlistETL`

Dành cho thành viên vừa clone repo về máy. Làm lần lượt; mỗi bước có cách kiểm tra kết quả.
Thiết kế chi tiết xem [Mo_ta_SSIS.md](Mo_ta_SSIS.md).

## 0. Cần có

| Phần mềm | Ghi chú |
|---|---|
| Windows x64 | Trình thiết kế SSIS chỉ chạy trên Windows |
| SQL Server 2022 hoặc 2025 (Developer/Express) **cài trên máy** | Không dùng bản Docker được: các thủ tục đọc file CSV bằng `OPENROWSET(BULK ...)` theo đường dẫn Windows |
| SSMS | Chạy file SQL, xem kết quả |
| Visual Studio 2022 + extension **SQL Server Integration Services Projects 2022+** | Cách cài: [cai-dat-windows.md](cai-dat-windows.md) mục 3. Project đặt *TargetServerVersion* SQL Server 2025 |
| Python 3.10 trở lên | Chỉ dùng để tạo dữ liệu batch (thư viện chuẩn, không cần cài gói) |
| Git | |

**Lưu ý quyền đọc file:** tài khoản dịch vụ SQL Server (ví dụ `NT Service\MSSQL$SQLEXPRESS`) phải **đọc được thư mục repo**.
- Tránh để repo trong `Desktop` hay `Documents` của user, nên đặt ở ổ khác, ví dụ `D:\...`.
- Nếu bị lỗi *Cannot bulk load … access denied*, nhấp phải thư mục repo → Properties → Security → thêm quyền **Read** cho tài khoản dịch vụ trên.

## 1. Lấy mã nguồn

```powershell
git clone https://github.com/tthoan23/bi-genai.git
cd bi-genai
git switch ssis/t3-ssis-etl
```

## 2. Chuẩn bị dữ liệu

```powershell
Expand-Archive -Path data\olist-brazilian-ecommerce.zip -DestinationPath data\raw -Force
python scripts\make_batches.py
python scripts\make_test_batch.py
```

**Kiểm tra:**
- `data\batches` có 4 thư mục: `FULL_001`, `INC_001`, `INC_002`, `INC_003`.
- Mỗi thư mục có 9 file CSV và `_cutoff.txt`.
- `make_batches.py` in bảng số dòng, ví dụ orders: 45.430 / 73.577 / 99.441.

Các batch mô phỏng nguồn thay đổi theo thời gian (dữ liệu Olist là dữ liệu tĩnh):

| Batch | Nội dung | Chế độ khi chạy |
|---|---|---|
| `FULL_001` | Nguồn tại 2017-12-31 | FULL (lần nạp đầu) |
| `INC_001` | Nguồn tại 2018-04-30 | INCREMENTAL |
| `INC_002` | Toàn bộ dữ liệu gốc | INCREMENTAL; kho sau batch này phải bằng nạp toàn bộ |
| `INC_003` | `INC_002` + 2 dòng hỏng trong orders | Kiểm thử dòng lỗi |

## 3. Tạo database

Trong SSMS (kết nối máy chủ của bạn, tick *Trust server certificate*), mở và chạy **theo đúng thứ tự** các file
trong `sql_server\`:

```
00_database.sql → 01_audit.sql → 02_staging.sql → 04_ingest_helpers.sql → 05_transform_tables.sql
→ 06_dwh_tables.sql → 07_etl_procs.sql → 08_ingest_ssis.sql
```

Hoặc bằng dòng lệnh, chạy tại thư mục repo (thay tên máy chủ nếu khác):

```powershell
$files = '00_database','01_audit','02_staging','04_ingest_helpers','05_transform_tables','06_dwh_tables','07_etl_procs','08_ingest_ssis'
foreach ($f in $files) { sqlcmd -S "localhost\SQLEXPRESS" -E -C -b -I -f 65001 -i "sql_server\$f.sql" }
```

**Kiểm tra trong SSMS:** database `OlistDW` có các schema `staging`, `intermediate`, `dwh`, `audit`; bảng `dwh.dim_customer` có 1 dòng (Unknown).

Không chạy `03_staging_load.sql`, vì `08` đã tạo bảng `_load` thay cho nó. Chạy lại các file trên vẫn an toàn, nhưng:
- `05` xoá dữ liệu của schema `intermediate`.
- `06_dwh_reset.sql` xoá toàn bộ kho.

## 4. Mở project và đặt tham số

1. Visual Studio → **File → Open → Project/Solution** → `ssis\OlistETL\OlistETL.sln`.
   VS 2022 bản 17.13 trở về trước không mở được `.slnx`; luôn dùng `.sln`.
2. Solution Explorer → mở **Project.params**, sửa cho đúng máy của bạn:

| Tham số | Giá trị |
|---|---|
| `SqlServerName` | Tên máy chủ SQL, ví dụ `localhost\SQLEXPRESS` hoặc `localhost` |
| `DatabaseName` | `OlistDW` |
| `RawDir` | Đường dẫn **tuyệt đối** tới `data\batches` của repo, ví dụ `D:\bi-genai\data\batches` |
| `BatchId` | `FULL_001` (lưu ý: giá trị mặc định trong `Project.params` trên repo hiện đang để sẵn `INC_003` cho kịch bản test lỗi; nếu chạy mới từ đầu cần chỉnh lại thành `FULL_001`) |

   Cách khác: đóng VS rồi chạy `python ssis\tools\register_packages.py --server "localhost\SQLEXPRESS"`
   (tự đặt `SqlServerName` và `RawDir` theo vị trí repo).
3. **Ctrl+S** để lưu. Kiểm tra: mở **Connection Managers → OlistDW** → **Test Connection** phải thành công.

## 5. Chạy demo

Mỗi lần chạy: nhấp phải **`Master.dtsx`** trong Solution Explorer → **Execute Package**.
- Chờ mọi task có dấu tick xanh.
- Dòng cuối tab **Output** (chọn *Show output from: Debug*) phải là `... finished: Success`.
- Nhấn **Shift+F5** để dừng gỡ lỗi trước khi chạy lần sau.

`DFT cln_geolocation` (trong `Transform_Clean`) mất vài phút vì xử lý hơn 1 triệu dòng và sắp xếp để bỏ trùng.
Đây không phải bị treo.

### 5.1. Full Load lần đầu: `BatchId = FULL_001`

```sql
SELECT run_id, batch_id, status, error_message FROM audit.etl_run ORDER BY run_id;          -- FULL_001 SUCCESS
SELECT batch_id, batch_type, status FROM audit.etl_batch;                                   -- batch_type = FULL
SELECT table_name, rows_read, rows_extracted FROM audit.extract_stat WHERE batch_id = 'FULL_001';
SELECT COUNT(*) FROM dwh.fact_order_experience;                                             -- 45430
SELECT source_name, lset FROM audit.etl_metadata;                                           -- 2017-12-31 23:59:59
```

### 5.2. Incremental Load: `BatchId = INC_001`, sau đó `INC_002`

Đổi `BatchId` trong Project.params, lưu, chạy Master. Sau mỗi batch:

```sql
SELECT table_name, file_skipped, rows_read, rows_in_window, rows_changed_outside_window,
       rows_extracted, rows_unchanged
FROM audit.extract_stat WHERE batch_id = 'INC_001' ORDER BY table_name;
SELECT source_name, lset FROM audit.etl_metadata;
SELECT reason, COUNT(*) FROM intermediate.affected_orders GROUP BY reason;
```

**Kết quả đúng:**

| Batch | Chế độ | Bỏ qua (SHA-256 trùng) | orders: trong cửa sổ / đổi ngoài cửa sổ / lấy | LSET sau batch | Fact (đơn) |
|---|---|---|---|---|---|
| `INC_001` | INCREMENTAL | geolocation, category_translation | 30.650 / **51** / 30.701 | 2018-04-30 23:59:59 | 73.577 |
| `INC_002` | INCREMENTAL | geolocation, category_translation | 28.673 / **19** / 28.692 | 2018-10-29 12:27:35 | 99.441 |

Cột "đổi ngoài cửa sổ" là các đơn bị huỷ mà không có mốc thời gian mới: LSET/CET không bắt được, so mã băm bắt được.

**Sau `INC_002`, KPI phải bằng nạp toàn bộ:**

```sql
SELECT COUNT(*) AS so_don,
       CAST(100.0 * SUM(late_count) / SUM(delivery_eligible_count) AS decimal(5,2)) AS ty_le_tre,      -- 6.77
       CAST(AVG(1.0 * representative_review_score) AS decimal(4,2)) AS diem_tb                      -- 4.09
FROM dwh.fact_order_experience;                                                                     -- 99441
SELECT SUM(price_amount) FROM dwh.fact_order_item;                                                  -- 13591643.70
SELECT table_name, rows_rejected AS failed, status FROM audit.etl_step_log
WHERE step = 'test' AND run_id = (SELECT MAX(run_id) FROM audit.etl_run);                          -- PASS, T13 WARN 303
```

### 5.3. Chạy lại không trùng: chạy Master lần nữa với `INC_002`

```sql
SELECT table_name, status FROM audit.etl_step_log
WHERE step = 'ingest' AND run_id = (SELECT MAX(run_id) FROM audit.etl_run);   -- 9 dòng SKIPPED
```

Số dòng fact, khoá dimension, `dw_created_at` không đổi.

### 5.4. Dòng lỗi và lỗi giữa chừng: `BatchId = INC_003`

1. **Gây lỗi có chủ đích** (SSMS): `EXEC sp_rename 'dwh.fact_order_item_stage', 'fact_order_item_stage_tam';`
2. Chạy Master với `INC_003`. Kết quả: `EPT Load_Facts` đỏ, Master dừng.
   ```sql
   SELECT batch_id, status, error_message FROM audit.etl_run ORDER BY run_id DESC;  -- FAILED, có nội dung lỗi
   SELECT source_name, lset FROM audit.etl_metadata;                                 -- LSET vẫn 2018-10-29
   SELECT stage, error_code, error_description, LEFT(raw_data, 60) FROM audit.reject_row;
   ```
   `reject_row` có 2 dòng:
   - `extract`: dòng có `customer_id` dài 300 ký tự, Flat File Source chuyển sang Error Output.
   - `transform`: dòng thiếu `order_id`.

   Các dòng khác vẫn được nạp.
3. **Sửa lỗi:** `EXEC sp_rename 'dwh.fact_order_item_stage_tam', 'fact_order_item_stage';`
4. Chạy lại Master với `INC_003`. Kết quả: SUCCESS; LSET thành `2018-10-31 00:00:00`; kho vẫn 99.441 đơn (2 dòng hỏng không lọt vào kho); kiểm thử T16 cảnh báo 2 dòng bị loại.

### 5.5. Làm lại từ đầu

```sql
EXEC audit.usp_reset_all;   -- XOÁ toàn bộ dữ liệu staging, intermediate, kho, audit (giữ cấu trúc)
```

Sau đó đặt `BatchId = FULL_001` và chạy lại từ mục 5.1.

## 6. Chạy từng package riêng (khi gỡ lỗi)

Thứ tự: `Ingest_Staging` → `Transform_Clean` → `Transform_Business` → `Load_Dimensions` → `Load_Facts` → `Test_DW`.
- `Ingest_Staging` mở lần chạy (như `Master`); các package sau ghi vào lần chạy đó. Việc đẩy LSET và chốt SUCCESS
  chỉ có trong `Master`.
- Khi chạy riêng, cuối cùng chạy thêm `EXEC audit.usp_finish_run 'FULL_001', 'SUCCESS';` (thay mã batch) để chốt batch.

## 7. Lỗi hay gặp

| Hiện tượng | Cách xử lý |
|---|---|
| Không mở được `.slnx` | Mở `OlistETL.sln` |
| Test Connection lỗi | Sai `SqlServerName`; kiểm tra dịch vụ SQL Server đang chạy (`services.msc`) |
| `Cannot bulk load … does not exist or you don't have file access rights` | Sai `RawDir` hoặc chưa tạo batch (mục 2), hoặc dịch vụ SQL Server không có quyền đọc thư mục (mục 0) |
| `Sai tiêu đề file …` | File CSV không đúng cấu trúc; tạo lại bằng `make_batches.py` |
| Một package báo đỏ | Tab **Output** (Debug), tìm dòng `Error:` đầu tiên; xem thêm `audit.etl_run.error_message` |
| Package đứng lâu ở `DFT cln_geolocation` | Bình thường, chờ vài phút |
| VS báo file đã đổi bên ngoài | Đóng solution **không lưu**, mở lại |
| Sau khi pull bản mới | Chạy lại `07_etl_procs.sql`, `08_ingest_ssis.sql` (và `05`, `06` nếu có đổi); đóng mở lại solution |

## 8. Dành cho người sửa package

- Các file `.dtsx` được **sinh bằng chương trình** từ `ssis\tools\BuildOlistEtl.cs` (dùng thư viện SSIS chính thức).
- Muốn sửa thì sửa file C#, rồi chạy:
  ```powershell
  powershell -ExecutionPolicy Bypass -File ssis\tools\build.ps1 -Server "localhost\SQLEXPRESS"
  python ssis\tools\register_packages.py --server "localhost\SQLEXPRESS"
  ```
  `build.ps1` Validate từng package với database thật rồi ghi đè `.dtsx`.
- **Sửa tay trong Visual Studio sẽ bị mất** ở lần build sau.
- Câu SQL dùng trong OLE DB Source nằm ở `ssis\OlistETL\queries\` (sinh bằng `ssis\tools\make_queries.py`).
- Đối chiếu với bản tham chiếu DuckDB (cần `warehouse\olist.duckdb` của bản Mage và gói `pyodbc`, `duckdb`):
  ```powershell
  python -X utf8 ssis\tools\verify_dw.py cln int dim fact
  ```
