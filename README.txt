BILIBILI + VOCAL REMOVER 2.4 — Windows (17/10/2026)

MỞ VÀ DÙNG
Bản 2.4.3 thêm curl có sẵn trên Windows làm bộ tải dự phòng, tải các đoạn 8 MiB có xác minh Range. Nếu aria2 lỗi hoặc tải video quá chậm, app thử curl; curl đổi CDN khi tốc độ dưới 256 KiB/s liên tục 30 giây. Nếu tất cả vẫn lỗi, app thử HTTP yt-dlp để tiếp tục trên kết nối chậm. Không đặt trần tốc độ tải.
Bản 2.4 có nút Vocal Remover ngay trên cửa sổ Bilibili. Tải xong rồi bấm nút này để mở sẵn audio vừa tải; cũng có thể chọn audio/video khác. Hai chức năng cùng repo, VERSION.txt và nút Cập nhật ứng dụng.
Nâng từ 2.3: lần mở Vocal đầu hoàn tất module từ ZIP đã tải, xác minh bằng checksum GitHub. Đóng Vocal trước khi cập nhật. Model UVR, môi trường Python, thiết lập và checkpoint được giữ riêng, không thay khi cập nhật code.
Vocal cần Python 3.12 64-bit, FFmpeg trong PATH và model UVR-MDX-NET Inst HQ 1 từ bản UVR đã cài. Nếu chưa có môi trường thư viện phù hợp, app chuẩn bị riêng lần đầu qua mạng. Không phát hành trọng số model hoặc media lên GitHub.
Vocal tự chia phần, xử lý tuần tự CPU 2 luồng, ghép đúng số mẫu và lưu tiến độ. Mặc định phần 120 giây + vùng chồng lấn. Cần đủ dung lượng đĩa cho file trung gian; nên nghe đối chiếu chất lượng.
Bản 2.3 tách Cập nhật ứng dụng (repo QuanVu512/downloader-video, có kiểm tra SHA-256 và sao lưu) khỏi Cập nhật yt-dlp. Chỉ cập nhật ứng dụng khi không có tác vụ tải. Sau khi cài xong giao diện mở lại. Tăng VERSION.txt rồi commit/push main để GitHub Actions kiểm tra và tạo Release mới.
Bản 2.2 tự tạo <tên>stage1.zip trong thư mục lưu sau khi video và âm thanh đã được xác minh. ZIP chỉ chứa hai tệp media ở thư mục gốc, dùng trực tiếp cho capcut-1-5-auto-dub giai đoạn 1. Tệp rời vẫn được giữ. Không nén lại media; hỗ trợ tệp lớn bằng ZIP64. ZIP cùng tên được kiểm tra SHA-256 để dùng lại; nếu nội dung khác, ứng dụng giữ nguyên ZIP cũ và báo lỗi. Lỗi đóng gói không làm mất video/âm thanh, bấm tải lại cùng thông tin để thử đóng gói tiếp.
Từ bản 2.1.1, khi hai tệp đã được xác minh, nút tải chuyển thành Đã tải xong và khóa; bấm Mở thư mục chứa tệp để xem kết quả. Đổi link, chất lượng, tên hoặc thư mục sẽ mở lại nút tải cho lựa chọn mới. Nếu hai tệp đã có sẵn từ một lượt trước, ứng dụng chỉ xác minh lại, không tải lại dữ liệu.
1. Đóng bản cũ. Giải nén gói ZIP vào một thư mục mới, mở Bilibili-Downloader, nhấn đúp Start.bat.
2. Dán link trang video Bilibili. Link không có p mặc định là P1; ?p=2 tải P2.
3. Bấm Lấy chất lượng. Danh sách thay đổi theo video; mặc định chọn độ cao lớn nhất có sẵn, không cố định 720p/1080p. Ưu tiên H.264 trong cùng độ cao và tốc độ khung hình để dễ dùng trong phần mềm dựng.
4. Chọn chất lượng, tên cơ sở và thư mục. Bấm Tải video và âm thanh.
5. Kết quả: <tên>_video.mp4 có hình, không tiếng; <tên>_audio.m4a chứa AAC riêng. Không ghép hoặc nén lại.
6. Tiến độ chung chạy từ 0 đến 100; dòng trạng thái ghi rõ đang tải video hay tiếng, tốc độ và thời gian còn lại khi máy chủ cung cấp.

