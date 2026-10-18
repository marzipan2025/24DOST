import AVFoundation
import CFFmpeg
import CoreVideo
import VideoToolbox

/// IINA 처럼 mkv·avi 등을 앱 안에서 직접 읽는다(33RUVI 의 엔진을 옮겨 온 것). 다시 묶지(remux) 않으므로 큰 파일도 바로 열린다.
/// mp4·mov 는 지금처럼 AVPlayer 로 틀고, 이 엔진으로 못 여는 파일(소리만 있는 ogg·wma 등)은 remux 로 넘어간다.
///
/// 스레드 셋:
/// - 읽기(demux): 패킷을 읽어 영상 패킷은 줄에 넣고, 소리는 바로 풀어 `AVSampleBufferAudioRenderer` 에 넣는다.
/// - 영상 풀기: 줄의 패킷을 풀어(h264·hevc 는 VideoToolbox) BGRA 프레임으로 바꿔 몇 장 쌓아 둔다.
/// - 메인: `newFrame` 이 시계(`AVSampleBufferRenderSynchronizer`, 소리가 기준)에 맞는 프레임을 꺼내 간다.
final class FFmpegEngine {
    struct OpenError: Error { let message: String }

    let duration: Double
    /// 화소 비율까지 반영한 화면 비율(가로/세로)
    let aspect: Float
    /// 화소 비율까지 반영한 영상 크기
    let videoSize: CGSize
    /// 글자 자막(srt·ass 등)이 들어 있는지. 그림 자막(PGS·VobSub)은 읽지 않는다.
    var hasTextSubtitles: Bool { sdec != nil }
    var onEnd: (() -> Void)?

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private let videoIndex: Int32
    private let audioIndex: Int32
    private var vdec: UnsafeMutablePointer<AVCodecContext>?
    private var adec: UnsafeMutablePointer<AVCodecContext>?
    private var sdec: UnsafeMutablePointer<AVCodecContext>?
    private var subtitleIndex: Int32 = -1
    private var subtitleTimeBase = 0.0
    /// 읽어 들인 글자 자막(시작 순). 재생하며 읽는 만큼 늘어난다. `lock` 으로 지킨다.
    private var cues: [(start: Double, end: Double, text: String)] = []
    private let videoTimeBase: Double
    private let audioTimeBase: Double
    /// 파일의 시작 시각(초). 시계는 0 부터 세므로 패킷 시각에서 뺀다.
    private let startTime: Double

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()

    // 아래는 `lock` 으로 지킨다
    private let lock = NSCondition()
    private var videoPackets: [UnsafeMutablePointer<AVPacket>] = []
    private var frames: [(pts: Double, buffer: CVPixelBuffer)] = []
    private var demuxEOF = false
    private var videoDrained = false
    private var stopping = false
    /// 옮길 때마다 하나씩 올린다. 이전 번호로 풀린 프레임은 버린다.
    private var serial = 0
    private var pendingSeek: (target: Double, accurate: Bool)?
    /// 이 시각보다 앞선 프레임·소리는 버린다(정확히 옮길 때)
    private var dropBefore = -Double.infinity
    /// 소리를 이 시각까지 넣었다
    private var audioQueuedUntil = 0.0

    // 메인 스레드에서만
    private var wantsPlaying = false
    /// 옮긴 뒤 첫 프레임은 시계와 상관없이 바로 보여 준다(멈춰 있을 때도 화면이 바뀌게)
    private var showNextNow = true
    private var seekDone: (() -> Void)?
    private var lastShown = 0.0
    private var ended = false

    private let threads = DispatchGroup()

