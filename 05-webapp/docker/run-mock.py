import subprocess
import sys

ports = [8008, 9090, 2379, 7000]
procs = []

for p in ports:
    procs.append(subprocess.Popen(
        ["python3", "/mock-server.py", str(p)]
    ))

print(f"Started {len(procs)} mock servers on {ports}")

for p in procs:
    p.wait()
