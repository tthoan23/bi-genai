# BI-GenAI: hệ thống BI cho dữ liệu thương mại điện tử Olist

Đồ án môn Hệ thống thông tin phục vụ trí tuệ kinh doanh (CSC12107, FIT HCMUS). Hệ thống trả lời ba câu hỏi: **đơn hàng có được giao đúng hạn không, khách phải chờ bao lâu, và đơn giao trễ có bị đánh giá thấp hơn không**.

```
9 file CSV ──► Mage (nạp dữ liệu) ──► DuckDB ◄── dbt (làm sạch, dựng kho) ──► Power BI ──► AI tóm tắt, giải thích
 data/                                 warehouse/olist.duckdb
```

| Công cụ | Dùng để | Chạy ở đâu |
|---|---|---|
| Mage | Nạp dữ liệu, điều phối các bước | Trong Docker |
| dbt | Làm sạch dữ liệu, dựng kho (fact, dimension), kiểm thử | Trong Docker (cùng container với Mage) |
| DuckDB | Kho dữ liệu, là một file duy nhất | `warehouse/olist.duckdb` |
| Power BI Desktop | Dashboard | Windows |

Hướng dẫn này đi từng bước. Làm xong bước nào thì kiểm tra kết quả của bước đó rồi mới sang bước sau.

## Mục lục

