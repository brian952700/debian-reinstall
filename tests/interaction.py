"""PTY tests: never confirm an installation or execute the upstream engine."""
import os
import pty
import re
import select
import subprocess
import time

SECRET = "a long pass!$'word"


ANSI = re.compile(rb"\x1b\[[0-9;]*m")


def run(args, replies, color=False):
    master, slave = pty.openpty()
    # setsid + TIOCSCTTY are needed for the script's /dev/tty.
    def session():
        import fcntl
        import termios
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    env = dict(os.environ, TERM="xterm-256color")
    if color:
        env.pop("NO_COLOR", None)
    else:
        env["NO_COLOR"] = "1"
    process = subprocess.Popen(
        ["bash", "install.sh", *args], stdin=slave, stdout=slave,
        stderr=slave, preexec_fn=session, env=env,
    )
    os.close(slave)
    output = b""
    cursor = 0
    try:
        for prompt, answer in replies:
            end = time.monotonic() + 10
            while prompt.encode() not in ANSI.sub(b"", output[cursor:]):
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
        assert (b"\x1b[" in output) == color, "Incorrect color mode"
        text = ANSI.sub(b"", output).decode()
        assert SECRET not in text, "Password leaked to terminal"
        return text
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


# CI runs in a VM, not a container, and all runs stop before download/mutation.
text = run(["--dry-run"], [
    ("主版本 [默认：13]：", "14"),
    ("主版本 [默认：13]：", "13"),
    ("SSH 端口 [默认：22]：", "65536"),
    ("SSH 端口 [默认：22]：", "abc"),
    ("SSH 端口 [默认：22]：", "00222"),
    ("root 密码 [至少 12 字符，隐藏输入]：", "short"),
    ("root 密码 [至少 12 字符，隐藏输入]：", SECRET),
    ("再次输入 root 密码：", "different password"),
    ("root 密码 [至少 12 字符，隐藏输入]：", SECRET),
    ("再次输入 root 密码：", SECRET),
])
assert "SSH 端口    222" in text
assert "步骤 4/4 · 试运行完成" in text
assert "登录密码    已设置（隐藏）" in text
assert "未修改系统" in text
assert "两次密码不同" in text
text = run([], [
    ("主版本 [默认：13]：", ""),
    ("SSH 端口 [默认：22]：", ""),
    ("root 密码 [至少 12 字符，隐藏输入]：", SECRET),
    ("再次输入 root 密码：", SECRET),
    ("输入 ERASE：", "no"),
], color=True)
assert "已取消" in text
assert "SSH 端口    22" in text
print("Interaction tests passed")