    /// 파일을 열고 스트림을 고른다. 블록되므로 메인 스레드 밖에서 부른다.
    init(url: URL) throws {
        var f: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&f, url.path, nil, nil) == 0, let f else { throw OpenError(message: "파일을 열 수 없습니다.") }
        fmt = f
        guard avformat_find_stream_info(f, nil) >= 0 else {
            avformat_close_input(&fmt)
            throw OpenError(message: "파일 정보를 읽을 수 없습니다.")
        }
        videoIndex = av_find_best_stream(f, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioIndex = av_find_best_stream(f, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        guard videoIndex >= 0, let vs = f.pointee.streams[Int(videoIndex)], let v = Self.openDecoder(vs, hardware: true) else {
            avformat_close_input(&fmt)
            throw OpenError(message: "영상 트랙이 없거나 풀 수 없는 형식입니다.")
        }
        vdec = v
        videoTimeBase = av_q2d(vs.pointee.time_base)
        if audioIndex >= 0, let s = f.pointee.streams[Int(audioIndex)] {
            adec = Self.openDecoder(s, hardware: false)
            audioTimeBase = av_q2d(s.pointee.time_base)
        } else {
            audioTimeBase = 0
        }
        startTime = f.pointee.start_time == Self.noPTS ? 0 : Double(f.pointee.start_time) / Double(AV_TIME_BASE)
        duration = f.pointee.duration > 0 ? Double(f.pointee.duration) / Double(AV_TIME_BASE) : 0
        let par = vs.pointee.codecpar.pointee
        let sar = av_guess_sample_aspect_ratio(f, vs, nil)
        let pixel = sar.num > 0 && sar.den > 0 ? Double(sar.num) / Double(sar.den) : 1
        aspect = par.height > 0 ? Float(Double(par.width) * pixel / Double(par.height)) : 16.0 / 9.0
        videoSize = CGSize(width: Double(par.width) * pixel, height: Double(par.height))
        // 글자 자막 트랙: 강제 자막만 든 것이 아닌 첫 트랙
        for i in 0..<Int32(f.pointee.nb_streams) {
            guard let s = f.pointee.streams[Int(i)], s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
                  s.pointee.disposition & AV_DISPOSITION_FORCED == 0,
                  let desc = avcodec_descriptor_get(s.pointee.codecpar.pointee.codec_id),
                  desc.pointee.props & AV_CODEC_PROP_TEXT_SUB != 0,
                  let d = Self.openDecoder(s, hardware: false) else { continue }
            sdec = d
            subtitleIndex = i
            subtitleTimeBase = av_q2d(s.pointee.time_base)
            break
        }

        if adec != nil { synchronizer.addRenderer(audioRenderer) }
        synchronizer.setRate(0, time: .zero)
        threads.enter()
        Thread.detachNewThread { [self] in demuxLoop(); threads.leave() }
        threads.enter()
        Thread.detachNewThread { [self] in videoLoop(); threads.leave() }
    }

    // MARK: 조작 (메인 스레드)

    var currentTime: Double { max(synchronizer.currentTime().seconds, 0) }

    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = min(max(newValue, 0), 1) }
    }

    func play() {
        wantsPlaying = true
        startIfReady()
    }

    func pause() {
        wantsPlaying = false
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    func seek(to seconds: Double, accurate: Bool, done: (() -> Void)?) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90000))
        ended = false
        showNextNow = true
        seekDone = done
        lock.lock()
        pendingSeek = (target, accurate)
        frames.removeAll()
        lock.broadcast()
        lock.unlock()
    }

    func newFrame() -> CVPixelBuffer? {
        let now = currentTime
        var pick: CVPixelBuffer?
        lock.lock()
        if pendingSeek == nil {
            if showNextNow, let first = frames.first {
                pick = first.buffer
                lastShown = first.pts
                frames.removeFirst()
            }
            while let first = frames.first, first.pts <= now + 0.005 {
                pick = first.buffer
                lastShown = first.pts
                frames.removeFirst()
            }
        }
        let finished = demuxEOF && videoDrained && frames.isEmpty && pendingSeek == nil
        if pick != nil { lock.broadcast() }
        lock.unlock()

        if pick != nil, showNextNow {
            showNextNow = false
            if let done = seekDone { seekDone = nil; done() }
        }
        startIfReady()
        if finished, !ended, now >= max(lastShown, audioQueuedUntilSnapshot) - 0.05 {
            ended = true
            synchronizer.setRate(0, time: synchronizer.currentTime())
            wantsPlaying = false
            onEnd?()
        }
        return pick
    }

    private var audioQueuedUntilSnapshot: Double {
        lock.lock(); defer { lock.unlock() }
        return audioQueuedUntil
    }

    /// 재생하려는데 시계가 멈춰 있으면, 프레임과 소리가 조금 쌓인 뒤 시계를 돌린다(첫 소리가 잘리지 않게).
    private func startIfReady() {
        guard wantsPlaying, synchronizer.rate == 0, !ended else { return }
        lock.lock()
        let now = currentTime
        let ready = pendingSeek == nil && !showNextNow
            && (!frames.isEmpty || (demuxEOF && videoDrained))
            && (adec == nil || audioQueuedUntil >= now + 0.3 || demuxEOF)
        lock.unlock()
        if ready { synchronizer.setRate(1, time: CMTime(seconds: now, preferredTimescale: 90000)) }
    }

    func close() {
        synchronizer.setRate(0, time: .zero)
        lock.lock()
        stopping = true
        lock.broadcast()
        lock.unlock()
        // 스레드가 끝나기를 기다렸다가 풀어 준다(메인 스레드를 막지 않는다)
        threads.notify(queue: .global()) { [self] in
            audioRenderer.flush()
            if adec != nil { synchronizer.removeRenderer(audioRenderer, at: .zero) }
            for p in videoPackets { var p: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&p) }
            videoPackets.removeAll()
            frames.removeAll()
            avcodec_free_context(&vdec)
            avcodec_free_context(&adec)
            avcodec_free_context(&sdec)
            swr_free(&swr)
            sws_freeContext(sws)
            avformat_close_input(&fmt)
        }
    }

    // MARK: 읽기 스레드

    private var swr: OpaquePointer?

    private func demuxLoop() {
        guard let fmt else { return }
        let pkt = av_packet_alloc()!
        let frame = av_frame_alloc()!
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p)
            var fr: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&fr)
        }
        while true {
            lock.lock()
            while !stopping, pendingSeek == nil, !needsMoreData() { lock.wait(until: Date().addingTimeInterval(0.05)) }
            if stopping { lock.unlock(); return }
            if let seek = pendingSeek {
                pendingSeek = nil
                serial += 1
                for p in videoPackets { var p: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&p) }
                videoPackets.removeAll()
                frames.removeAll()
                demuxEOF = false
                videoDrained = false
                dropBefore = seek.accurate ? seek.target - 0.02 : -Double.infinity
                audioQueuedUntil = seek.target
                lock.broadcast()
                lock.unlock()
                let ts = Int64((seek.target + startTime) * Double(AV_TIME_BASE))
                av_seek_frame(fmt, -1, ts, AVSEEK_FLAG_BACKWARD)
                if let adec { avcodec_flush_buffers(adec) }
                audioRenderer.flush()
                continue
            }
            lock.unlock()

            let r = av_read_frame(fmt, pkt)
            if r < 0 {
                // 끝(또는 읽기 오류): 소리 디코더에 남은 것을 비운다
                if adec != nil { decodeAudio(nil, frame) }
                lock.lock()
                demuxEOF = true
                lock.broadcast()
                lock.unlock()
                continue
            }
            if pkt.pointee.stream_index == videoIndex {
                let copy = av_packet_alloc()!
                av_packet_move_ref(copy, pkt)
                lock.lock()
                videoPackets.append(copy)
                lock.broadcast()
                lock.unlock()
            } else if pkt.pointee.stream_index == audioIndex, adec != nil {
                decodeAudio(pkt, frame)
                av_packet_unref(pkt)
            } else if pkt.pointee.stream_index == subtitleIndex {
                decodeSubtitle(pkt)
                av_packet_unref(pkt)
            } else {
                av_packet_unref(pkt)
            }
        }
    }

    /// `lock` 을 잡은 채로 부른다. 영상 패킷이 모자라거나 소리가 2초 넘게 앞서 있지 않으면 더 읽는다.
    private func needsMoreData() -> Bool {
        if demuxEOF { return false }
        if videoPackets.count > 3000 { return false }   // 소리가 아무리 모자라도 메모리는 지킨다
        if videoPackets.count < 90 { return true }
        return adec != nil && audioQueuedUntil < currentTime + 2
    }

    private func decodeAudio(_ pkt: UnsafeMutablePointer<AVPacket>?, _ frame: UnsafeMutablePointer<AVFrame>) {
        guard let adec, avcodec_send_packet(adec, pkt) == 0 || pkt == nil else { return }
        while avcodec_receive_frame(adec, frame) == 0 {
            defer { av_frame_unref(frame) }
            let n = Int(frame.pointee.nb_samples)
            let rate = Int(frame.pointee.sample_rate)
            guard n > 0, rate > 0 else { continue }
            lock.lock()
            let ts = frame.pointee.best_effort_timestamp
            let pts = ts == Self.noPTS ? audioQueuedUntil : Double(ts) * audioTimeBase - startTime
            let end = pts + Double(n) / Double(rate)
            let drop = end < dropBefore
            if !drop { audioQueuedUntil = end }
            let mySerial = serial
            lock.unlock()
            if drop { continue }
            guard let sample = makeAudioSample(frame, pts: pts) else { continue }
            lock.lock()
            let current = mySerial == serial && pendingSeek == nil
            lock.unlock()
            if current { audioRenderer.enqueue(sample) }
        }
    }

    /// 지금 시각의 글자 자막. 없으면 빈 문자열. 메인 스레드에서 부른다.
    func subtitleText(at t: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        // 시작 순으로 정렬돼 있다. t 보다 늦게 시작하는 첫 자리 앞에서부터 거꾸로 찾는다.
        var lo = 0, hi = cues.count
        while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start <= t { lo = mid + 1 } else { hi = mid } }
        var lines: [String] = []
        var i = lo - 1
        while i >= 0, lo - i <= 8 {
            if cues[i].end > t { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return lines.joined(separator: "\n")
    }

    private func decodeSubtitle(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard let sdec else { return }
        var sub = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(sdec, &sub, &got, pkt) >= 0, got != 0 else { return }
        defer { avsubtitle_free(&sub) }
        let ts = pkt.pointee.pts != Self.noPTS ? pkt.pointee.pts : pkt.pointee.dts
        guard ts != Self.noPTS else { return }
        let base = Double(ts) * subtitleTimeBase - startTime
        let start = base + Double(sub.start_display_time) / 1000
        let end = pkt.pointee.duration > 0 ? base + Double(pkt.pointee.duration) * subtitleTimeBase
            : sub.end_display_time > 0 ? base + Double(sub.end_display_time) / 1000 : start + 3
        var parts: [String] = []
        for r in 0..<Int(sub.num_rects) {
            guard let rect = sub.rects[r] else { continue }
            if let ass = rect.pointee.ass { parts.append(Self.assText(String(cString: ass))) }
            else if let text = rect.pointee.text { parts.append(String(cString: text)) }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, end > start else { return }
        lock.lock()
        // 이동하면 같은 자막을 또 읽는다. 시작 시각이 같으면 한 번만 둔다.
        var lo = 0, hi = cues.count
        while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start < start { lo = mid + 1 } else { hi = mid } }
        if !(lo < cues.count && abs(cues[lo].start - start) < 0.001 && cues[lo].text == text) {
            cues.insert((start, end, text), at: lo)
        }
        lock.unlock()
    }

    /// ASS 대사 줄("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text")에서 글자만: {\…} 태그를 빼고 \N 은 줄바꿈.
    private static func assText(_ line: String) -> String {
        var text = line
        var commas = 0
        if let i = line.firstIndex(where: { c in if c == "," { commas += 1 }; return commas == 8 }) {
            text = String(line[line.index(after: i)...])
        }
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }

    private var swrInput: (layout: String, rate: Int32, format: Int32)?
    private var audioFormat: CMAudioFormatDescription?

    /// 2채널 float32(인터리브)로 바꿔 CMSampleBuffer 로 싼다. 5.1 등은 ffmpeg 이 2채널로 섞는다.
    private func makeAudioSample(_ frame: UnsafeMutablePointer<AVFrame>, pts: Double) -> CMSampleBuffer? {
        let rate = frame.pointee.sample_rate
        var desc = [CChar](repeating: 0, count: 64)
        av_channel_layout_describe(&frame.pointee.ch_layout, &desc, 64)
        let key = (String(cString: desc), rate, frame.pointee.format)
        if swr == nil || swrInput.map({ $0 != key }) ?? true {
            swr_free(&swr)
            var stereo = AVChannelLayout()
            av_channel_layout_default(&stereo, 2)
            var s: OpaquePointer?
            guard swr_alloc_set_opts2(&s, &stereo, AV_SAMPLE_FMT_FLT, rate, &frame.pointee.ch_layout,
                                      AVSampleFormat(frame.pointee.format), rate, 0, nil) == 0, swr_init(s) == 0 else { return nil }
            swr = s
            swrInput = key
            var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            audioFormat = nil
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        }
        guard let swr, let audioFormat else { return nil }
        let maxOut = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        var data = Data(count: maxOut * 8)
        let got: Int32 = data.withUnsafeMutableBytes { raw in
            var out: UnsafeMutablePointer<UInt8>? = raw.bindMemory(to: UInt8.self).baseAddress
            return withUnsafeMutablePointer(to: &out) { outPtr in
                frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { inPtr in
                    swr_convert(swr, outPtr, Int32(maxOut), inPtr, frame.pointee.nb_samples)
                }
            }
        }
        guard got > 0 else { return nil }
        let bytes = Int(got) * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                                                             sampleCount: CMItemCount(got),
                                                             presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: rate),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    // MARK: 영상 풀기 스레드

    private var sws: UnsafeMutablePointer<SwsContext>?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var transfer: VTPixelTransferSession?

    private func videoLoop() {
        guard let vdec else { return }
        let frame = av_frame_alloc()!
        defer { var fr: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&fr) }
        var mySerial = -1
        var sentFlush = false
        while true {
            lock.lock()
            while !stopping, serial == mySerial, frames.count >= 4 || (videoPackets.isEmpty && (!demuxEOF || sentFlush)) {
                lock.wait(until: Date().addingTimeInterval(0.05))
            }
            if stopping { lock.unlock(); return }
            if serial != mySerial {
                mySerial = serial
                sentFlush = false
                lock.unlock()
                avcodec_flush_buffers(vdec)
                continue
            }
            let pkt = videoPackets.isEmpty ? nil : videoPackets.removeFirst()
            let drop = dropBefore
            lock.unlock()

            if pkt == nil { sentFlush = true }
            _ = avcodec_send_packet(vdec, pkt)
            if pkt != nil { var p = pkt; av_packet_free(&p) }
            while avcodec_receive_frame(vdec, frame) == 0 {
                defer { av_frame_unref(frame) }
                let ts = frame.pointee.best_effort_timestamp
                guard ts != Self.noPTS else { continue }
                let pts = Double(ts) * videoTimeBase - startTime
                if pts < drop { continue }
                guard let buffer = convert(frame) else { continue }
                lock.lock()
                // 쌓아 둔 프레임이 넘치면 먹을 때까지 기다린다(그 사이 옮기면 버린다)
                while !stopping, serial == mySerial, frames.count >= 4 { lock.wait(until: Date().addingTimeInterval(0.05)) }
                if serial == mySerial, !stopping { frames.append((pts, buffer)) }
                lock.unlock()
            }
            if pkt == nil {
                lock.lock()
                if serial == mySerial { videoDrained = true }
                lock.unlock()
            }
        }
    }

    /// 풀린 프레임을 BGRA CVPixelBuffer(Metal 호환)로. VideoToolbox 프레임은 GPU 로 바꾸고, 소프트웨어 프레임은 swscale 로.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        guard w > 0, h > 0 else { return nil }
        if pool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = (w, h)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = frame.pointee.data.3 {
            let src = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
            if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
            guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: src, to: out) == noErr else { return nil }
            return out
        }
        let src = AVPixelFormat(frame.pointee.format)
        sws = sws_getCachedContext(sws, Int32(w), Int32(h), src, Int32(w), Int32(h), AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
        guard let sws else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        var dst: [UnsafeMutablePointer<UInt8>?] = [CVPixelBufferGetBaseAddress(out)?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        var stride: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(out)), 0, 0, 0]
        let lines = withUnsafePointer(to: &frame.pointee.data) { dataPtr in
            withUnsafePointer(to: &frame.pointee.linesize) { sizePtr in
                dataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { d in
                    sizePtr.withMemoryRebound(to: Int32.self, capacity: 8) { s in
                        sws_scale(sws, d, s, 0, Int32(h), &dst, &stride)
                    }
                }
            }
        }
        return lines > 0 ? out : nil
    }

    // MARK: 디코더

    private static let noPTS = Int64.min   // AV_NOPTS_VALUE

    /// h264·hevc 등은 VideoToolbox 로 풀고, 못 풀면 소프트웨어로
    private static let pickHardware: @convention(c) (UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { _, fmts in
        guard var p = fmts else { return AV_PIX_FMT_NONE }
        let first = p.pointee
        while p.pointee != AV_PIX_FMT_NONE {
            if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
            p += 1
        }
        return first
    }

    private static func openDecoder(_ s: UnsafeMutablePointer<AVStream>, hardware: Bool) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec = avcodec_find_decoder(s.pointee.codecpar.pointee.codec_id),
              let c = avcodec_alloc_context3(codec) else { return nil }
        avcodec_parameters_to_context(c, s.pointee.codecpar)
        c.pointee.pkt_timebase = s.pointee.time_base
        c.pointee.thread_count = 0
        if hardware {
            var hw: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) == 0 {
                c.pointee.hw_device_ctx = av_buffer_ref(hw)
                c.pointee.get_format = pickHardware
                av_buffer_unref(&hw)
            }
        }
        guard avcodec_open2(c, codec, nil) == 0 else {
            var opt: UnsafeMutablePointer<AVCodecContext>? = c
            avcodec_free_context(&opt)
            return nil
        }
        return c
    }
}

