#!/usr/bin/env python3
# Nexus Commit Tracker — GitHub commits cache con PostgreSQL
import os, json, time, threading, requests
from http.server import HTTPServer, BaseHTTPRequestHandler
import psycopg2
from psycopg2.extras import RealDictCursor

PORT = 7691
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
DB_HOST = os.environ.get("DB_HOST", "commits-db")
DB_NAME = os.environ.get("DB_NAME", "commits")
DB_USER = os.environ.get("DB_USER", "commits")
DB_PASS = os.environ.get("DB_PASS", "commits_secret")

def get_db():
    return psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS)

def init_db():
    for _ in range(30):
        try:
            conn = get_db()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS commits (
                    id SERIAL PRIMARY KEY,
                    sha VARCHAR(40) UNIQUE,
                    repo VARCHAR(255),
                    message TEXT,
                    author VARCHAR(255),
                    date TIMESTAMP,
                    url VARCHAR(512),
                    fetched_at TIMESTAMP DEFAULT NOW()
                );
                CREATE TABLE IF NOT EXISTS repos (
                    name VARCHAR(255) PRIMARY KEY,
                    last_fetch TIMESTAMP
                );
            """)
            conn.commit()
            conn.close()
            print("DB initialized")
            return
        except Exception as e:
            print(f"Waiting for DB... {e}")
            time.sleep(3)

def fetch_github_commits():
    if not GITHUB_TOKEN: return []
    headers = {"Authorization": f"Bearer {GITHUB_TOKEN}", "Accept": "application/vnd.github+json"}
    repos_url = "https://api.github.com/user/repos?per_page=50&sort=updated"
    
    all_commits = []
    try:
        repos_resp = requests.get(repos_url, headers=headers, timeout=15)
        repos = repos_resp.json()
        if not isinstance(repos, list): return []
        
        for repo in repos[:8]:  # Top 8 repos más recientes
            repo_name = repo["full_name"]
            commits_url = f"https://api.github.com/repos/{repo_name}/commits?per_page=10"
            try:
                commits_resp = requests.get(commits_url, headers=headers, timeout=10)
                commits = commits_resp.json()
                if not isinstance(commits, list): continue
                for c in commits:
                    all_commits.append({
                        "sha": c.get("sha",""),
                        "repo": repo_name,
                        "message": (c.get("commit",{}).get("message","") or "")[:120],
                        "author": c.get("commit",{}).get("author",{}).get("name",""),
                        "date": c.get("commit",{}).get("author",{}).get("date",""),
                        "url": c.get("html_url","")
                    })
            except: pass
    except Exception as e:
        print(f"GitHub fetch error: {e}")
    
    # Store in DB
    if all_commits:
        try:
            conn = get_db()
            cur = conn.cursor()
            for c in all_commits:
                cur.execute("""
                    INSERT INTO commits (sha, repo, message, author, date, url)
                    VALUES (%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (sha) DO UPDATE SET message=EXCLUDED.message, date=EXCLUDED.date
                """, (c["sha"], c["repo"], c["message"], c["author"], c["date"], c["url"]))
            conn.commit()
            conn.close()
        except Exception as e:
            print(f"DB write error: {e}")
    
    return all_commits

def get_cached_commits(limit=50):
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM commits ORDER BY date DESC LIMIT %s", (limit,))
        rows = [dict(r) for r in cur.fetchall()]
        conn.close()
        for r in rows:
            if isinstance(r.get("date"), str): pass
            else: r["date"] = str(r["date"])
        return rows
    except:
        return []

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            if "/refresh" in self.path:
                commits = fetch_github_commits()
                self.wfile.write(json.dumps({"status":"ok","count":len(commits)}).encode())
            else:
                commits = get_cached_commits()
                self.wfile.write(json.dumps(commits).encode())
        except Exception as e:
            self.wfile.write(json.dumps({"error":str(e)}).encode())
    def log_message(self, *a): pass

def auto_refresh():
    while True:
        time.sleep(300)
        try: fetch_github_commits()
        except: pass

if __name__ == "__main__":
    print("Nexus Commit Tracker starting...")
    init_db()
    threading.Thread(target=auto_refresh, daemon=True).start()
    # Fetch inicial
    threading.Thread(target=fetch_github_commits, daemon=True).start()
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
