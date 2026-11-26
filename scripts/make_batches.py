"""Mô phỏng nguồn dữ liệu thay đổi theo thời gian cho bài Full Load / Incremental Load.

Bộ dữ liệu Olist là dữ liệu tĩnh: mỗi đơn chỉ có trạng thái cuối cùng. Script này dựng lại
"nguồn trông như thế nào" tại từng mốc (ảnh chụp tích luỹ), để SSIS có dữ liệu mới và dữ liệu thay đổi:

    data/batches/FULL_001/  nguồn tại 2017-12-31 23:59:59   (lần nạp đầu: Full Load)
    data/batches/INC_001/   nguồn tại 2018-04-30 23:59:59   (Incremental Load)
    data/batches/INC_002/   toàn bộ dữ liệu gốc, CET = mốc lớn nhất trong dữ liệu (kết quả cuối = nạp toàn bộ)

Mỗi thư mục có 9 file cùng tên với file gốc và _cutoff.txt (mốc CET của batch).

Giả định mô phỏng (cần ghi vào báo cáo):
 1. Đơn xuất hiện khi đã đặt mua (ngày mua <= mốc). Ngày giao dự kiến biết ngay khi đặt.
 2. Mốc duyệt, giao vận chuyển, khách nhận sau mốc thì chưa xảy ra: để trống, trạng thái lùi về
    shipped / approved / created theo mốc gần nhất còn lại.
 3. Đơn bị huỷ / không có hàng trong 30 ngày cuối trước mốc và không có mốc nào sau mốc: tại mốc vẫn là
    'processing', batch sau mới thành 'canceled' / 'unavailable' (đổi trạng thái KHÔNG kèm mốc thời gian mới;
    LSET/CET không bắt được, phải so mã băm).
 4. Đánh giá xuất hiện khi khách đã trả lời (review_answer_timestamp <= mốc).
 5. Dòng hàng, thanh toán, khách hàng có cùng lúc với đơn; sản phẩm, người bán xuất hiện khi có dòng hàng.
 6. geolocation và category_translation không có mốc thời gian: chép nguyên file gốc vào mọi batch
    (cùng nội dung nên cùng SHA-256; SSIS bỏ qua ở các batch sau).

Chạy từ thư mục gốc repo:  python scripts/make_batches.py
"""
import csv
import datetime as dt
import pathlib
import shutil

RAW = pathlib.Path("data/raw")
OUT = pathlib.Path("data/batches")
BATCHES = [("FULL_001", "2017-12-31 23:59:59"), ("INC_001", "2018-04-30 23:59:59"), ("INC_002", None)]
FILES = {
    "orders": "olist_orders_dataset.csv", "customers": "olist_customers_dataset.csv",
    "order_items": "olist_order_items_dataset.csv", "order_reviews": "olist_order_reviews_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv", "products": "olist_products_dataset.csv",
    "sellers": "olist_sellers_dataset.csv", "geolocation": "olist_geolocation_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}
# Ký tự xuống dòng phải giống file gốc vì Flat File Connection trong SSIS khai báo cố định
LINE_END = {"order_reviews": "\r\n"}
CANCEL_WINDOW_DAYS = 30

csv.field_size_limit(10 ** 7)


def read(table):
    with open(RAW / FILES[table], encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]


def write(folder, table, header, rows):
    with open(folder / FILES[table], "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator=LINE_END.get(table, "\n"))
        w.writerow(header)
        w.writerows(rows)


def orders_at(header, rows, cutoff, final):
    i = {c: k for k, c in enumerate(header)}
    later = ["order_approved_at", "order_delivered_carrier_date", "order_delivered_customer_date"]
    cancel_from = (dt.datetime.fromisoformat(cutoff) - dt.timedelta(days=CANCEL_WINDOW_DAYS)).isoformat(" ")
    out, rolled_back, cancel_hidden = [], 0, 0
    for r in rows:
        if r[i["order_purchase_timestamp"]] > cutoff:
            continue
        r = list(r)
        masked = False
        for c in later:
            if r[i[c]] and r[i[c]] > cutoff:
                r[i[c]] = ""
                masked = True
        status = r[i["order_status"]]
        if masked:
            rolled_back += 1
            if r[i["order_delivered_carrier_date"]]:
                r[i["order_status"]] = "shipped"
            elif r[i["order_approved_at"]]:
                r[i["order_status"]] = "approved"
            else:
                r[i["order_status"]] = "created"
        elif not final and status in ("canceled", "unavailable") and r[i["order_purchase_timestamp"]] >= cancel_from:
            r[i["order_status"]] = "processing"
            cancel_hidden += 1
        out.append(r)
    return out, rolled_back, cancel_hidden


def main():
    raw = {t: read(t) for t in FILES if t not in ("geolocation", "category_translation")}
    # Batch cuối không cắt: CET = thời điểm nghiệp vụ lớn nhất có trong dữ liệu (đơn và đánh giá)
    oh, orows = raw["orders"]
    rh, rrows = raw["order_reviews"]
    latest = max([v for r in orows for v in r[3:7] if v] + [r[rh.index("review_answer_timestamp")] for r in rrows])
    report = []
    for batch, cutoff in BATCHES:
        folder = OUT / batch
        folder.mkdir(parents=True, exist_ok=True)
        c = cutoff or latest
        (folder / "_cutoff.txt").write_text(c, encoding="ascii")

        oh, orows = raw["orders"]
        orders, rolled_back, cancel_hidden = orders_at(oh, orows, c, cutoff is None)
        order_ids = {r[0] for r in orders}
        customer_ids = {r[1] for r in orders}

        ih, irows = raw["order_items"]
        items = [r for r in irows if r[0] in order_ids]
        product_ids = {r[2] for r in items}
        seller_ids = {r[3] for r in items}
        ph, prows = raw["order_payments"]
        payments = [r for r in prows if r[0] in order_ids]
        rh, rrows = raw["order_reviews"]
        ri = {col: k for k, col in enumerate(rh)}
        reviews = [r for r in rrows if r[ri["order_id"]] in order_ids and r[ri["review_answer_timestamp"]] <= c]
        ch, crows = raw["customers"]
        customers = [r for r in crows if r[0] in customer_ids]
        prh, prrows = raw["products"]
        products = [r for r in prrows if r[0] in product_ids]
        sh, srows = raw["sellers"]
        sellers = [r for r in srows if r[0] in seller_ids]

        for table, header, rows in [("orders", oh, orders), ("order_items", ih, items), ("order_payments", ph, payments),
                                    ("order_reviews", rh, reviews), ("customers", ch, customers),
                                    ("products", prh, products), ("sellers", sh, sellers)]:
            write(folder, table, header, rows)
            report.append((batch, table, len(rows)))
        for table in ("geolocation", "category_translation"):
            shutil.copyfile(RAW / FILES[table], folder / FILES[table])
            with open(RAW / FILES[table], encoding="utf-8-sig", newline="") as f:
                report.append((batch, table, sum(1 for _ in csv.reader(f)) - 1))
        print(f"{batch}: CET {c}; {rolled_back:,} đơn lùi trạng thái do mốc sau CET; "
              f"{cancel_hidden:,} đơn huỷ chưa lộ (đổi trạng thái không kèm mốc thời gian)")

    print(f"\n{'Bảng':22}" + "".join(f"{b:>12}" for b, _ in BATCHES))
    for table in FILES:
        print(f"{table:22}" + "".join(f"{n:>12,}" for b, t, n in report if t == table))


if __name__ == "__main__":
    main()
