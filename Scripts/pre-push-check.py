#!/usr/bin/env python3
"""推 CI 前的本地预检：只跑守卫断言（violations），跳过耗时的变异循环。

用法：cd ~/mjorb-work && python3 Scripts/pre-push-check.py
通过标准：Checks 数 > 0 且 Failures == 0
"""
import os
import sys

os.chdir(os.path.expanduser("~/mjorb-work"))

src = open("Scripts/verify-release-safety.py").read()
lines = src.split("\n")
main_idx = next(i for i, l in enumerate(lines) if l.startswith("def main("))
preamble = "\n".join(lines[:main_idx])

g = {"__name__": "__test__", "__file__": "Scripts/verify-release-safety.py"}
exec(preamble, g)

def base_read(path):
    with open(path) as f:
        return f.read()

count, failures = g["violations"](base_read)
print(f"Checks: {count}, Failures: {len(failures)}")
for f in failures:
    code = f.split(":")[0] if ":" in f else f[:40]
    print(f"FAIL: {code}")
sys.exit(1 if failures else 0)
