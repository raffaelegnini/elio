"""Spike: latency of a persistent Claude Code session (stream-json in/out)."""
import json, subprocess, sys, time

MODEL = sys.argv[1] if len(sys.argv) > 1 else "sonnet"
SYSTEM = ("Sei Jarvis, assistente vocale di Vincenzo. Rispondi in italiano, "
          "frasi brevi e parlabili, niente markdown.")
PROMPTS = ["Ciao Jarvis, come va?",
           "Dammi un consiglio veloce per concentrarmi stamattina.",
           "Che differenza c'è tra merge e rebase, in due frasi?"]

t0 = time.time()
p = subprocess.Popen(
    ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
     "--verbose", "--include-partial-messages", "--model", MODEL,
     "--setting-sources", "project", "--strict-mcp-config", "--tools", "",
     "--no-session-persistence", "--system-prompt", SYSTEM],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
    cwd="/Users/raffaele/Desktop/dev/jarvis")

def wait_init():
    for line in p.stdout:
        ev = json.loads(line)
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            return

def ask(text):
    start = time.time(); first = None; out = ""
    p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
    p.stdin.flush()
    for line in p.stdout:
        ev = json.loads(line)
        if ev.get("type") == "stream_event":
            d = ev["event"].get("delta", {})
            if d.get("type") == "text_delta":
                if first is None: first = time.time() - start
                out += d["text"]
        elif ev.get("type") == "result":
            return first, time.time() - start, out.strip(), ev.get("usage", {})

# First message also triggers init
for i, q in enumerate(PROMPTS):
    ttft, total, out, usage = ask(q)
    if i == 0: print(f"[process start→first msg incl. boot]")
    print(f"{MODEL} | TTFT {ttft:.2f}s | total {total:.2f}s | cache_read {usage.get('cache_read_input_tokens')} | {out[:90]!r}")
p.stdin.close(); p.wait()
