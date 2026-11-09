#!/data/data/com.termux/files/usr/bin/bash
# Petlja unutar Termuxa: svakih 15 min pokreće posao.sh (koji sam odlučuje je li u prozoru
# ned 18:00 - pon 07:40 i je li ciklus već gotov). Dok spava ne drži wake-lock, pa ne troši bateriju.
# Pokreće je cuvar.sh (kopira je u ~/.prt-video/ i pokreće odande).
export PATH="$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"
DIR="$HOME/.prt-video"
echo $$ > "$DIR/petlja.pid"
trap 'rm -f "$DIR/petlja.pid"' EXIT
n=0
while true; do
  # jednom na sat vrati Android posao ako ga je Xiaomi obrisao
  [ $((n % 4)) -eq 0 ] && bash "$HOME/prt-eaet-video/telefon/cuvar.sh" --samo-posao >/dev/null 2>&1
  bash "$HOME/prt-eaet-video/telefon/posao.sh" --petlja >/dev/null 2>&1
  n=$((n + 1))
  sleep 900
done
