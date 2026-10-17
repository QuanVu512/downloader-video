# Bilibili Downloader — Windows

Tải một phần video Bilibili thành MP4 không tiếng và AAC riêng, sau đó tự tạo `<tên>stage1.zip` để dùng với skill CapCut. Hỗ trợ tải tiếp, CDN dự phòng, URL mới và HTTP native khi aria2 lỗi.

## Sử dụng

Tải ZIP tại [GitHub Releases](https://github.com/QuanVu512/downloader-video/releases/latest), giải nén vào một thư mục riêng rồi mở `Start.bat`.

1. Dán link video Bilibili, có thể chỉ định phần bằng `?p=2`.
2. Bấm **Lấy chất lượng**, chọn chất lượng, tên và thư mục lưu.
3. Bấm tải. Chỉ báo hoàn tất sau khi kiểm tra hai tệp và ZIP.
4. Để tiếp tục, dùng đúng link/phần, chất lượng, tên và thư mục trước đó. Giữ `.part`, `.native.part`, `.aria2`, `.bilibili.json`.

Từ 2.3.0, tải chậm vẫn tiếp tục nhận dữ liệu; không dừng chỉ vì thấp hơn 64 KiB/s. Timeout socket vẫn xử lý kết nối đứng hoàn toàn. Phiên bản cũ có thể báo `ThrottledDownload`; cập nhật ứng dụng để nhận bản sửa.

## Hai nút cập nhật

- **Cập nhật ứng dụng**: lấy bản mới của repo này từ GitHub Releases, kiểm tra SHA-256, cú pháp script và phiên bản rồi thay các tệp ứng dụng. Giữ công cụ đã cài, thư mục `work`, video và checkpoint. Lưu bản sao phiên bản cũ; hoàn nguyên nếu cài lỗi. Khi cập nhật thành công, giao diện mở lại.
- **Cập nhật yt-dlp**: cập nhật bộ trích xuất yt-dlp từ dự án chính thức; không đổi mã ứng dụng.

Bản 2.2 trở về trước chưa có cơ chế tự cập nhật ứng dụng: giải nén bản 2.3.0 một lần để bắt đầu dùng nút mới. Không cập nhật ứng dụng khi cửa sổ khác đang tải. Nút mới dùng bản phát hành công khai, không yêu cầu đưa GitHub token vào ứng dụng.

## Phát triển và phát hành

Repository chỉ chứa source/test, không chứa media hay các executable đã tải. Chạy `Start-CLI.bat -SetupOnly` để cài công cụ từ GitHub chính thức, hoặc mở `Start.bat` để cài khi cần.

Chạy kiểm tra trên Windows có Python:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test.ps1
```

Tạo gói portable:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build-Release.ps1 -SetupTools
```

Để phát hành phiên bản mới:

1. Sửa code, tăng dòng đầu `VERSION.txt` theo `x.y.z`, cập nhật ngày và `CHANGELOG.md`.
2. Commit và push lên `main`.
3. GitHub Actions chạy kiểm tra, đóng gói và tạo Release `vX.Y.Z` cùng ZIP/checksum. Nếu tag đã có, workflow không thay nội dung release cũ; phải tăng version để phát hành bản tiếp theo.

Không commit `tools/`, `work/`, `tests/work/`, `dist/`, token hoặc media. Fixture kiểm thử được sinh từ dữ liệu cấu trúc, không dùng video của người dùng. Tải/giải nén media không tự chạy workflow CapCut.

Chi tiết sử dụng portable: [README.txt](README.txt). Tham chiếu giao thức phát hành: [GitHub Releases API](https://docs.github.com/en/rest/releases/releases).
