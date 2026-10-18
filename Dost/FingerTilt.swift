import AVFoundation
import Combine
import Vision

/// 전체화면에서만 켜는 카메라 검지 기울이기(모션 감지). 33RUVI 0.2.9 의 FingerTilt 를 옮긴 것.
///
/// 카메라 그림을 거울처럼 뒤집어 화면 가득(비율 유지, 넘치는 쪽은 잘라 냄) 맞췄다고 보고, 검지의 네 관절
/// (뿌리 → 둘째 마디 → 첫째 마디 → 손끝)을 찾는다. 검지가 펴졌다고 볼 만하면(두 마디가 꺾인 각도의 합이 30도 이하),
/// 위를 가리킨 데서 화면 왼쪽으로 30~150도 기울면 뒤로, 오른쪽으로 30~150도 기울면 앞으로(33RUVI 는 30~100도),
/// 그 동안 끊김 없이 1초에 5초씩 옮긴다(장면마다 조금씩). 이때 중지도 펴 있으면 1초에 30초씩 빠르게 옮긴다.
/// 관절 자리는 떨림 거르개(One Euro: 천천히 움직일 땐 많이, 빨리 움직일 땐 적게 거른다)를 거친다.
///
/// 표시는 도트로 한다(DotsOverlayView): 손끝에서 가장 가까운 도트 하나를 켠다 —
/// 검지만 찾으면 흰색, 펴면 액센트 색, 옮기는 중엔 그 도트는 흰색이고 진행 방향 옆 도트가 액센트 색으로 깜빡인다.
/// 빠르게(중지까지 폄)는 두 도트 모두 액센트이고 진행 방향 도트만 깜빡인다.
final class FingerTilt: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = FingerTilt()

    private static let tiltThreshold: Double = 30 // 위를 가리킨 데서 몇 도 넘게 기울면 옮기나
    private static let maxTilt: Double = 150      // 이보다 더 기울면(아래를 가리킴) 옮기지 않는다
    private static let maxBend: Double = 30        // 두 마디(둘째·첫째 마디)가 꺾인 각도의 합이 이 이하면 펴진 것
    private static let speed: Double = 5           // 옮기는 동안 1초에 몇 초씩 옮기나
    private static let fastSpeed: Double = 30      // 중지도 펴 있을 때
    private static let releaseDelay: Double = 0.15    // 잠깐(한두 장면) 놓친 것은 이어 간다

    /// 모션 감지 켜짐·꺼짐(전체화면에서 `m`, View 메뉴, 설정 General). 앱을 다시 켜도 마지막 설정을 따른다.
    static let enabledKey = "24dost.motionSensing"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 손끝 표시 상태
    enum Marker: Equatable {
        case found                  // 검지만 찾음 → 흰 도트
        case straight               // 펴짐 → 액센트 도트
        case moving(Int, fast: Bool) // 옮기는 중(-1 뒤로, 1 앞으로) → 흰 도트(빠르게는 액센트) + 진행 방향 옆 깜빡이는 액센트 도트
    }

    /// 화면에 그릴 손끝(창 안 0~1 비율, 위가 0)과 표시 상태. 없으면 nil.
    @Published private(set) var tip: CGPoint?
    @Published private(set) var marker: Marker = .found

    private let queue = DispatchQueue(label: "24dost.fingertilt")
    private var session: AVCaptureSession?
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private var screenSize = CGSize.zero          // queue 에서 읽는다(start 에서만 바꾼다)
    private var filters: [OneEuro] = []           // 검지 관절 넷의 떨림 거르개(queue 에서만)
    private var lastFound: CFTimeInterval = 0     // queue 에서만
    private var middleFilters: [OneEuro] = []     // 중지 관절 넷의 떨림 거르개(queue 에서만)
    private var middleLastFound: CFTimeInterval = 0

    /// 한 장면에서 본 검지
    private struct Finger {
        var tip: CGPoint                          // 손끝(창 안 0~1 비율, 위가 0)
        var bend: Double                          // 굽힘: 두 마디에서 꺾인 각도의 합(도, 0 = 곧게 폄)
        var tilt: Double                          // 위 = 0도, 화면 오른쪽이 +, 왼쪽이 −
        var middleExtended: Bool                  // 중지도 펴 있는지
    }

    // 아래는 메인 스레드에서만
    private(set) var isRunning = false
    private weak var sampler: VideoSampler?
    private var direction = 0                     // 지금 옮기는 방향(-1 뒤로, 1 앞으로, 0 멈춤)
    private var releasedSince: CFTimeInterval?
    private var position: Double = 0              // 옮기는 동안 옮겨 가는 재생 자리
    private var lastMove: CFTimeInterval = 0

    // MARK: - 켜고 끄기

    @MainActor
    func start(screenSize: CGSize, sampler: VideoSampler) {
        guard !isRunning else { return }
        isRunning = true
        self.screenSize = screenSize
        self.sampler = sampler
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, ok else { return }
                    self.startSession()
                }
            }
        default: break
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false
        tip = nil
        marker = .found
        direction = 0
        releasedSince = nil
        let s = session
        session = nil
        queue.async { s?.stopRunning() }
    }

    private func startSession() {
        guard session == nil, let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        guard s.canAddInput(input) else { return }
        s.addInput(input)
        // 넓게 보기: 가장 큰 가로 포맷(640×480 같은 작은 포맷은 가운데만 잘라 낸 것이라 화각이 좁다)
        if let wide = device.formats.filter({ f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= d.height
        }).max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = wide
            device.unlockForConfiguration()
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { return }
        s.addOutput(output)
        // 카메라가 본 그대로 받고, 거울 뒤집기는 아래에서 직접 한다
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        session = s
        queue.async { s.startRunning() }
    }

    // MARK: - 인식 (queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), screenSize.width > 0 else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        try? handler.perform([handRequest])

        // 거울처럼 뒤집은 카메라 그림을 화면 가득 맞춘 배치(34VITE 와 같다). 결과는 포인트, 위가 0.
        let cam = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let sw = screenSize.width, sh = screenSize.height
        let scale = max(sw / cam.width, sh / cam.height)
        let w = cam.width * scale, h = cam.height * scale
        let ox = (sw - w) / 2, oy = (sh - h) / 2
        func place(_ p: CGPoint) -> SIMD2<Double> {   // Vision 정규화 좌표(아래가 0) → 화면
            SIMD2(Double(ox + (1 - p.x) * w), Double(sh - (oy + p.y * h)))
        }

        var seen: Finger?
        if let hand = handRequest.results?.first {
            let names: [VNHumanHandPoseObservation.JointName] = [.indexMCP, .indexPIP, .indexDIP, .indexTip]
            let raw = names.compactMap { n -> SIMD2<Double>? in
                guard let q = try? hand.recognizedPoint(n), q.confidence > 0.3 else { return nil }
                return place(q.location)
            }
            if raw.count == 4 {
                // 떨림 거르기. 손을 잠깐(0.3초 넘게) 놓쳤다 다시 찾으면 새로 시작한다.
                let now = CACurrentMediaTime()
                if filters.count != 4 || now - lastFound > 0.3 { filters = (0..<4).map { _ in OneEuro() } }
                lastFound = now
                let pts = (0..<4).map { filters[$0].filter(raw[$0], at: now) }
                // 굽힘: 둘째 마디와 첫째 마디에서 앞 마디 방향이 얼마나 꺾였는지의 합.
                // (곧은 거리 ÷ 마디 길이 합은 고르게 60도쯤 휘어도 94% 가 나와 굽힘을 잘 못 가려서 쓰지 않는다)
                func turn(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
                    let u = b - a, v = c - b
                    let n = simd_length(u) * simd_length(v)
                    return n > 0 ? acos(min(max(simd_dot(u, v) / n, -1), 1)) * 180 / .pi : 0
                }
                let bend = turn(pts[0], pts[1], pts[2]) + turn(pts[1], pts[2], pts[3])
                // 기울기: 뿌리 → 손끝 방향. 화면은 위가 0 이라 y 를 뒤집는다.
                let d = pts[3] - pts[0]
                let tilt = atan2(d.x, -d.y) * 180 / .pi
                // 중지: 검지와 같은 굽힘 기준(30도 이하)에 더해, 손끝이 둘째 마디보다 손목에서 확실히 멀어야 펴진 것.
                // (주먹 쥔 중지는 뿌리 마디에서 접혀 둘째·첫째 마디만 보면 곧게 보일 수 있다)
                var middle = false
                let mNames: [VNHumanHandPoseObservation.JointName] = [.middleMCP, .middlePIP, .middleDIP, .middleTip]
                let mRaw = mNames.compactMap { n -> SIMD2<Double>? in
                    guard let q = try? hand.recognizedPoint(n), q.confidence > 0.3 else { return nil }
                    return place(q.location)
                }
                if mRaw.count == 4, let wq = try? hand.recognizedPoint(.wrist), wq.confidence > 0.3 {
                    if middleFilters.count != 4 || now - middleLastFound > 0.3 { middleFilters = (0..<4).map { _ in OneEuro() } }
                    middleLastFound = now
                    let m = (0..<4).map { middleFilters[$0].filter(mRaw[$0], at: now) }
                    let wrist = place(wq.location)
                    middle = turn(m[0], m[1], m[2]) + turn(m[1], m[2], m[3]) <= Self.maxBend
                        && simd_distance(wrist, m[3]) > simd_distance(wrist, m[1]) * 1.15
                }
                let tipPoint = CGPoint(x: pts[3].x / Double(sw), y: pts[3].y / Double(sh))
                seen = Finger(tip: tipPoint, bend: bend, tilt: tilt, middleExtended: middle)
            }
        }
        Task { @MainActor [weak self] in self?.handle(seen) }
    }

    // MARK: - 이동 (메인)

    @MainActor
    private func handle(_ seen: Finger?) {
        guard isRunning else { return }
        var want = 0
        var newMarker = Marker.found
        if let f = seen, f.bend <= Self.maxBend {
            newMarker = .straight
            if abs(f.tilt) >= Self.tiltThreshold, abs(f.tilt) <= Self.maxTilt {
                want = f.tilt < 0 ? -1 : 1
                newMarker = .moving(want, fast: f.middleExtended)
            }
        }
        tip = seen?.tip
        if marker != newMarker { marker = newMarker }
        let now = CACurrentMediaTime()
        guard let v = sampler else { return }
        if want != 0 {
            releasedSince = nil
            if want != direction {
                // 옮기기 시작: 지금 자리에서부터 끊김 없이 옮긴다
                direction = want
                position = v.currentSeconds
                lastMove = now
            }
            // 장면마다(초당 약 30번) 지난 시간만큼 옮긴다. 재생 중이면 그동안 재생된 만큼도 더한다.
            let dt = min(now - lastMove, 0.2)
            lastMove = now
            // 빠르기는 장면마다 그때의 중지로 정한다(옮기는 도중 중지를 펴고 접어도 자리는 이어진다)
            let speed = seen?.middleExtended == true ? Self.fastSpeed : Self.speed
            position += (Double(direction) * speed + (v.isPlaying ? 1 : 0)) * dt
            position = min(max(position, 0), max(v.durationSeconds - 0.25, 0))
            v.scrub(toSeconds: position)
        } else if direction != 0 {
            if releasedSince == nil { releasedSince = now }
            if let t = releasedSince, now - t > Self.releaseDelay { direction = 0; releasedSince = nil }
        }
    }
}

