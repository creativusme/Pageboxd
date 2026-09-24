import Foundation
import ImageIO
import OSLog
import UIKit

enum ImageStorageError: LocalizedError {
    case encodingFailed
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Impossibile convertire la foto in JPEG."
        case .writeFailed(let error):
            return "Impossibile salvare la foto sul dispositivo: \(error.localizedDescription)"
        }
    }
}

struct StorageUsage: Sendable {
    var fileCount: Int = 0
    var bytes: Int64 = 0
    var orphanCount: Int = 0
}

struct StorageCleanupReport: Sendable {
    var removedOrphans: Int = 0
    var optimizedImages: Int = 0
    var bytesFreed: Int64 = 0
}

/// Gestisce le immagini su disco. Nel database viene salvato solo il percorso relativo
/// (es. "covers/UUID.jpg"), mai i dati binari dell'immagine.
final class ImageStorageManager: @unchecked Sendable {
    static let shared = ImageStorageManager()

    static let maxPixelDimension: CGFloat = 1080
    static let jpegQuality: CGFloat = 0.75
    static let coversDirectoryName = "covers"
    /// Foto degli autori: ricostruibili online, quindi escluse da backup e pulizia delle foto orfane.
    static let authorsDirectoryName = "authors"

    /// Oltre questa dimensione un file viene ricompresso durante l'ottimizzazione.
    private static let optimizationSizeThreshold: Int64 = 600 * 1024

    private let fileManager = FileManager.default
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private init() {}

    // MARK: Percorsi

    var documentsDirectory: URL { URL.documentsDirectory }

    var coversDirectory: URL {
        documentsDirectory.appending(path: Self.coversDirectoryName, directoryHint: .isDirectory)
    }

    func absoluteURL(for relativePath: String) -> URL {
        documentsDirectory.appending(path: relativePath, directoryHint: .notDirectory)
    }

    /// Accetta solo percorsi interni alla cartella delle copertine, per non toccare mai altri file.
    private func isSafeRelativePath(_ relativePath: String) -> Bool {
        let allowed = [Self.coversDirectoryName, Self.authorsDirectoryName]
        return allowed.contains { relativePath.hasPrefix($0 + "/") } && !relativePath.contains("..")
    }

