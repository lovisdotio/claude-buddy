#!/opt/homebrew/bin/python3.12
"""Texte OCR (stdin) -> réponse de Claude à lire (stdout).
  match.py          : la réponse complète qui contient ce texte (glisser-déposer)
  match.py --last   : la DERNIÈRE réponse de la conversation reconnue derrière le buddy (clic)
Cherche dans les transcripts des conversations récentes."""
import json, re, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hook import speakable  # noqa: E402

HOME = Path.home() / "claude-buddy"
words = lambda t: {w for w in re.findall(r"[a-zà-ÿ0-9]{3,}", t.lower())}


def transcripts():
    seen = []
    ev = HOME / "events.jsonl"
    if ev.exists():
        for line in reversed(ev.read_text().splitlines()):
            try:
                t = json.loads(line).get("transcript")
            except Exception:
                continue
            if t and t not in seen and Path(t).exists():
                seen.append(t)
    recent = sorted((Path.home() / ".claude" / "projects").glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    for p in recent[:15]:
        if time.time() - p.stat().st_mtime < 3 * 86400 and str(p) not in seen:
            seen.append(str(p))
    return seen[:20]


def messages(path):
    """(rôle, texte) dans l'ordre ; rôle user seulement pour les vrais messages tapés."""
    with open(path, errors="ignore") as f:
        for line in f:
            if '"text"' not in line and '"content":"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            t, c = e.get("type"), e.get("message", {}).get("content")
            if t == "user" and isinstance(c, str):
                yield "user", c
            elif t == "user" and isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "text" for x in c):
                yield "user", " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
            elif t == "assistant" and isinstance(c, list):
                for x in c:
                    if isinstance(x, dict) and x.get("type") == "text" and x.get("text", "").strip():
                        yield "assistant", x["text"]


def last_answer(path):
    """Tous les blocs de texte de Claude depuis le dernier message tapé = sa dernière réponse complète."""
    turn = []
    for role, text in messages(path):
        if role == "user":
            turn = []
        else:
            turn.append(text)
    return "\n\n".join(turn)


def answers(path):
    with open(path, errors="ignore") as f:
        for line in f:
            if '"assistant"' not in line or '"text"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") != "assistant":
                continue
            for c in e.get("message", {}).get("content", []):
                if isinstance(c, dict) and c.get("type") == "text" and len(c.get("text", "")) > 20:
                    yield c["text"]


raw = sys.stdin.read()
(HOME / "last-ocr.txt").write_text(raw)
ocr = words(raw)
if len(ocr) < 3:
    sys.exit(1)

if "--under" in sys.argv:
    # le message (de Claude ou de l'utilisateur) qui contient les quelques lignes juste sous le buddy
    seq = re.findall(r"[a-zà-ÿ0-9]{2,}", raw.lower())
    grams = {" ".join(seq[i:i + 3]) for i in range(len(seq) - 2)}
    if len(grams) < 2:
        sys.exit(1)
    best, best_hit = "", 0
    for t in transcripts():
        for _, text in messages(t):
            norm = " ".join(re.findall(r"[a-zà-ÿ0-9]{2,}", text.lower()))
            hit = sum(1 for g in grams if g in norm)
            if hit > best_hit or (hit == best_hit and hit and len(text) < len(best)):
                best, best_hit = text, hit
    if best_hit < 2 or best_hit < 0.3 * len(grams):
        sys.exit(1)
    print(speakable(best))
    sys.exit(0)

if "--last" in sys.argv:
    # quelle conversation est derrière ? celle qui contient le plus de suites de 3 mots vues à l'écran
    seq = re.findall(r"[a-zà-ÿ0-9]{2,}", raw.lower())
    grams = {" ".join(seq[i:i + 3]) for i in range(len(seq) - 2)}
    best_t, best_hit, second = None, 0, 0
    for t in transcripts():
        recent = " ".join(re.findall(r"[a-zà-ÿ0-9]{2,}", " ".join(x for _, x in list(messages(t))[-80:]).lower()))
        hit = sum(1 for g in grams if g in recent)
        if hit > best_hit:
            best_t, second, best_hit = t, best_hit, hit
        elif hit > second:
            second = hit
    # il faut une conversation clairement reconnue (sinon on ne lit rien plutôt que la mauvaise)
    if not best_t or best_hit < 3 or best_hit < 2 * second:
        sys.exit(1)
    print(speakable(last_answer(best_t)))
    sys.exit(0)

best, score = "", 0.0
for t in transcripts():
    for a in answers(t):
        hit = len(ocr & words(a))
        sc = hit / len(ocr)
        if hit >= 4 and sc > score:
            best, score = a, sc
if score < 0.3:
    sys.exit(1)
print(speakable(best))
