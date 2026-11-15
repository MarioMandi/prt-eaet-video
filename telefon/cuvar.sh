#!/data/data/com.termux/files/usr/bin/bash
# Čuvar rasporeda za PRT/EAET video paket. Dva neovisna okidača za posao.sh:
#   (1) Android posao 4711 (Termux:API job scheduler) - Xiaomi ga briše kad prisilno zaustavi Termux:API,
#       pa ga čuvar vraća čim primijeti da ga nema;
#   (2) petlja unutar Termuxa (svakih 15 min) - ne ovisi o Termux:API; gasi se kad se Termux zatvori
#       (Exit u obavijesti, `exit` u zadnjoj sesiji, povlačenje kartice), pa je Android posao
#       pri svakom okidanju vraća (posao.sh -> cuvar.sh --samo-petlja).
# Okidači se tako međusobno vraćaju. Dijele bravu i provjeru "već gotovo" u posao.sh, pa dvostruki rad nije moguć.
#
#   cuvar.sh             provjeri i popravi oba (poziva se iz ~/.bashrc, Termux:Boot i petlje)
#   cuvar.sh --samo-posao  vrati samo Android posao ako ga nema (poziva petlja jednom na sat)
#   cuvar.sh --samo-petlja vrati samo petlju ako ne radi (poziva Android posao); izlaz 0 = radi,
#                          10 = ponovno pokrenuta, 1/2 = nije uspjelo
#   cuvar.sh --postavi   jednokratno: poziv u ~/.bashrc + Termux:Boot skripta, pa provjeri i popravi
#   cuvar.sh --stanje    ispiši stanje
export PATH="$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"
REPO="$HOME/prt-eaet-video"
DIR="$HOME/.prt-video"
mkdir -p "$DIR"
JOB_ID=4711
POSAO="$REPO/telefon/posao.sh"
PID="$DIR/petlja.pid"

posao_registriran() { timeout 20 termux-job-scheduler -p 2>/dev/null | grep -q "Job $JOB_ID"; }
registriraj_posao() {
  command -v termux-job-scheduler >/dev/null || return 1
  timeout 25 termux-job-scheduler --job-id $JOB_ID --script "$POSAO" --period-ms 3600000 \
    --persisted true --network any >/dev/null 2>&1
  echo "$(date '+%Y-%m-%d %H:%M:%S') cuvar: Android posao $JOB_ID ponovno registriran" >> "$DIR/tik.log"
}
petlja_radi() {
  [ -f "$PID" ] || return 1
  local p; p=$(cat "$PID" 2>/dev/null); [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  # nakon prisilnog gašenja PID može dobiti drugi proces: provjeri da je to stvarno petlja
  if [ -r "/proc/$p/cmdline" ]; then tr '\0' ' ' < "/proc/$p/cmdline" | grep -q 'petlja\.sh' || return 1; fi
  return 0
}
pokreni_petlju() {
  # brava: dva istodobna okidanja ne smiju pokrenuti dvije petlje
  local L="$DIR/petlja.lock"
  if ! mkdir "$L" 2>/dev/null; then
    if [ -n "$(find "$L" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$L" 2>/dev/null; mkdir "$L" 2>/dev/null || return 2
    else
      # drugo okidanje upravo pokreće petlju: pričekaj da proradi
      for i in 1 2 3 4 5 6 7 8; do sleep 1; petlja_radi && return 0; done; return 2
    fi
  fi
  if petlja_radi; then rmdir "$L"; return 0; fi
  # kopija izvan repozitorija, da je git reset ne mijenja dok radi
  cp "$REPO/telefon/petlja.sh" "$DIR/petlja.sh" && chmod +x "$DIR/petlja.sh" || { rmdir "$L"; return 1; }
  if command -v setsid >/dev/null; then
    setsid nohup bash "$DIR/petlja.sh" >/dev/null 2>&1 < /dev/null &
  else
    nohup bash "$DIR/petlja.sh" >/dev/null 2>&1 < /dev/null &
  fi
  disown 2>/dev/null
  for i in 1 2 3 4 5; do sleep 1; petlja_radi && break; done
  rmdir "$L" 2>/dev/null
  petlja_radi
}

case "${1:-}" in
  --samo-posao)
    posao_registriran || registriraj_posao
    exit 0 ;;
  --samo-petlja)
    petlja_radi && exit 0
    pokreni_petlju && exit 10
    exit $? ;;
  --stanje)
    if posao_registriran; then echo "Android posao $JOB_ID: registriran"; else echo "Android posao $JOB_ID: NEMA"; fi
    if petlja_radi; then echo "Termux petlja: radi (PID $(cat "$PID"))"; else echo "Termux petlja: NE radi"; fi
    echo "Zadnja okidanja:"; tail -n 8 "$DIR/tik.log" 2>/dev/null || echo "  (još nema)"
    exit 0 ;;
  --postavi)
    if ! grep -qF 'prt-eaet-video/telefon/cuvar.sh' "$HOME/.bashrc" 2>/dev/null; then
      printf '\n# PRT/EAET video paket: čuvar rasporeda (vraća Android posao i petlju ako nestanu)\n' >> "$HOME/.bashrc"
      echo '[ -x "$HOME/prt-eaet-video/telefon/cuvar.sh" ] && ( bash "$HOME/prt-eaet-video/telefon/cuvar.sh" >/dev/null 2>&1 & )' >> "$HOME/.bashrc"
      echo "Dodano u ~/.bashrc (čuvar se pokreće pri svakom otvaranju Termuxa)."
    fi
    mkdir -p "$HOME/.termux/boot"
    printf '#!/data/data/com.termux/files/usr/bin/sh\n# PRT/EAET video paket: nakon paljenja mobitela vrati raspored (radi ako je instaliran Termux:Boot)\nsleep 60\nbash "$HOME/prt-eaet-video/telefon/cuvar.sh"\n' \
      > "$HOME/.termux/boot/prt-video.sh"
    chmod +x "$HOME/.termux/boot/prt-video.sh"
    echo "Postavljeno: ~/.termux/boot/prt-video.sh (koristi se ako imaš aplikaciju Termux:Boot)."
    ;;
esac

posao_registriran || registriraj_posao
if ! petlja_radi; then
  pokreni_petlju && echo "$(date '+%Y-%m-%d %H:%M:%S') cuvar: petlja ponovno pokrenuta" >> "$DIR/tik.log"
fi

if [ "${1:-}" = "--postavi" ]; then
  echo
  bash "$REPO/telefon/cuvar.sh" --stanje
fi
