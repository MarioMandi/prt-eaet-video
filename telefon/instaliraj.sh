#!/data/data/com.termux/files/usr/bin/bash
# Instalacija PRT/EAET tjednog video paketa na Android (Termux).
# Pokretanje u Termuxu:  bash ~/storage/downloads/instaliraj.sh
# (može se pokrenuti ponovno bilo kada - npr. novi ključ, novi mobitel; postojeće stanje se čuva)
set -u
REPO_PUT="github.com/MarioMandi/prt-eaet-video.git"
REPO="$HOME/prt-eaet-video"
KONF="$HOME/.config/prt-video"
JOB_ID=4711
mkdir -p "$KONF" "$HOME/bin" "$HOME/.prt-video"; chmod 700 "$KONF"

case "${PREFIX:-}" in *com.termux*) ;; *) echo "Ovo pokreni u Termuxu."; exit 1;; esac

echo; echo "== 1/6 Paketi (git, python, termux-api, openssl)"
for p in git python termux-api curl openssl-tool; do
  dpkg -s "$p" >/dev/null 2>&1 || pkg install -y "$p" || { echo "GREŠKA: pkg install $p"; exit 1; }
done
if [ ! -f "$HOME/bin/yt-dlp" ] && ! command -v yt-dlp >/dev/null; then
  echo "yt-dlp nije pronađen - preuzimam nightly u ~/bin/yt-dlp"
  curl -fsSL -o "$HOME/bin/yt-dlp" https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp || exit 1
  chmod +x "$HOME/bin/yt-dlp"
fi
echo "yt-dlp: $( (python3 "$HOME/bin/yt-dlp" --version 2>/dev/null || yt-dlp --version) | head -1)"

echo; echo "== 2/6 GitHub ključ"
echo "Zalijepi ključ (fine-grained, samo za prt-eaet-video): dugo pritisni ekran -> Paste -> Enter."
echo "Znakovi se neće prikazivati; nakon Entera vidjet ćeš početak i kraj zalijepljenog teksta."
OK=0
for pokusaj in 1 2 3; do
  read -rsp "Ključ (pokušaj $pokusaj/3): " TOKEN; echo
  TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')
  N=${#TOKEN}
  if [ "$N" -eq 0 ]; then echo "  Ništa nije zalijepljeno (0 znakova)."; continue; fi
  if [ "$N" -gt 20 ]; then echo "  Zalijepljeno: ${TOKEN:0:15}...${TOKEN: -4} ($N znakova)"; else echo "  Zalijepljeno: $N znakova"; fi
  case "$TOKEN" in
    github_pat_*|ghp_*) ;;
    *) echo "  UPOZORENJE: GitHub ključ počinje s 'github_pat_' - u međuspremniku je vjerojatno nešto drugo.";;
  esac
  HDR=$(curl -sS -D - -o /dev/null -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/MarioMandi/prt-eaet-video)
  KOD=$(printf '%s' "$HDR" | head -1 | awk '{print $2}')
  if [ "$KOD" = 200 ]; then OK=1; break; fi
  case "$KOD" in
    401) echo "  GREŠKA 401: GitHub ne prepoznaje ovaj ključ (pogrešno kopiran, nepotpun ili obrisan).";;
    403|404) echo "  GREŠKA $KOD: ključ je valjan, ali nema pristup repozitoriju prt-eaet-video (provjeri Repository access i Contents).";;
    *) echo "  GREŠKA: odgovor GitHuba '$KOD' (provjeri internet).";;
  esac
done
if [ $OK -ne 1 ]; then
  echo "Ključ nije prihvaćen. Kopiraj ga ponovno (ili napravi novi) i pokreni skriptu ponovno."; exit 1
fi
ISTJECE=$(printf '%s' "$HDR" | grep -i '^github-authentication-token-expiration:' | cut -d' ' -f2- | tr -d '\r')
printf '{"istjece": "%s"}\n' "$ISTJECE" > "$KONF/github.json"
echo "Ključ OK. Istječe: ${ISTJECE:-nepoznato}"

echo; echo "== 3/6 Repozitorij"
URL="https://MarioMandi:$TOKEN@$REPO_PUT"
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" remote set-url origin "$URL"
  git -C "$REPO" pull -q --rebase --autostash || { echo "GREŠKA: git pull"; exit 1; }
else
  git clone -q "$URL" "$REPO" || { echo "GREŠKA: git clone"; exit 1; }
