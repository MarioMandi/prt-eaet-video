#!/data/data/com.termux/files/usr/bin/bash
# Postavljanje Soniox ključa za PRT/EAET video paket (transkripcija videa bez titlova).
# Ne traži GitHub ključ i ne dira ostatak instalacije.
# Pokretanje:  cd ~/prt-eaet-video && git pull -q && bash telefon/soniox_postavi.sh
KONF="$HOME/.config/prt-video"
mkdir -p "$KONF"; chmod 700 "$KONF"

maska() { local k="$1"; [ ${#k} -gt 12 ] && echo "${k:0:4}...${k: -4} (${#k} znakova)" || echo "(${#k} znakova)"; }

# datoteke u kojima bi mogao biti postojeći ključ (bez dijeljene memorije ~/storage i bez ovog repozitorija)
DATOTEKE=$(find "$HOME" -maxdepth 4 \( -path "$HOME/storage" -o -path "$HOME/prt-eaet-video" -o -path "$HOME/.cache" -o -path "$HOME/.npm" \) -prune -o \
  -type f \( -name '*.py' -o -name '*.sh' -o -name '.bashrc' -o -name '.profile' -o -name '.bash_profile' -o -name '*.env' -o -name '*.json' -o -name '*soniox*' \) \
  -size -2M -print 2>/dev/null | xargs -r grep -Ili soniox 2>/dev/null)

KAND_BAZA=$(printf '%s\n' $DATOTEKE | xargs -r grep -IhoE 'https://[a-z0-9.-]*soniox\.[a-z]+' 2>/dev/null | grep -v 'docs\.' | sort -u)
BAZA=""
DIJAG=""
probaj() {  # $1 = ključ; postavlja BAZA ako ga Soniox prihvati; DIJAG = odgovori po adresi
  local b c
  DIJAG=""
  for b in $KAND_BAZA https://api.eu.soniox.com https://api.soniox.com; do
    c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "$b/v1/models")
    DIJAG="$DIJAG ${b#https://}=$c"
    if [ "$c" = 200 ]; then BAZA="$b/v1"; return 0; fi
  done
  return 1
}

echo "== Soniox ključ"
KLJUC=""
# 1) varijabla okoline (i ona iz .bashrc)
for k in "${SONIOX_API_KEY:-}" "$(bash -ic 'printf %s "${SONIOX_API_KEY:-}"' 2>/dev/null)"; do
  [ -n "$k" ] && probaj "$k" && { KLJUC="$k"; echo "Pronađen u varijabli SONIOX_API_KEY: $(maska "$k")"; break; }
done
# 2) postojeće skripte (npr. transkript.py) i datoteke/varijable na koje one upućuju
if [ -z "$KLJUC" ]; then
  [ -n "$DATOTEKE" ] && echo "Tražim u: $(printf '%s ' $DATOTEKE | sed "s#$HOME#~#g")"
  KAND=$(mktemp)
  # a) ključ upisan u skriptu: "abc..." ili ='abc...' ili =abc... (export X=...)
  for f in $DATOTEKE; do
    grep -IiE 'soniox|api_?key|token|key|kljuc' "$f" 2>/dev/null | grep -oE "[\"'][A-Za-z0-9_-]{24,}[\"']|=[[:space:]]*[A-Za-z0-9_-]{24,}" | tr -d "\"'= \t" >> "$KAND"
  done
  # b) datoteke na koje skripte upućuju (~/..., $HOME/..., ".nesto" uz Path.home()) i datoteke s "soniox"/"key" u imenu
  REF=$(printf '%s\n' $DATOTEKE | xargs -r grep -IhoE "(~|\\\$HOME|/data/data/com\.termux/files/home)/[A-Za-z0-9._/-]+|[\"']\.[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*[\"']" 2>/dev/null \
        | tr -d "\"'" | sed -e "s#^~#$HOME#" -e "s#^\\\$HOME#$HOME#" -e "s#^\.#$HOME/.#" | sort -u)
  IME=$(find "$HOME" -maxdepth 4 \( -path "$HOME/storage" -o -path "$HOME/prt-eaet-video" -o -path "$HOME/.cache" \) -prune -o \
        -type f \( -iname '*soniox*' -o -iname '*api*key*' -o -iname '*kljuc*' -o -iname '*.key' -o -iname '.env' \) -size -4k -print 2>/dev/null)
  for f in $REF $IME; do
    [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 4096 ] || continue
    tr -d '[:space:]' < "$f" | grep -oE '^[^"=]{20,}$' >> "$KAND"          # cijela datoteka je ključ
    grep -oE "[\"'][A-Za-z0-9_.:+/-]{20,}[\"']|=[[:space:]]*[\"']?[A-Za-z0-9_.:+/-]{20,}" "$f" 2>/dev/null | tr -d "\"'= \t" >> "$KAND"
    echo "$f" >> "$KAND.izvori"
  done
  # c) varijable okoline koje skripte čitaju (os.environ.get("X"), getenv("X"), $X)
  for v in $(printf '%s\n' $DATOTEKE | xargs -r grep -IhoE "(environ(\.get)?[\[(]|getenv\()[[:space:]]*[\"'][A-Za-z_][A-Za-z0-9_]*[\"']|\\\$\{?[A-Z_]*(KEY|TOKEN|SONIOX)[A-Z_]*" 2>/dev/null \
            | grep -oE "[A-Za-z_][A-Za-z0-9_]*[\"']?$|[A-Z_]*(KEY|TOKEN|SONIOX)[A-Z_]*$" | tr -d "\"'" | sort -u); do
    bash -ic "printf '%s\n' \"\${$v:-}\"" 2>/dev/null >> "$KAND"
  done
  [ -f "$KAND.izvori" ] && echo "Provjeravam i: $(sort -u "$KAND.izvori" | sed "s#$HOME#~#g" | tr '\n' ' ')"
  for k in $(grep -E '^[^[:space:]]{20,}$' "$KAND" | grep -vE '^(https?|wss?):' | sort -u); do
    if probaj "$k"; then KLJUC="$k"; echo "Pronađen: $(maska "$k")"; break; fi
    echo "  kandidat $(maska "$k") odbijen:$DIJAG"
  done
  rm -f "$KAND" "$KAND.izvori"
fi
# 3) ručni unos
if [ -z "$KLJUC" ]; then
  echo "Ključ nije pronađen automatski. Zalijepi ga (Soniox konzola -> API keys): dugo pritisni -> Paste -> Enter."
  for pokusaj in 1 2 3; do
    read -rsp "Soniox ključ (pokušaj $pokusaj/3): " k; echo
    k=$(printf '%s' "$k" | tr -d '[:space:]')
    [ -z "$k" ] && { echo "  Ništa nije zalijepljeno."; continue; }
    echo "  Zalijepljeno: $(maska "$k")"
    if probaj "$k"; then KLJUC="$k"; break; fi
    echo "  Soniox ne prihvaća ovaj ključ. Odgovori:$DIJAG (401 = krivi ključ za tu adresu)"
  done
fi
if [ -z "$KLJUC" ]; then echo "Soniox NIJE postavljen."; exit 1; fi

printf '%s\n%s\n' "$KLJUC" "$BAZA" | python3 -c "import json,sys;k,b=sys.stdin.read().split();json.dump({'kljuc':k,'baza':b},open('$KONF/soniox.json','w'))"
chmod 600 "$KONF/soniox.json"
unset KLJUC k
echo "Soniox OK ($BAZA). Spremljeno u ~/.config/prt-video/soniox.json (samo na mobitelu)."
echo "Od sljedećeg pokretanja relevantni videi bez titlova dobivaju transkript (limit 180 min tjedno, ~0,30 \$)."