/// One Euro 거르개(Casiez 외, 2012). 움직임이 느리면 세게 걸러 떨림을 없애고, 빠르면 약하게 걸러 늦지 않게 따라간다.
/// 단위는 화면 포인트와 초.
private struct OneEuro {
    var minCutoff: Double = 1.0     // 가만히 있을 때의 차단 주파수(Hz). 작을수록 덜 떨리고 더 늦다
    var beta: Double = 0.02         // 빠르기에 따라 차단 주파수를 올리는 정도
    var derivativeCutoff: Double = 1.0
    private var last: SIMD2<Double>?
    private var lastSpeed = SIMD2<Double>(0, 0)
    private var lastTime: CFTimeInterval = 0

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ x: SIMD2<Double>, at t: CFTimeInterval) -> SIMD2<Double> {
        guard let prev = last else { last = x; lastTime = t; return x }
        let dt = max(t - lastTime, 1.0 / 120)
        lastTime = t
        let speed = (x - prev) / dt
        let ad = Self.alpha(derivativeCutoff, dt)
        lastSpeed = lastSpeed + (speed - lastSpeed) * ad
        let cutoff = minCutoff + beta * simd_length(lastSpeed)
        let a = Self.alpha(cutoff, dt)
        let y = prev + (x - prev) * a
        last = y
        return y
    }
}
