import UIKit
import CoreText

// ===== 安卓阅读器主题/排版/字体复刻（来自 _appv2.read.js + _appv2.css）=====

/// 单个阅读主题：背景色 + 正文色
struct ReaderTheme {
    let backgroundColor: UIColor
    let textColor: UIColor

    init(bg: String, fg: String) {
        self.backgroundColor = UIColor(hex: bg) ?? UIColor(white: 0.9, alpha: 1)
        self.textColor = UIColor(hex: fg) ?? UIColor.black
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 3,
              let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 3 {
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            self.init(red: CGFloat(r) / 15, green: CGFloat(g) / 15, blue: CGFloat(b) / 15, alpha: 1)
        } else {
            self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                      green: CGFloat((v >> 8) & 0xFF) / 255,
                      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }
}

/// 安卓默认排版参数（app.reader.style 默认值）
enum ReaderDefaultStyle {
    static let fontSizePt: CGFloat = 17      // 安卓 24px，iOS 按 pt 折中
    static let lineHeight: CGFloat = 1.8     // 行高倍数
    static let textAlign: NSTextAlignment = .justified
    static let textIndent: CGFloat = 2 * 17  // 首行缩进两字符
    static let paragraphSpacing: CGFloat = 8 // 段间距
    static let padding: CGFloat = 12         // 左右内边距
    static let fontFamily = "nunito"
}

/// 安卓 12 主题（app.reader.style.themeSet）
enum ReaderThemes {
    static let all: [ReaderTheme] = [
        ReaderTheme(bg: "#eae4d3", fg: "#000"),
        ReaderTheme(bg: "#eae4d3", fg: "#333"),
        ReaderTheme(bg: "#f5f5f5", fg: "#000"),
        ReaderTheme(bg: "#d0d0d0", fg: "#000"),
        ReaderTheme(bg: "#a3e6a2", fg: "#000"),
        ReaderTheme(bg: "#a7d4e8", fg: "#000"),
        ReaderTheme(bg: "#d7ffff", fg: "#000"),
        ReaderTheme(bg: "#8a8a88", fg: "#eae4d3"),
        ReaderTheme(bg: "#8a8a88", fg: "#ececec"),
        ReaderTheme(bg: "#464646", fg: "#bdbdbd"),
        ReaderTheme(bg: "#262626", fg: "#dddddd"),
        ReaderTheme(bg: "#ececec", fg: "#333"),
    ]
}

/// 正文字体注册：从 bundle 的 www/font 目录动态注册安卓 TTF 字体
enum ReaderFontLoader {
    /// 已注册字体名集合，避免重复注册
    private static var registered = Set<String>()

    /// 字体文件名 -> UIFont(name:)
    static let familyFile: [String: String] = [
        "nunito": "Nunito-Regular.ttf",
        "helvetica": "helvetica.ttf",
        "opensans": "opensans.ttf",
        "roboto": "roboto.ttf",
        "robotoslab": "robotoslab.ttf",
        "sourceserifpro": "sourceserifpro.ttf",
        "verdana": "verdana.ttf",
        "tahoma": "tahoma.ttf",
        "palatinolinotype": "palatinolinotype.ttf",
        "linotype": "pala.ttf",
    ]

    /// 注册所有正文字体（幂等）。返回注册成功的字体 postscript 名列表。
    @discardableResult
    static func registerAll() -> [String] {
        var ok: [String] = []
        for (family, file) in familyFile {
            if let name = register(file: file) {
                ok.append(name)
                registered.insert(family)
            }
        }
        return ok
    }

    /// 注册单个 TTF，返回其 UIFont familyName（供 UIFont(name:) 使用）
    static func register(file: String) -> String? {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "www/font") ?? Bundle.main.url(forResource: file, withExtension: nil) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let post = CTFontDescriptorCopyAttribute(descriptors[0], kCTFontNameAttribute) as? String else {
                return nil
            }
            return post
        }
        // 已注册过可能返回 false，直接尝试用文件名读取字体族名
        return file
    }

    /// 按安卓字体族名取 UIFont，找不到则回退系统字体
    static func font(family: String, size: CGFloat) -> UIFont {
        let sanitized = family.trimmingCharacters(in: .whitespaces).lowercased()
        if let f = UIFont(name: sanitized, size: size) { return f }
        // 部分字体注册后名称是文件基准名，再尝试
        if let file = familyFile[sanitized] {
            let base = (file as NSString).deletingPathExtension
            if let f = UIFont(name: base, size: size) { return f }
        }
        return UIFont.systemFont(ofSize: size)
    }
}
