#!/opt/homebrew/bin/python3.12
"""Hook Claude Code -> état du buddy, et voix sur demande.

Usage dans settings.json : hook.py <prompt|tool|thinking|waiting|error|stop>
- prompt  (UserPromptSubmit) : état thinking ; si le message contient
  « fais parler le bot » ou « go bot », la prochaine réponse sera lue.
- stop    (Stop) : lit la réponse (Eleven v4 Turbo via fal, secours `say`) si demandé.
Voix : contenu de ~/claude-buddy/voice (défaut Charlotte).
"""
import json, os, re, signal, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

HOME = Path.home() / "claude-buddy"
STATE = HOME / "state"
SAY_PID = HOME / "say.pid"
SPEAK_NEXT = HOME / "speak-next"
PINNED = HOME / "pinned-session"
# la dictée écrit souvent « Go, but », « go bote », « gobot »…
TRIGGER = re.compile(r"fais\s+parler\s+le\s+bot|\bgo[\s,.!-]*(bot|but|bote|botte|bots|beau|baut)\b", re.I)
MAX_CHARS = 4500  # Eleven accepte 5000 ; il lit toute la réponse
# clé fal : $FAL_KEY, sinon 1Password ($BUDDY_OP_REF) — jamais écrite sur disque
OP_REF = os.environ.get("BUDDY_OP_REF", "op://Employee/fal/credential")
TTS_URL = "https://fal.run/elevenlabs/tts/eleven-v4-turbo"
FALLBACK_VOICE = "Flo (French (France))"


def log_event(**kw):
    """Journal lu par le buddy : quelle conversation (session) parle et où elle est."""
    with open(HOME / "events.jsonl", "a") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")


def set_state(s):
    STATE.write_text(s)


def stop_voice():
    try:
        os.kill(int(SAY_PID.read_text()), signal.SIGTERM)
    except Exception:
        pass


def last_assistant_text(data):
    if data.get("last_assistant_message"):
        return data["last_assistant_message"]
    path = data.get("transcript_path")
    if not path or not os.path.exists(path):
        return ""
    text = ""
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") != "assistant":
                continue
            content = e.get("message", {}).get("content", [])
            parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
            if any(p.strip() for p in parts):
                text = "\n".join(parts)
    return text


def speakable(md, limit=MAX_CHARS):
    md = re.sub(r"```.*?```", " ", md, flags=re.S)
    md = re.sub(r"`([^`]*)`", r"\1", md)
    md = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md)
    md = re.sub(r"https?://\S+", "", md)
    md = re.sub(r"[*_#>|~]+", "", md)
    md = re.sub(r"^\s*[-•]\s*", "", md, flags=re.M)
    md = re.sub(r"\s+", " ", md).strip()
    if limit is None or len(md) <= limit:
        return md
    cut = md[:limit]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "), cut.rfind(" : "))
    return cut[: end + 1] if end > 80 else cut.rsplit(" ", 1)[0] + "…"


def eleven_mp3(text):
    """Renvoie le chemin d'un mp3 Eleven, ou None (clé via 1Password, jamais stockée)."""
    try:
        key = os.environ.get("FAL_KEY") or subprocess.run(["op", "read", OP_REF],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        if not key:
            return None
        voice = (HOME / "voice").read_text().strip() if (HOME / "voice").exists() else "Charlotte"
        body = json.dumps({"text": text, "voice": voice, "output_format": "mp3_44100_64"}).encode()
        req = urllib.request.Request(TTS_URL, body, {"Authorization": f"Key {key}", "Content-Type": "application/json"})
        url = json.load(urllib.request.urlopen(req, timeout=20))["audio"]["url"]
        out = Path(tempfile.gettempdir()) / "claude-buddy.mp3"
        urllib.request.urlretrieve(url, out)
        return out
    except Exception:
        return None


def speak(text):
    """Process détaché : talking pendant la voix, done 3 s, puis idle."""
    if os.fork():
        return
    os.setsid()
    stop_voice()
    mp3 = eleven_mp3(text)
    set_state("talking")
    cmd = ["afplay", str(mp3)] if mp3 else ["say", "-v", FALLBACK_VOICE, "-r", "200", text]
    p = subprocess.Popen(cmd)
    SAY_PID.write_text(str(p.pid))
    p.wait()
    if STATE.read_text() == "talking":
        set_state("done")
        time.sleep(3)
        if STATE.read_text() == "done":
            set_state("idle")
    os._exit(0)


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else "stop"
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    # le buddy n'écoute qu'UNE conversation : celle où l'on a dit « go bot » en dernier
    sid = data.get("session_id", "")
    pinned = PINNED.read_text().strip() if PINNED.exists() else ""
    if event == "prompt" and sid and TRIGGER.search(data.get("prompt", "")):
        PINNED.write_text(sid)
        pinned = sid
    # mode vidéo : la dernière réponse de CHAQUE conversation est gardée en entier (le panneau prend la plus récente)
    if event == "stop":
        whole = speakable(last_assistant_text(data), limit=None)
        if whole:
            log_event(ev="answer", sid=sid, text=whole)
    if pinned and sid and sid != pinned:
        return
    if event == "tool":
        name = data.get("tool_name", "")
        variant = ("think-scan" if name in ("Read", "Grep", "Glob", "LS", "NotebookRead") else
                   "think-typing" if name in ("Edit", "Write", "MultiEdit", "Bash", "NotebookEdit") else
                   "think-squint" if name.startswith(("Web", "mcp__")) else
                   "think-spin" if name in ("Agent", "Task", "Workflow") else "")
        set_state(f"thinking:{variant}" if variant else "thinking")
    elif event in ("prompt", "thinking"):
        stop_voice()
        if event == "prompt":
            log_event(ev="prompt", sid=data.get("session_id", ""), cwd=data.get("cwd", ""))
            if TRIGGER.search(data.get("prompt", "")):
                SPEAK_NEXT.touch()
        set_state("thinking")
    elif event in ("waiting", "error"):
        set_state(event)
    elif event == "stop":
        full = speakable(last_assistant_text(data))
        if full:
            (HOME / "last.txt").write_text(full)  # gardé pour un clic sur le buddy
        speak_now = SPEAK_NEXT.exists() and bool(full)
        SPEAK_NEXT.unlink(missing_ok=True)
        if full:
            # le buddy saute sur cette conversation, garde sa réponse, et la lit tout de suite si « go bot »
            log_event(ev="stop", sid=data.get("session_id", ""), text=full, speak=speak_now,
                      transcript=data.get("transcript_path", ""))
        if not speak_now:
            set_state("done")
            subprocess.Popen(["sh", "-c", f"sleep 3; grep -qx done '{STATE}' && echo idle > '{STATE}'"],
                             start_new_session=True)


if __name__ == "__main__":
    main()