TẢI TIẾP VÀ XỬ LÝ LỖI
- Bấm Dừng / giữ phần dở khi muốn dừng. Đợi tác vụ dừng rồi mới đóng cửa sổ.
- Để tiếp tục: dùng cùng link/phần p, chất lượng, tên và thư mục, rồi bấm tải lại.
- Giữ các tệp .part, .aria2 và .bilibili.json khi muốn tải tiếp. Tệp .download.lock 0 byte dùng để ngăn hai cửa sổ cùng ghi một tên.
- Tên đã dùng cho video/phần/chất lượng khác sẽ được chặn. Chọn tên mới để giữ nguyên tệp cũ.
- Khi cập nhật từ bản 1.x, nếu tên tệp cũ đã tồn tại mà chưa có hồ sơ .bilibili.json, chọn tên mới. Không tự nối vào tệp cũ chưa xác nhận danh tính.
- Máy chủ tải lỗi: ứng dụng thử riêng từng URL CDN do Bilibili cung cấp; lấy URL mới sau khi các CDN trong lượt đều lỗi. Giới hạn 3 lượt: 4, 2 rồi 1 kết nối. Gặp HTTP 567/429 hoặc lỗi socket/TLS thì các lần thử còn lại của luồng đó dùng 1 kết nối; đợi 5 rồi 10 giây giữa các lượt làm mới.
- HTTP 567 là phản hồi từ CDN; chưa đủ bằng chứng kết luận video bị xóa. Chỉ nhận 404 từ mã HTTP thật, không từ chữ số trong URL. Nếu các CDN vẫn lỗi, giữ phần dở rồi thử lại sau.
- Nếu aria2 lỗi socket/TLS, HTTP 567/429 hoặc video tải quá chậm, ứng dụng thử curl, lần lượt các CDN và URL mới. Nếu Windows không có curl hoặc các đường curl đều lỗi, bộ tải HTTP yt-dlp là phương án cuối, không dừng chỉ vì tốc độ dưới 64 KiB/s. Không cần cài Python cho downloader.
- Curl dùng <tên>_video.mp4.curl.part hoặc <tên>_audio.m4a.curl.part, xác minh Content-Range trước khi dùng phần tải tiếp. Phản hồi sai Range không được ghép vào checkpoint. Nếu đã có .native.part tuần tự, app sao chép sang checkpoint curl để tải tiếp và giữ nguyên bản cũ. Các checkpoint aria2 có thể chứa vùng khuyết, luôn được giữ riêng.
- HTTP dùng <tên>_video.mp4.native.part hoặc <tên>_audio.m4a.native.part làm checkpoint riêng. Tệp aria2 có thể chứa vùng khuyết nên không được nối tuần tự bằng bộ tải khác; lần chuyển từ aria2 sang HTTP có thể cần tải lại từ đầu, các lần HTTP sau tiếp tục checkpoint HTTP. Phần aria2 cũ vẫn được giữ, kể cả khi HTTP hoàn tất; có thể tự dọn .part/.aria2 cũ sau khi đã kiểm tra tệp cuối.
- Tải tiếp từ bản 2.0: mở bản 2.1, chọn đúng link/phần p, chất lượng, tên và thư mục lưu cũ để dùng tiếp .part/.aria2/.bilibili.json. Không di chuyển hoặc xóa các tệp này. Bản mới giữ hồ sơ tải schema 1.
- Lỗi bảng tiến độ không làm dừng tải. Hoạt động đọc stdout/stderr liên tục, giữ nguyên dòng nguyên nhân; query/token bị ẩn trong log.
- 403/đăng nhập/VIP/giới hạn vùng, DNS, hết dung lượng và quyền thư mục được báo rõ. Chỉ tải chất lượng mà quyền truy cập hiện tại của ứng dụng lấy được; không có cơ chế bỏ qua quyền của Bilibili.
- Bấm Cập nhật công cụ khi Bilibili đổi cách cung cấp thông tin. yt-dlp và checksum được lấy từ cùng một bản phát hành chính thức; công cụ cũ được giữ đến khi tải mới xác minh xong.

XÁC MINH KẾT QUẢ
Ứng dụng chỉ đổi tệp tải thành tên chính thức sau khi công cụ báo hoàn tất, aria2 không còn phần thiếu (nếu dùng aria2), và kiểm tra cấu trúc MP4, luồng hình/tiếng, độ cao, thời lượng. Dung lượng được đối chiếu nếu nguồn trả số byte chính xác. Hai tệp phải có thời lượng gần nhau. Kiểm tra này không giải mã từng khung hình và không thay thế checksum nguồn khi nguồn không cung cấp.

PORTABLE / COMMAND LINE
- Riêng chức năng tải Bilibili không cần Python; Vocal cần Python/FFmpeg như trên. Không thay thiết lập PowerShell của máy; ExecutionPolicy Bypass chỉ áp dụng cho tiến trình mở ứng dụng.
- Gói đã kèm yt-dlp và aria2. Nếu thiếu công cụ, ứng dụng tải chúng từ GitHub chính thức.
- Start-CLI.bat -SetupOnly
- Start-CLI.bat "LINK_BILIBILI" -InspectOnly
- Start-CLI.bat "LINK_BILIBILI" -VideoFormatId 30064 -FileName "ten_tuy_chon" -OutputDirectory "D:\Video"
- Start-CLI.bat -SetupOnly -UpdateTools
- Nhận link https://www.bilibili.com/video/BV.../ hoặc av..., không nhận token BraveDown. Mỗi lần tải đúng một phần p.

Mã nguồn mở: yt-dlp (https://github.com/yt-dlp/yt-dlp), aria2 (https://github.com/aria2/aria2). Giữ các tệp giấy phép trong tools.
