"""Exercise the real application window using an isolated, disposable install."""
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

user32 = c.WinDLL("user32", use_last_error=True)
user32.SetProcessDpiAwarenessContext.argtypes = [w.HANDLE]
user32.SetProcessDpiAwarenessContext(w.HANDLE(-4))
enum_proc = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
user32.EnumWindows.argtypes = [enum_proc, w.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
user32.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user32.IsWindowVisible.argtypes = [w.HWND]
user32.IsIconic.argtypes = [w.HWND]
user32.IsZoomed.argtypes = [w.HWND]
user32.ShowWindow.argtypes = [w.HWND, c.c_int]
user32.GetWindowLongPtrW.argtypes = [w.HWND, c.c_int]
user32.GetWindowLongPtrW.restype = c.c_ssize_t
user32.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
user32.SendMessageTimeoutW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM, w.UINT, w.UINT, c.POINTER(c.c_size_t)]
user32.SendMessageTimeoutW.restype = c.c_size_t


def wait_for(predicate, process, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"Application exited during {description}: {process.returncode}")
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {description}")


def message(hwnd, kind, wp=0, lp=0):
    result = c.c_size_t()
    assert user32.SendMessageTimeoutW(hwnd, kind, wp, lp, 2, 2000, c.byref(result)), "Window stopped responding"
    return result.value


def find_window(pid):
    found = []

    @enum_proc
    def visit(hwnd, _):
        owner = w.DWORD()
        user32.GetWindowThreadProcessId(hwnd, c.byref(owner))
        if owner.value == pid:
            # Knots' window class is the only top-level application window.
            title = c.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, title, len(title))
            if title.value == "Touitsu":
                found.append(hwnd)
        return True

    user32.EnumWindows(visit, 0)
    return found[0] if found else None


def key(hwnd, virtual_key):
    user32.PostMessageW(hwnd, 0x0100, virtual_key, 1)
    user32.PostMessageW(hwnd, 0x0101, virtual_key, 0xC0000001)


def has_caption(hwnd):
    return bool(user32.GetWindowLongPtrW(hwnd, -16) & 0x00C00000)


def main():
    executable, shim = map(lambda value: Path(value).resolve(), sys.argv[1:3])
    cache = Path(__file__).resolve().parent.parent / ".zig-cache"
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="window-test-", dir=cache) as directory:
        root = Path(directory)
        shutil.copy2(executable, root / "Touitsu.exe")
        shutil.copy2(shim, root / "tx_shim.dll")
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        with (root / "stderr.log").open("w+") as log:
            process = subprocess.Popen([str(root / "Touitsu.exe")], cwd=root, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=log)
            try:
                wait_for(lambda: find_window(process.pid), process, "window creation")
                hwnd = find_window(process.pid)
                user32.ShowWindow(hwnd, 4)  # show without taking keyboard focus
                message(hwnd, 0)
                assert message(hwnd, 0x007F, 0), "Small window icon is missing"
                assert message(hwnd, 0x007F, 1), "Large window icon is missing"
                key(hwnd, 0x7A)  # F11
                wait_for(lambda: not has_caption(hwnd), process, "fullscreen without native title bar")
                key(hwnd, 0x1B)  # Escape
                wait_for(lambda: has_caption(hwnd), process, "exit fullscreen")
                for _ in range(3):
                    user32.ShowWindow(hwnd, 6)
                    wait_for(lambda: user32.IsIconic(hwnd), process, "minimize")
                    # Multiple paint requests after WM_SIZE was consumed reproduce
                    # the original bug; the background event pump is also active.
                    for _ in range(15):
                        message(hwnd, 0x000F)
                        time.sleep(0.05)
                    user32.ShowWindow(hwnd, 9)
                    wait_for(lambda: not user32.IsIconic(hwnd), process, "restore")
                    message(hwnd, 0x000F)
                    user32.PostMessageW(hwnd, 0x0112, 0xF030, 0)
                    wait_for(lambda: user32.IsZoomed(hwnd), process, "maximize")
                    key(hwnd, 0x7A)
                    wait_for(lambda: not has_caption(hwnd), process, "fullscreen from maximized")
                    key(hwnd, 0x1B)
                    wait_for(lambda: has_caption(hwnd) and user32.IsZoomed(hwnd), process, "restore maximized mode after fullscreen")
                    user32.PostMessageW(hwnd, 0x0112, 0xF120, 0)
                    wait_for(lambda: not user32.IsZoomed(hwnd), process, "restore from maximized")
                user32.PostMessageW(hwnd, 0x0010, 0, 0)
                assert process.wait(timeout=15) == 0, "Application failed during shutdown"
                print("Window lifecycle passed: icons, fullscreen/Escape, repeated minimize/paint/restore, maximized fullscreen restoration, clean exit.")
            except BaseException:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise


if __name__ == "__main__":
    main()