1. [Cài công cụ (làm một lần)](#1-cài-công-cụ-làm-một-lần)
2. [Lấy mã nguồn](#2-lấy-mã-nguồn)
3. [Giải nén dữ liệu](#3-giải-nén-dữ-liệu)
4. [Khởi động Mage và DuckDB](#4-khởi-động-mage-và-duckdb)
5. [Nạp dữ liệu vào DuckDB](#5-nạp-dữ-liệu-vào-duckdb)
6. [Làm sạch dữ liệu bằng dbt](#6-làm-sạch-dữ-liệu-bằng-dbt)
7. [Tầng trung gian và bảng khoá](#7-tầng-trung-gian-và-bảng-khoá)
8. [Dừng và chạy lại](#8-dừng-và-chạy-lại)
9. [Các bước tiếp theo](#9-các-bước-tiếp-theo)
10. [Xử lý sự cố](#10-xử-lý-sự-cố)
11. [Nguồn dữ liệu](#11-nguồn-dữ-liệu)

**Cấu trúc thư mục:**

```
bi-genai/
├── data/                         dữ liệu nguồn (file zip gốc; data/raw là bản giải nén, không đưa lên git)
├── olist_bi/                     dự án Mage
│   ├── custom/ingest_csv.py      block nạp 9 file CSV vào DuckDB
│   └── pipelines/ingest_olist/   pipeline nạp dữ liệu
├── olist_dbt/                    dự án dbt
│   ├── models/staging/           9 model stg_* làm sạch từng bảng nguồn, kèm kiểm thử
│   ├── models/intermediate/      7 model int_* tính toán trung gian theo nghiệp vụ
│   ├── models/marts/keys/        6 bảng km_* cấp khoá thay thế bền vững
│   └── macros/                   hàm đổi kiểu dữ liệu an toàn, hàm cấp khoá
├── sql/                          câu SQL tạo bảng audit và kiểm tra kết quả
├── scripts/query.py              chạy một file SQL trên kho DuckDB
├── warehouse/olist.duckdb        kho dữ liệu (mỗi người tự tạo, không đưa lên git)
└── docker-compose.yml            cấu hình container Mage
```

## 1. Cài công cụ (làm một lần)

| Công cụ | Windows | macOS | Linux |
|---|---|---|---|
| Git | [git-scm.com/downloads](https://git-scm.com/downloads) | Có sẵn khi gõ `git` lần đầu, hoặc cài từ link bên trái | `sudo apt install git` (Ubuntu) hoặc trình quản lý gói của bản phân phối |
| Docker | [Docker Desktop cho Windows](https://docs.docker.com/desktop/setup/install/windows-install/) | [Docker Desktop cho Mac](https://docs.docker.com/desktop/setup/install/mac-install/) | [Docker Engine](https://docs.docker.com/engine/install/) kèm plugin Docker Compose |

Lưu ý:
- **Windows:** Docker Desktop cần WSL 2. Nếu trình cài báo thiếu, mở PowerShell bằng quyền Administrator, chạy `wsl --install` rồi khởi động lại máy.
- **Máy cần:** RAM từ 8 GB, ổ đĩa trống khoảng 8 GB (image Mage tải về khoảng 1,3 GB, giải nén ra khoảng 5,5 GB).
- **Kiểm tra cài xong:** mở terminal (Windows: PowerShell; macOS: Terminal; Linux: terminal bất kỳ) và chạy:

```bash
git --version
docker --version
docker compose version
```

Cả ba lệnh đều in ra số phiên bản là được. Trên Windows và macOS, nhớ **mở Docker Desktop** và chờ biểu tượng cá voi báo đang chạy trước khi làm các bước sau.

## 2. Lấy mã nguồn

```bash
git clone https://github.com/tthoan23/bi-genai.git
cd bi-genai
```

Mọi lệnh từ đây trở đi đều chạy **trong thư mục `bi-genai`**.

## 3. Giải nén dữ liệu

Dữ liệu gốc nằm sẵn trong repo ở `data/olist-brazilian-ecommerce.zip`. Giải nén vào `data/raw`:

**Windows (PowerShell):**
```powershell
Expand-Archive -Path data\olist-brazilian-ecommerce.zip -DestinationPath data\raw -Force
```

**macOS và Linux:**
```bash
unzip -o data/olist-brazilian-ecommerce.zip -d data/raw
```

**Kiểm tra:** thư mục `data/raw` có đúng 9 file `.csv`, từ `olist_customers_dataset.csv` đến `product_category_name_translation.csv`.

## 4. Khởi động Mage và DuckDB

**Chỉ dành cho Linux:** nếu lệnh `id -u` không in ra `1000`, tạo file `.env` trong thư mục `bi-genai` với nội dung sau (thay số cho đúng máy bạn, lấy từ `id -u` và `id -g`), để file do Mage tạo ra thuộc về tài khoản của bạn:

```
UID=1001
GID=1001
```

Khởi động (lần đầu sẽ tải image Mage, mất vài phút tùy mạng):

```bash
docker compose up -d
```

Chờ khoảng 30 giây rồi mở trình duyệt vào **http://localhost:6789**. Thấy giao diện Mage là được.

**Kiểm tra DuckDB:**

```bash
docker compose exec mage python -c "import duckdb, os; con = duckdb.connect(os.environ['DUCKDB_PATH']); print(con.sql('select 42 as ket_qua'))"
```

Kết quả đúng là một bảng nhỏ có cột `ket_qua` bằng `42`, đồng thời xuất hiện file `warehouse/olist.duckdb`. Đây chính là kho dữ liệu: toàn bộ bảng sẽ nằm trong file này.

## 5. Nạp dữ liệu vào DuckDB

Pipeline `ingest_olist` đọc 9 file CSV trong `data/raw` và nạp vào DuckDB:
- Mỗi file thành một bảng trong schema `staging`, mọi cột giữ nguyên dạng chữ (text) để không mất dòng nào vì lỗi kiểu dữ liệu.
- Mỗi dòng có thêm 5 cột truy vết: tên file, mã kiểm tra (checksum) của file, số thứ tự dòng trong file, mã batch, thời điểm nạp.
- Mỗi lần chạy được ghi vào schema `audit`: batch, lần chạy, số dòng đọc và nạp của từng bảng, lỗi nếu có.

**Cách 1: chạy trên giao diện Mage.** Mở http://localhost:6789, chọn **Pipelines** ở thanh bên trái, bấm vào `ingest_olist`, vào mục **Triggers**, bấm **Run@once** rồi **Run now**. Chờ trạng thái chuyển sang *completed* (khoảng 30 giây).

**Cách 2: chạy bằng lệnh** (dùng khi giao diện khác với mô tả ở trên):

```bash
docker compose exec mage mage run olist_bi ingest_olist
```

Thấy dòng `Pipeline run completed.` là xong.

**Kiểm tra:**

```bash
docker compose exec mage python scripts/query.py sql/check_ingest.sql
```

Kết quả đúng:
- Bảng đầu tiên: batch `FULL_001` có trạng thái `INGESTED` (nạp xong; trạng thái `SUCCESS` sẽ có sau khi làm bước dbt).
- Bảng thứ ba: 9 bảng đều có `rows_read` bằng `rows_loaded`, `rows_rejected` bằng 0, `status` là `SUCCESS`.
- Bảng cuối: số dòng là orders 99.441, customers 99.441, order_items 112.650, order_reviews 99.224, order_payments 103.886, products 32.951, sellers 3.095, geolocation 1.000.163, category_translation 71 (tổng 1.550.922).

**Thử chạy lại:** chạy pipeline thêm một lần nữa rồi kiểm tra lại. Số dòng không đổi (không sinh dòng trùng), còn bảng thứ hai có thêm một lần chạy với `attempt` bằng 2.

## 6. Làm sạch dữ liệu bằng dbt

Bảng thô trong `staging` còn ở dạng chữ, có thể trùng phiên bản giữa các đợt nạp. dbt tạo 9 **view** `stg_*` (cũng trong schema `staging`), mỗi view làm sạch một bảng nguồn:
- Đổi kiểu dữ liệu an toàn: chữ thành ngày giờ, số; giá trị sai thành rỗng (NULL) thay vì làm hỏng cả câu lệnh, và được đếm vào các cột `*_parse_error`.
- Mỗi khoá chỉ giữ một dòng: nếu có nhiều phiên bản từ nhiều đợt nạp, lấy phiên bản của đợt mới nhất (theo `batch_seq`).
- Chuẩn hoá mã bưu chính (đủ 5 chữ số) và tên thành phố (chữ thường, bỏ dấu); bỏ dòng toạ độ trùng.

**Nếu bạn đã khởi động hệ thống trước khi kéo (pull) bước này về**, chạy `docker compose up -d` một lần để container nhận cấu hình mới (thêm biến `DBT_PROJECT_DIR`, `DBT_PROFILES_DIR`).

**Kiểm tra dbt kết nối được kho:**

```bash
docker compose exec mage dbt debug
```

Dòng cuối phải là `All checks passed!`.

**Chạy dbt** (tạo các view và chạy kiểm thử):

```bash
docker compose exec mage dbt build --select staging
```

Kết quả đúng: dòng cuối là `Done. PASS=23 WARN=0 ERROR=0 SKIP=0 TOTAL=23` (9 view và 14 kiểm thử: khoá không rỗng, không trùng, trạng thái đơn và điểm đánh giá hợp lệ).

**Kiểm tra số dòng:**

```bash
docker compose exec mage python scripts/query.py sql/check_staging.sql
```

Kết quả đúng: 8 bảng có `dong_tho` bằng `dong_stg`; riêng geolocation giảm từ 1.000.163 xuống 720.460 do bỏ dòng trùng; các cột thời điểm hiển thị dạng ngày giờ; bảng cuối toàn số 0 (không có giá trị đọc lỗi).

Lưu ý: dbt cần ghi vào `olist.duckdb`, nên đừng chạy dbt khi pipeline Mage đang chạy hoặc DBeaver đang mở file kho.

## 7. Tầng trung gian và bảng khoá

dbt dựng thêm hai tầng (lưu thành **bảng**, nên mỗi lần nạp dữ liệu mới phải chạy lại dbt):

| Tầng | Schema | Làm gì |
|---|---|---|
| Intermediate (7 model `int_*`) | `intermediate` | Vòng đời mỗi đơn (đủ điều kiện xét giao, đúng hạn hay trễ, thời gian từng bước); một đánh giá đại diện cho mỗi đơn; gộp dòng hàng theo đơn; một dòng cho mỗi mã bưu chính; đối chiếu thanh toán |
| Bảng khoá (6 model `km_*`) | `dwh` | Cấp khoá thay thế (số nguyên) cho đơn, dòng hàng, khách, sản phẩm, người bán, mã bưu chính. Khoá đã cấp không bao giờ đổi, kể cả khi chạy lại hay `--full-refresh` |

**Chạy toàn bộ dbt** (staging, intermediate, bảng khoá và kiểm thử):

```bash
docker compose exec mage dbt build
```

Kết quả đúng: dòng cuối là `Done. PASS=71 WARN=0 ERROR=0 SKIP=0 TOTAL=71`, mất khoảng 30 giây.

**Kiểm tra:**

```bash
docker compose exec mage python scripts/query.py sql/check_intermediate.sql
```

Kết quả đúng:
- Bảng khoá: km_order 99.441, km_order_item 112.650, km_customer 96.096, km_product 32.951, km_seller 3.095, km_geography 19.177.
- Giao hàng: 96.478 đơn đã giao, 96.470 đơn đủ điều kiện xét, 6.534 đơn trễ, tỷ lệ trễ 6,77%.
- 98.673 đơn có đánh giá đại diện, điểm trung bình 4,09; 303 đơn lệch thanh toán trên 0,01 BRL, 249 đơn trên 1 BRL.
- 19.177 mã bưu chính, 682 mã có nhiều tên thành phố, 41 mã có nhiều bang.

## 8. Dừng và chạy lại

| Việc | Lệnh |
|---|---|
| Xem container có đang chạy không | `docker compose ps` |
| Dừng (giữ nguyên dữ liệu) | `docker compose stop` |
| Chạy lại | `docker compose start` |
| Xem log khi có lỗi | `docker compose logs --tail 50 mage` |
| Gỡ container (file trong repo vẫn còn) | `docker compose down` |

## 9. Các bước tiếp theo

Nhóm đang dựng hệ thống theo từng bước. Mỗi bước xong sẽ được thêm hướng dẫn vào đây.

- [x] Bước 0: khung repo, dữ liệu, Docker Compose
- [x] Bước 1: Mage và DuckDB chạy được
- [x] Bước 2: pipeline Mage nạp 9 file CSV vào DuckDB, có bảng audit
- [x] Bước 3: dbt làm sạch dữ liệu (staging)
- [x] Bước 4a: tầng trung gian (intermediate) và bảng khoá thay thế
- [ ] Bước 4b: 7 dimension, 2 fact và block dbt trong pipeline Mage
- [ ] Bước 5: kiểm thử và tài liệu dbt
- [ ] Bước 6: nạp tăng thêm (incremental) và kiểm tra chạy lại
- [ ] Bước 7: kết nối Power BI
- [ ] Bước 8: AI tóm tắt và giải thích

## 10. Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| `docker: command not found` hoặc `Cannot connect to the Docker daemon` | Docker chưa cài hoặc Docker Desktop chưa mở. Mở Docker Desktop, chờ chạy xong rồi thử lại. |
| `port is already allocated` khi `docker compose up` | Cổng 6789 đang bị chương trình khác dùng. Tắt chương trình đó, hoặc đổi dòng `"6789:6789"` trong `docker-compose.yml` thành `"6790:6789"` rồi mở http://localhost:6790. |
| Trang http://localhost:6789 không mở được | Chờ thêm 30 giây; xem log bằng `docker compose logs --tail 50 mage`. |
| Báo lỗi file DuckDB bị khóa (`Could not set lock on file`) | DuckDB chỉ cho một chương trình ghi cùng lúc. Đóng DBeaver hoặc chương trình khác đang mở `olist.duckdb` rồi chạy lại. |
| Pipeline báo `Không tìm thấy /home/src/data/raw/...` | Chưa giải nén dữ liệu. Làm lại mục 3 rồi chạy pipeline lại. |
| Pipeline báo `Could not set lock on file` | Đang có chương trình khác mở `olist.duckdb` (ví dụ DBeaver). Ngắt kết nối (Disconnect) trong chương trình đó rồi chạy lại. |
| `dbt` báo `Could not set lock on file` | Giống lỗi trên: đóng chương trình đang mở `olist.duckdb`, đợi pipeline Mage chạy xong rồi chạy lại dbt. |
| `dbt build` báo không tìm thấy bảng nguồn (`Catalog Error: Table … does not exist`) | Chưa nạp dữ liệu. Làm mục 5 trước rồi chạy lại dbt. |
| Linux: không sửa được file do Mage tạo | Xem phần `.env` với `UID`, `GID` ở mục 4, rồi chạy `docker compose up -d` lại. |

## 11. Nguồn dữ liệu

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), giấy phép CC BY-NC-SA 4.0. Repo giữ nguyên file gốc trong `data/` để mọi người chạy lại được, chỉ dùng cho mục đích học tập. Xem thêm `data/README.md`.
