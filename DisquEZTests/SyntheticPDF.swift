import CoreText
import PDFKit

enum SyntheticPDF {
    static func make(in directory: URL, images: Bool = true, rotated: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "DisquEZ Synthetic PDF"] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for page in 1...2 {
            context.beginPDFPage(nil)
            if images {
                let width = 800, height = 1000
                var state = UInt32(page)
                var pixels = [UInt8](repeating: 0, count: width * height * 3)
                for i in pixels.indices {
                    state = 1_664_525 &* state &+ 1_013_904_223
                    let x = (i / 3) % width, y = (i / 3) / width
                    pixels[i] = UInt8((x / 8 + y / 9 + Int(state >> 27) + page * (i % 3 + 1) * 30) % 256)
                }
                let provider = CGDataProvider(data: Data(pixels) as CFData)!
                let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                context.draw(image, in: CGRect(x: 40, y: 50, width: 532, height: 665))
            }
            context.textPosition = CGPoint(x: 40, y: 750)
            let text = NSAttributedString(string: "DisquEZ searchable page \(page)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        if rotated {
            let document = PDFDocument(url: url)!
            document.page(at: 1)!.rotation = 90
            guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        }
        return url
    }
    static func structured(in directory: URL, entry: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("pdf")
        let objects = ["<< /Type /Catalog /Pages 2 0 R \(entry) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(i + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let start = data.count
        data.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
        try data.write(to: url)
        return url
    }
}
