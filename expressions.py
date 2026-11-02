#!/opt/homebrew/bin/python3.12
"""Génère les expressions du buddy une par une (H3 Max i2v, début = fin = image du perso).
Lancer : opfal ~/claude-buddy/expressions.py   (reprend là où il s'est arrêté)
Sortie : clips/<état>/<nom>.mp4 (360 px, muet) + raw/<nom>.mp4
"""
import json, os, subprocess, time, urllib.request
from pathlib import Path

HOME = Path.home() / "claude-buddy"
IMG = "https://v3b.fal.media/files/b/0aae4d9c/FUQE8jDd9vKX92eAwuZPf_3FiyyD5k.png"
EP = "minimax/h3-max/image-to-video"
KEY = os.environ["FAL_KEY"]
TAIL = " The character stays the same smooth ivory ball with small black eyes. Static locked camera, plain dark background, it returns to its exact starting pose facing the camera at the end. Silent."

E = [
    # parle (variantes jouées à la suite pendant la voix)
    ("talking", "talk-explain", "The round ivory ball character talks calmly, its tiny mouth opening and closing as it explains something, small nods."),
    ("talking", "talk-excited", "The round ivory ball character talks excitedly, mouth moving fast, bouncing with enthusiasm, eyes sparkling."),
    ("talking", "talk-lean", "The round ivory ball character leans toward the camera while talking as if sharing a secret, mouth moving softly."),
    ("talking", "talk-sway", "The round ivory ball character talks while swaying gently side to side, mouth moving, relaxed and friendly."),
    ("talking", "talk-laugh", "The round ivory ball character talks and laughs in the middle of a sentence, eyes squinting happily, mouth wide."),
    ("talking", "talk-serious", "The round ivory ball character talks seriously, eyes slightly narrowed, mouth moving steadily, a firm small nod."),
    ("talking", "talk-question", "The round ivory ball character asks a question while talking, tilting to the side with raised eyebrows, mouth moving."),
    ("talking", "talk-whisper", "The round ivory ball character whispers, mouth moving in tiny movements, eyes glancing left and right conspiratorially."),
    # attente
    ("idle", "idle-look", "The round ivory ball character looks around curiously, eyes glancing left, then right, then up."),
    ("idle", "idle-sleepy", "The round ivory ball character gets sleepy, eyelids slowly drooping, a small yawn, then wakes up with a little start."),
    ("idle", "idle-hum", "The round ivory ball character hums happily to itself with closed content eyes, rocking gently."),
    ("idle", "idle-roll", "The round ivory ball character rolls a little to the left and back to the right playfully."),
    # réfléchit / travaille
    ("thinking", "think-squint", "The round ivory ball character concentrates hard, eyes squinting, a tiny frown, slowly rotating a little in place."),
    ("thinking", "think-eureka", "The round ivory ball character thinks with eyes looking up, then suddenly has an idea, eyes widen and it pops up."),
    ("thinking", "think-typing", "The round ivory ball character works busily, vibrating with tiny quick bounces, focused eyes looking down."),
    ("thinking", "think-scan", "The round ivory ball character reads something, eyes scanning left to right repeatedly, focused."),
    ("thinking", "think-spin", "The round ivory ball character is processing: it spins slowly around its vertical axis once while thinking."),
    # attend ton go
    ("waiting", "wait-tap", "The round ivory ball character waits impatiently, tapping by bouncing in a steady rhythm, eyes looking at the camera."),
    ("waiting", "wait-puppy", "The round ivory ball character makes big pleading puppy eyes at the camera, wobbling hopefully."),
    ("waiting", "wait-wave", "The round ivory ball character tries to get attention: it hops side to side as if waving, eyes wide."),
    # fini
    ("done", "done-cheer", "The round ivory ball character cheers, eyes closed in joy, jumps high with tiny sparkles around it."),
    ("done", "done-proud", "The round ivory ball character puffs up proudly, a confident smile, a satisfied nod."),
    ("done", "done-wink", "The round ivory ball character gives a playful wink at the camera with a small smile."),
    ("done", "done-dance", "The round ivory ball character does a happy little dance, bouncing left and right to a rhythm."),
    # erreur / problème
    ("error", "err-oops", "The round ivory ball character makes an embarrassed 'oops' face, eyes wide, a small sweat drop, shrinks slightly."),
    ("error", "err-sad", "The round ivory ball character is sad, eyes droop, it sinks a little and sighs."),
    ("error", "err-shock", "The round ivory ball character is shocked, eyes pop wide open, mouth forms a small O, it jumps back slightly."),
    ("error", "err-dizzy", "The round ivory ball character is dizzy and confused, eyes become spirals, it wobbles around."),
    # extras
    ("love", "love-hearts", "The round ivory ball character blushes with pink cheeks, eyes become little hearts, it wiggles happily."),
    ("talking", "talk-nod", "The round ivory ball character talks while nodding firmly in agreement, mouth moving."),
    ("talking", "talk-tilt", "The round ivory ball character talks with its head tilting left then right, curious and friendly."),
    ("talking", "talk-fast", "The round ivory ball character talks very fast like an excited commentator, mouth moving rapidly."),
    ("talking", "talk-slow", "The round ivory ball character talks slowly and calmly, mouth opening wide on each word."),
    ("talking", "talk-smirk", "The round ivory ball character talks with a confident smirk, one eye half closed."),
    ("talking", "talk-surprised", "The round ivory ball character talks with surprised wide eyes, as if telling amazing news."),
    ("talking", "talk-shy", "The round ivory ball character talks shyly with pink cheeks, looking slightly down."),
    ("talking", "talk-storyteller", "The round ivory ball character talks dramatically like a storyteller, leaning in then back."),
    ("talking", "talk-hop", "The round ivory ball character talks and does tiny hops between sentences."),
    ("talking", "talk-giggle", "The round ivory ball character talks and giggles, eyes squinting in amusement."),
    ("talking", "talk-sing", "The round ivory ball character sings a little tune, mouth shaped like an O, swaying to the rhythm."),
    ("talking", "talk-announce", "The round ivory ball character announces something proudly, puffing up, mouth wide."),
    ("talking", "talk-sideeye", "The round ivory ball character talks while glancing sideways at the camera playfully."),
    ("talking", "talk-sigh", "The round ivory ball character talks with a small tired sigh then smiles. No text, no subtitles, no captions."),
    ("talking", "talk-wobble", "The round ivory ball character talks while wobbling like jelly with each word."),
    ("idle", "idle-blink", "The round ivory ball character blinks twice quickly, then stays still and calm."),
    ("idle", "idle-stretch", "The round ivory ball character stretches by squashing down and stretching up tall like a yawn."),
    ("idle", "idle-whistle", "The round ivory ball character whistles softly with pursed lips, eyes looking up."),
    ("idle", "idle-peek", "The round ivory ball character slowly peeks to the right as if looking at something off-screen."),
    ("idle", "idle-bounce", "The round ivory ball character does one small lazy bounce in place."),
    ("idle", "idle-daydream", "The round ivory ball character daydreams with a soft smile, eyes looking up dreamily."),
    ("idle", "idle-nod-off", "The round ivory ball character nods off, eyes closing, then snaps awake."),
    ("idle", "idle-tiny-spin", "The round ivory ball character turns slightly left then back to center."),
    ("idle", "idle-smile", "The round ivory ball character slowly breaks into a gentle content smile, then relaxes."),
    ("idle", "idle-squish", "The round ivory ball character gently squishes down and springs back up."),
    ("idle", "idle-breathe-deep", "The round ivory ball character takes a slow deep breath, swelling slightly, then exhales."),
    ("idle", "idle-glance-up", "The round ivory ball character glances up at the top of the screen, then back."),
    ("idle", "idle-hum-sway", "The round ivory ball character hums with eyes closed, swaying slowly."),
    ("idle", "idle-wiggle", "The round ivory ball character does a tiny happy wiggle."),
    ("thinking", "think-hmm", "The round ivory ball character goes 'hmm' with a pursed mouth, eyes looking up-left."),
    ("thinking", "think-sweat", "The round ivory ball character concentrates intensely, a small sweat drop appears on its side."),
    ("thinking", "think-lightbulb", "The round ivory ball character thinks and a small glowing lightbulb appears above it, then fades."),
    ("thinking", "think-search", "The round ivory ball character looks around searching, eyes darting in different directions."),
    ("thinking", "think-count", "The round ivory ball character counts with small rhythmic nods, eyes moving up."),
    ("thinking", "think-gears", "The round ivory ball character thinks with tiny spinning gear symbols above its head that fade away."),
    ("thinking", "think-focus", "The round ivory ball character narrows its eyes into a determined focused stare at the camera."),
    ("thinking", "think-pace", "The round ivory ball character slides left and right as if pacing while thinking."),
    ("thinking", "think-dots", "The round ivory ball character thinks while three small dots appear one by one above it, then fade."),
    ("thinking", "think-zoom", "The round ivory ball character leans close to the camera as if inspecting something tiny."),
    ("waiting", "wait-knock", "The round ivory ball character bounces forward twice toward the camera as if knocking on the screen."),
    ("waiting", "wait-clock", "The round ivory ball character looks left and right impatiently, puffing its cheeks."),
    ("waiting", "wait-hopeful", "The round ivory ball character makes a hopeful smile, eyes sparkling."),
    ("waiting", "wait-peek", "The round ivory ball character peeks up from the bottom of frame, looking at the camera, then rises back."),
    ("waiting", "wait-bounce", "The round ivory ball character bounces on the spot eagerly like an excited puppy."),
    ("waiting", "wait-ahem", "The round ivory ball character makes a polite 'ahem' face, eyebrows raised at the camera."),
    ("done", "done-spin", "The round ivory ball character spins around joyfully once and lands facing the camera."),
    ("done", "done-stars", "The round ivory ball character beams with joy as small sparkling stars pop around it."),
    ("done", "done-confetti", "The round ivory ball character celebrates as a little burst of confetti falls around it."),
    ("done", "done-flip", "The round ivory ball character does a small backflip and lands perfectly."),
    ("done", "done-relief", "The round ivory ball character sighs with relief, eyes closing, a relaxed smile."),
    ("done", "done-giggle", "The round ivory ball character giggles happily and bounces twice."),
    ("done", "done-nod", "The round ivory ball character gives a satisfied firm nod with a smile."),
    ("done", "done-glow", "The round ivory ball character glows softly with a warm light for a moment, smiling."),
    ("error", "err-angry", "The round ivory ball character gets grumpy, eyebrows furrowed, a tiny steam puff above it, then calms down."),
    ("error", "err-facepalm", "The round ivory ball character rolls its eyes and sinks in exasperation."),
    ("error", "err-shiver", "The round ivory ball character shivers nervously, eyes darting."),
    ("error", "err-deflate", "The round ivory ball character deflates slightly like a sad balloon, then reinflates."),
    ("error", "err-confused", "The round ivory ball character looks confused with a small question mark appearing above it."),
    ("error", "err-cry", "The round ivory ball character sheds a small single tear, then wipes it away bravely by blinking."),
    ("love", "love-blush", "The round ivory ball character blushes deeply with pink cheeks and looks away shyly."),
    ("love", "love-heart-pop", "The round ivory ball character a small pink heart pops up above it, it smiles warmly."),
    ("hello", "hello-pop", "The round ivory ball character pops up from below into frame happily and says hi with a smile."),
    ("hello", "hello-wink", "The round ivory ball character greets the camera with a wink and a small bounce."),
    ("hello", "hello-wave", "The round ivory ball character waves hello by rocking side to side with a big smile."),
    ("hello", "hello-surprise", "The round ivory ball character notices the camera with a surprised happy face, then smiles."),
    ("hello", "hello-greet", "The round ivory ball character greets the camera warmly, bounces up once with a big smile as if saying hello."),
]


def call(url, body=None):
    req = urllib.request.Request(url, json.dumps(body).encode() if body else None,
                                 {"Authorization": f"Key {KEY}", "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


for cat, name, prompt in E:
    out = HOME / "clips" / cat / f"{name}.mp4"
    if out.exists():
        continue
    out.parent.mkdir(parents=True, exist_ok=True)
    t = time.time()
    job = call(f"https://queue.fal.run/{EP}", {"prompt": prompt + TAIL, "image_url": IMG, "end_image_url": IMG,
                                               "duration": 4, "resolution": "768P", "prompt_expansion_mode": "disabled"})
    while call(job["status_url"])["status"] != "COMPLETED":
        time.sleep(2)
    url = call(job["response_url"])["video"]["url"]
    raw = HOME / "raw" / f"{name}.mp4"
    urllib.request.urlretrieve(url, raw)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-an", "-vf", "scale=360:360", "-c:v", "libx264",
                    "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out], check=True)
    print(f"{cat}/{name} ok ({time.time() - t:.0f}s)", flush=True)
print("TERMINÉ")
