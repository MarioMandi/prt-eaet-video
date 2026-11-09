#!/data/data/com.termux/files/usr/bin/bash
# Jednokratni prijelaz na v2.0 (javni repozitorij, šifrirani paketi). Sigurno ga je pokrenuti više puta.
#   bash prijelaz.sh <KLJUČ_64_HEX>
# Radi:
#   1. premjesti podatke (tjedni/, stanje/) iz repozitorija u ~/.prt-video/radni (samo mobitel)
#   2. spremi ključ za šifriranje u ~/.config/prt-video/paket.key (chmod 600)
#   3. instalira openssl ako ga nema
#   4. poravna kopiju repozitorija s GitHubom (povijest je 09.11.2026. prepisana bez nešifriranih transkripata)
#   5. ponovno pokrene čuvar/petlju i provjeri da ključ otvara objavljeni paket
export PATH="$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"
REPO="$HOME/prt-eaet-video"
DIR="$HOME/.prt-video"
RADNI="$DIR/radni"
KONF="$HOME/.config/prt-video"
KLJUC="$KONF/paket.key"
mkdir -p "$DIR" "$RADNI/stanje" "$KONF"; chmod 700 "$KONF"

K=$(printf '%s' "${1:-}" | tr -d '[:space:]')
if ! printf '%s' "$K" | grep -qE '^[0-9a-f]{64}$'; then
  if [ -s "$KLJUC" ]; then
    echo "Ključ nije zadan; koristim postojeći $KLJUC."
  else
    echo "GREŠKA: zadaj ključ (64 heksadecimalna znaka): bash prijelaz.sh <ključ>"; exit 1
  fi
else
  printf '%s' "$K" > "$KLJUC"; chmod 600 "$KLJUC"; echo "1/5 Ključ spremljen u ~/.config/prt-video/paket.key"
fi

# pričekaj ako posao upravo radi
for i in $(seq 1 60); do mkdir "$DIR/lock" 2>/dev/null && break; [ $i -eq 1 ] && echo "Čekam da završi posao koji je u tijeku..."; sleep 10; done
trap 'rmdir "$DIR/lock" 2>/dev/null' EXIT

echo "2/5 Premještam podatke u ~/.prt-video/radni"
if [ -d "$REPO/tjedni" ]; then
  mkdir -p "$RADNI/tjedni"
  cp -rn "$REPO/tjedni/." "$RADNI/tjedni/" 2>/dev/null
fi
for f in vidjeno.json kanali.json zadnji_rad.json; do
  [ -f "$REPO/stanje/$f" ] && [ ! -f "$RADNI/stanje/$f" ] && cp "$REPO/stanje/$f" "$RADNI/stanje/$f"
done
echo "   paketi: $(ls "$RADNI/tjedni" 2>/dev/null | grep -c '^20') | stanje: $(ls "$RADNI/stanje" 2>/dev/null | tr '\n' ' ')"

echo "3/5 openssl"
command -v openssl >/dev/null || pkg install -y openssl-tool >/dev/null 2>&1 || pkg install -y openssl >/dev/null 2>&1
command -v openssl >/dev/null || { echo "GREŠKA: openssl nije instaliran (pkg install openssl-tool)"; exit 1; }
openssl version

echo "4/5 Poravnavam kod s GitHubom"
cd "$REPO" || exit 1
git rebase --abort 2>/dev/null; git merge --abort 2>/dev/null
git fetch -q origin || { echo "GREŠKA: git fetch"; exit 1; }
git reset -q --hard origin/main && git clean -qfd tjedni stanje 2>/dev/null
chmod +x telefon/*.sh
echo "   kod: $(git log -1 --format='%h %s' | cut -c1-70)"

echo "5/5 Čuvar, petlja i provjera ključa"
[ -f "$DIR/petlja.pid" ] && kill "$(cat "$DIR/petlja.pid")" 2>/dev/null; rm -f "$DIR/petlja.pid"
rmdir "$DIR/lock" 2>/dev/null; trap - EXIT
bash "$REPO/telefon/cuvar.sh" --postavi >/dev/null 2>&1
bash "$REPO/telefon/cuvar.sh" --stanje | head -2
P=$(sed -n 4p paket/ZADNJI.txt 2>/dev/null)
if [ -n "$P" ] && [ -f "paket/$P" ]; then
  N=$(openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -pass file:"$KLJUC" -in "paket/$P" 2>/dev/null | tar tzf - 2>/dev/null | wc -l)
  if [ "$N" -gt 0 ]; then echo "Ključ OK: objavljeni paket $P se otvara ($N datoteka)."; else echo "GREŠKA: ključ ne otvara paket $P - provjeri da si kopirao cijeli ključ."; exit 1; fi
else
  echo "(još nema objavljenog paketa za provjeru ključa)"
fi
echo
echo "Prijelaz gotov. Od sada se u repozitorij šalje samo šifrirani paket."
