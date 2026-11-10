# Dịch Anh → Việt trực tiếp

Ứng dụng nghe tiếng Anh qua micro, dịch ngay khi hết mỗi câu và đọc to bản dịch tiếng Việt ra loa. Trong lúc đang đọc, app vẫn nghe tiếp câu mới.

Repo có **2 phiên bản**:

| | App iPhone (thư mục `ios/`) | Bản web (`index.html`) |
|---|---|---|
| Vừa đọc vừa nghe câu mới | **Có** (khử tiếng vọng) | Không: trên iPhone phải tắt micro khi đang đọc |
| Cách cài | Cần cài lên máy (xem bên dưới) | Mở bằng Safari, không cần cài |
| Dịch | Apple Translation trên máy (miễn phí, nhanh), dự phòng dịch trực tuyến | Google / AI Claude, có từ điển y khoa |
| Hết hạn | Cài bằng Apple ID miễn phí: 7 ngày phải cài lại | Không |

---

## A. App iPhone: cách cài

Yêu cầu: iPhone chạy **iOS 18 trở lên**, một **Apple ID** (tài khoản miễn phí là được), dây cáp nối iPhone với máy tính.

### Cách 1: Có máy Mac (khuyến nghị)

1. Trên Mac, mở **App Store** → tìm **Xcode** → Cài đặt (khoảng 10 GB, mất 30–60 phút).
2. Tải mã nguồn: trên trang GitHub của repo bấm **Code → Download ZIP**, giải nén.
3. Mở thư mục `ios`, nhấp đúp file **`DichAnhViet.xcodeproj`** → Xcode mở ra.
4. Đăng nhập Apple ID: menu **Xcode → Settings → Accounts → nút +** → Apple ID.
5. Ở cột trái bấm vào **DichAnhViet** (biểu tượng xanh trên cùng) → tab **Signing & Capabilities**:
   - **Team**: chọn tên của bạn (Personal Team).
   - **Bundle Identifier**: nếu báo lỗi đỏ, sửa `vn.dichanhviet.live` thành tên khác không trùng, ví dụ `vn.tenban.dichanhviet`.
6. Cắm iPhone vào Mac bằng cáp, trên iPhone bấm **Tin cậy**.
7. Trên iPhone bật **Chế độ nhà phát triển**: Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển → Bật → máy khởi động lại.
8. Trong Xcode, ở thanh trên cùng chọn tên iPhone của bạn, bấm nút **▶ (Run)**.
9. Lần đầu, iPhone sẽ báo "nhà phát triển không được tin cậy": vào **Cài đặt → Cài đặt chung → Quản lý VPN & Thiết bị** → chọn Apple ID của bạn → **Tin cậy**. Mở lại app.

### Cách 2: Chỉ có máy Windows

GitHub tự biên dịch sẵn file cài đặt `.ipa` mỗi khi mã nguồn thay đổi.

1. Trên trang GitHub của repo, vào tab **Actions** → chọn lần chạy **Build iOS app** mới nhất (dấu ✓ xanh) → kéo xuống mục **Artifacts** → tải **DichAnhViet-ipa** → giải nén ra file `DichAnhViet-unsigned.ipa`.
2. Cài **iTunes** (bản tải từ apple.com, không dùng bản Microsoft Store) và **Sideloadly** (sideloadly.io).
3. Cắm iPhone vào máy tính, mở Sideloadly, kéo file `.ipa` vào, nhập Apple ID, bấm **Start**.
4. Trên iPhone: bật Chế độ nhà phát triển và Tin cậy như bước 7 và 9 ở Cách 1.

> Với Apple ID miễn phí, app chỉ chạy được **7 ngày**, sau đó cắm máy và cài lại (bấm ▶ trong Xcode hoặc Start trong Sideloadly). Muốn dùng lâu dài thì cần tài khoản Apple Developer (99 USD/năm).

### Lần đầu mở app

1. Bấm **Bắt đầu nghe** → cho phép **Micro** và **Nhận dạng lời nói**.
2. iPhone sẽ hỏi tải gói dịch **Anh – Việt**: bấm **Tải về** (cần mạng một lần, sau đó dịch được cả khi không có mạng).
3. Nên tải giọng đọc tiếng Việt chất lượng cao: **Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt** → tải giọng có chữ "Nâng cao".

### Cài đặt trong app (biểu tượng bánh răng)

- **Tốc độ đọc**, **Nghe thử giọng đọc**.
- **Chốt câu sau khi im lặng**: mặc định 0,8 giây. Câu có dấu chấm thì được chốt ngay.
- **Khử tiếng vọng** (mặc định bật): micro không nghe lại tiếng Việt từ loa, nên vừa đọc vừa nghe được.
- **Tạm ngưng nghe khi đang đọc**: bật nếu dùng loa ngoài mà app vẫn bắt nhầm tiếng vọng.

**Mẹo:** đeo tai nghe (AirPods…) để nghe bản dịch, micro điện thoại vẫn hướng về người nói tiếng Anh. Đây là cách cho kết quả tốt nhất.

---

## B. Bản web (không cần cài)

1. Bật GitHub Pages: repo → **Settings → Pages** → Source: *Deploy from a branch* → chọn nhánh chứa `index.html`, thư mục `/ (root)` → Save.
2. Mở địa chỉ `https://<tên-tài-khoản>.github.io/dich-anh-viet/` bằng **Safari** trên iPhone.
3. Cho phép micro: Cài đặt → Safari → Micro → Cho phép; và Cài đặt → Cài đặt chung → Bàn phím → bật **Đọc chính tả**.

Hạn chế: trên iPhone, bản web phải tắt micro trong lúc đọc, nên câu nói chen vào lúc đó có thể bị sót.
