#!/data/data/com.termux/files/usr/bin/bash
# PRT/EAET tjedni video paket - posao koji pokreću Android raspored (Termux:API) i Termux petlja (petlja.sh).
# Od v2.0: podaci ostaju na mobitelu (~/.prt-video/radni); u javni repozitorij ide samo šifrirani paket.
# Stvarni rad radi samo u prozoru NEDJELJA 18:00 - PONEDJELJAK 07:40, i to jednom po ciklusu;
# ostala pokretanja odmah završe (traju < 1 s).
#   posao.sh          - automatsko pokretanje (poštuje prozor)
#   posao.sh --sada   - ručno pokretanje odmah (npr. prečac na početnom zaslonu)
#   posao.sh --petlja - pokretanje iz Termux petlje (petlja.sh, svakih 15 min)
export PATH="$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"
REPO="$HOME/prt-eaet-video"          # kod (javni repozitorij); na mobitelu u njemu NEMA podataka
DIR="$HOME/.prt-video"
RADNI="$DIR/radni"                    # podaci samo na mobitelu: tjedni/ (nešifrirani paketi) i stanje/
KLJUC="$HOME/.config/prt-video/paket.key"   # ključ za šifriranje paketa (isti je u uputi tjednog zadatka)
LOG="$DIR/posao.log"
mkdir -p "$DIR" "$RADNI"

# log ne smije rasti beskonačno
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then tail -c 300000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi

RUCNO=0; IZVOR=android
case "${1:-}" in --sada) RUCNO=1; IZVOR=rucno;; --petlja) IZVOR=petlja;; esac
# dijagnostika: svako pokretanje (i izvan prozora) ostavlja trag; zadnjih 200 redaka
echo "$(date '+%Y-%m-%d %H:%M:%S') izvor=$IZVOR" >> "$DIR/tik.log"
[ "$(wc -l < "$DIR/tik.log")" -gt 200 ] && tail -n 200 "$DIR/tik.log" > "$DIR/tik.tmp" && mv "$DIR/tik.tmp" "$DIR/tik.log"
if [ $RUCNO -eq 0 ]; then
  dan=$(date +%u); hm=$((10#$(date +%H%M)))
  if ! { [ "$dan" = 7 ] && [ $hm -ge 1800 ]; } && ! { [ "$dan" = 1 ] && [ $hm -lt 740 ]; }; then exit 0; fi
  # brza provjera bez gita i mreže: ciklus ovog ponedjeljka već je gotov u zadnjih 20 h -> izlaz
  if python3 - "$RADNI/stanje/zadnji_rad.json" <<'PYEOF' 2>/dev/null
import json, sys, datetime as d
s = json.load(open(sys.argv[1]))
t = d.date.today(); pon = (t if t.isoweekday() == 1 else t + d.timedelta(8 - t.isoweekday())).isoformat()
z = d.datetime.fromisoformat(s["zadnja_promjena"])
sys.exit(0 if s.get("ciklus") == pon and s.get("faza") == "gotovo"
         and (d.datetime.now(d.timezone.utc) - z).total_seconds() < 20 * 3600 else 1)
PYEOF
  then exit 0; fi
fi

# samo jedan primjerak odjednom (zaključavanje istječe nakon 3 h)
LOCK="$DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" || exit 0; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null; command -v termux-wake-unlock >/dev/null && termux-wake-unlock' EXIT

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') start (ručno=$RUCNO)"
  set -o pipefail
  command -v termux-wake-lock >/dev/null && termux-wake-lock
  cd "$REPO" || { echo "GREŠKA: nema $REPO"; exit 1; }

  # 1) kod i izvori.json: repozitorij na mobitelu je samo kopija koda, pa ga se smije poravnati s GitHubom
  git fetch -q origin && git reset -q --hard origin/main || echo "UPOZORENJE: dohvat koda nije uspio (nastavljam s lokalnom verzijom)"
  chmod +x telefon/*.sh 2>/dev/null

  # YouTube se često mijenja: yt-dlp nightly ažuriraj najviše jednom dnevno
  YT="$HOME/bin/yt-dlp"
  if [ -f "$YT" ] && [ -z "$(find "$DIR/yt_azuriran" -mmin -1440 2>/dev/null)" ]; then
    python3 "$YT" --update-to nightly 2>&1 | tail -1 && touch "$DIR/yt_azuriran"
  fi

  # 2) sakupljanje (u $RADNI, ne u repozitorij)
  ARG=""; [ $RUCNO -eq 1 ] && ARG="--sada"
  python3 telefon/prt_video.py $ARG --radni "$RADNI"
  echo "prt_video.py izlazni kod: $?"

  # 3) objava: SAMO šifrirani paket + kratki status (paket/ZADNJI.txt)
  C=$(head -1 "$RADNI/tjedni/ZADNJI.txt" 2>/dev/null)
  if [ -z "$C" ] || [ ! -d "$RADNI/tjedni/$C" ]; then
    echo "UPOZORENJE: nema paketa za objavu"
  elif [ ! -s "$KLJUC" ] || ! command -v openssl >/dev/null; then
    echo "GREŠKA: nema ključa ($KLJUC) ili programa openssl - paket NIJE objavljen. Pokreni telefon/prijelaz.sh."
  else
    tail -n 40 "$DIR/tik.log" > "$RADNI/stanje/pokretanja.txt" 2>/dev/null
    mkdir -p paket
    if tar -C "$RADNI" -czf - "tjedni/$C" stanje/zadnji_rad.json stanje/pokretanja.txt \
         | openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt -pass file:"$KLJUC" -out "paket/$C.tar.gz.enc.tmp"; then
      mv "paket/$C.tar.gz.enc.tmp" "paket/$C.tar.gz.enc"
      ISTJECE=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('istjece',''))" "$HOME/.config/prt-video/github.json" 2>/dev/null)
      { sed -n 1,3p "$RADNI/tjedni/ZADNJI.txt"; echo "$C.tar.gz.enc"; echo "github_kljuc_istjece: $ISTJECE"; } > paket/ZADNJI.txt
      ls paket/*.tar.gz.enc 2>/dev/null | sort | head -n -12 | xargs -r git rm -q --cached --ignore-unmatch
      ls paket/*.tar.gz.enc 2>/dev/null | sort | head -n -12 | xargs -r rm -f
      git add paket
      git diff --cached --quiet || git commit -q -m "mobitel: šifrirani paket $C ($(date '+%Y-%m-%d %H:%M'))"
      for i in 1 2 3; do
        if git push -q origin HEAD:main 2>&1; then echo "push OK"; break; fi
        echo "push nije uspio (pokušaj $i)"; sleep 20; git pull -q --rebase origin main
      done
    else
      rm -f "paket/$C.tar.gz.enc.tmp"; echo "GREŠKA: šifriranje nije uspjelo"
    fi
  fi
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') kraj"
} 2>&1 | if [ -t 1 ]; then tee -a "$LOG"; else cat >> "$LOG"; fi
