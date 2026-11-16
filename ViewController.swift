import UIKit
import AVFoundation
import VideoToolbox
import Network
import CoreMedia
import CoreVideo

final class ViewController: UIViewController,
                            AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Configuration

    private let port: NWEndpoint.Port = 8888
    private let targetFPS: Double = 60
    private let targetBitrate = 10_000_000

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(
        label: "camera.session",
        qos: .userInitiated
    )

    private let encodeQueue = DispatchQueue(
        label: "camera.encoder",
        qos: .userInteractive
    )

    private let networkQueue = DispatchQueue(
        label: "camera.network",
        qos: .userInitiated
    )

    // Access only from sessionQueue
    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var locksEnabled = false

    // Access only from encodeQueue
    private var compressionSession: VTCompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var forceKeyframe = true

    // Access only from networkQueue
    private var listener: NWListener?
    private var client: NWConnection?
    private var clientReady = false
    private var sending = false
    private var waitingForKeyframe = true

    // MARK: - UI

    private var previewLayer: AVCaptureVideoPreviewLayer!

    private let topBar = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemThinMaterialDark)
    )

    private let wideButton = UIButton(type: .system)
    private let teleButton = UIButton(type: .system)
    private let frontButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()

    private var selectedCamera = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        setupPreview()
        setupUI()
        updateButtons()

        startTCPServer()
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        UIApplication.shared.isIdleTimerDisabled = false

        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            self.encodeQueue.sync {
                self.destroyEncoder()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard isViewLoaded else { return }

        sessionQueue.async {
            if self.currentInput != nil &&
               !self.captureSession.isRunning {
                self.captureSession.startRunning()

                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
        }
    }

    deinit {
        listener?.cancel()
        client?.cancel()
    }

    // MARK: - Preview

    private func setupPreview() {
        previewLayer = AVCaptureVideoPreviewLayer(
            session: captureSession
        )

        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = UIColor.black.cgColor

        view.layer.addSublayer(previewLayer)
    }

    // MARK: - UI Setup

    private func setupUI() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.layer.cornerRadius = 18
        topBar.clipsToBounds = true

        view.addSubview(topBar)

        let stack = UIStackView(arrangedSubviews: [
            wideButton,
            teleButton,
            frontButton,
            lockButton
        ])

        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        topBar.contentView.addSubview(stack)

        configureButton(
            wideButton,
            title: "1x",
            action: #selector(selectWide)
        )

        configureButton(
            teleButton,
            title: "2x",
            action: #selector(selectTele)
        )

        configureButton(
            frontButton,
            title: "Ön",
            action: #selector(selectFront)
        )

        configureButton(
            lockButton,
            title: "AE/AWB",
            action: #selector(toggleLocks)
        )

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(
            ofSize: 14,
            weight: .semibold
        )
        statusLabel.textAlignment = .center
        statusLabel.text = "Kamera hazırlanıyor..."
        statusLabel.numberOfLines = 0

        detailLabel.textColor = .lightGray
        detailLabel.font = .monospacedSystemFont(
            ofSize: 11,
            weight: .medium
        )
        detailLabel.textAlignment = .center
        detailLabel.text = "TCP :8888"
        detailLabel.numberOfLines = 0

        let bottomStack = UIStackView(arrangedSubviews: [
            statusLabel,
            detailLabel
        ])

        bottomStack.axis = .vertical
        bottomStack.spacing = 6
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomBackground = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemThinMaterialDark)
        )

        bottomBackground.translatesAutoresizingMaskIntoConstraints = false
        bottomBackground.layer.cornerRadius = 16
        bottomBackground.clipsToBounds = true

        view.addSubview(bottomBackground)
        bottomBackground.contentView.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 10
            ),
            topBar.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 12
            ),
            topBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -12
            ),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            stack.leadingAnchor.constraint(
                equalTo: topBar.contentView.leadingAnchor,
                constant: 6
            ),
            stack.trailingAnchor.constraint(
                equalTo: topBar.contentView.trailingAnchor,
                constant: -6
            ),
            stack.topAnchor.constraint(
                equalTo: topBar.contentView.topAnchor,
                constant: 5
            ),
            stack.bottomAnchor.constraint(
                equalTo: topBar.contentView.bottomAnchor,
                constant: -5
            ),

            bottomBackground.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 16
            ),
            bottomBackground.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -16
            ),
            bottomBackground.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -12
            ),

            bottomStack.leadingAnchor.constraint(
                equalTo: bottomBackground.contentView.leadingAnchor,
                constant: 12
            ),
            bottomStack.trailingAnchor.constraint(
                equalTo: bottomBackground.contentView.trailingAnchor,
                constant: -12
            ),
            bottomStack.topAnchor.constraint(
                equalTo: bottomBackground.contentView.topAnchor,
                constant: 10
            ),
            bottomStack.bottomAnchor.constraint(
                equalTo: bottomBackground.contentView.bottomAnchor,
                constant: -10
            )
        ])
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        action: Selector
    ) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(
            ofSize: 13,
            weight: .semibold
        )

        button.layer.cornerRadius = 10
        button.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        button.addTarget(
            self,
            action: action,
            for: .touchUpInside
        )
    }

    private func updateButtons() {
        let buttons = [
            wideButton,
            teleButton,
            frontButton
        ]

        for (index, button) in buttons.enumerated() {
            button.backgroundColor =
                selectedCamera == index
                ? UIColor.systemBlue
                : UIColor.white.withAlphaComponent(0.10)
        }

        lockButton.backgroundColor =
            locksEnabled
            ? UIColor.systemOrange
            : UIColor.white.withAlphaComponent(0.10)
    }

    private func setStatus(
        _ message: String,
        detail: String? = nil
    ) {
        DispatchQueue.main.async {
            self.statusLabel.text = message

            if let detail {
                self.detailLabel.text = detail
            }
        }
    }

    // MARK: - Camera Permission

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera(
                type: .builtInWideAngleCamera,
                position: .back,
                index: 0
            )

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) {
                [weak self] allowed in

                guard let self else { return }

                if allowed {
                    self.configureCamera(
                        type: .builtInWideAngleCamera,
                        position: .back,
                        index: 0
                    )
                } else {
                    self.setStatus("Kamera izni verilmedi")
                }
            }

        default:
            setStatus(
                "Kamera izni gerekli",
                detail: "Ayarlar > Gizlilik > Kamera"
            )
        }
    }

    // MARK: - Camera Selection

    @objc private func selectWide() {
        configureCamera(
            type: .builtInWideAngleCamera,
            position: .back,
            index: 0
        )
    }

    @objc private func selectTele() {
        configureCamera(
            type: .builtInTelephotoCamera,
            position: .back,
            index: 1
        )
    }

    @objc private func selectFront() {
        configureCamera(
            type: .builtInWideAngleCamera,
            position: .front,
            index: 2
        )
    }

    private func configureCamera(
        type: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position,
        index: Int
    ) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(
                type,
                for: .video,
                position: position
            ) else {
                self.setStatus("Seçilen fiziksel kamera bulunamadı")
                return
            }

            guard let format = self.bestFormat(for: device) else {
                self.setStatus(
                    "4:3 / 60 FPS desteklenmiyor",
                    detail: "\(device.localizedName) için uygun format yok"
                )
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(
                    device: device
                )

                self.captureSession.beginConfiguration()

                // Do not let session presets override activeFormat.
                self.captureSession.sessionPreset = .inputPriority

                if let oldInput = self.currentInput {
                    self.captureSession.removeInput(oldInput)
                }

                guard self.captureSession.canAddInput(newInput) else {
                    if let oldInput = self.currentInput {
                        self.captureSession.addInput(oldInput)
                    }

                    self.captureSession.commitConfiguration()
                    self.setStatus("Kamera girişi eklenemedi")
                    return
                }

                self.captureSession.addInput(newInput)

                if !self.captureSession.outputs.contains(
                    self.videoOutput
                ) {
                    self.videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            Int(
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            )
                    ]

                    self.videoOutput.alwaysDiscardsLateVideoFrames = true

                    self.videoOutput.setSampleBufferDelegate(
                        self,
                        queue: self.encodeQueue
                    )

                    guard self.captureSession.canAddOutput(
                        self.videoOutput
                    ) else {
                        self.captureSession.removeInput(newInput)

                        if let oldInput = self.currentInput {
                            self.captureSession.addInput(oldInput)
                        }

                        self.captureSession.commitConfiguration()
                        self.setStatus("Video çıkışı eklenemedi")
                        return
                    }

                    self.captureSession.addOutput(self.videoOutput)
                }

                try device.lockForConfiguration()

                device.activeFormat = format

                let frameDuration = CMTime(
                    value: 1,
                    timescale: 60
                )

                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration

                device.isSubjectAreaChangeMonitoringEnabled = false

                self.applyLocks(to: device)
                device.unlockForConfiguration()

                if let connection = self.videoOutput.connection(
                    with: .video
                ) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }

                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = position == .front
                    }
                }

                self.captureSession.commitConfiguration()

                self.currentInput = newInput
                self.currentDevice = device

                // Encoder is accessed only on encodeQueue.
                self.encodeQueue.sync {
                    self.destroyEncoder()
                    self.forceKeyframe = true
                }

                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }

                let dimensions =
                    CMVideoFormatDescriptionGetDimensions(
                        format.formatDescription
                    )

                self.setStatus(
                    "Kamera aktif · 60 FPS",
                    detail:
                        "\(dimensions.width)x\(dimensions.height) · 4:3 · TCP :8888"
                )

                DispatchQueue.main.async {
                    self.selectedCamera = index
                    self.updateButtons()
                    UIApplication.shared.isIdleTimerDisabled = true

                    if let previewConnection =
                        self.previewLayer.connection,
                       previewConnection.isVideoOrientationSupported {
                        previewConnection.videoOrientation = .portrait
                    }

                    if let previewConnection =
                        self.previewLayer.connection,
                       previewConnection.isVideoMirroringSupported {
                        previewConnection.automaticallyAdjustsVideoMirroring =
                            false
                        previewConnection.isVideoMirrored =
                            position == .front
                    }
                }

            } catch {
                self.setStatus(
                    "Kamera başlatılamadı",
                    detail: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Strict 4:3 + 60 FPS Selection

    private func bestFormat(
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.Format? {

        let candidates = device.formats.compactMap {
            format -> (
                format: AVCaptureDevice.Format,
                score: Double
            )? in

            let dimensions =
                CMVideoFormatDescriptionGetDimensions(
                    format.formatDescription
                )

            let width = Double(dimensions.width)
            let height = Double(dimensions.height)

            let longSide = max(width, height)
            let shortSide = min(width, height)

            guard shortSide > 0 else { return nil }

            let aspect = longSide / shortSide

            // Strict 4:3, not cropped 16:9
            guard abs(aspect - 4.0 / 3.0) < 0.015 else {
                return nil
            }

            let supports60 =
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 60.0 &&
                    $0.maxFrameRate >= 60.0
                }

            guard supports60 else { return nil }

            // Prefer common 4:3 streaming dimensions.
            let preferredSizes: [(Double, Double)] = [
                (1440, 1080),
                (1920, 1440)
            ]

            let exactIndex = preferredSizes.firstIndex {
                abs(longSide - $0.0) < 1 &&
                abs(shortSide - $0.1) < 1
            }

            let score: Double

            if let exactIndex {
                score = Double(exactIndex)
            } else {
                // Other genuine 4:3/60 formats are allowed.
                // Prefer dimensions closest to 1440x1080.
                let pixelCount = width * height
                let target = 1440.0 * 1080.0

                score = 10 + abs(
                    log(max(pixelCount, 1) / target)
                )
            }

            return (format, score)
        }

        return candidates.min {
            $0.score < $1.score
        }?.format
    }

    // MARK: - AE / AWB Lock

    @objc private func toggleLocks() {
        sessionQueue.async {
            guard let device = self.currentDevice else {
                return
            }

            do {
                try device.lockForConfiguration()
                self.locksEnabled.toggle()

                self.applyLocks(to: device)

                device.unlockForConfiguration()

                let enabled = self.locksEnabled

                DispatchQueue.main.async {
                    self.updateButtons()
                    self.statusLabel.text =
                        enabled
                        ? "AE / AWB kilitli"
                        : "Otomatik pozlama aktif"
                }
            } catch {
                self.setStatus(
                    "Pozlama kilidi başarısız",
                    detail: error.localizedDescription
                )
            }
        }
    }

    // Caller must hold device configuration lock.
    private func applyLocks(to device: AVCaptureDevice) {
        if locksEnabled {
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }

            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        } else {
            if device.isExposureModeSupported(
                .continuousAutoExposure
            ) {
                device.exposureMode = .continuousAutoExposure
            }

            if device.isWhiteBalanceModeSupported(
                .continuousAutoWhiteBalance
            ) {
                device.whiteBalanceMode =
                    .continuousAutoWhiteBalance
            }
        }
    }

    // MARK: - VideoToolbox Encoder

    private static let compressionCallback:
        VTCompressionOutputCallback = {
            refCon,
            _,
            status,
            _,
            sampleBuffer in

            guard status == noErr,
                  let refCon,
                  let sampleBuffer else {
                return
            }

            let controller =
                Unmanaged<ViewController>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()

            controller.handleEncodedSample(sampleBuffer)
        }

    // Must run on encodeQueue.
    private func createEncoder(
        width: Int,
        height: Int
    ) -> Bool {

        destroyEncoder()

        var encoder: VTCompressionSession?

        let result = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &encoder
        )

        guard result == noErr, let encoder else {
            setStatus(
                "H.264 encoder oluşturulamadı",
                detail: "VideoToolbox hata kodu: \(result)"
            )
            return false
        }

        compressionSession = encoder
        encoderWidth = width
        encoderHeight = height

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: targetBitrate)
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: 60)
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: 60)
        )

        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 1.0)
        )

        let prepareResult =
            VTCompressionSessionPrepareToEncodeFrames(encoder)

        if prepareResult != noErr {
            setStatus(
                "H.264 encoder hazırlanamadı",
                detail: "VideoToolbox: \(prepareResult)"
            )

            destroyEncoder()
            return false
        }

        forceKeyframe = true
        return true
    }

    // Must run on encodeQueue.
    private func destroyEncoder() {
        if let encoder = compressionSession {
            VTCompressionSessionCompleteFrames(
                encoder,
                untilPresentationTimeStamp: .invalid
            )

            VTCompressionSessionInvalidate(encoder)
        }

        compressionSession = nil
        encoderWidth = 0
        encoderHeight = 0
    }

    // MARK: - Capture Delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer =
            CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if compressionSession == nil ||
           encoderWidth != width ||
           encoderHeight != height {

            guard createEncoder(
                width: width,
                height: height
            ) else {
                return
            }
        }

        guard let encoder = compressionSession else {
            return
        }

        let presentationTime =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let duration = CMSampleBufferGetDuration(sampleBuffer)

        let properties: CFDictionary?

        if forceKeyframe {
            properties = NSDictionary(
                dictionary: [
                    kVTEncodeFrameOptionKey_ForceKeyFrame
                        as String: true
                ]
            ) as CFDictionary

            forceKeyframe = false
        } else {
            properties = nil
        }

        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            forceKeyframe = true
        }
    }

    // MARK: - H.264 Annex-B Packaging

    private func handleEncodedSample(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer =
                CMSampleBufferGetDataBuffer(sampleBuffer),
              let format =
                CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        let isKeyframe =
            CMGetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                attachmentModeOut: nil
            ) == nil

        var annexB = Data()

        let startCode = Data([0, 0, 0, 1])

        // Prepend SPS and PPS to every access unit.
        for index in 0..<2 {
            var parameterPointer:
                UnsafePointer<UInt8>?

            var parameterSize = 0

            let result =
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointer: &parameterPointer,
                    parameterSetSize: &parameterSize,
                    parameterSetCount: nil,
                    nalUnitHeaderLength: nil
                )

            if result == noErr,
               let pointer = parameterPointer,
               parameterSize > 0 {

                annexB.append(startCode)

                annexB.append(
                    pointer,
                    count: parameterSize
                )
            }
        }

        // VideoToolbox outputs length-prefixed AVCC NAL units.
        // Convert each NAL unit to Annex-B.
        let totalLength = CMBlockBufferGetDataLength(
            blockBuffer
        )

        guard totalLength > 4 else { return }

        var bytes = [UInt8](
            repeating: 0,
            count: totalLength
        )

        let copyStatus = bytes.withUnsafeMutableBytes {
            buffer -> OSStatus in

            guard let base = buffer.baseAddress else {
                return -1
            }

            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: base
            )
        }

        guard copyStatus == noErr else { return }

        var offset = 0

        while offset + 4 <= bytes.count {
            let length =
                (Int(bytes[offset]) << 24) |
                (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) |
                Int(bytes[offset + 3])

            offset += 4

            guard length > 0,
                  length <= bytes.count - offset else {
                return
            }

            annexB.append(startCode)

            annexB.append(
                contentsOf: bytes[offset..<(offset + length)]
            )

            offset += length
        }

        guard offset == bytes.count else { return }

        networkQueue.async {
            self.sendEncodedFrame(
                annexB,
                isKeyframe: isKeyframe
            )
        }
    }

    // MARK: - TCP Listener

    private func startTCPServer() {
        networkQueue.async {
            do {
                let parameters = NWParameters.tcp

                if let tcp = parameters.defaultProtocolStack
                    .transportProtocol as? NWProtocolTCP.Options {
                    tcp.noDelay = true
                }

                let listener = try NWListener(
                    using: parameters,
                    on: self.port
                )

                self.listener = listener

                listener.stateUpdateHandler = {
                    [weak self] state in

                    switch state {
                    case .ready:
                        self?.setStatus(
                            "TCP sunucusu hazır",
                            detail: "Port 8888 · USB bağlantısı bekleniyor"
                        )

                    case .failed(let error):
                        self?.setStatus(
                            "TCP dinleyici hatası",
                            detail: error.localizedDescription
                        )

                    default:
                        break
                    }
                }

                listener.newConnectionHandler = {
                    [weak self] connection in

                    self?.acceptConnection(connection)
                }

                listener.start(queue: self.networkQueue)

            } catch {
                self.setStatus(
                    "TCP sunucusu başlatılamadı",
                    detail: error.localizedDescription
                )
            }
        }
    }

    // Must run on networkQueue.
    private func acceptConnection(
        _ connection: NWConnection
    ) {
        // Only one subscriber at a time.
        client?.cancel()

        client = connection
        clientReady = false
        sending = false
        waitingForKeyframe = true

        connection.stateUpdateHandler = {
            [weak self, weak connection] state in

            guard let self,
                  let connection,
                  self.client === connection else {
                return
            }

            switch state {
            case .ready:
                self.clientReady = true
                self.sending = false
                self.waitingForKeyframe = true

                self.encodeQueue.async {
                    self.forceKeyframe = true
                }

                self.setStatus(
                    "USB / TCP istemcisi bağlı",
                    detail: "H.264 Annex-B · 60 FPS hedefi"
                )

                self.monitorConnection(connection)

            case .failed, .cancelled:
                self.removeConnection(connection)

            default:
                break
            }
        }

        connection.start(queue: networkQueue)
    }

    // Detect EOF or disconnection.
    private func monitorConnection(
        _ connection: NWConnection
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1024
        ) { [weak self, weak connection]
            _, _, isComplete, error in

            guard let self,
                  let connection,
                  self.client === connection else {
                return
            }

            if isComplete || error != nil {
                self.removeConnection(connection)
                return
            }

            self.monitorConnection(connection)
        }
    }

    // Must run on networkQueue.
    private func removeConnection(
        _ connection: NWConnection
    ) {
        guard client === connection else { return }

        clientReady = false
        sending = false
        waitingForKeyframe = true
        client = nil

        connection.cancel()

        setStatus(
            "İstemci bağlantısı kesildi",
            detail: "TCP :8888 · Yeniden bağlantı bekleniyor"
        )
    }

    // MARK: - Low Latency Backpressure

    // Must run on networkQueue.
    private func sendEncodedFrame(
        _ frame: Data,
        isKeyframe: Bool
    ) {
        guard let connection = client,
              clientReady else {
            return
        }

        // Never build an unbounded network queue.
        if sending {
            waitingForKeyframe = true

            encodeQueue.async {
                self.forceKeyframe = true
            }

            return
        }

        // After frame loss, resume at an IDR frame.
        if waitingForKeyframe {
            guard isKeyframe else {
                return
            }

            waitingForKeyframe = false
        }

        sending = true

        connection.send(
            content: frame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed {
                [weak self, weak connection] error in

                guard let self,
                      let connection,
                      self.client === connection else {
                    return
                }

                self.sending = false

                if error != nil {
                    self.removeConnection(connection)
                }
            }
        )
    }
}
