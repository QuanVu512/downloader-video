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