fi
chmod 600 "$REPO/.git/config"
git -C "$REPO" config user.name "Mobitel (Termux)"
git -C "$REPO" config user.email "mobitel@prt-eaet-video.local"
chmod +x "$REPO"/telefon/*.sh
unset TOKEN URL
echo "Repozitorij: $REPO"

echo; echo "== 3b Ključ za šifriranje paketa"
# paketi se u (javni) repozitorij šalju šifrirani; isti ključ je u uputi tjednog zadatka (Korak 5 a)
if [ -s "$KONF/paket.key" ]; then
  echo "Koristim postojeći ključ (~/.config/prt-video/paket.key)."
else
  echo "Zalijepi ključ za šifriranje (64 znaka; nalazi se u uputi tjednog zadatka, Korak 5 a)."
  for pokusaj in 1 2 3; do
    read -rp "Ključ za šifriranje (pokušaj $pokusaj/3): " PK
    PK=$(printf '%s' "$PK" | tr -d '[:space:]')
    if printf '%s' "$PK" | grep -qE '^[0-9a-f]{64}$'; then printf '%s' "$PK" > "$KONF/paket.key"; chmod 600 "$KONF/paket.key"; echo "  Spremljeno."; break; fi
    echo "  Ključ mora imati točno 64 znaka 0-9 i a-f."
  done
  [ -s "$KONF/paket.key" ] || { echo "GREŠKA: ključ nije spremljen - paketi se neće objavljivati."; exit 1; }
fi
mkdir -p "$HOME/.prt-video/radni"

echo; echo "== 4/6 Soniox (samo za videe bez titlova; ~0,10 \$/h, tjedni limit 180 min)"
SKEY="${SONIOX_API_KEY:-}"
if [ -z "$SKEY" ] && [ -f "$KONF/soniox.json" ]; then
  SKEY=$(python3 -c "import json;print(json.load(open('$KONF/soniox.json')).get('kljuc',''))" 2>/dev/null)
  [ -n "$SKEY" ] && echo "Koristim već spremljeni Soniox ključ."
fi
[ -n "${SONIOX_API_KEY:-}" ] && echo "Koristim Soniox ključ iz varijable SONIOX_API_KEY."
if [ -z "$SKEY" ]; then
  read -rsp "Soniox API ključ (Enter = preskoči; tada se videi bez titlova samo popisuju): " SKEY; echo
  SKEY=$(printf '%s' "$SKEY" | tr -d '[:space:]')
fi
if [ -n "$SKEY" ]; then
  KAND=$(grep -IhoE 'https://api[a-z0-9.-]*soniox\.com' "$HOME"/*.py "$HOME"/bin/*.py "$HOME"/bin/* 2>/dev/null | sort -u)
  BAZA=""
  for b in $KAND https://api.eu.soniox.com https://api.soniox.com; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SKEY" "$b/v1/models")
    if [ "$code" = 200 ]; then BAZA="$b/v1"; break; fi
  done
  if [ -n "$BAZA" ]; then
    printf '%s\n%s\n' "$SKEY" "$BAZA" | python3 -c "import json,sys;k,b=sys.stdin.read().split();json.dump({'kljuc':k,'baza':b},open('$KONF/soniox.json','w'))"
    chmod 600 "$KONF/soniox.json"; echo "Soniox OK ($BAZA)"
  else
    echo "UPOZORENJE: Soniox ključ nije prihvaćen ni na EU ni na globalnoj adresi - Soniox ostaje isključen."
  fi
fi
unset SKEY

echo; echo "== 5/6 Raspored (Termux:API, svakih sat vremena; rad samo ned 18:00 - pon 07:40)"
if ! timeout 25 termux-job-scheduler -p >/dev/null 2>&1; then
  echo "GREŠKA: aplikacija Termux:API ne odgovara."
  echo "Instaliraj 'Termux:API' iz F-Droida (isti izvor kao Termux), otvori je jednom i ponovno pokreni ovu skriptu."
  exit 1
fi
termux-job-scheduler --cancel --job-id $JOB_ID >/dev/null 2>&1
termux-job-scheduler --job-id $JOB_ID --script "$REPO/telefon/posao.sh" --period-ms 3600000 --persisted true --network any
termux-job-scheduler -p
# Xiaomi briše Android posao kad prisilno zaustavi Termux:API -> čuvar ga vraća, a petlja u Termuxu je drugi, neovisni okidač
bash "$REPO/telefon/cuvar.sh" --postavi

# prečac za ručno pokretanje (vidljiv ako imaš Termux:Widget; inače bezopasan)
mkdir -p "$HOME/.shortcuts"; chmod 700 "$HOME/.shortcuts"
cat > "$HOME/.shortcuts/PRT-video-sada.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$REPO/telefon/posao.sh" --sada
echo; read -p "Gotovo. Enter za zatvaranje. " x
EOF
chmod +x "$HOME/.shortcuts/PRT-video-sada.sh"

echo; echo "== 6/6 Prvo pokretanje (5-15 min; prvi put se postavlja bazna linija i šalje probni paket)"
"$REPO/telefon/posao.sh" --sada
echo
echo "Zadnji paket: $(head -1 "$HOME/.prt-video/radni/tjedni/ZADNJI.txt" 2>/dev/null) | stanje: $(sed -n 3p "$HOME/.prt-video/radni/tjedni/ZADNJI.txt" 2>/dev/null) | objavljeno: $(sed -n 4p "$REPO/paket/ZADNJI.txt" 2>/dev/null)"
echo "Log: ~/.prt-video/posao.log"
cat <<'EOF'

================ OBAVEZNO NA XIAOMIJU (jednom) ================
Postavke > Aplikacije > Upravljanje aplikacijama > Termux:
  - Automatsko pokretanje: UKLJUČENO
  - Ušteda baterije: Bez ograničenja
Isto za aplikaciju Termux:API.
U nedavnim aplikacijama zaključaj Termux (povuci karticu prema dolje -> lokot).
Bez ovoga Xiaomi gasi raspored i paket u nedjelju neće otići.
================================================================
Javi Claudeu u razgovoru: "instalirano".
EOF
