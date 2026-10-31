"""PTY tests: never confirm an installation or execute the upstream engine."""
import os
import pty
import select
import subprocess
import time

SECRET = "a long pass!$'word"


def run(args, replies):
    master, slave = pty.openpty()
    # setsid + TIOCSCTTY are needed for the script's /dev/tty.
    def session():
        import fcntl
        import termios
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        ["bash", "install.sh", *args], stdin=slave, stdout=slave,
        stderr=slave, preexec_fn=session,
    )
    os.close(slave)
    output = b""
    cursor = 0
    try:
        for prompt, answer in replies:
            end = time.monotonic() + 10
            while prompt.encode() not in output[cursor:]:
                if time.monotonic() > end:
                    raise AssertionError(f"Missing prompt: {prompt}; output={output!r}")
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        raise AssertionError(f"Early exit: {output!r}") from None
            cursor = len(output)
            os.write(master, (answer + "\n").encode())
        end = time.monotonic() + 10
        while time.monotonic() < end:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            elif process.poll() is not None:
                break
        assert process.wait(timeout=2) == 0, output
        text = output.decode()
        assert SECRET not in text, "Password leaked to terminal"
        return text
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


# CI runs in a VM, not a container, and all runs stop before download/mutation.
text = run(["--dry-run"], [
    ("主版本 [13]：", "14"),
    ("主版本 [13]：", "13"),
    ("SSH 端口 [22]：", "65536"),
    ("SSH 端口 [22]：", "abc"),
    ("SSH 端口 [22]：", "00222"),
    ("root 密码（至少 12 字符）：", "short"),
    ("root 密码（至少 12 字符）：", SECRET),
    ("再次输入 root 密码：", "different password"),
    ("root 密码（至少 12 字符）：", SECRET),
    ("再次输入 root 密码：", SECRET),
])
assert "SSH TCP 端口：222" in text
assert "未修改系统" in text
assert "两次密码不同" in text
text = run([], [
    ("主版本 [13]：", ""),
    ("SSH 端口 [22]：", ""),
    ("root 密码（至少 12 字符）：", SECRET),
    ("再次输入 root 密码：", SECRET),
    ("输入 ERASE：", "no"),
])
assert "已取消" in text
assert "SSH TCP 端口：22" in text
print("Interaction tests passed")
