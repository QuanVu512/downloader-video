"""Small desktop front end; all inference runs in a separate bounded worker."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import uuid
from suite_runtime import DATA_ROOT, SETTINGS, use_lock, version

HOME = Path(__file__).resolve().parent
ROOT = DATA_ROOT
DEFAULT_MODEL = Path(os.environ.get("LOCALAPPDATA", "")) / (
    "Programs/Ultimate Vocal Remover/models/MDX_Net_Models/UVR-MDX-NET-Inst_HQ_1.onnx")


class App:
    def __init__(self, root, settings_path=None):
        self.root = root
        self.settings_path = Path(settings_path) if settings_path else SETTINGS
        root.title("Bilibili & Vocal Remover " + version() + " — Tách lời tự động")
        root.geometry("920x730")
        root.minsize(800, 690)
        root.configure(background="#f1f5f9")
        if (HOME / "vocal.ico").exists():
            root.iconbitmap(str(HOME / "vocal.ico"))
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("TFrame", background="#f1f5f9")
        style.configure("TLabel", background="#f1f5f9", foreground="#334155", font=("Segoe UI", 10))
        style.configure("TButton", padding=(12, 7), font=("Segoe UI", 10))
        style.configure("TEntry", padding=7, font=("Segoe UI", 10))
        style.configure("TCombobox", padding=5, font=("Segoe UI", 10))
        style.configure("Accent.TButton", background="#047857", foreground="white", font=("Segoe UI", 11, "bold"), padding=(22, 10))
        style.map("Accent.TButton", background=[("disabled", "#cbd5e1"), ("active", "#065f46")],
                  foreground=[("disabled", "#475569")])
        style.configure("Heading.TLabel", foreground="#0f172a", font=("Segoe UI", 11, "bold"))
        style.configure("Horizontal.TProgressbar", troughcolor="#e2e8f0", background="#059669", thickness=10)
        self.process = None
        self.stop_file = None
        self.closing = False
        self.result = None
        self.advanced_visible = False
        self.last_exit_code = None
        self.messages = queue.Queue()
        self.source = tk.StringVar()
        self.output = tk.StringVar()
        self.model = tk.StringVar(value=str(DEFAULT_MODEL))
        self.seconds = tk.StringVar(value="120")
        self.threads = tk.StringVar(value="2")
        self.status = tk.StringVar(value="Chọn audio hoặc video để bắt đầu.")
        self.percent = tk.StringVar(value="0%")
        self.model_label = tk.StringVar()
        self.controls = []
        self.load_settings()
        header = tk.Frame(root, background="#0f172a", padx=24, pady=16)
        header.pack(fill="x")
        tk.Label(header, text="VOCAL REMOVER AUTO", background="#0f172a", foreground="#6ee7b7",
                 font=("Segoe UI", 10, "bold")).pack(anchor="w")
        tk.Label(header, text="Tách lời cho video dài", background="#0f172a", foreground="white",
                 font=("Segoe UI", 21, "bold")).pack(anchor="w", pady=(3, 2))
        tk.Label(header, text="Chọn một tệp · Tự xử lý từng phần · Nhận một audio nền", background="#0f172a",
                 foreground="#cbd5e1", font=("Segoe UI", 10)).pack(anchor="w")
        frame = ttk.Frame(root, padding=(24, 16))
        frame.pack(fill="both", expand=True)
        for label, variable, browse in [("1. Chọn audio / video gốc", self.source, self.browse_source),
                                         ("2. Lưu audio nền tại", self.output, self.browse_output)]:
            ttk.Label(frame, text=label, style="Heading.TLabel").pack(anchor="w")
            row = ttk.Frame(frame)
            row.pack(fill="x", pady=(2, 9))
            entry = ttk.Entry(row, textvariable=variable)
            entry.pack(side="left", fill="x", expand=True)
            button = ttk.Button(row, text="Chọn…", command=browse)
            button.pack(side="left", padx=(8, 0))
            self.controls.extend([entry, button])
        ttk.Label(frame, textvariable=self.model_label).pack(anchor="w", pady=(3, 0))
        self.model.trace_add("write", lambda *_: self.refresh_model_label())
        self.refresh_model_label()
        self.advanced_toggle = ttk.Button(frame, text="Thiết lập nâng cao ▸", command=self.toggle_advanced)
        self.advanced_toggle.pack(anchor="w", pady=(5, 0))
        self.advanced = ttk.Frame(frame)
        model_row = ttk.Frame(self.advanced)
        model_row.pack(fill="x", pady=(4, 8))
        ttk.Label(model_row, text="Model ONNX:").pack(side="left")
        model_entry = ttk.Entry(model_row, textvariable=self.model)
        model_entry.pack(side="left", fill="x", expand=True, padx=8)
        model_button = ttk.Button(model_row, text="Chọn model…", command=self.browse_model)
        model_button.pack(side="left")
        self.controls.extend([model_entry, model_button])
        row = ttk.Frame(self.advanced)
        row.pack(fill="x", pady=5)
        ttk.Label(row, text="Mỗi phần (giây):").pack(side="left")
        chunks = ttk.Combobox(row, textvariable=self.seconds, values=[30, 60, 120, 180, 300], width=7, state="readonly")
        chunks.pack(side="left", padx=(6, 20))
        ttk.Label(row, text="Luồng CPU:").pack(side="left")
        threads = ttk.Combobox(row, textvariable=self.threads, values=[1, 2, 3, 4], width=5, state="readonly")
        threads.pack(side="left", padx=6)
        self.combos = [chunks, threads]
        ttk.Label(self.advanced, text="Mặc định: CPU 2 luồng, phần 120 giây. Giảm độ dài phần nếu cần tiết kiệm RAM.").pack(anchor="w", pady=4)
        self.action_row = ttk.Frame(frame)
        self.action_row.pack(fill="x", pady=(14, 8))
        row = self.action_row
        self.start_button = ttk.Button(row, text="Bắt đầu / Tiếp tục", command=self.start, style="Accent.TButton")
        self.start_button.pack(side="left")
        self.stop_button = ttk.Button(row, text="Dừng và giữ tiến độ", command=self.stop, state="disabled")
        self.stop_button.pack(side="left", padx=8)
        progress_row = ttk.Frame(frame)
        progress_row.pack(fill="x", pady=(6, 3))
        self.bar = ttk.Progressbar(progress_row, maximum=100)
        self.bar.pack(side="left", fill="x", expand=True)
        ttk.Label(progress_row, textvariable=self.percent, width=7, anchor="e").pack(side="right")
        ttk.Label(frame, textvariable=self.status, wraplength=760).pack(anchor="w", pady=(4, 8))
        results = ttk.Frame(frame)
        results.pack(fill="x", pady=(0, 8))
        self.listen_button = ttk.Button(results, text="Nghe kết quả", command=self.open_result, state="disabled")
        self.listen_button.pack(side="left")
        self.folder_button = ttk.Button(results, text="Mở thư mục kết quả", command=lambda: self.open_result(folder=True), state="disabled")
        self.folder_button.pack(side="left", padx=8)
        ttk.Label(frame, text="Nhật ký", style="Heading.TLabel").pack(anchor="w", pady=(0, 4))
        log_frame = ttk.Frame(frame)
        log_frame.pack(fill="both", expand=True)
        self.log = tk.Text(log_frame, height=4, wrap="word", state="disabled", font=("Consolas", 10),
                           background="white", foreground="#334155", relief="flat", padx=10, pady=8)
        scrollbar = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True)
        ttk.Label(frame, text="File gốc và tiến độ luôn được giữ lại. Đóng app khi đang chạy sẽ yêu cầu dừng an toàn.",
                  font=("Segoe UI", 9)).pack(anchor="w", pady=(8, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(150, self.poll)

    def load_settings(self):
        try:
            data = json.loads(self.settings_path.read_text(encoding="utf-8"))
            for name in ("source", "output", "model"):
                if isinstance(data.get(name), str):
                    getattr(self, name).set(data[name])
            if str(data.get("seconds")) in {"30", "60", "120", "180", "300"}:
                self.seconds.set(str(data["seconds"]))
            if str(data.get("threads")) in {"1", "2", "3", "4"}:
                self.threads.set(str(data["threads"]))
        except (OSError, ValueError, TypeError, AttributeError):
            pass

    def save_settings(self):
        try:
            data = {name: getattr(self, name).get() for name in ("source", "output", "model", "seconds", "threads")}
            self.settings_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.settings_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(temporary, self.settings_path)
        except OSError as exc:
            self.append("Không lưu được lựa chọn gần nhất: " + str(exc))

    def refresh_model_label(self):
        name = Path(self.model.get()).stem
        self.model_label.set("Model: " + name + ("  ·  CPU" if Path(self.model.get()).is_file() else "  ·  Chưa tìm thấy, chọn lại trong thiết lập nâng cao"))

    def toggle_advanced(self):
        self.advanced_visible = not self.advanced_visible
        if self.advanced_visible:
            self.advanced.pack(fill="x", before=self.action_row, pady=(4, 0))
            self.advanced_toggle.configure(text="Thiết lập nâng cao ▾")
            self.root.minsize(800, 810)
            self.root.geometry("920x840")
        else:
            self.advanced.pack_forget()
            self.advanced_toggle.configure(text="Thiết lập nâng cao ▸")
            self.root.minsize(800, 690)
            self.root.geometry("920x730")

    def open_result(self, folder=False):
        if not self.result or not self.result.is_file():
            messagebox.showinfo("Chưa có kết quả", "Tách lời hoàn tất rồi mở kết quả tại đây.")
            return
        try:
            os.startfile(str(self.result.parent if folder else self.result))
        except OSError as exc:
            messagebox.showerror("Không mở được kết quả", str(exc))

    def browse_source(self):
        path = filedialog.askopenfilename(initialdir=str(ROOT / "inbox"),
            filetypes=[("Audio / video", "*.m4a *.wav *.mp3 *.flac *.mp4 *.mkv *.aac"), ("Tất cả", "*.*")])
        if path:
            self.source.set(path)
            self.output.set(str(ROOT / "output" / (Path(path).stem + "_ambience.wav")))

    def browse_output(self):
        path = filedialog.asksaveasfilename(defaultextension=".wav", initialdir=str(ROOT / "output"),
            filetypes=[("WAV", "*.wav"), ("FLAC", "*.flac")])
        if path:
            self.output.set(path)

    def browse_model(self):
        path = filedialog.askopenfilename(initialdir=str(DEFAULT_MODEL.parent), filetypes=[("MDX ONNX", "*.onnx")])
        if path:
            self.model.set(path)

    def append(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        # UI memory remains bounded even for multi-day jobs.
        if int(self.log.index("end-1c").split(".")[0]) > 600:
            self.log.delete("1.0", "100.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def busy(self, active):
        for control in self.controls:
            control.configure(state="disabled" if active else "normal")
        for combo in self.combos:
            combo.configure(state="disabled" if active else "readonly")
        self.start_button.configure(state="disabled" if active else "normal")
        self.stop_button.configure(state="normal" if active else "disabled")

    def start(self):
        if self.process and self.process.poll() is None:
            return
        if not Path(self.source.get()).is_file() or not Path(self.model.get()).is_file() or not self.output.get():
            messagebox.showerror("Thiếu thông tin", "Chọn file gốc, model ONNX có sẵn và đường dẫn đầu ra.")
            return
        if Path(self.output.get()).suffix.lower() not in {".wav", ".flac"}:
            messagebox.showerror("Đầu ra không hợp lệ", "Chọn file WAV hoặc FLAC để lưu audio nền.")
            return
        self.save_settings()
        stop_dir = ROOT / "work/vocal-remover/control"
        stop_dir.mkdir(parents=True, exist_ok=True)
        self.stop_file = stop_dir / (str(uuid.uuid4()) + ".stop")
        python = Path(sys.executable).with_name("python.exe")
        command = [str(python), "-u", str(HOME / "vocal_queue.py"), self.source.get(),
                   "--output", self.output.get(), "--model", self.model.get(),
                   "--chunk-seconds", self.seconds.get(), "--threads", self.threads.get(),
                   "--stop-file", str(self.stop_file)]
        env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
        try:
            self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", env=env,
                creationflags=0x08000000 if os.name == "nt" else 0)
        except OSError as exc:
            messagebox.showerror("Không khởi động được", str(exc))
            return
        self.bar["value"] = 0
        self.percent.set("0%")
        self.result = None
        self.last_exit_code = None
        self.listen_button.configure(state="disabled")
        self.folder_button.configure(state="disabled")
        self.status.set("Đang chuẩn bị công việc…")
        self.busy(True)
        def read_worker():
            for line in self.process.stdout:
                self.messages.put(line.strip())
            self.messages.put({"exit_code": self.process.wait()})
        threading.Thread(target=read_worker, daemon=True).start()

    def stop(self):
        if self.process and self.process.poll() is None:
            self.stop_file.touch()
            self.status.set("Đang dừng sau lượt xử lý hiện tại; phần hoàn tất được giữ lại.")
            self.stop_button.configure(state="disabled")

    def close(self):
        self.save_settings()
        if self.process and self.process.poll() is None:
            self.closing = True
            self.stop()
        else:
            self.root.destroy()

    def poll(self):
        while not self.messages.empty():
            event = self.messages.get()
            if isinstance(event, dict) and "exit_code" in event:
                self.last_exit_code = event["exit_code"]
                self.busy(False)
                if event["exit_code"] and not self.closing:
                    self.status.set("Đã dừng hoặc có lỗi. Tiến độ được giữ; xem nhật ký bên dưới.")
                if self.closing:
                    self.root.destroy()
                    return
                continue
            try:
                event = json.loads(event)
            except (ValueError, TypeError):
                self.append(str(event))
                continue
            if "percent" in event:
                self.bar["value"] = event["percent"]
                self.percent.set(f"{event['percent']:g}%")
                self.status.set(f"Phần {event['part']}/{event['total']} — {event['percent']}%")
            if "message" in event:
                self.status.set(event["message"])
                self.append(event["message"])
            if event.get("state") == "complete":
                self.bar["value"] = 100
                self.percent.set("100%")
                self.result = Path(event["output"])
                self.listen_button.configure(state="normal")
                self.folder_button.configure(state="normal")
                self.append(event.get("output", ""))
        self.root.after(150, self.poll)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with use_lock():
        root = tk.Tk()
        app = App(root)
        if args.input and args.input.is_file():
            app.source.set(str(args.input.resolve()))
            stem = args.input.stem.removesuffix("_audio")
            app.output.set(str(args.output or args.input.with_name(stem + "_ambience.wav")))
        root.mainloop()


if __name__ == "__main__":
    main()
