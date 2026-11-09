#!/usr/bin/env python3
"""打印 Pulse Analytics 客户端凭据的异或+Base64 常量。

用法（从 stdin 读取，避免把密钥写进 shell 历史/进程参数）：
    printf '%s' "$PULSE_WRITE_KEY" | python3 Tooling/encode_pulse_credential.py

算法必须与 ConnAnalytics.XORObfuscation 保持一致：UTF-8 字节逐字节异或 key，
再做 Base64。异或只是混淆，不是加密。
"""

import base64
import sys

KEY = 0x5A


def main() -> int:
    value = sys.stdin.readline().rstrip("\n")
    if not value:
        print("从 stdin 读取一个非空值", file=sys.stderr)
        return 1
    encoded = base64.b64encode(bytes(byte ^ KEY for byte in value.encode("utf-8")))
    print(encoded.decode("ascii"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
