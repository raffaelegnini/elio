"""Spike: time-to-first-text of a warm session by --effort level (Elio latency work)."""
import json, subprocess, sys, time

def bench(effort):
    args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", "sonnet", "--setting-sources", "project",
            "--strict-mcp-config", "--tools", "", "--no-session-persistence",
            "--system-prompt", "Sei Elio, assistente vocale. Rispondi in italiano in una o due frasi."]
    if effort: args += ["--effort", effort]
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    out = []
    for q in ["Ciao", "Meglio Postgres o MySQL per un e-commerce Laravel con molte varianti prodotto?",
              "Quanto fa il 17% di 2340 euro?"]:
        start = time.time(); first = None
        p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": q}}) + "\n"); p.stdin.flush()
        for line in p.stdout:
            ev = json.loads(line)
            if ev.get("type") == "stream_event" and ev["event"].get("delta", {}).get("type") == "text_delta" and first is None:
                first = time.time() - start
            if ev.get("type") == "result":
                out.append((q[:30], round(first or -1, 2), round(time.time() - start, 2))); break
    p.stdin.close(); p.wait()
    return out

for e in sys.argv[1:] or ["", "low"]:
    print(e or "default", bench(e or None))
