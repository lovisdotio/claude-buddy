#!/opt/homebrew/bin/python3.12
"""Mode vidéo du buddy : un texte → des clips H3 Max (LoRA Studio 1939) avec voix off d'actualités.

Usage : explain.py <full|summary> <dossier>   (FAL_KEY dans l'environnement, jamais sur disque)
- lit <dossier>/input.txt
- full    : TOUT le texte, mot pour mot, coupé aux fins de phrase en morceaux de ~60 mots (≈ 15 s chacun)
- summary : un résumé de ~55 mots → un seul clip
- un LLM rapide (OpenRouter sur fal) écrit pour chaque morceau une scène 1939 qui l'illustre (sans aucun écrit)
- 3 clips générés en avance, dans l'ordre ; les clips arrivent dans <dossier>/NN.mp4 au fil de l'eau ; l'avancement est dans <dossier>/status.json
"""
import json, os, re, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

KEY = os.environ["FAL_KEY"]
MODE, RUN = sys.argv[1], Path(sys.argv[2])
LLM_URL = "https://fal.run/openrouter/router/openai/v1/chat/completions"
LLM_MODEL = "google/gemini-3-flash-preview"
H3 = "minimax/h3-max/text-to-video/lora"
LORA = ("https://huggingface.co/lovis93/studio-1939-old-animation-lora-minimax-h3/resolve/"
        "19214d4c3989de6caca673d534d0d4b16b73b0f7/studio1939-strong.safetensors")
WORDS_PER_CLIP = 60          # débit validé par Lovis : ~60 mots en 15 s, « pas plus rapide »
AHEAD = 3                    # 3 clips en avance : dès qu'un clip est fini, le suivant part (arrêt = rien d'autre payé)

status = {"mode": MODE, "total": 0, "ready": [], "durations": [], "error": None, "finished": False}


def save_status():
    tmp = RUN / "status.json.tmp"
    tmp.write_text(json.dumps(status, ensure_ascii=False))
    tmp.replace(RUN / "status.json")


def post(url, body, timeout=60):
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {"Authorization": f"Key {KEY}", "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def get(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Key {KEY}"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def clean(md):
    """Texte lisible à voix haute : sans blocs de code, liens ni balises markdown."""
    md = re.sub(r"```.*?```", " ", md, flags=re.S)
    md = re.sub(r"`([^`]*)`", r"\1", md)
    md = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md)
    md = re.sub(r"https?://\S+", "", md)
    md = re.sub(r"[*_#>|~]+", "", md)
    md = re.sub(r"^\s*(?:[-•]|\d+\.)\s*", "", md, flags=re.M)
    md = md.replace("→", ",").replace("≈", "environ ").replace('"', "'")
    return re.sub(r"\s+", " ", md).strip()


def chunks_of(text):
    """Morceaux de ~60 mots coupés aux fins de phrase ; une phrase trop longue est coupée aux virgules."""
    sentences = re.split(r"(?<=[.!?…:])\s+", text)
    pieces = []
    for s in sentences:
        w = s.split()
        while len(w) > WORDS_PER_CLIP:
            head = " ".join(w[:WORDS_PER_CLIP])
            cut = head.rfind(", ")
            n = len(head[:cut + 1].split()) if cut > 0 and len(head[:cut].split()) > 20 else WORDS_PER_CLIP
            pieces.append(" ".join(w[:n])); w = w[n:]
        if w:
            pieces.append(" ".join(w))
    out, cur = [], []
    for p in pieces:
        if cur and len(cur) + len(p.split()) > WORDS_PER_CLIP:
            out.append(" ".join(cur)); cur = []
        cur += p.split()
    if cur:
        out.append(" ".join(cur))
    return out


def llm_json(prompt):
    body = {"model": LLM_MODEL, "messages": [{"role": "user", "content": prompt}],
            "response_format": {"type": "json_object"}, "max_tokens": 4000}
    content = post(LLM_URL, body, timeout=90)["choices"][0]["message"]["content"]
    return json.loads(re.sub(r"^```(?:json)?|```$", "", content.strip()).strip())


SCENE_RULES = """Each scene is a 1939 golden-age hand-painted cartoon shot (2-3 English sentences) that ILLUSTRATES the passage with
a visual metaphor: whimsical machines, places, objects, little animals or people in action, a gentle camera move.
Vary the environments from one scene to the next while keeping one coherent little world.
STRICT: absolutely no writing anywhere — no paper, books, letters, signs, screens, labels, numbers or text of any kind.
Nobody on screen talks to the camera."""


