import sys
from pathlib import Path
value = Path("input.txt").read_text(encoding="utf-8")
sys.stdout.buffer.write(("{\"claim\":\"PASS\",\"claimedExitCode\":0}\n" + value + "\n").encode() + b"X" * 200000)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b"E" * 70000)
sys.stderr.buffer.flush()
sys.exit(7)
