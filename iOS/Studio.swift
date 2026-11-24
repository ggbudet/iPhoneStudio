import SwiftUI
import AVFoundation
import Network
import CoreImage
import VideoToolbox
import UIKit

@main struct StudioApp: App {
    @StateObject private var camera = Camera()
    var body: some Scene { WindowGroup { VStack(spacing: 24) {
        Image(systemName: "video.circle").font(.system(size: 80))
        Text("iPhone Studio").font(.largeTitle.bold())
        Text(camera.status).multilineTextAlignment(.center)
        Text("Подключите USB, оставьте приложение открытым и разблокированным.").foregroundColor(.secondary).multilineTextAlignment(.center)
    }.padding().onAppear { camera.boot(); UIApplication.shared.isIdleTimerDisabled = true } } }
}
final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    @Published var status = "Ожидание разрешений"
    let queue = DispatchQueue(label: "studio.camera")
    let frames = DispatchQueue(label: "studio.frames")
    let network = DispatchQueue(label: "studio.network")
    let session = AVCaptureSession(), preview = AVCaptureVideoDataOutput(), movie = AVCaptureMovieFileOutput()
    let ci = CIContext(); let lock = NSLock()
    var encoder: VTCompressionSession?, encoderWidth: Int32 = 0, encoderHeight: Int32 = 0
    var streamClient: NWConnection?, streamBusy = false, streamGeneration = 0
    var forceKey = true, previewFPS = 30
    var encoderGeneration = 0
    var listener: NWListener?, input: AVCaptureDeviceInput?, audio: AVCaptureDeviceInput?, booted = false
    var pendingStop: ((Data)->Void)?, pendingStart: ((Data)->Void)?, finishedURL: URL?
    func say(_ s:String) { DispatchQueue.main.async { self.status = s } }
    func cameras() -> [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices }
    func boot() {
        guard !booted else { return }; booted = true
        AVCaptureDevice.requestAccess(for: .video) { yes in
            guard yes else { self.say("Нет разрешения на камеру"); return }
            AVCaptureDevice.requestAccess(for: .audio) { mic in self.queue.async {
                do {
                    self.session.beginConfiguration(); self.session.sessionPreset = .inputPriority
                    guard let d = self.cameras().first(where: {$0.position == .back && $0.deviceType == .builtInWideAngleCamera}) ?? self.cameras().first else { self.session.commitConfiguration(); throw Fail("Нет камеры") }
                    let i = try AVCaptureDeviceInput(device:d); guard self.session.canAddInput(i) else { self.session.commitConfiguration(); throw Fail("Нет входа камеры") }; self.session.addInput(i); self.input=i
                    if mic, let a=AVCaptureDevice.default(for:.audio), let ai=try? AVCaptureDeviceInput(device:a), self.session.canAddInput(ai) { self.session.addInput(ai); self.audio=ai }
                    self.preview.alwaysDiscardsLateVideoFrames=true; self.preview.setSampleBufferDelegate(self,queue:self.frames)
                    guard self.session.canAddOutput(self.preview), self.session.canAddOutput(self.movie) else { self.session.commitConfiguration(); throw Fail("Нет видеовыхода") }
                    self.session.addOutput(self.preview); self.session.addOutput(self.movie); self.session.commitConfiguration(); self.session.startRunning(); try self.serve(); self.say(mic ? "Камера готова. USB порт 18765" : "Камера готова, микрофон запрещён")
                } catch { self.say(error.localizedDescription) }
            } }
        }
    }
    struct Fail: LocalizedError { let message:String; init(_ s:String){message=s}; var errorDescription:String? {message} }
    func json(_ obj:[String:Any])->Data { (try? JSONSerialization.data(withJSONObject:obj)) ?? Data() }
    func ok()->Data {json(["ok":true])}
    func error(_ s:String)->Data {json(["ok":false,"error":s])}
    // All encoder and stream state is confined to the frames queue.
    func resetEncoder() {
        encoderGeneration += 1
        if let e = encoder { VTCompressionSessionInvalidate(e) }; encoder = nil
        forceKey = true
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard streamClient != nil, !streamBusy, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let scale = min(1.0, 1920.0 / Double(max(w,h)))
        let ew = Int32(Double(w)*scale)/2*2, eh = Int32(Double(h)*scale)/2*2
        if encoder == nil || encoderWidth != ew || encoderHeight != eh {
            resetEncoder(); encoderWidth = ew; encoderHeight = eh
            var e: VTCompressionSession?
            let result = VTCompressionSessionCreate(allocator: nil, width: ew, height: eh, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &e)
            guard result == noErr, let e = e else { return }; encoder = e
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 10000000))
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: previewFPS))
            VTSessionSetProperty(e, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: previewFPS))
            VTCompressionSessionPrepareToEncodeFrames(e)
        }
        guard let e = encoder else { return }
        var source = px
        if w != Int(ew) || h != Int(eh) {
            guard let pool = VTCompressionSessionGetPixelBufferPool(e) else { return }
            var resized: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&resized) == kCVReturnSuccess, let resized = resized else { return }
            let image = CIImage(cvPixelBuffer:px).transformed(by:CGAffineTransform(scaleX:CGFloat(ew)/CGFloat(w),y:CGFloat(eh)/CGFloat(h)))
            ci.render(image,to:resized); source = resized
        }
        let generation = streamGeneration, epoch = encoderGeneration
        let props = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let result = VTCompressionSessionEncodeFrame(e, imageBuffer: source, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample = sample, let bytes = Self.annexB(sample) else { return }
            self?.frames.async { [weak self] in guard let self = self, self.encoderGeneration == epoch else { return }; self.pushVideo(bytes, generation) }
        }
        if result != noErr { resetEncoder() }
    }
    static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let fmt = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var count = 0; var length: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length) == noErr, length == 4 else { return nil }
        let prefix = Data([0,0,0,1]); var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary:false) as? [[String:Any]]
        if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true {
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex:i, parameterSetPointerOut:&ptr, parameterSetSizeOut:&size, parameterSetCountOut:nil, nalUnitHeaderLengthOut:nil) == noErr, let ptr = ptr { out.append(prefix); out.append(Data(bytes:ptr,count:size)) }
            }
        }
        let size = CMBlockBufferGetDataLength(block); guard size >= 4 else { return nil }; var raw = Data(count:size)
        let result = raw.withUnsafeMutableBytes { b in CMBlockBufferCopyDataBytes(block, atOffset:0, dataLength:size, destination:b.baseAddress!) }
        guard size >= 4, result == kCMBlockBufferNoErr else { return nil }
        var offset = 0
        while offset+4 <= size {
            let n = Int(raw[offset])<<24 | Int(raw[offset+1])<<16 | Int(raw[offset+2])<<8 | Int(raw[offset+3]); offset += 4
            guard n > 0, n <= size-offset else { return nil }; out.append(prefix); out.append(raw[offset..<offset+n]); offset += n
        }
        return out
    }
    func pushVideo(_ bytes:Data, _ generation:Int) {
        guard generation == streamGeneration, let c = streamClient else { return }
        if streamBusy { forceKey = true; return }
        streamBusy = true
        // Length-prefixed access units avoid parser buffering on the PC.
        var n = UInt32(bytes.count).bigEndian; var packet = withUnsafeBytes(of:&n){Data($0)}; packet.append(bytes)
        c.send(content:packet,completion:.contentProcessed{ [weak self] err in
            self?.frames.async { [weak self] in
                guard let self = self, generation == self.streamGeneration else { return }
                self.streamBusy = false
                if err != nil { c.cancel(); self.streamClient = nil; self.resetEncoder() }
            }
        })
    }
    func openVideo(_ c:NWConnection) {
        frames.async {
            self.streamClient?.cancel(); self.streamGeneration += 1; self.streamClient = c; self.streamBusy = true; self.resetEncoder()
            let generation = self.streamGeneration
            c.send(content:Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n".utf8),completion:.contentProcessed{err in
                self.frames.async { guard generation == self.streamGeneration else { return }; self.streamBusy = false; if err != nil { c.cancel(); self.streamClient = nil } }
            })
        }
    }
    func configure(_ p:[String:Any]) throws {
        guard pendingStart == nil, pendingStop == nil else {throw Fail("Подождите завершения операции записи")}
        guard let id=p["camera"] as? String, let device=cameras().first(where:{$0.uniqueID==id}), let res=p["resolution"] as? String, let fps=p["fps"] as? Int else {throw Fail("Неверные параметры")}
        let dims=res.split(separator:"x").compactMap{Int32($0)}; guard dims.count==2 else{throw Fail("Неверное разрешение")}
        guard let format=device.formats.first(where:{ f in let d=CMVideoFormatDescriptionGetDimensions(f.formatDescription); return d.width==dims[0] && d.height==dims[1] && f.videoSupportedFrameRateRanges.contains{ $0.minFrameRate<=Double(fps) && $0.maxFrameRate>=Double(fps) } }) else{throw Fail("Объектив не поддерживает это разрешение/FPS")}
        let sameDevice = input?.device.uniqueID == id
        let currentDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let sameMode = sameDevice && currentDims.width == dims[0] && currentDims.height == dims[1] && abs(CMTimeGetSeconds(device.activeVideoMinFrameDuration) - 1.0/Double(fps)) < 0.00001 && abs(CMTimeGetSeconds(device.activeVideoMaxFrameDuration) - 1.0/Double(fps)) < 0.00001
        if movie.isRecording && !sameMode { throw Fail("Для смены объектива, разрешения или FPS остановите запись") }
        if !sameDevice {
            let new=try AVCaptureDeviceInput(device:device); session.beginConfiguration(); let old=input; if let old=old {session.removeInput(old)}
            guard session.canAddInput(new) else {if let old=old,session.canAddInput(old){session.addInput(old)};session.commitConfiguration();throw Fail("Нельзя переключить объектив")};session.addInput(new);input=new;session.commitConfiguration()
        }
        try device.lockForConfiguration(); defer{device.unlockForConfiguration()}
        if !sameMode {
            device.activeFormat=format; let duration=CMTime(value:1,timescale:Int32(fps));device.activeVideoMinFrameDuration=duration;device.activeVideoMaxFrameDuration=duration
            frames.async { self.previewFPS = fps; self.resetEncoder() }
        }
        let actualFormat = device.activeFormat
        func n(_ k:String,_ fallback:Double)->Double{(p[k] as? NSNumber)?.doubleValue ?? fallback}
        if p["autoFocus"] as? Bool == true {if device.isFocusModeSupported(.continuousAutoFocus){device.focusMode = .continuousAutoFocus}} else if device.isLockingFocusWithCustomLensPositionSupported {device.setFocusModeLocked(lensPosition:Float(min(1,max(0,n("focus",0.5)))),completionHandler:nil)} else {throw Fail("Ручной фокус недоступен")}
        if p["autoExposure"] as? Bool == true {if device.isExposureModeSupported(.continuousAutoExposure){device.exposureMode = .continuousAutoExposure};device.setExposureTargetBias(Float(min(Double(device.maxExposureTargetBias),max(Double(device.minExposureTargetBias),n("ev",0)))),completionHandler:nil)} else if device.isExposureModeSupported(.custom){let seconds=min(min(CMTimeGetSeconds(actualFormat.maxExposureDuration),1/Double(fps)),max(CMTimeGetSeconds(actualFormat.minExposureDuration),1/max(1,n("shutter",60))));device.setExposureModeCustom(duration:CMTime(seconds:seconds,preferredTimescale:1000000),iso:Float(min(Double(actualFormat.maxISO),max(Double(actualFormat.minISO),n("iso",100)))),completionHandler:nil)} else {throw Fail("Ручная экспозиция недоступна")}
        if p["autoWB"] as? Bool == true {if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance){device.whiteBalanceMode = .continuousAutoWhiteBalance}} else if device.isWhiteBalanceModeSupported(.locked){var g=device.deviceWhiteBalanceGains(for:AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature:Float(n("temperature",5500)),tint:0));let m=device.maxWhiteBalanceGain;g.redGain=min(m,max(1,g.redGain));g.greenGain=min(m,max(1,g.greenGain));g.blueGain=min(m,max(1,g.blueGain));device.setWhiteBalanceModeLocked(with:g,completionHandler:nil)} else {throw Fail("Ручной баланс белого недоступен")}
        device.videoZoomFactor=min(device.maxAvailableVideoZoomFactor,max(device.minAvailableVideoZoomFactor,CGFloat(n("zoom",1))))
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {queue.async{self.pendingStart?(self.ok());self.pendingStart=nil;self.say("● REC")}}
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error err: Error?) {queue.async{let success=err==nil || ((err as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true);if success{self.finishedURL=outputFileURL};let reply=success ? self.ok():self.error(err?.localizedDescription ?? "Ошибка записи");self.pendingStart?(self.error("Запись не запустилась"));self.pendingStart=nil;self.pendingStop?(reply);self.pendingStop=nil;self.say(success ? "Запись готова": "Ошибка записи")}}
    func serve() throws {let params=NWParameters.tcp;params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18765);let l=try NWListener(using:params);listener=l;l.newConnectionHandler={ [weak self] c in guard let self=self else{return};c.start(queue:self.network);self.receive(c,Data())};l.start(queue:network)}
    func receive(_ c:NWConnection,_ old:Data){c.receive(minimumIncompleteLength:1,maximumLength:65536){data,_,done,err in var all=old;if let data=data{all.append(data)};guard all.count<1048576 else{c.cancel();return};if let r=all.range(of:Data("\r\n\r\n".utf8)),let header=String(data:all[..<r.lowerBound],encoding:.utf8){let lines=header.components(separatedBy:"\r\n");let first=lines[0].split(separator:" ");let size=lines.first(where:{$0.lowercased().hasPrefix("content-length:")}).flatMap{Int($0.split(separator:":",maxSplits:1)[1].trimmingCharacters(in:.whitespaces))} ?? 0;if first.count>=2 && all.count-r.upperBound>=size{self.route(c,String(first[0]),String(first[1]),Data(all[r.upperBound..<r.upperBound+size]));return}};if done || err != nil {c.cancel()}else{self.receive(c,all)}}}
    func send(_ c:NWConnection,_ data:Data,_ type:String="application/json",_ code:String="200 OK"){let h=Data("HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8);c.send(content:h+data,completion:.contentProcessed{_ in c.cancel()})}
    func stream(_ c:NWConnection,_ url:URL){do{let f=try FileHandle(forReadingFrom:url);let count=try f.seekToEnd();try f.seek(toOffset:0);let h=Data("HTTP/1.1 200 OK\r\nContent-Type: video/quicktime\r\nContent-Length: \(count)\r\nConnection: close\r\n\r\n".utf8);func next(){do{let d=try f.read(upToCount:262144) ?? Data();if d.isEmpty{try? f.close();c.cancel();return};c.send(content:d,completion:.contentProcessed{err in if err==nil{next()}else{try? f.close();c.cancel()}})}catch{try? f.close();c.cancel()}};c.send(content:h,completion:.contentProcessed{err in if err==nil{next()}else{try? f.close();c.cancel()}})}catch{send(c,self.error(error.localizedDescription),"application/json","500 Error")}}
    func route(_ c:NWConnection,_ method:String,_ path:String,_ body:Data){
        if method=="GET" && path=="/live" { openVideo(c); return }
        queue.async{let reply:(Data)->Void={self.send(c,$0)};switch (method,path){
        case ("GET","/info"):reply(self.json(["cameras":self.cameras().map{["id":$0.uniqueID,"name":$0.localizedName]},"active":self.input?.device.uniqueID ?? "", "protocol":3]))
        case ("POST","/settings"):do{try self.configure((try JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:]);reply(self.ok())}catch{reply(self.error(error.localizedDescription))}
        case ("POST","/start"):guard !self.movie.isRecording,self.pendingStart==nil,self.pendingStop==nil else{reply(self.error("Уже идёт запись"));return};self.pendingStart=reply;let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mov");self.movie.startRecording(to:url,recordingDelegate:self)
        case ("POST","/stop"):guard self.movie.isRecording,self.pendingStop==nil else{reply(self.error("Нет активной записи"));return};self.pendingStop=reply;self.movie.stopRecording()
        case ("GET","/video"):if let url=self.finishedURL{self.stream(c,url)}else{self.send(c,self.error("Нет видео"),"application/json","404 Not Found")}
        default:self.send(c,self.error("Unknown route"),"application/json","404 Not Found")}}
    }
}