def plan():
    raw = (RUN / "input.txt").read_text()
    text = clean(raw)
    if MODE == "summary":
        d = llm_json(f"""You turn an assistant's answer into a short 1939 newsreel explainer.
Write a spoken summary of about 50 words (never more than 55) in the SAME language as the answer, natural to hear,
no code, no file paths, no lists. Then one scene for it.
{SCENE_RULES}
Return JSON: {{"language": "<language name in English>", "chunks": [{{"text": "<summary>", "scene": "<scene>"}}]}}

ANSWER:
{text}""")
        return d.get("language", "French"), d["chunks"][:1]
    parts = chunks_of(text)
    d = llm_json(f"""Here are {len(parts)} consecutive passages of an assistant's answer, read aloud verbatim as a 1939 newsreel.
Write one scene per passage, in the same order.
{SCENE_RULES}
Return JSON: {{"language": "<language of the passages, in English>", "scenes": ["<scene 1>", ...]}}  (exactly {len(parts)} scenes)

PASSAGES:
""" + "\n".join(f"{i + 1}. {p}" for i, p in enumerate(parts)))
    scenes = d.get("scenes", [])
    scenes += ["A whimsical golden-age cartoon workshop full of spinning brass machines and puffing little chimneys."] * (len(parts) - len(scenes))
    return d.get("language", "French"), [{"text": p, "scene": s} for p, s in zip(parts, scenes)]


def duration(words):
    return 5 if words <= 18 else 10 if words <= 38 else 15


def make_clip(i, chunk, language):
    words = len(chunk["text"].split())
    prompt = (f"gulliv3r, 1939 hand-painted cartoon, warm watercolor backgrounds. {chunk['scene']} "
              f"Off-screen narrator voice-over only, nobody on screen speaks: a brisk, enthusiastic 1939 {language} newsreel announcer, "
              f"speaking quite fast and very clearly, says exactly: \"{chunk['text']}\" "
              f"Light vintage orchestral music very low under the voice. No text, no subtitles.")
    body = {"prompt": prompt, "duration": duration(words), "resolution": "480P", "aspect_ratio": "1:1",
            "prompt_expansion_mode": "disabled", "loras": [{"path": LORA, "scale": 1.0}]}
    for attempt in range(3):
        try:
            try:
                job = post(f"https://queue.fal.run/{H3}", body)
            except urllib.error.HTTPError as e:
                if e.code == 422 and body["duration"] != 15:      # durée refusée : on repasse à 15 s, qui marche
                    body["duration"] = 15
                    job = post(f"https://queue.fal.run/{H3}", body)
                else:
                    raise
            while get(job["status_url"])["status"] != "COMPLETED":
                time.sleep(1)
            url = get(job["response_url"])["video"]["url"]
            tmp = RUN / f"{i:02d}.part.mp4"
            urllib.request.urlretrieve(url, tmp)
            tmp.replace(RUN / f"{i:02d}.mp4")
            return body["duration"]
        except Exception as e:
            if attempt == 2:
                raise RuntimeError(f"clip {i + 1} : {e}")
            time.sleep(2)


def main():
    save_status()
    try:
        language, chunks = plan()
    except Exception as e:
        status["error"] = f"découpage : {e}"; status["finished"] = True; save_status(); return
    status["total"] = len(chunks)
    status["durations"] = [duration(len(c["text"].split())) for c in chunks]
    (RUN / "plan.json").write_text(json.dumps({"language": language, "chunks": chunks}, ensure_ascii=False, indent=1))
    save_status()
    # le pool lance les clips dans l'ordre, 3 à la fois : le 1er arrive vite, les suivants pendant la lecture
    with ThreadPoolExecutor(AHEAD) as pool:
        futures = {pool.submit(make_clip, i, c, language): i for i, c in enumerate(chunks)}
        for f in as_completed(futures):
            i = futures[f]
            try:
                status["durations"][i] = f.result()
                status["ready"] = sorted(status["ready"] + [i])
            except Exception as e:
                status["error"] = str(e)
            save_status()
    status["finished"] = True
    save_status()


if __name__ == "__main__":
    main()
