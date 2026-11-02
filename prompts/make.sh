#!/bin/zsh
cd ~/claude-buddy/prompts
i=0
for t in "Je prépare la lecture du message." "Une seconde, je prépare le message." "D'accord, je te lis ça."; do
  u=$(curl -s https://fal.run/elevenlabs/tts/eleven-v4-turbo -H "Authorization: Key $FAL_KEY" -H 'Content-Type: application/json' \
    -d "{\"text\":\"$t\",\"voice\":\"George\",\"output_format\":\"mp3_44100_64\"}" | /opt/homebrew/bin/python3.12 -c 'import sys,json;print(json.load(sys.stdin)["audio"]["url"])')
  curl -s -o prep$i.mp3 "$u"; i=$((i+1))
done
ls -la
