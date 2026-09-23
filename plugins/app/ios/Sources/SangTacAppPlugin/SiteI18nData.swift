import Foundation

/**
 GENERATED FILE — do not edit by hand.

 The Vietnamese -> Simplified Chinese overlay injected into the site at document
 start. Regenerate with `node scripts/gen-site-i18n.js`; CI runs the same script
 with --check so the Swift and data/site-i18n.json cannot drift apart.

 Why an overlay at all: the site's own i18n only covers `<text>key</text>`
 placeholders (fed by /mobile/lang/zh.json, which is complete — 188 keys, same as
 vi.json). Everything else is a hardcoded Vietnamese literal in the server HTML
 or in the site's JS, and the server is not ours to change.
 */
enum SiteI18nData {
    static let script = """
    (function () {
        if (window.__stvI18nInstalled) { return; }
        window.__stvI18nInstalled = true;

        // Pairs are [vietnamese, chinese]. The site translates anything written as
        // <text>some_key</text> itself from /mobile/lang/zh.json; these are the
        // strings it hardcodes in the server HTML and in its own JS.
        var EXACT = [
            ['Âm lượng (0 - 1)', '播放音量（0 - 1）'],
            ['Ảnh', '图片'],
            ['Ảnh đã lưu', '已保存图片'],
            ['API key của Fpt.ai', 'Fpt.ai 的 API key'],
            ['API key của VBee.', 'VBee 的 API key。'],
            ['ApiKey của zalo', 'zalo 的 ApiKey'],
            ['App id của VBee.', 'VBee 的 App id。'],
            ['App lag? Cập nhật webview ngay', '应用卡顿？立即更新 WebView'],
            ['Bá tổng', '霸总'],
            ['Bách hợp', '百合'],
            ['Bài viết của', '的文章'],
            ['Bấm back lần nữa để thoát...', '再按一次返回键退出...'],
            ['Bạn cần phải là VIP trở lên để sử dụng tính năng này', '你需要 VIP 及以上权限才能使用此功能'],
            ['Bạn chưa đăng nhập', '您尚未登录'],
            ['Bạn chưa tạo gói name nào.', '你还没有创建译名包。'],
            ['Bạn chưa từng mua chương nào..', '你还没有购买过章节。'],
            ['Bạn chưa từng tải truyện nào.', '你还没有下载过小说。'],
            ['Bạn có muốn xóa từ "{0}" này không?', '要删除译名「{0}」吗？'],
            ['Bạn có xác nhận đăng xuất tài khoản?', '确认要注销账号吗？'],
            ['Bật', '开启'],
            ['Bắt đầu từ', '起始章节'],
            ['Nhập khoảng chương để tải:', '输入要下载的章节范围：'],
            ['Đến chương', '结束章节'],
            ['Bật dịch chương truyện', '开启章节翻译'],
            ['Biết rồi!', '知道了！'],
            ['Bình luận', '评论'],
            ['BÌNH LUẬN', '评论数'],
            ['Bộ lọc name', '译名过滤器'],
            ['Bộ nhớ tạm', '剪贴板'],
            ['Cách đấu', '格斗'],
            ['Cài đặt', '设置'],
            ['Cài đặt dịch truyện', '翻译设置'],
            ['Cài đặt TextToSpeech', '文字转语音设置'],
            ['Cạnh kỹ', '竞技'],
            ['Cao giọng (0.5 - 2)', '音调（0.5 - 2）'],
            ['Cấu hình audio', '播放设置'],
            ['Chân nhân', '真人'],
            ['Chiến đấu', '战斗'],
            ['Chiến tranh', '战争'],
            ['Chính năng lượng', '正能量'],
            ['Chỉnh sửa', '编辑'],
            ['Chỉnh sửa màu', '编辑颜色'],
            ['Cho phép hoạt động', '启用'],
            ['Chọn công cụ dịch', '选择翻译工具'],
            ['Chọn hình nền', '选择背景图片'],
            ['Chọn khung', '框选'],
            ['Chọn màu', '选择颜色'],
            ['Chọn ngôn ngữ dịch', '选择翻译语言'],
            ['Chưa có bình luận nào', '暂无评论'],
            ['Chưa có dữ liệu', '暂无数据'],
            ['Chưa có gói name cho truyện này.', '此小说还没有译名包。'],
            ['Chưa phân loại', '未分类'],
            ['Chữa trị', '治愈'],
            ['Chung', '通用'],
            ['Chương', '章'],
            ['Chuyển văn bản thành giọng nói không khả dụng trên thiết bị này', '此设备不支持文字转语音'],
            ['Cơ chiến', '机战'],
            ['Cố gắng', '努力'],
            ['Có lỗi khi tải danh sách gói name cho truyện này.', '加载此小说的译名包列表时出错。'],
            ['Có lỗi khi tải danh sách gói name đặc biệt.', '加载特殊译名包列表时出错。'],
            ['Cổ phong', '古风'],
            ['Còn tiếp', '连载中'],
            ['Công pháp', '功法'],
            ['Công sở', '职场'],
            ['Cũ nhất', '最早'],
            ['Cười vang', '爆笑'],
            ['Đã dừng', '已停止'],
            ['Đã lưu', '已保存'],
            ['Đã nhập gói name', '已导入译名包'],
            ['Đã tải {0}/', '已下载 {0}/'],
            ['Đã tới cuối danh sách', '已到列表末尾'],
            ['Đam mỹ', '耽美'],
            ['Đan dược', '丹药'],
            ['Đang kích hoạt', '已激活'],
            ['Đang làm mới', '正在刷新'],
            ['Đang tải bình luận...', '正在加载评论...'],
            ['Đang tải lịch sử...', '正在加载历史...'],
            ['Đang tải nội dung...', '正在加载内容...'],
            ['Đang tải...', '加载中...'],
            ['Đang trả lời', '回复'],
            ['Đang trả lời <b>', '正在回复 <b>'],
            ['Đang trả lời <b>@', '正在回复 <b>@'],
            ['Đánh dấu', '书签'],
            ['Danh mục', '目录'],
            ['Danh sách chương', '章节目录'],
            ['Danh sách thế lực', '势力列表'],
            ['Danh sách truyện', '小说列表'],
            ['Đề cử ngẫu nhiên', '随机推荐'],
            ['Dị năng', '异能'],
            ['Dị thế giới', '异世界'],
            ['Địa chỉ', '地址'],
            ['Dịch', '翻译'],
            ['Dịch hình ảnh', '翻译图片'],
            ['Dịch tiếng trung', '翻译中文'],
            ['Dịch trang web', '翻译网页'],
            ['Diễn cảm Nam-1', '情感男声-1'],
            ['Diễn cảm Nam-3', '情感男声-3'],
            ['Diễn cảm Nam-6', '情感男声-6'],
            ['Diễn cảm Nam-8', '情感男声-8'],
            ['Diễn cảm Nữ-2', '情感女声-2'],
            ['Diễn cảm Nữ-4', '情感女声-4'],
            ['Diễn cảm Nữ-5', '情感女声-5'],
            ['Diễn cảm Nữ-7', '情感女声-7'],
            ['Độ cao giọng', '音调'],
            ['Đô thị', '都市'],
            ['ĐỌC', '阅读次数'],
            ['Đọc chương kế', '阅读下一章'],
            ['Đọc manhua Qidian', '看漫画 起点'],
            ['Đọc manhwa Manhwasco', '看韩漫 Manhwasco'],
            ['Đọc ngay', '立即阅读'],
            ['Đọc truyện BaoziManhua', '看漫画 BaoziManhua'],
            ['Đọc truyện Colamanga', '看漫画 Colamanga'],
            ['Đọc truyện Kuaikanmanhua', '看漫画 快看漫画'],
            ['Đọc truyện ManhuaSFACG', '看漫画 SFACG'],
            ['Đọc truyện tranh RawKuma', '看漫画 RawKuma'],
            ['Đọc truyện YemanComic', '看漫画 YemanComic'],
            ['Đổi mật khẩu', '修改密码'],
            ['Đổi mật khẩu thành công', '密码修改成功'],
            ['Đóng', '关闭'],
            ['đồng nhân', '同人'],
            ['Đồng nhân', '同人'],
            ['Động tác', '动作'],
            ['Dữ liệu cá nhân', '个人数据'],
            ['Dùng luật nhân thử nghiệm', '使用实验性译名规则'],
            ['Dùng tóm tắt', '使用简介'],
            ['Font chữ 1(Lời thoại)', '字体1（对话）'],
            ['Font chữ 2(Hét)', '字体2（喊叫）'],
            ['Font chữ 3(Tường thuật)', '字体3（叙述）'],
            ['Font chữ mặc định', '默认字体'],
            ['Giá trị', '值'],
            ['Giải trí', '娱乐'],
            ['Giám đốc', '经理'],
            ['Giảm viền 2 bên', '减少左右边框'],
            ['Giọng {0} ({1})', '语音 {0}（{1}）'],
            ['Giọng đọc', '语音朗读声音'],
            ['Giọng đọc.', '语音朗读声音。'],
            ['Giọng Nam 1', '男声 1'],
            ['Gốc', '原文'],
            ['Gợi', '提示'],
            ['Gói công cộng', '公共译名包'],
            ['Gói của tôi', '我的译名包'],
            ['Gói name', '译名包'],
            ['Gói name đặc biệt', '特殊译名包'],
            ['Gói name theo truyện', '按小说译名包'],
            ['Gửi', '发送'],
            ['Hài hước', '幽默'],
            ['Hán', '汉'],
            ['Hán Việt', '汉越'],
            ['Hành động', '动作'],
            ['Hậu cung', '后宫'],
            ['Hệ thống', '系统'],
            ['Hệ thống đang bận, hãy thử lại sau', '系统繁忙，请稍后重试'],
            ['Hiển thị', '显示'],
            ['Hiệu chỉnh âm thanh', '播放均衡器'],
            ['HN - Mai Phương', 'HN - Mai Phương'],
            ['HN - Mạnh Dũng', 'HN - Mạnh Dũng'],
            ['HN - Ngọc Huyền', 'HN - Ngọc Huyền'],
            ['HN - Phú Thăng', 'HN - Phú Thăng'],
            ['Hoa:', '大写：'],
            ['Hoài My', 'Hoài My'],
            ['Hoàn thành', '已完结'],
            ['Huế - Duy Phương', 'Huế - Duy Phương'],
            ['Huế - Hương Giang', 'Huế - Hương Giang'],
            ['Hút máu', '吸血鬼'],
            ['Hủy', '取消'],
            ['Huyền huyễn', '玄幻'],
            ['Huyền nghi', '悬疑'],
            ['Huyễn tưởng', '奇幻'],
            ['Kênh linh tinh', '杂谈频道'],
            ['Kênh thế lực', '势力频道'],
            ['Kênh truyện', '小说频道'],
            ['Kéo xuống để làm mới', '下拉刷新'],
            ['Kết', '结果'],
            ['Kết nối tới máy chủ thất bại, hãy thử kiểm tra kết nối mạng.', '连接服务器失败，请检查网络连接。'],
            ['Khác', '其他'],
            ['KHAI SINH', '创建日期'],
            ['Khắp đổi', '惊悚'],
            ['Khoa học viễn tưởng', '科幻'],
            ['Khoa huyễn', '科幻'],
            ['Khởi động lại ứng dụng để tự động cập nhật', '重启应用以自动更新'],
            ['Khôi hài', '搞笑'],
            ['Khởi tạo audio thất bại, hãy thử lại', '音频初始化失败，请重试'],
            ['Không', '不限'],
            ['Không chọn từ', '不选词'],
            ['Không có bài viết nào', '暂无文章'],
            ['Không có dữ liệu...', '暂无数据...'],
            ['Không có kết nối mạng, tải danh sách nguồn thất bại.', '无网络连接，加载书源列表失败。'],
            ['Không phù hợp', '不适用'],
            ['Không rõ', '未知'],
            ['Không tạm ngưng', '未暂停'],
            ['Không thể đăng ảnh', '无法上传图片'],
            ['Không thể đọc dữ liệu', '无法读取数据'],
            ['Không thể tải danh sách chương!', '无法加载章节列表！'],
            ['Không thể tải dữ liệu', '无法加载数据'],
            ['Không thể tạo file mp3', '无法生成 mp3 文件'],
            ['Không tìm thấy dữ liệu', '未找到数据'],
            ['Không tìm thấy gói name nào.', '未找到译名包。'],
            ['Không tìm thấy nội dung để đọc, có thể do phát sinh lỗi', '未找到可朗读的内容，可能发生了错误'],
            ['Không tìm thấy provider', '未找到 provider'],
            ['Không tìm thấy trang web hỗ trợ', '未找到支持的网站'],
            ['Không tìm thấy truyện nào', '未找到小说'],
            ['Không tìm thấy truyện nào...', '未找到小说...'],
            ['Không viền dưới', '无下边框'],
            ['Không viền trên', '无上边框'],
            ['Kịch bản', '剧本'],
            ['Kích thước', '大小'],
            ['Kích thước font chữ', '字体大小'],
            ['Kích thước font tối thiểu', '最小字体大小'],
            ['Kích thước tối đa', '最大尺寸'],
            ['Kiểu chọn từ', '选词方式'],
            ['Kinh dị', '恐怖'],
            ['Kinh khủng', '惊悚'],
            ['Kỳ huyễn', '奇幻'],
            ['La lỵ', '萝莉'],
            ['Làm mới thành công', '刷新成功'],
            ['Làm mới thất bại', '刷新失败'],
            ['Lấp hố', '填坑'],
            ['Lịch sử', '历史'],
            ['Linh dị', '灵异'],
            ['Linh thạch', '灵石'],
            ['Loại', '类型'],
            ['Lọc', '筛选'],
            ['Lọc địa danh', '过滤地名'],
            ['Lọc tên kỹ năng', '过滤技能名'],
            ['Lọc tên người', '过滤人名'],
            ['Lọc tên tiếng Anh', '过滤英文名'],
            ['Lọc theo []', '按[]过滤'],
            ['Lọc theo hậu tố', '按后缀过滤'],
            ['Lọc truyện', '筛选小说'],
            ['Lỗi khi tải truyện...', '加载小说失败...'],
            ['Lỗi không xác định', '未知错误'],
            ['Lỗi tải dữ liệu', '加载错误'],
            ['Lỗi: Không thể đọc dữ liệu', '错误：无法读取数据'],
            ['Lỗi: Lỗi mạng', '错误：网络错误'],
            ['Lớn nữ chính', '大女主'],
            ['Luật nhân cao cấp', '高级译名规则'],
            ['Lượt đánh dấu', '书签数'],
            ['Lượt theo dõi', '关注数'],
            ['Lượt thích', '点赞数'],
            ['Lượt xem ngày', '日点击'],
            ['Lượt xem tổng', '总点击'],
            ['Lượt xem tuần', '周点击'],
            ['Lưu', '保存'],
            ['Lưu sau khi lọc', '过滤后保存'],
            ['Lưu trữ', '存档'],
            ['Luyến ái', '恋爱'],
            ['Ma huyễn', '魔幻'],
            ['Mã xác thực không hợp lệ', '验证码无效'],
            ['Manh hệ', '萌系'],
            ['Mạnh kịch bản', '强剧情'],
            ['Mạo hiểm', '冒险'],
            ['Mạo hiểm nhiệt huyết', '冒险热血'],
            ['Mật khẩu cũ:', '旧密码：'],
            ['Mật khẩu mới không khớp', '新密码不一致'],
            ['Mật khẩu mới:', '新密码：'],
            ['Màu chữ', '文字颜色'],
            ['Màu nền', '背景颜色'],
            ['Menu ngữ cảnh', '上下文菜单'],
            ['Mới cập nhật', '最新更新'],
            ['Mới nhập kho', '新入库'],
            ['Mới nhất', '最新'],
            ['Mục lục', '目录'],
            ['Mỹ thực', '美食'],
            ['Nam miền Bắc', '北方男声'],
            ['Nam miền Nam', '南方男声'],
            ['Nam miền Trung', '中部男声'],
            ['Name', '译名'],
            ['Name chung', '通用译名'],
            ['Name riêng', '专属译名'],
            ['Name V0(Regex)', '译名 V0（正则）'],
            ['Name V1(Gốc tiếng việt)', '译名 V1（越南语原文）'],
            ['Name V2(Gốc tiếng trung)', '译名 V2（中文原文）'],
            ['Nghịch tập', '逆袭'],
            ['Ngôn tình', '言情'],
            ['Ngự tỷ', '御姐'],
            ['Ngừng giữa các câu (-1s - 1s)', '句间暂停（-1s - 1s）'],
            ['Ngừng tải', '停止下载'],
            ['Nguồn cấp', '语音引擎'],
            ['Nguồn truyện', '小说源'],
            ['Ngụy nương', '伪娘'],
            ['Nhãn dán', '标签'],
            ['Nhấn giữ', '长按'],
            ['Nhấp', '点击'],
            ['Nhấp 2 lần', '双击'],
            ['Nhập bình luận', '输入评论'],
            ['Nhập lại mật khẩu mới:', '再次输入新密码：'],
            ['Nhập mã xác thực', '输入验证码'],
            ['Nhập số chương để tải:', '输入要下载的章节数：'],
            ['Nhập thời gian tối đa đọc (phút)', '输入最长朗读时间（分钟）'],
            ['Nhiệt huyết', '热血'],
            ['Nội dung đánh giá', '评论内容'],
            ['Nữ chính', '女主角'],
            ['Nữ miền Bắc', '北方女声'],
            ['Nữ miền Bắc chất lượng cao', '北方女声（高品质）'],
            ['Nữ miền Nam', '南方女声'],
            ['Nữ miền Nam chất lượng cao', '南方女声（高品质）'],
            ['Nữ miền Trung', '中部女声'],
            ['Nữ miền Trung chất lượng cao', '中部女声（高品质）'],
            ['Nút copy', '复制按钮'],
            ['Nút thêm tên', '添加名称按钮'],
            ['Nút tìm kiếm', '搜索按钮'],
            ['Ok', '确定'],
            ['Ôn hòa', '温和'],
            ['Phân trang', '分页'],
            ['Phép thuật', '魔法'],
            ['Phi nhân loại', '非人类'],
            ['Português', '葡萄牙语'],
            ['Quả', '果'],
            ['Quỷ thần', '鬼神'],
            ['Redraw nền', '重绘背景'],
            ['Sân trường', '校园'],
            ['Sáng Tác Việt', 'Sáng Tác Việt'],
            ['Sáng Tác Việt - Nền tảng văn học mạng mở mới', 'Sáng Tác Việt - 开放网络文学平台'],
            ['Sao chép', '复制'],
            ['Sắp xếp', '排序'],
            ['SG - Minh Hoàng', 'SG - Minh Hoàng'],
            ['SG - Thảo Trinh', 'SG - Thảo Trinh'],
            ['SG - Trung Kiên', 'SG - Trung Kiên'],
            ['SG - Tường Vy', 'SG - Tường Vy'],
            ['Siêu nhiên', '超自然'],
            ['Sinh hoạt', '日常'],
            ['Số chương', '章节数'],
            ['Số chương tối thiểu', '最少章节数'],
            ['Sửa', '修改'],
            ['Sửa chữa', '修改'],
            ['Sửa tên hiển thị', '修改昵称'],
            ['Sửa tiểu sử', '修改签名'],
            ['Sủng vật', '宠物'],
            ['Suy luận', '推理'],
            ['Tải bình luận thất bại', '评论加载失败'],
            ['Tải dữ liệu thất bại...', '数据加载失败...'],
            ['Tải gói name', '下载译名包'],
            ['Tải lại', '重新加载'],
            ['Tải lại nội dung', '重新加载内容'],
            ['Tải lên', '上传'],
            ['Tải name theo truyện', '按小说下载译名'],
            ['Tải xuống', '下载'],
            ['Tạm ngưng', '已暂停'],
            ['Tần số', '频率'],
            ['Tận thế', '末世'],
            ['Tắt', '关闭'],
            ['Tất cả', '全部'],
            ['Tên', '名称'],
            ['Tên chương', '章节名称'],
            ['Tên chương dưới', '底部章节名'],
            ['Tên chương trên', '顶部章节名'],
            ['Tên kỹ năng viết hoa', '技能名大写'],
            ['Tên quá ngắn', '名称太短'],
            ['Thả để làm mới', '松开刷新'],
            ['Thám tử', '侦探'],
            ['Thần Ma', '神魔'],
            ['Thanh xuân', '青春'],
            ['Thao tác', '操作'],
            ['Thể loại', '分类'],
            ['Thế lực', '势力'],
            ['Thêm mới', '新增'],
            ['Thêm name', '添加译名'],
            ['Thêm name 1 nhấp', '一键添加译名'],
            ['Thêm vào bộ sưu tập', '加入收藏'],
            ['Thêm viền 2 bên', '添加左右边框'],
            ['Thêm viền dưới', '添加下边框'],
            ['Thêm viền trên', '添加上边框'],
            ['Theo dõi', '关注'],
            ['Thi đấu', '竞技'],
            ['Thiết bị của bạn không hỗ trợ tính năng này', '你的设备不支持此功能'],
            ['Thiết bị không phù hợp hoặc phiên bản ứng dụng đã lỗi thời', '设备不兼容或应用版本过旧'],
            ['Thiếu nam', '少年'],
            ['Thiếu niên', '少年'],
            ['Thiếu nữ', '少女'],
            ['Thơ dài', '文艺'],
            ['Thời gian không hợp lệ', '时间无效'],
            ['Thông báo', '通知'],
            ['Thông tin truyện', '小说信息'],
            ['Thử lại', '重试'],
            ['Thử nhúng truyện', '尝试嵌入小说'],
            ['Thuần ái', '纯爱'],
            ['Thường ngày', '日常'],
            ['Tiếng Việt', '越南语'],
            ['Tiết tháo', '节操'],
            ['Tiêu đề', '标题'],
            ['Tiêu đề sách', '书名'],
            ['Tìm kiếm', '搜索'],
            ['Tìm kiếm bằng ngôn ngữ của trang', '用网页的语言搜索'],
            ['Tìm trong tóm tắt', '在简介中搜索'],
            ['Tình ái', '爱情'],
            ['Tình cảm', '情感'],
            ['Tính chuyển', '性转'],
            ['Tính năng khác', '其他功能'],
            ['Tình yêu', '爱情'],
            ['Toàn bộ', '全部'],
            ['Toàn trang', '整页'],
            ['Tốc độ đọc', '语速'],
            ['Tốc độ đọc (-3 đến +3)', '语速（-3 到 +3）'],
            ['Tốc độ đọc (0.5 - 5)', '语速（0.5 - 5）'],
            ['Tốc độ đọc (0.7 - 1.3)', '语速（0.7 - 1.3）'],
            ['Tốc độ đọc (0.8 - 1.2)', '语速（0.8 - 1.2）'],
            ['Tốc độ đọc.', '语速。'],
            ['Tốc độ phát lại', '播放速度'],
            ['Token_id của viettelgroup.ai', 'viettelgroup.ai 的 Token_id'],
            ['Tổng giám đốc', '总裁'],
            ['Tổng mạn', '综漫'],
            ['Trang', '个人页'],
            ['Trạng thái', '状态'],
            ['Trang trước', '上一页'],
            ['Trang web', '网站'],
            ['Tri Âm Mạn Khách', '知音漫客'],
            ['Trinh thám', '侦探'],
            ['Trò chơi', '游戏'],
            ['Trùng sinh', '重生'],
            ['Trường học', '校园'],
            ['Truyện đã tải', '已下载小说'],
            ['Truyện không tồn tại hoặc đã bị xóa', '小说不存在或已被删除'],
            ['Truyền ngôn', '世界评论'],
            ['Truyện thầu', '承包小说'],
            ['Truyện tranh', '漫画'],
            ['Tu chân', '修真'],
            ['Tự đảo giới từ', '自动倒装介词'],
            ['Tự động', '自动'],
            ['Tự động đọc', '自动阅读'],
            ['Tự nối từ', '自动连词'],
            ['Tu tiên', '修仙'],
            ['Túi đồ', '储物袋'],
            ['Tương tác', '交互'],
            ['Tùy chọn', '选项'],
            ['URL không hợp lệ', 'URL 无效'],
            ['Văn bản gốc', '原文'],
            ['Vận động', '运动'],
            ['Vị trí', '位置'],
            ['Việt', '越'],
            ['Viết bình luận...', '写评论...'],
            ['Viết nội dung', '输入内容'],
            ['Viết preview', '撰写评论'],
            ['Viết truyền ngôn', '发布世界评论'],
            ['Võ hiệp', '武侠'],
            ['Võ kỹ', '武技'],
            ['Võ thuật', '武术'],
            ['Võng du', '网游'],
            ['Vui lòng đăng nhập để sử dụng tính năng này', '请登录后使用此功能'],
            ['Vui lòng nhập nội dung', '请输入内容'],
            ['Vuốt chọn từ', '滑动选词'],
            ['Xã hội', '社会'],
            ['Xác nhận', '确认'],
            ['Xin chào, đây là chuyển văn bản thành giọng nói', '你好，这是文字转语音测试'],
            ['Xin vào', '申请加入'],
            ['Xin vào thế lực này? Nếu đã có xin thế lực khác, lần xin cũ sẽ bị hủy?', '申请加入此势力？如果已申请其他势力，之前的申请将被取消？'],
            ['Xóa font này?', '删除此字体？'],
            ['Xóa tất cả name theo truyện', '删除所有按小说的译名'],
            ['Xử lý', '处理'],
            ['Xuyên không', '穿越'],
            ['Xuyên qua', '穿越'],
            ['Xuyên việt', '穿越'],
            ['Yêu nhau', '恋爱'],
            ['Engine TTS', '朗读引擎'],
            ['Cập nhật audio', '音频播放'],
            ['Nhập thời gian tối đa để đọc (phút)', '朗读最长时间（分钟）'],
            ['Viettelgroup TextToSpeech', 'Viettel 语音'],
            ['Đã tải', '已下载'],
            ['Bạn chưa tải truyện nào.', '你还没有下载任何小说。']
        ];

        // Concatenated messages ("Đã dừng đọc sau " + n + " phút"), matched as
        // substrings, longest first. Only fragments of 5+ characters are listed, so
        // a short common word can never be rewritten in the middle of user data.
        var FRAGMENTS = [
            ['Đăng nhập thất bại, vui lòng thử lại sau, nguyên nhân: ', '登录失败，请稍后重试，原因：'],
            ['Đăng ký thất bại, vui lòng thử lại sau, nguyên nhân: ', '注册失败，请稍后重试，原因：'],
            ['Không thể tải ngôn ngữ ', '无法加载语言 '],
            ['Kích thước tối đa ', '最大尺寸 '],
            [' Chính năng lượng ', ' 正能量 '],
            ['Các bài viết của ', '的文章 '],
            ['Đã dừng đọc sau ', '已停止朗读，时长 '],
            ['Thiếu giá trị: ', '缺少参数：'],
            [' Phi nhân loại ', ' 非人类 '],
            [' Tổng giám đốc ', ' 总裁 '],
            [' Mạnh kịch bản ', ' 强剧情 '],
            ['Các truyện do ', '由 '],
            [' Lớn nữ chính ', ' 大女主 '],
            [' Huyền huyễn ', ' 玄幻 '],
            [' Nhiệt huyết ', ' 热血 '],
            [' Thanh xuân ', ' 青春 '],
            [' Huyền nghi ', ' 悬疑 '],
            [' Trùng sinh ', ' 重生 '],
            [', máy chủ: ', '，服务器：'],
            [' Xuyên qua ', ' 穿越 '],
            [' Cổ phong ', ' 古风 '],
            [' Kỳ huyễn ', ' 奇幻 '],
            [' Hệ thống ', ' 系统 '],
            [' Khôi hài ', ' 搞笑 '],
            [' Mạo hiểm ', ' 冒险 '],
            ['Nữ chính ', '女主角 '],
            [' Toàn bộ ', ' 全部 '],
            [' Tận thế ', ' 末世 '],
            [' Manh hệ ', ' 萌系 '],
            [' Dị năng ', ' 异能 '],
            [' Võ hiệp ', ' 武侠 '],
            [' Thi đấu ', ' 竞技 '],
            ['Lịch sử ', '历史 '],
            [' Đô thị ', ' 都市 '],
            [' phút', ' 分钟']
        ];

        // [viPrefix, viSuffix, zhPrefix, zhSuffix] for messages whose middle part is
        // a value we must keep.
        var PATTERNS = [
            ['Các truyện do ', ' làm', '由 ', ' 承包的小说']
        ];

        var MAP = {};
        for (var i = 0; i < EXACT.length; i++) { MAP[EXACT[i][0]] = EXACT[i][1]; }

        // Containers holding user data: chapter body, comments, book blurbs, titles,
        // the name editor. Never rewrite text inside these.
        var SKIP = {};
        var SKIP_NAMES = ['pageflipper', 'chapterdpageflip', 'chapterdcontinuos', 'chapterdisplay',
            'chapterview', 'chapterscroller', 'chaptercontent', 'chapterd', 'info', 'comment',
            'post', 'previewcontent', 'name', 'cname', 'chaptername', 'chapter-name',
            'contentcontainer', 'searchinput'];
        for (var s = 0; s < SKIP_NAMES.length; s++) { SKIP[SKIP_NAMES[s]] = true; }

        function hasSkipClass(element) {
            var classes = element.className;
            if (typeof classes !== 'string' || !classes) { return false; }
            var parts = classes.split(' ');
            for (var i = 0; i < parts.length; i++) { if (SKIP[parts[i]]) { return true; } }
            return false;
        }

        function translate(value) {
            if (!value) { return null; }
            var trimmed = value.trim();
            if (!trimmed) { return null; }
            var direct = MAP[trimmed];
            if (direct !== undefined) {
                return value.replace(trimmed, function () { return direct; });
            }
            for (var i = 0; i < PATTERNS.length; i++) {
                var prefix = PATTERNS[i][0];
                var suffix = PATTERNS[i][1];
                if (prefix.length + suffix.length >= trimmed.length) { continue; }
                if (trimmed.indexOf(prefix) !== 0) { continue; }
                if (trimmed.slice(trimmed.length - suffix.length) !== suffix) { continue; }
                var middle = trimmed.slice(prefix.length, trimmed.length - suffix.length);
                var replacement = PATTERNS[i][2] + middle + PATTERNS[i][3];
                return value.replace(trimmed, function () { return replacement; });
            }
            return null;
        }

        function translateFragments(value) {
            for (var i = 0; i < FRAGMENTS.length; i++) {
                var vi = FRAGMENTS[i][0];
                if (value.indexOf(vi) >= 0) {
                    value = value.split(vi).join(FRAGMENTS[i][1]);
                }
            }
            return value;
        }

        var rewritten = 0;

        // The reader header prints the site's own Vietnamese machine translation of
        // the chapter name. The server never exposes the original Chinese title:
        // sajax=readchapter returns only bookname and chaptername,
        // mobile/bookinfo.php carries no chapter list, and transmode=original
        // switches the BODY to Chinese while leaving the title Vietnamese. So the
        // words cannot be recovered here. What we can fix is the scaffolding.
        //
        // Two number formats show up in the wild:
        //     "Chương 3:. Giao phong"   (qidian)
        //     "Thứ 2 chương Ngọc Long"  (fanqie)
        // both become "第<n>章 <title>".
        //
        // Deliberately no regular expression: the whole block has to survive being
        // embedded in a Swift multiline string, which forbids backslashes.
        function skipSpaces(text, index) {
            while (index < text.length && text.charCodeAt(index) <= 32) { index++; }
            return index;
        }

        function digitsAfter(text, index) {
            var digits = '';
            while (index < text.length) {
                var code = text.charCodeAt(index);
                if (code < 48 || code > 57) { break; }
                digits += text.charAt(index);
                index++;
            }
            return digits;
        }

        function stripSeparators(text) {
            while (text.length) {
                var first = text.charAt(0);
                if (first === ':' || first === '.' || first === '-' || text.charCodeAt(0) <= 32) {
                    text = text.substring(1);
                } else {
                    break;
                }
            }
            return text;
        }

        var TITLE_HEADS = [['Chương', ''], ['Thứ', 'chương']];

        function fixChapterTitle(raw) {
            if (!raw) { return raw; }
            var text = raw;
            var start = skipSpaces(text, 0);
            for (var h = 0; h < TITLE_HEADS.length; h++) {
                var head = TITLE_HEADS[h][0];
                if (text.substring(start, start + head.length) !== head) { continue; }
                var index = skipSpaces(text, start + head.length);
                var digits = digitsAfter(text, index);
                if (!digits) { continue; }
                index += digits.length;
                // qidian zero-pads ("Chương 03:. Giao phong"); 第03章 reads wrong.
                while (digits.length > 1 && digits.charAt(0) === '0') {
                    digits = digits.substring(1);
                }
                var between = TITLE_HEADS[h][1];
                if (between) {
                    index = skipSpaces(text, index);
                    if (text.substring(index, index + between.length) !== between) { continue; }
                    index += between.length;
                }
                var tail = stripSeparators(text.substring(index));
                var out = '第' + digits + '章';
                if (tail.length) { out += ' ' + tail; }
                return out;
            }
            return raw;
        }

        // Chapter names sit in SKIP, so walk() never descends into them. That is
        // deliberate: chapter titles are per-book data and must not be run through
        // the fragment table. This pass is the only thing allowed to touch them.
        //
        // Two different elements carry the title and both must be covered:
        //   .chaptername      -- the reader's bottom bar (page-readchapter)
        //   .chapternamefixed -- the static name pinned to the top of the page
        //                        (PageFlipChapterDisplay.updateFixedChapterName)
        // Missing .chapternamefixed is why the top of the reader kept printing
        // "Chương 03:. Giao phong" after the first fix.
        var TITLE_SELECTOR = '.chaptername, .chapternamefixed';

        function applyChapterTitle(node) {
            var text = node.textContent || '';
            var fixed = fixChapterTitle(text);
            if (fixed !== text) { node.textContent = fixed; rewritten++; }
        }

        function fixChapterTitles(root) {
            if (!root || root.nodeType !== 1) { return; }
            if (root.classList && (root.classList.contains('chaptername')
                || root.classList.contains('chapternamefixed'))) { applyChapterTitle(root); }
            if (!root.querySelectorAll) { return; }
            var nodes = root.querySelectorAll(TITLE_SELECTOR);
            for (var i = 0; i < nodes.length; i++) { applyChapterTitle(nodes[i]); }
        }

        function walk(node) {
            if (!node) { return; }
            if (node.nodeType === 3) {
                var current = node.nodeValue || '';
                var next = translate(current);
                if (next !== null) {
                    if (next !== current) { node.nodeValue = next; rewritten++; }
                    return;
                }
                if (current.length >= 5) {
                    var fragments = translateFragments(current);
                    if (fragments !== current) { node.nodeValue = fragments; rewritten++; }
                }
                return;
            }
            if (node.nodeType !== 1) { return; }
            if (hasSkipClass(node)) { return; }
            if (node.getAttribute && node.getAttribute('data-stvdiag')) { return; }
            if (node.getAttribute) {
                var placeholder = node.getAttribute('placeholder');
                if (placeholder) {
                    var translatedPlaceholder = translate(placeholder);
                    if (translatedPlaceholder !== null) { node.setAttribute('placeholder', translatedPlaceholder); }
                }
                var title = node.getAttribute('title');
                if (title) {
                    var translatedTitle = translate(title);
                    if (translatedTitle !== null) { node.setAttribute('title', translatedTitle); }
                }
            }
            var tag = node.tagName ? node.tagName.toLowerCase() : '';
            if (tag === 'script' || tag === 'style' || tag === 'textarea' || tag === 'input') { return; }
            var children = node.childNodes || [];
            for (var i = 0; i < children.length; i++) { walk(children[i]); }
        }

        function sweep() {
            try {
                walk(document.body || document.documentElement);
                fixChapterTitles(document.documentElement);
            } catch (e) {
                if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n sweep failed: ' + e); }
            }
        }

        // The chapter text -- and therefore the pinned chapter name -- lives in a
        // same-origin srcdoc iframe, not in this document, so the main sweep can
        // never reach it. Only the title pass runs inside frames: walking the whole
        // frame would put the fragment table on top of novel text, and that table is
        // only meant for the site's own UI strings.
        function frameDocument(frame) {
            var doc = null;
            try { doc = frame.contentDocument; } catch (e) { doc = null; }
            return doc || null;
        }

        function sweepFrame(frame) {
            var doc = frameDocument(frame);
            if (!doc || !doc.documentElement) { return; }
            try {
                fixChapterTitles(doc.documentElement);
            } catch (e) {
                if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n frame sweep failed: ' + e); }
            }
        }

        function frameRecords(records) {
            for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.target && record.target.nodeType === 1) {
                    fixChapterTitles(record.target);
                }
            }
        }

        function attachFrame(frame) {
            var doc = frameDocument(frame);
            if (!doc) { return; }
            // The flag lives on the document, not the window: assigning srcdoc
            // navigates the iframe and swaps the document out, so a window-scoped
            // flag would leave the observer attached to a dead document and the
            // pinned name would stop being translated after the first chapter change.
            if (!doc.__stvI18nFrame) {
                doc.__stvI18nFrame = true;
                var win = null;
                try { win = frame.contentWindow; } catch (e) { win = null; }
                if (win) {
                    try {
                        win.addEventListener('load', function () { sweepFrame(frame); });
                    } catch (e) {}
                }
                if (window.MutationObserver) {
                    try {
                        new window.MutationObserver(frameRecords).observe(doc, {
                            childList: true, subtree: true, characterData: true
                        });
                    } catch (e) {}
                }
            }
            sweepFrame(frame);
        }

        function attachFrames() {
            var list = document.querySelectorAll('iframe');
            for (var i = 0; i < list.length; i++) { attachFrame(list[i]); }
        }

        // Translating the title element in place is not enough on its own: the site
        // compares what it wrote last time with the chapter's own name and, when the
        // two differ, re-runs a whole recycle pass --
        //
        //     updateFixedChapterName(c)  (chapterdisplay.js:3579)
        //         var oldName = fixed.textContent;
        //         if (oldName != name) { fixed.textContent = name; this.recycle(c);
        //                                app.reader.updateHistory2(); }
        //
        // so a translated DOM value makes that branch fire on every scroll tick.
        // The name itself comes from one place -- cdata.chaptername, produced by
        // app.reader.getContent() -- and every consumer (createPage, resetPageHtml,
        // getPrependChapterNameHTML, updateFixedChapterName, the bottom bar) reads
        // it from there. Translating at that single source keeps the comparison
        // equal, so the title is Chinese everywhere and the recycle branch stays
        // quiet. The DOM pass above remains as a fallback for anything rendered
        // before this wrapper is installed.
        var CONTENT_FIELDS = ['chaptername'];

        function fixChapterData(cdata) {
            if (!cdata || typeof cdata !== 'object') { return cdata; }
            for (var i = 0; i < CONTENT_FIELDS.length; i++) {
                var field = CONTENT_FIELDS[i];
                var raw = cdata[field];
                if (typeof raw !== 'string' || !raw) { continue; }
                var fixed = fixChapterTitle(raw);
                if (fixed !== raw) {
                    cdata[field] = fixed;
                    rewritten++;
                }
            }
            return cdata;
        }

        // The chapter NAME the reader receives is the site's Vietnamese machine
        // translation, and readchapter carries no original: the chaptername field stays
        // Vietnamese even when the body comes back in Chinese (transmode=chinese).
        // The chapter LIST does have it -- getChapterListOnline (app.v2.js:270)
        // prefers x.oridata, the original, whenever app.language is not Vietnamese
        // -- so the Chinese title is one chapterlist request away, keyed by the same
        // cid the reader already knows.
        var titleMaps = {};
        var titleTried = {};

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function trimText(value) {
            var s = String(value == null ? '' : value);
            while (s.length && s.charCodeAt(0) <= 32) { s = s.substring(1); }
            while (s.length && s.charCodeAt(s.length - 1) <= 32) {
                s = s.substring(0, s.length - 1);
            }
            return s;
        }

        function cjkCount(text) {
            var n = 0;
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code >= 0x3400 && code <= 0x9FFF) { n++; }
            }
            return n;
        }

        function parseChapterList(text) {
            var out = {};
            var list = String(text).split('-//-');
            for (var i = 0; i < list.length; i++) {
                var parts = list[i].split('-/-');
                if (parts.length < 3) { continue; }
                var cid = trimText(parts[1]);
                var title = trimText(parts[2]);
                if (cid && title) { out[cid] = title; }
            }
            return out;
        }

        function firstChinese(map) {
            for (var cid in map) {
                if (cjkCount(map[cid])) { return map[cid].substring(0, 20); }
            }
            return '';
        }

        // "Chương 03:. Giao phong" + original "交锋" -> "第3章 交锋". When the
        // original already carries its own numbering the Vietnamese scaffolding is
        // dropped instead of duplicated.
        function chineseChapterName(vietnamese, original) {
            var text = trimText(original);
            if (!text) { return null; }
            if (text.indexOf('章') >= 0) { return text; }
            var numbered = fixChapterTitle(vietnamese || '');
            var head = '';
            if (numbered.indexOf('第') === 0) {
                var index = numbered.indexOf('章');
                if (index > 0) { head = numbered.substring(0, index + 1); }
            }
            return head ? head + ' ' + text : text;
        }

        function currentCid() {
            try { return String(window.app.reader.getPCN().current.cid); } catch (e) { return ''; }
        }

        // Called once the list arrives: the chapter is already on screen with its
        // Vietnamese name, so rewrite the rendered title and the chapter's own
        // cdata. Keeping cdata in step is what stops updateFixedChapterName()'s
        // oldName != name guard from firing a recycle pass on every scroll.
        function applyTitles(host, id) {
            var map = titleMaps[host + '/' + id];
            if (!map) { return; }
            var app = window.app;
            var cid = currentCid();
            if (!cid || !map[cid]) { return; }
            var display = null;
            try { display = app.reader.getDisplay(); } catch (e) { display = null; }
            var view = null;
            try { view = display.getCurrentChapter(); } catch (e) { view = null; }
            var vietnamese = (view && view.cdata && view.cdata.chaptername) || '';
            var name = chineseChapterName(vietnamese, map[cid]);
            if (!name) { return; }
            if (view && view.cdata) { view.cdata.chaptername = name; }
            // Scoped to the reader page: .chaptername is the bottom bar there, and
            // an unscoped query could catch an unrelated element.
            var nodes = document.querySelectorAll('#chapterview .chaptername');
            for (var i = 0; i < nodes.length; i++) { nodes[i].textContent = name; }
            try {
                var list = display.innerWindow.q('.chapternamefixed');
                for (var j = 0; j < list.length; j++) { list[j].textContent = name; }
            } catch (e) {}
            note('TITLE', 'chapter ' + cid + ' -> ' + name);
        }

        // Returns the map when it is already loaded, null otherwise. The lookup is
        // deliberately not awaited: the first chapter of a book must not wait for a
        // 100 KB chapterlist response, so the title is corrected a moment later.
        function chapterTitleMap(host, id) {
            var key = host + '/' + id;
            if (titleMaps[key]) { return titleMaps[key]; }
            if (titleTried[key]) { return null; }
            var app = window.app;
            if (!app || !app.net || typeof app.net.get !== 'function') { return null; }
            titleTried[key] = true;
            var url = '/index.php?ngmar=chapterlist&h=' + host + '&bookid=' + id
                + '&sajax=getchapterlist';
            app.net.get(url).then(function (down) {
                var map = null;
                if (down && typeof down.oridata === 'string' && down.oridata) {
                    map = parseChapterList(down.oridata);
                }
                var usable = 0;
                for (var cid in map) { if (cjkCount(map[cid])) { usable++; } }
                if (!usable) {
                    note('TITLE', 'no original chapter names for ' + key + ' (oridata '
                        + (down && down.oridata ? 'present but not Chinese' : 'absent') + ')');
                    return;
                }
                titleMaps[key] = map;
                note('TITLE', 'original chapter names for ' + key + ': ' + usable + ' of '
                    + Object.keys(map).length + ', sample=' + firstChinese(map));
                applyTitles(host, id);
            }, function (error) {
                note('ERR', 'chapter name lookup failed for ' + key + ': ' + error);
            });
            return null;
        }

        function attachContent() {
            var app = window.app;
            if (!app || !app.reader || typeof app.reader.getContent !== 'function') { return false; }
            if (app.reader.__stvTitleSourceWrapped) { return true; }
            app.reader.__stvTitleSourceWrapped = true;
            var original = app.reader.getContent;
            app.reader.getContent = function (host, id, cid, reload) {
                var args = arguments;
                var result = original.apply(this, args);
                if (!result || typeof result.then !== 'function') {
                    return fixChapterData(result, host, id, cid);
                }
                return result.then(function (cdata) {
                    var fixed = fixChapterData(cdata, host, id, cid);
                    var map = chapterTitleMap(host, id);
                    if (map && cid && map[String(cid)]) {
                        var name = chineseChapterName(fixed && fixed.chaptername, map[String(cid)]);
                        if (name && fixed) { fixed.chaptername = name; rewritten++; }
                    }
                    return fixed;
                });
            };
            return true;
        }

        window.__stvI18n = {
            translate: translate,
            sweep: sweep,
            sweepFrames: attachFrames,
            fixChapterTitle: fixChapterTitle,
            size: EXACT.length,
            rewritten: function () { return rewritten; }
        };

        if (window.MutationObserver) {
            var observer = new MutationObserver(function (records) {
                for (var i = 0; i < records.length; i++) {
                    var record = records[i];
                    if (record.type === 'characterData') {
                        walk(record.target);
                    } else {
                        var added = record.addedNodes || [];
                        for (var j = 0; j < added.length; j++) {
                            var node = added[j];
                            walk(node);
                            if (node.nodeType === 1 && node.tagName === 'IFRAME') { attachFrame(node); }
                        }
                    }
                    // The reader rewrites .chaptername.textContent on every chapter
                    // change, which arrives as a childList mutation ON that node.
                    if (record.target && record.target.nodeType === 1) {
                        fixChapterTitles(record.target);
                    }
                }
            });
            observer.observe(document, { childList: true, subtree: true, characterData: true });
        }

        if (document.body) {
            sweep();
        } else {
            document.addEventListener('DOMContentLoaded', function () { sweep(); });
        }
        // The reader builds its iframe lazily and rebuilds it on every display-type
        // change, so re-scan a handful of times instead of trusting one pass.
        var FRAME_DELAYS = [0, 300, 1000, 2000, 4000, 8000];
        for (var f = 0; f < FRAME_DELAYS.length; f++) {
            setTimeout(function () { sweep(); attachFrames(); attachContent(); }, FRAME_DELAYS[f]);
        }

        var contentAttempts = 0;
        var contentTimer = setInterval(function () {
            contentAttempts++;
            if (attachContent() || contentAttempts > 600) { clearInterval(contentTimer); }
        }, 200);

        if (window.__stvDiag) {
            window.__stvDiag.log('PATCH', 'i18n overlay ready: ' + EXACT.length + ' labels, '
                + FRAGMENTS.length + ' fragments, ' + PATTERNS.length + ' patterns, chapter titles on');
        }
    })();
    """
}
