import SwiftUI
import AVFoundation
import Network
import CoreImage
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
    var jpeg = Data(), lastFrame = Date.distantPast, listener: NWListener?, input: AVCaptureDeviceInput?, audio: AVCaptureDeviceInput?, booted = false
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
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrame)>0.08, let px=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}; lastFrame=Date()
        var image=CIImage(cvPixelBuffer:px); let scale=min(1,960/image.extent.width); image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=ci.createCGImage(image,from:image.extent), let data=UIImage(cgImage:cg).jpegData(compressionQuality:0.65) else{return}; lock.lock(); jpeg=data; lock.unlock()
    }
    func configure(_ p:[String:Any]) throws {
        guard !movie.isRecording, pendingStart == nil, pendingStop == nil else {throw Fail("Остановите запись")}
        guard let id=p["camera"] as? String, let device=cameras().first(where:{$0.uniqueID==id}), let res=p["resolution"] as? String, let fps=p["fps"] as? Int else {throw Fail("Неверные параметры")}
        let dims=res.split(separator:"x").compactMap{Int32($0)}; guard dims.count==2 else{throw Fail("Неверное разрешение")}
        guard let format=device.formats.first(where:{ f in let d=CMVideoFormatDescriptionGetDimensions(f.formatDescription); return d.width==dims[0] && d.height==dims[1] && f.videoSupportedFrameRateRanges.contains{ $0.minFrameRate<=Double(fps) && $0.maxFrameRate>=Double(fps) } }) else{throw Fail("Объектив не поддерживает это разрешение/FPS")}
        if input?.device.uniqueID != id {
            let new=try AVCaptureDeviceInput(device:device); session.beginConfiguration(); let old=input; if let old=old {session.removeInput(old)}
            guard session.canAddInput(new) else {if let old=old,session.canAddInput(old){session.addInput(old)};session.commitConfiguration();throw Fail("Нельзя переключить объектив")};session.addInput(new);input=new;session.commitConfiguration()
        }
        try device.lockForConfiguration(); defer{device.unlockForConfiguration()}
        device.activeFormat=format; let duration=CMTime(value:1,timescale:Int32(fps));device.activeVideoMinFrameDuration=duration;device.activeVideoMaxFrameDuration=duration
        func n(_ k:String,_ fallback:Double)->Double{(p[k] as? NSNumber)?.doubleValue ?? fallback}
        if p["autoFocus"] as? Bool == true {if device.isFocusModeSupported(.continuousAutoFocus){device.focusMode = .continuousAutoFocus}} else if device.isLockingFocusWithCustomLensPositionSupported {device.setFocusModeLocked(lensPosition:Float(min(1,max(0,n("focus",0.5)))),completionHandler:nil)} else {throw Fail("Ручной фокус недоступен")}
        if p["autoExposure"] as? Bool == true {if device.isExposureModeSupported(.continuousAutoExposure){device.exposureMode = .continuousAutoExposure};device.setExposureTargetBias(Float(min(Double(device.maxExposureTargetBias),max(Double(device.minExposureTargetBias),n("ev",0)))),completionHandler:nil)} else if device.isExposureModeSupported(.custom){let seconds=min(min(CMTimeGetSeconds(format.maxExposureDuration),1/Double(fps)),max(CMTimeGetSeconds(format.minExposureDuration),1/max(1,n("shutter",60))));device.setExposureModeCustom(duration:CMTime(seconds:seconds,preferredTimescale:1000000),iso:Float(min(Double(format.maxISO),max(Double(format.minISO),n("iso",100)))),completionHandler:nil)} else {throw Fail("Ручная экспозиция недоступна")}
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
        if method=="GET" && path=="/preview"{lock.lock();let d=jpeg;lock.unlock();send(c,d,"image/jpeg",d.isEmpty ? "503 Waiting":"200 OK");return}
        queue.async{let reply:(Data)->Void={self.send(c,$0)};switch (method,path){
        case ("GET","/info"):reply(self.json(["cameras":self.cameras().map{["id":$0.uniqueID,"name":$0.localizedName]},"active":self.input?.device.uniqueID ?? ""]))
        case ("POST","/settings"):do{try self.configure((try JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:]);reply(self.ok())}catch{reply(self.error(error.localizedDescription))}
        case ("POST","/start"):guard !self.movie.isRecording,self.pendingStart==nil,self.pendingStop==nil else{reply(self.error("Уже идёт запись"));return};self.pendingStart=reply;let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mov");self.movie.startRecording(to:url,recordingDelegate:self)
        case ("POST","/stop"):guard self.movie.isRecording,self.pendingStop==nil else{reply(self.error("Нет активной записи"));return};self.pendingStop=reply;self.movie.stopRecording()
        case ("GET","/video"):if let url=self.finishedURL{self.stream(c,url)}else{self.send(c,self.error("Нет видео"),"application/json","404 Not Found")}
        default:self.send(c,self.error("Unknown route"),"application/json","404 Not Found")}}
    }
}
