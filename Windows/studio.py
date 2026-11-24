import sys, subprocess, os, threading, struct, time
import av
import numpy as np
import pyvirtualcam
from pathlib import Path
from datetime import datetime
import requests
from PySide6.QtCore import Qt, QTimer, Signal, QObject
from PySide6.QtGui import QPixmap, QImage
from PySide6.QtWidgets import *
BASE='http://127.0.0.1:18765'
class Bus(QObject):
    frame=Signal(bytes); status=Signal(str); info=Signal(dict); done=Signal(); busy=Signal(bool); settings_done=Signal(object); virtual_status=Signal(str); virtual_done=Signal()
class Studio(QMainWindow):
    def __init__(self):
        super().__init__(); self.setWindowTitle('iPhone Studio'); self.resize(1250,780); self.bus=Bus(); self.proc=None; self.connected=False; self.polling=False; self.recording=False; self.folder=str(Path.home()/'Videos'); self.original=None; self.latest=None; self.frame_lock=threading.Lock(); self.live_thread=None; self.closing=threading.Event(); self.frame_count=0; self.fps_time=time.monotonic(); self.display_count=0
        self.settings_running=False; self.settings_pending=False; self.loading_info=False; self.last_applied=None; self.virtual_thread=None; self.virtual_stop=threading.Event(); self.virtual_frame=None; self.virtual_time=0; self.operation_lock=threading.Lock(); self.operation_busy=False
        root=QWidget(); self.setCentralWidget(root); layout=QHBoxLayout(root); left=QVBoxLayout(); layout.addLayout(left,4); right=QVBoxLayout(); layout.addLayout(right,1)
        self.preview=QLabel('Подключите iPhone по USB'); self.preview.setAlignment(Qt.AlignCenter); self.preview.setMinimumSize(500,350); self.preview.setStyleSheet('background:#080a0e;color:#8994a6;border-radius:12px'); left.addWidget(self.preview,1)
        self.stats=QLabel('H.264 | ожидание потока'); left.addWidget(self.stats); self.status=QLabel('Нет подключения'); left.addWidget(self.status); bar=QHBoxLayout(); left.addLayout(bar)
        for label,fn in [('Подключить USB',self.connect_usb),('Папка',self.choose),('Начать запись',self.start),('Стоп и сохранить',self.stop)]:
            b=QPushButton(label); b.clicked.connect(fn); bar.addWidget(b)
        self.lens=QComboBox(); self.res=QComboBox(); self.res.addItems(['1280x720','1920x1080','3840x2160']); self.res.setCurrentIndex(1); self.fps=QComboBox(); self.fps.addItems(['24','25','30','60']); self.fps.setCurrentIndex(3)
        self.form=QFormLayout(); right.addLayout(self.form); self.form.addRow('Объектив',self.lens); self.form.addRow('Разрешение',self.res); self.form.addRow('FPS',self.fps)
        self.auto=QCheckBox('Автоэкспозиция'); self.auto.setChecked(True); right.addWidget(self.auto); self.af=QCheckBox('Автофокус'); self.af.setChecked(True); right.addWidget(self.af); self.awb=QCheckBox('Автобаланс белого'); self.awb.setChecked(True); right.addWidget(self.awb)
        self.values={}
        for key,label,lo,hi,val,dec in [('iso','ISO',20,3200,100,0),('shutter','Выдержка 1/',1,8000,60,0),('focus','Фокус',0,1,.5,2),('temperature','Кельвин',2500,10000,5500,0),('ev','Экспокоррекция',-3,3,0,1),('zoom','Зум',1,10,1,1)]:
            w=QDoubleSpinBox(); w.setRange(lo,hi); w.setDecimals(dec); w.setValue(val); self.values[key]=w; self.form.addRow(label,w)
        self.grid=QCheckBox('Сетка 3×3'); right.addWidget(self.grid); self.grid.toggled.connect(lambda _:self.render()); self.settings_label=QLabel('Настройки применяются автоматически'); self.settings_label.setWordWrap(True); right.addWidget(self.settings_label); self.settings_timer=QTimer(self); self.settings_timer.setSingleShot(True); self.settings_timer.setInterval(120); self.settings_timer.timeout.connect(self.apply); self.bus.settings_done.connect(self.settings_finished);
        for widget in (self.lens,self.res,self.fps): widget.currentIndexChanged.connect(self.schedule_settings)
        for widget in (self.auto,self.af,self.awb): widget.toggled.connect(self.schedule_settings)
        for widget in self.values.values(): widget.valueChanged.connect(self.schedule_settings)
        self.virtual_button=QPushButton('Включить виртуальную камеру'); self.virtual_button.setCheckable(True); self.virtual_button.toggled.connect(self.toggle_virtual); right.addWidget(self.virtual_button); self.virtual_fps=QComboBox(); self.virtual_fps.addItems(['30','60']); self.virtual_fps.setCurrentIndex(1); self.form.addRow('OBS FPS',self.virtual_fps); self.virtual_label=QLabel('OBS: выключена'); self.virtual_label.setWordWrap(True); right.addWidget(self.virtual_label); self.bus.virtual_status.connect(self.virtual_label.setText); self.bus.virtual_done.connect(self.virtual_finished); right.addStretch(); self.bus.frame.connect(self.show_frame); self.bus.status.connect(self.status.setText); self.bus.info.connect(self.set_info); self.bus.done.connect(self.poll_done); self.bus.busy.connect(root.setEnabled); self.timer=QTimer(); self.timer.timeout.connect(self.poll); self.timer.setTimerType(Qt.PreciseTimer); self.timer.start(8)
        self.setStyleSheet('QWidget{background:#171b22;color:#e8edf5;font-size:14px} QPushButton,QComboBox,QDoubleSpinBox{background:#293241;padding:8px;border:1px solid #465468;border-radius:6px} QPushButton:hover{background:#394b65} QLabel{padding:4px}')
    def task(self,fn):
        def run():
            try:
                with self.operation_lock: fn()
            except Exception as e: self.bus.status.emit(str(e))
            finally: self.bus.busy.emit(True)
        self.bus.busy.emit(False); threading.Thread(target=run,daemon=True).start()
    def connect_usb(self):
        def run():
            import time
            if self.proc is None or self.proc.poll() is not None:
                self.proc=subprocess.Popen([sys.executable,'-m','pymobiledevice3','usbmux','forward','18765','18765'],creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            for _ in range(15):
                try:
                    data=requests.get(BASE+'/info',timeout=1).json();
                    if data.get('protocol') != 3: raise ValueError('Установите новый IPA версии 3')
                    self.connected=True; self.bus.info.emit(data); self.bus.status.emit('USB подключён'); return
                except ValueError: raise
                except Exception: time.sleep(.4)
            raise RuntimeError('Нет связи. Откройте iPhone Studio на телефоне, подтвердите доверие и проверьте Apple Devices / USB.')
        self.task(run)
    def set_info(self,data):
        self.loading_info=True; self.lens.clear()
        for d in data['cameras']: self.lens.addItem(d['name'],d['id'])
        idx=self.lens.findData(data.get('active')); self.lens.setCurrentIndex(max(0,idx)); self.loading_info=False; self.last_applied=None; self.schedule_settings()
    def poll(self):
        if self.connected and (self.live_thread is None or not self.live_thread.is_alive()) and not self.closing.is_set():
            self.live_thread=threading.Thread(target=self.live,daemon=True); self.live_thread.start()
        with self.frame_lock:
            frame=self.latest; self.latest=None; decoded=self.frame_count
        if frame is not None:
            self.original=QPixmap.fromImage(frame); self.render(); self.display_count+=1
        now=time.monotonic(); elapsed=now-self.fps_time
        if elapsed>=1:
            self.stats.setText(f'H.264 | декодировано {decoded/elapsed:.1f} FPS | показано {self.display_count/elapsed:.1f} FPS')
            with self.frame_lock: self.frame_count-=decoded
            self.display_count=0; self.fps_time=now
    def live(self):
        def exact(raw,n):
            result=bytearray()
            while len(result)<n:
                part=raw.read(n-len(result))
                if not part: raise EOFError('Поток закрыт')
                result.extend(part)
            return bytes(result)
        while not self.closing.is_set():
            try:
                codec=av.CodecContext.create('h264','r'); codec.thread_count=1
                with requests.get(BASE+'/live',stream=True,timeout=(5,5)) as response:
                    response.raise_for_status(); self.bus.status.emit('USB: видеопоток подключён')
                    while not self.closing.is_set():
                        n=struct.unpack('>I',exact(response.raw,4))[0]
                        if not 0<n<=16*1024*1024: raise ValueError('Некорректный пакет')
                        packet=av.Packet(exact(response.raw,n))
                        try: frames=codec.decode(packet)
                        except av.error.FFmpegError: continue
                        for frame in frames:
                            rgb=frame.to_ndarray(format='rgb24')
                            h,w,_=rgb.shape
                            image=QImage(rgb.data,w,h,rgb.strides[0],QImage.Format_RGB888).copy()
                            with self.frame_lock: self.latest=image; self.frame_count+=1; self.virtual_frame=rgb; self.virtual_time=time.monotonic()
            except Exception as e:
                if not self.closing.is_set(): self.bus.status.emit('Поток: '+str(e)+' | переподключение'); self.closing.wait(1)
                if not self.closing.is_set() and self.proc is not None and self.proc.poll() is not None:
                    try: self.proc=subprocess.Popen([sys.executable,'-m','pymobiledevice3','usbmux','forward','18765','18765'],creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                    except OSError as err: self.bus.status.emit(str(err))
    def poll_done(self): pass
    def show_frame(self,data): pass
    def render(self):
        if not self.original:return
        from PySide6.QtGui import QPainter,QPen,QColor
        p=self.original.scaled(self.preview.size(),Qt.KeepAspectRatio,Qt.SmoothTransformation)
        if self.grid.isChecked():
            painter=QPainter(p); painter.setPen(QPen(QColor(255,255,255,130),1)); w,h=p.width(),p.height()
            for i in (1,2):painter.drawLine(w*i//3,0,w*i//3,h); painter.drawLine(0,h*i//3,w,h*i//3)
            painter.end()
        self.preview.setPixmap(p)
    def choose(self):
        f=QFileDialog.getExistingDirectory(self,'Папка записи',self.folder)
        if f:self.folder=f
    def command(self,path,data=None):
        r=requests.post(BASE+path,json=data or {},timeout=20); r.raise_for_status(); result=r.json();
        if not result.get('ok'):raise RuntimeError(result.get('error','Ошибка камеры'))
        return result
    def schedule_settings(self,*_):
        if self.loading_info: return
        self.values['iso'].setEnabled(not self.auto.isChecked()); self.values['shutter'].setEnabled(not self.auto.isChecked()); self.values['ev'].setEnabled(self.auto.isChecked()); self.values['focus'].setEnabled(not self.af.isChecked()); self.values['temperature'].setEnabled(not self.awb.isChecked())
        if self.connected: self.settings_pending=True; self.settings_timer.start()
    def apply(self):
        if not self.connected or self.settings_running or not self.settings_pending: return
        data={k:v.value() for k,v in self.values.items()}; data.update(camera=self.lens.currentData(),resolution=self.res.currentText(),fps=int(self.fps.currentText()),autoExposure=self.auto.isChecked(),autoFocus=self.af.isChecked(),autoWB=self.awb.isChecked())
        if not data['camera']: return
        self.settings_pending=False
        if data==self.last_applied: return
        self.settings_running=True; self.settings_label.setText('Применение…')
        def run():
            try:
                with self.operation_lock: self.command('/settings',data)
                self.bus.settings_done.emit((data,None))
            except Exception as e: self.bus.settings_done.emit((data,str(e)))
        threading.Thread(target=run,daemon=True).start()
    def settings_finished(self,result):
        data,error=result; self.settings_running=False
        if error: self.settings_label.setText('Не применено: '+error)
        else: self.last_applied=data; self.settings_label.setText('Настройки применены')
        if self.settings_pending: self.settings_timer.start()
    def toggle_virtual(self,enabled):
        if not enabled: self.virtual_stop.set(); self.virtual_button.setEnabled(False); return
        if self.virtual_thread and self.virtual_thread.is_alive(): return
        self.virtual_stop.clear(); self.virtual_fps.setEnabled(False); fps=int(self.virtual_fps.currentText())
        self.virtual_thread=threading.Thread(target=self.virtual_loop,args=(fps,),daemon=True); self.virtual_thread.start()
    def virtual_loop(self,fps):
        try:
            with pyvirtualcam.Camera(width=1920,height=1080,fps=fps,fmt=pyvirtualcam.PixelFormat.RGB,backend='unitycapture') as cam:
                self.bus.virtual_status.emit('OBS: '+cam.device+' | 1080p '+str(fps)+' FPS')
                blank=np.zeros((1080,1920,3),dtype=np.uint8); last=None; output=blank
                while not self.virtual_stop.is_set() and not self.closing.is_set():
                    with self.frame_lock: rgb=self.virtual_frame; age=time.monotonic()-self.virtual_time
                    if rgb is None or age>2: output=blank; last=None
                    elif rgb is not last:
                        h,w=rgb.shape[:2]; scale=min(1920/w,1080/h); nw=max(1,int(w*scale)); nh=max(1,int(h*scale))
                        if (w,h)==(1920,1080): output=np.ascontiguousarray(rgb)
                        else:
                            resized=av.VideoFrame.from_ndarray(rgb,format='rgb24').reformat(width=nw,height=nh,format='rgb24').to_ndarray(); output=blank.copy(); x=(1920-nw)//2; y=(1080-nh)//2; output[y:y+nh,x:x+nw]=resized
                        last=rgb
                    cam.send(output); cam.sleep_until_next_frame()
            self.bus.virtual_status.emit('OBS: выключена')
        except Exception as e: self.bus.virtual_status.emit('OBS: '+str(e)+' | Проверьте Unity Capture')
        finally: self.bus.virtual_done.emit()
    def virtual_finished(self):
        self.virtual_button.blockSignals(True); self.virtual_button.setChecked(False); self.virtual_button.blockSignals(False); self.virtual_fps.setEnabled(True); self.virtual_button.setEnabled(True)
    def start(self):
        if not self.connected:return
        def run():self.command('/start'); self.recording=True; self.bus.status.emit('● REC — запись на iPhone')
        self.task(run)
    def stop(self):
        if not self.connected:return
        folder=self.folder
        def run():
            self.command('/stop'); self.recording=False; p=Path(folder)/('iPhone_'+datetime.now().strftime('%Y%m%d_%H%M%S')+'.mov'); p.parent.mkdir(parents=True,exist_ok=True)
            with requests.get(BASE+'/video',stream=True,timeout=120) as r:
                r.raise_for_status()
                with open(str(p)+'.part','wb') as f:
                    for chunk in r.iter_content(1024*1024):f.write(chunk)
            os.replace(str(p)+'.part',p); self.bus.status.emit('Сохранено: '+str(p))
        self.task(run)
    def closeEvent(self,e):
        self.closing.set(); self.virtual_stop.set()
        if self.proc:self.proc.terminate()
        e.accept()
app=QApplication(sys.argv); win=Studio(); win.show(); sys.exit(app.exec())
