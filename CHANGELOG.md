# Bilibili + Vocal Remover 2.4.5

- Sửa lỗi `Unable to extract initial state`: thử trang Bilibili `/en/` một lần khi trang thường thiếu dữ liệu video, giữ nguyên phần p và bộ trích xuất chính thức.
- Plugin tương thích nằm trong core hiện có để updater cũ cũng nhận được bản sửa; downloader portable vẫn không cần cài Python riêng.
- Thông báo lỗi phân biệt cập nhật ứng dụng và cập nhật yt-dlp.

# Bilibili + Vocal Remover 2.4.4

- Tự dọn các phần tải aria2, curl và HTTP cũ sau khi xác minh đủ video, audio và ZIP; giữ phần dở của job chưa hoàn tất để tải tiếp.
- Windows tự xoá file khóa khi worker kết thúc, kể cả khi bị dừng từ GUI.
- Lưu hồ sơ xác minh/tải tiếp trong work/download-records thay vì để JSON cạnh kết quả; tự chuyển hồ sơ cũ khi tiếp tục tải và vẫn dùng lại được media đã hoàn tất.
- Thêm kiểm tra dọn file đúng job, bảo toàn media/ZIP, phân biệt hồ sơ theo thư mục và khóa tải đồng thời.

# Bilibili + Vocal Remover 2.4.3

- Thêm curl dự phòng trên Windows, tải đoạn 8 MiB và checkpoint riêng có xác minh Range; giữ nguyên phần aria2 và HTTP cũ.
- Đổi CDN khi curl dưới 256 KiB/s trong 30 giây; chuyển khỏi aria2 khi video tải quá chậm. HTTP yt-dlp vẫn là phương án cuối cho mạng chậm.
- Kiểm tra tải tiếp, mất kết nối, Range sai/bị bỏ qua, tệp đã đủ và phản hồi HTTP lỗi; xác minh media và ZIP như trước.

# Bilibili + Vocal Remover 2.4.2

- Khi aria2 gặp HTTP 567/429 hoặc lỗi socket, thử tiếp aria2 với một kết nối và URL mới trước khi chuyển sang HTTP yt-dlp.

# Bilibili + Vocal Remover 2.4.1

- Sửa lỗi Get-FileHash không được nhận diện: dùng SHA-256 streaming của .NET cho kiểm tra công cụ, tạo ZIP và updater.
- Worker Windows PowerShell tự khởi tạo PSModulePath, tránh kế thừa đường dẫn module từ host khác.
- Giữ nguyên kiểm tra checksum và dữ liệu; thêm 11 hồi quy khi Get-FileHash bị vô hiệu hoá.

# Bilibili + Vocal Remover 2.4.0

- Thêm nút Vocal Remover trong Bilibili, chuyển sẵn audio vừa tải sang giao diện tách lời.
- Cập nhật engine và giao diện Vocal cùng Bilibili trong một gói phát hành.
- Hoàn tất module từ ZIP đã xác minh khi nâng từ updater 2.3.
- Khoá cập nhật giữa Python và PowerShell; giữ model, môi trường, thiết lập và checkpoint.
- CI kiểm tra cả hai chức năng, rollback và tương thích nâng cấp trước phát hành.
# Bilibili Downloader 2.3.0

- Cho phép tải HTTP tiếp tục khi tốc độ thấp hơn 64 KiB/s; không phát sinh `ThrottledDownload` từ ngưỡng do ứng dụng đặt.
- Giữ dòng nguyên nhân lỗi yt-dlp thay vì chỉ các dòng traceback cuối; phân biệt lỗi bộ tải native với aria2.
- Tách cập nhật ứng dụng từ repo QuanVu512/downloader-video và cập nhật công cụ yt-dlp.
- Kiểm tra checksum, phiên bản, đường dẫn ZIP, cú pháp script; sao lưu và hoàn nguyên khi cài ứng dụng thất bại.
- Chặn cập nhật khi có worker đang tải; bảo toàn tool, video và checkpoint.
- Thêm kiểm thử HTTP chậm, bộ kiểm thử updater và pipeline phát hành ZIP/checksum sau khi tăng VERSION.txt rồi push main.

Các tính năng giữ lại: tải tiếp theo danh tính video/phần/chất lượng, CDN dự phòng, bộ tải native, xác minh media và tự đóng gói ZIP đầu vào CapCut.
