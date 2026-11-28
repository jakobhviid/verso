// A video's stream as AVPlayer plays it, on the Mac, the iPhone and the iPad. AVPlayer fetches an https address itself
// and asks the app nothing about the server's certificate, so a server with a certificate of its own (ARCHITECTURE.md,
// "A certificate of the server's own") would be refused there whatever the person trusted. For such a server the
// asset's address takes a scheme of the app's own, which AVFoundation hands to the asset's resource loader, and its
// delegate here serves each byte range AVPlayer asks for through a session that answers the server-trust challenge as
// every other session does (ServerTrust): playback starts as the first bytes come, and seeking asks for the range it
// needs, so the player's own controls work as they do for a stream. A server the system trusts streams as before.

import AVFoundation
import Foundation
import UniformTypeIdentifiers

extension ImmichClient {
    /// The video's stream for AVPlayer, with the account's credential: through `VideoStream` where a certificate of
    /// the server's own is trusted for the server, straight from it otherwise. The server's version for playback, or
    /// the original as uploaded.
    func videoAsset(_ id: String, original: Bool = false) -> AVURLAsset {
        let url = original ? originalVideoURL(id) : videoURL(id)
        let headers = credential?.headers ?? [:]
        guard ServerTrust.certificate(for: url) != nil else {
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        return VideoStream.asset(url, headers: headers)
    }
}

/// One video's stream, served to its asset's resource loader through the app's own session. The asset keeps it; all
/// its work, and the session's, happens on one queue.
final class VideoStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The scheme the asset's address takes, which AVFoundation leaves to the resource loader.
    static let scheme = "verso-stream"
    fileprivate static let queue = DispatchQueue(label: "dev.hviid.Verso.video-stream")
    private nonisolated(unsafe) static var keptKey: UInt8 = 0

    /// An asset for `source` whose bytes come through this stream.
    static func asset(_ source: URL, headers: [String: String]) -> AVURLAsset {
        var address = URLComponents(url: source, resolvingAgainstBaseURL: false)
        address?.scheme = scheme
        let asset = AVURLAsset(url: address?.url ?? source)
        let stream = VideoStream(source: source, headers: headers)
        asset.resourceLoader.setDelegate(stream, queue: queue)
        // The resource loader holds its delegate weakly: the asset keeps it, and it goes with the asset.
        objc_setAssociatedObject(asset, &keptKey, stream, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    private let source: URL
    private let headers: [String: String]
    /// The loads in flight, by the loading request AVFoundation made. Touched on `queue` alone.
    private var loads: [ObjectIdentifier: URLSessionDataTask] = [:]

    private init(source: URL, headers: [String: String]) {
        self.source = source
        self.headers = headers
    }

    deinit {
        for task in loads.values { task.cancel() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let (offset, length) = Self.range(of: loadingRequest)
        var request = URLRequest(url: source)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let end = length.map { String(offset + $0 - 1) } ?? ""
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let task = StreamSession.shared.session.dataTask(with: request)
        let key = ObjectIdentifier(loadingRequest)
        loads[key] = task
        StreamSession.shared.start(task, Load(request: loadingRequest, offset: offset, length: length) { [weak self] in
            self?.loads[key] = nil
        })
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        loads.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// The bytes a loading request asks for: where they start, and how many, nil for all to the end. A request for
    /// what the video is (its type and length) alone asks for its first two bytes, which the answer's headers come with.
    private static func range(of loading: AVAssetResourceLoadingRequest) -> (offset: Int64, length: Int64?) {
        guard let data = loading.dataRequest else { return (0, 2) }
        let offset = max(data.currentOffset, data.requestedOffset)
        if data.requestsAllDataToEndOfResource { return (offset, nil) }
        return (offset, max(1, Int64(data.requestedLength) - (offset - data.requestedOffset)))
    }
}

/// One range on its way to AVFoundation.
private final class Load {
    let request: AVAssetResourceLoadingRequest
    let offset: Int64
    /// How many bytes are still to be handed over, nil for all to the end.
    var remaining: Int64?
    /// Bytes to drop first, where the server answered with the whole video rather than the range.
    var skip: Int64 = 0
    let ended: () -> Void

    init(request: AVAssetResourceLoadingRequest, offset: Int64, length: Int64?, ended: @escaping () -> Void) {
        self.request = request
        self.offset = offset
        remaining = length
        self.ended = ended
    }
}

/// The session every stream's ranges come through, and its delegate: the server's certificate as ServerTrust judges
/// it, and each answer's bytes handed to its loading request as they come. On the streams' queue.
private final class StreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamSession()

    private(set) var session: URLSession!
    private var loads: [Int: Load] = [:]

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        // The ranges go straight to the player; nothing is kept.
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": ImmichClient.userAgent]
        let queue = OperationQueue()
        queue.underlyingQueue = VideoStream.queue
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(_ task: URLSessionTask, _ load: Load) {
        loads[task.taskIdentifier] = load
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.answer(challenge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let load = loads[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(dataTask, error: status == 401 ? ImmichError.unauthorized(nil) : ImmichError.http(status, nil))
            return completionHandler(.cancel)
        }
        let whole = http.statusCode == 200
        if whole { load.skip = load.offset }
        if let information = load.request.contentInformationRequest {
            information.contentType = http.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
            information.contentLength = Self.totalLength(http) ?? (whole ? http.expectedContentLength : 0)
            information.isByteRangeAccessSupported = !whole
                || (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let load = loads[dataTask.taskIdentifier] else { return }
        var bytes = data
        if load.skip > 0 {
            let dropped = min(Int64(bytes.count), load.skip)
            bytes = bytes.dropFirst(Int(dropped))
            load.skip -= dropped
        }
        if let remaining = load.remaining, Int64(bytes.count) > remaining { bytes = bytes.prefix(Int(remaining)) }
        if !bytes.isEmpty { load.request.dataRequest?.respond(with: Data(bytes)) }
        if let remaining = load.remaining {
            load.remaining = remaining - Int64(bytes.count)
            // A whole answer to a range: what was asked has been handed over.
            if load.remaining == 0 {
                finish(dataTask, error: nil)
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Cancelled by AVFoundation, or by the stream itself once it had what it asked for: nothing to say.
        if let error = error as? URLError, error.code == .cancelled {
            loads.removeValue(forKey: task.taskIdentifier)?.ended()
            return
        }
        finish(task, error: error)
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        guard let load = loads.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { load.request.finishLoading(with: error) } else { load.request.finishLoading() }
        load.ended()
    }

    /// The video's whole length, from a range's answer (`Content-Range: bytes 0-1/12345`).
    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
    }
}
