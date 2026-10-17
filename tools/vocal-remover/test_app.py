"""GUI contracts only; no inference or media playback."""
import json
from pathlib import Path
import tempfile
import tkinter as tk
import unittest
from unittest.mock import Mock, patch

from app import App


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vocal-ui-test-")
        self.directory = Path(self.temp.name)
        self.root = tk.Tk()
        self.root.withdraw()
        self.app = App(self.root, settings_path=self.directory / "settings.json")
        self.root.update_idletasks()

    def tearDown(self):
        for timer in self.root.tk.call("after", "info"):
            self.root.after_cancel(timer)
        self.root.destroy()
        self.temp.cleanup()

    def test_settings_round_trip_and_invalid_file_fallback(self):
        self.app.source.set("test-input.wav")
        self.app.output.set("test-result.wav")
        self.app.threads.set("1")
        self.app.seconds.set("60")
        self.app.save_settings()
        self.app.source.set("")
        self.app.load_settings()
        self.assertEqual(self.app.source.get(), "test-input.wav")
        self.assertEqual(self.app.threads.get(), "1")
        self.app.settings_path.write_text("broken JSON", encoding="utf-8")
        self.app.load_settings()

    def test_invalid_input_stays_in_ui_without_launching_worker(self):
        self.app.source.set("")
        with patch("app.messagebox.showerror") as error, patch("app.subprocess.Popen") as process:
            self.app.start()
        error.assert_called_once()
        process.assert_not_called()

    def test_completed_event_enables_result_buttons(self):
        result = self.directory / "result.wav"
        result.write_bytes(b"test fixture, not playable")
        self.app.messages.put(json.dumps({"state": "complete", "output": str(result), "message": "Done"}))
        self.app.messages.put({"exit_code": 0})
        self.app.poll()
        self.assertEqual(self.app.percent.get(), "100%")
        self.assertEqual(self.app.last_exit_code, 0)
        self.assertEqual(str(self.app.listen_button["state"]), "normal")
        with patch("app.os.startfile") as open_file:
            self.app.open_result()
            open_file.assert_called_with(str(result))
            self.app.open_result(folder=True)
            open_file.assert_called_with(str(result.parent))

    def test_close_running_worker_signals_stop(self):
        self.app.process = Mock()
        self.app.process.poll.return_value = None
        self.app.stop_file = self.directory / "stop.signal"
        self.app.close()
        self.assertTrue(self.app.closing)
        self.assertTrue(self.app.stop_file.exists())
        self.app.process.terminate.assert_not_called()

    def test_advanced_controls_and_busy_state(self):
        self.app.toggle_advanced()
        self.assertEqual(self.app.advanced.winfo_manager(), "pack")
        self.app.busy(True)
        self.assertEqual(str(self.app.start_button["state"]), "disabled")
        self.app.busy(False)
        self.assertEqual(str(self.app.start_button["state"]), "normal")
        self.app.toggle_advanced()
        self.assertEqual(self.app.advanced.winfo_manager(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
