#!/usr/bin/env python3
# Nexus Monitor — HTTP server que expone métricas del servidor en JSON
import subprocess, json, time
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 7690

def get_stats():
    # RAM total del sistema
    free = subprocess.run(["free", "-m"], capture_output=True, text=True).stdout
    mem_line = [l for l in free.split('\n') if 'Mem:' in l]
    ram_total = ram_used = 0
    if mem_line:
        parts = mem_line[0].split()
        ram_total = int(parts[1]) if len(parts) > 1 else 0
        ram_used = int(parts[2]) if len(parts) > 2 else 0

    # Containers de agentes
    containers_raw = subprocess.run(
        ["docker","stats","--no-stream","--format",
         '{"name":"{{.Name}}","cpu":"{{.CPUPerc}}","mem":"{{.MemUsage}}","memPerc":"{{.MemPerc}}"}'],
        capture_output=True, text=True, timeout=10
    ).stdout.strip()

    containers = []
    agent_names = {"nexus-deepseek","nexus-gemini","nexus-antigravity","nexus-minimax","nexus-codex","cloudflared-deepseek","nexus-guardian"}
    for line in containers_raw.split('\n'):
        try:
            c = json.loads(line)
            if c["name"] in agent_names:
                mb = c["mem"].split('/')[0].strip()
                containers.append({"name":c["name"], "cpu": c["cpu"].strip('%'), "mem": mb})
        except: pass

    # Uptime
    uptime = subprocess.run(["cat","/proc/uptime"], capture_output=True, text=True).stdout.split()[0]
    uptime_sec = int(float(uptime))

    return {
        "ts": int(time.time()),
        "host": {"ram_total_mb": ram_total, "ram_used_mb": ram_used, "uptime_sec": uptime_sec},
        "containers": containers,
        "agent_ram_total_mb": sum(
            float(c["mem"].replace('MiB','').replace('GiB','').strip()) * (1024 if 'GiB' in c["mem"] else 1)
            for c in containers if 'GiB' not in c["mem"]
        )
    }

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            stats = get_stats()
            self.wfile.write(json.dumps(stats).encode())
        except Exception as e:
            self.wfile.write(json.dumps({"error": str(e)}).encode())
    def log_message(self, *a): pass

if __name__ == "__main__":
    print(f"Nexus Monitor on :{PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