/// 자동 자막용: 파일의 한 구간 소리를 ffmpeg 라이브러리로 풀어 1채널 float32 PCM 으로 넘긴다.
/// ffmpeg 엔진으로 트는 파일(mkv·avi 등)은 AVAsset 이 없어 AVAssetReader 를 쓸 수 없으므로 이걸 쓴다.
enum FFmpegAudioReader {
    /// `[start, end)` 초 구간을 `sampleRate` 로 바꿔 몇 천 샘플씩 `onSamples` 에 넘긴다.
    static func read(url: URL, start: Double, end: Double, sampleRate: Double,
                     onSamples: ([Float]) throws -> Void) throws {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, url.path, nil, nil) == 0, let f = fmt else {
            throw TranscriberError.readerFailed("파일을 열 수 없습니다.")
        }
        defer { avformat_close_input(&fmt) }
        guard avformat_find_stream_info(f, nil) >= 0 else { throw TranscriberError.readerFailed("파일 정보를 읽을 수 없습니다.") }
        let index = av_find_best_stream(f, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, let stream = f.pointee.streams[Int(index)],
              let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) else {
            throw TranscriberError.noAudioTrack
        }
        var dec = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&dec) }
        guard let dec, avcodec_parameters_to_context(dec, stream.pointee.codecpar) >= 0 else {
            throw TranscriberError.readerFailed("디코더를 만들 수 없습니다.")
        }
        dec.pointee.pkt_timebase = stream.pointee.time_base
        guard avcodec_open2(dec, codec, nil) == 0 else { throw TranscriberError.readerFailed("디코더를 열 수 없습니다.") }

        let timeBase = av_q2d(stream.pointee.time_base)
        let fileStart = f.pointee.start_time == Int64.min ? 0 : Double(f.pointee.start_time) / Double(AV_TIME_BASE)
        av_seek_frame(f, -1, Int64((max(0, start) + fileStart) * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)

        var swr: OpaquePointer?
        defer { swr_free(&swr) }
        let outRate = Int32(sampleRate.rounded())
        let pkt = av_packet_alloc()!, frame = av_frame_alloc()!
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p)
            var fr: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&fr)
        }
        var done = false
        /// 풀린 프레임 하나를 바꿔 구간 안의 샘플만 넘긴다
        func emit(_ frame: UnsafeMutablePointer<AVFrame>) throws {
            let ts = frame.pointee.best_effort_timestamp
            guard ts != Int64.min, frame.pointee.nb_samples > 0 else { return }
            let pts = Double(ts) * timeBase - fileStart
            if pts >= end { done = true; return }
            if swr == nil {
                var mono = AVChannelLayout()
                av_channel_layout_default(&mono, 1)
                guard swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLT, outRate, &frame.pointee.ch_layout,
                                          AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate, 0, nil) == 0,
                      swr_init(swr) == 0 else { throw TranscriberError.readerFailed("소리 변환을 준비할 수 없습니다.") }
            }
            let capacity = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
            var out = [Float](repeating: 0, count: max(capacity, 1))
            let got: Int32 = out.withUnsafeMutableBytes { raw in
                var dst: UnsafeMutablePointer<UInt8>? = raw.bindMemory(to: UInt8.self).baseAddress
                return withUnsafeMutablePointer(to: &dst) { dstPtr in
                    frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                        swr_convert(swr, dstPtr, Int32(capacity), src, frame.pointee.nb_samples)
                    }
                }
            }
            guard got > 0 else { return }
            out.removeLast(out.count - Int(got))
            // 구간 앞쪽(키프레임부터 읽느라 들어온 것)은 잘라 낸다
            if pts < start {
                let skip = Int(((start - pts) * sampleRate).rounded())
                guard skip < out.count else { return }
                out.removeFirst(skip)
            }
            // 구간 끝을 넘는 부분도 잘라 낸다
            let endIndex = Int(((end - max(pts, start)) * sampleRate).rounded())
            if endIndex < out.count { out.removeLast(out.count - max(endIndex, 0)); done = true }
            if !out.isEmpty { try onSamples(out) }
        }

        while !done {
            if av_read_frame(f, pkt) < 0 {
                avcodec_send_packet(dec, nil)
                while avcodec_receive_frame(dec, frame) == 0, !done { try emit(frame); av_frame_unref(frame) }
                break
            }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == index, avcodec_send_packet(dec, pkt) == 0 else { continue }
            while !done, avcodec_receive_frame(dec, frame) == 0 {
                defer { av_frame_unref(frame) }
                try emit(frame)
            }
        }
    }
}
