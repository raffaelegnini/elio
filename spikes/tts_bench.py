"""Spike: ElevenLabs streaming TTS time-to-first-byte.

Key is read from macOS Keychain (service 'jarvis-elevenlabs') or $ELEVENLABS_API_KEY.
"""
import json, os, subprocess, sys, time, urllib.request

def api_key():
    if os.environ.get("ELEVENLABS_API_KEY"):
        return os.environ["ELEVENLABS_API_KEY"]
    return subprocess.check_output(
        ["security", "find-generic-password", "-s", "jarvis-elevenlabs", "-w"], text=True).strip()

KEY = api_key()
H = {"xi-api-key": KEY, "Content-Type": "application/json"}

def get(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=H)))

voices = get("https://api.elevenlabs.io/v1/voices")["voices"]
voice = next((v for v in voices if sys.argv[1:] and v["name"].lower().startswith(sys.argv[1].lower())), voices[0])
print("voices:", ", ".join(v["name"] for v in voices[:12]))
print("using:", voice["name"], voice["voice_id"])

out_dir = os.environ.get("OUT", ".")
for model in ["eleven_flash_v2_5", "eleven_turbo_v2_5"]:
    text = "Buongiorno Raffaele. Oggi hai tre meeting, il primo alle dieci. Vuoi che prepari il riepilogo?"
    body = json.dumps({"text": text, "model_id": model}).encode()
    url = (f"https://api.elevenlabs.io/v1/text-to-speech/{voice['voice_id']}/stream"
           f"?output_format=mp3_44100_128")
    start = time.time()
    resp = urllib.request.urlopen(urllib.request.Request(url, data=body, headers=H))
    first = resp.read(1024); ttfb = time.time() - start
    rest = resp.read(); total = time.time() - start
    path = os.path.join(out_dir, f"tts_{model}.mp3")
    open(path, "wb").write(first + rest)
    print(f"{model} | TTFB {ttfb:.2f}s | total {total:.2f}s | {len(text)} chars | {path}")

sub = get("https://api.elevenlabs.io/v1/user/subscription")
print(f"credits used {sub['character_count']}/{sub['character_limit']} ({sub['tier']})")
