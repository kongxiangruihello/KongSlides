import Foundation

struct OpenTiming {
    let fileName: String
    let pageCount: Int
    let requestedAt: Double
    let readAndConvert: Double
    let imagePreparation: Double
    let uiInstalledAt: Double
    var firstDraw: Double?
    var displayImagePreparation: Double?
    var readyAfterDraw: Double?

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    var report: String {
        func ms(_ seconds: Double?) -> String {
            seconds.map { "\(Int(($0 * 1000).rounded())) 毫秒" } ?? "等待记录"
        }
        return """
        \(fileName) · \(pageCount) 页
        文件读取与结构转换　\(ms(readAndConvert))
        导入图片解码与转换　\(ms(imagePreparation))
        首屏图片解码与缓存读取　\(ms(displayImagePreparation))
        首屏绘制提交　\(ms(firstDraw))
        打开至首屏提交后的界面就绪　\(ms(readyAfterDraw))
        """
    }
}