    private func ensureDirectoryExists(_ name: String) throws {
        let directory = documentsDirectory.appending(path: name, directoryHint: .isDirectory)
        let path = directory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Ridimensionamento e compressione

    /// Ridimensiona l'immagine a massimo 1080 px sul lato lungo, normalizzando l'orientamento.
    func resizedImage(_ image: UIImage, maxPixelDimension: CGFloat = ImageStorageManager.maxPixelDimension) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestSide = max(pixelWidth, pixelHeight)
        guard longestSide > 0 else { return image }

        let ratio = longestSide > maxPixelDimension ? maxPixelDimension / longestSide : 1
        let targetSize = CGSize(width: floor(pixelWidth * ratio), height: floor(pixelHeight * ratio))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func jpegData(for image: UIImage) throws -> Data {
        let resized = resizedImage(image)
        guard let data = resized.jpegData(compressionQuality: Self.jpegQuality) else {
            throw ImageStorageError.encodingFailed
        }
        return data
    }

    /// Variante asincrona, eseguita fuori dal main thread.
    func preparedImage(from image: UIImage, maxPixelDimension: CGFloat = ImageStorageManager.maxPixelDimension) async -> UIImage {
        resizedImage(image, maxPixelDimension: maxPixelDimension)
    }

    // MARK: Salvataggio

    /// Ridimensiona, comprime e salva l'immagine. Restituisce il percorso relativo da salvare nel database.
    func saveImage(_ image: UIImage, directory: String = ImageStorageManager.coversDirectoryName) throws -> String {
        let data = try jpegData(for: image)
        try ensureDirectoryExists(directory)

        let relativePath = "\(directory)/\(UUID().uuidString).jpg"
        do {
            try data.write(
                to: absoluteURL(for: relativePath),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw ImageStorageError.writeFailed(error)
        }
        return relativePath
    }

    /// Variante asincrona, eseguita fuori dal main thread.
    func save(_ image: UIImage, directory: String = ImageStorageManager.coversDirectoryName) async throws -> String {
        try saveImage(image, directory: directory)
    }

    // MARK: Caricamento

    /// Carica un'anteprima già decodificata con lato lungo massimo `maxPixelSize`, con cache in memoria.
    func thumbnail(relativePath: String, maxPixelSize: CGFloat) -> UIImage? {
        let cacheKey = "\(relativePath)#\(Int(maxPixelSize))" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let url = absoluteURL(for: relativePath)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let image = UIImage(cgImage: cgImage)
        memoryCache.setObject(image, forKey: cacheKey, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Variante asincrona, eseguita fuori dal main thread.
    func loadThumbnail(relativePath: String, maxPixelSize: CGFloat) async -> UIImage? {
        thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }

    func loadImage(relativePath: String) async -> UIImage? {
        thumbnail(relativePath: relativePath, maxPixelSize: Self.maxPixelDimension)
    }

    // MARK: Eliminazione

    func deleteImage(relativePath: String?) {
        guard let relativePath, isSafeRelativePath(relativePath) else { return }
        let url = absoluteURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Logger.pageboxd.error("Eliminazione immagine fallita: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Analisi spazio

    private func storedImageFiles() -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: coversDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func relativePath(for url: URL) -> String {
        "\(Self.coversDirectoryName)/\(url.lastPathComponent)"
    }

    /// Calcola lo spazio occupato dalle foto e quante non sono più collegate ad alcun libro.
    func usage(referencedPaths: Set<String>) async -> StorageUsage {
        var usage = StorageUsage()
        for url in storedImageFiles() {
            usage.fileCount += 1
            usage.bytes += fileSize(of: url)
            if !referencedPaths.contains(relativePath(for: url)) {
                usage.orphanCount += 1
            }
        }
        return usage
    }

    /// Dimensione del database SwiftData (store + file WAL/SHM).
    func databaseSize() async -> Int64 {
        let directory = URL.applicationSupportDirectory
        let candidates = ["default.store", "default.store-wal", "default.store-shm"].map {
            directory.appending(path: $0, directoryHint: .notDirectory)
        }
        return candidates.reduce(Int64(0)) { total, url in
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return total }
            return total + fileSize(of: url)
        }
    }

    // MARK: Manutenzione

    /// Rimuove le foto orfane, ricomprime le foto troppo grandi e svuota cache e file temporanei.
    func performMaintenance(referencedPaths: Set<String>) async -> StorageCleanupReport {
        var report = StorageCleanupReport()

        for url in storedImageFiles() {
            let size = fileSize(of: url)
            if !referencedPaths.contains(relativePath(for: url)) {
                do {
                    try fileManager.removeItem(at: url)
                    report.removedOrphans += 1
                    report.bytesFreed += size
                } catch {
                    Logger.pageboxd.error("Rimozione file orfano fallita: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }
            if let saved = optimizeIfNeeded(url: url, currentSize: size) {
                report.optimizedImages += 1
                report.bytesFreed += saved
            }
        }

        report.bytesFreed += clearTemporaryDirectory()
        memoryCache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        return report
    }

    /// Ricomprime un file se supera 1080 px o la soglia di peso. Restituisce i byte risparmiati.
    private func optimizeIfNeeded(url: URL, currentSize: Int64) -> Int64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let isOversized = CGFloat(max(width, height)) > Self.maxPixelDimension
        guard isOversized || currentSize > Self.optimizationSizeThreshold else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelDimension
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: Self.jpegQuality),
              Int64(data.count) < currentSize
        else { return nil }

        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return currentSize - Int64(data.count)
        } catch {
            Logger.pageboxd.error("Ottimizzazione immagine fallita: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Svuota la cartella temporanea dell'app (es. CSV esportati in precedenza).
    private func clearTemporaryDirectory() -> Int64 {
        let temporaryDirectory = fileManager.temporaryDirectory
        let items = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: []
        )) ?? []

        var freed: Int64 = 0
        for item in items {
            let size = fileSize(of: item)
            if (try? fileManager.removeItem(at: item)) != nil {
                freed += size
            }
        }
        return freed
    }
}
