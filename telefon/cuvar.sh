#!/data/data/com.termux/files/usr/bin/bash
# Čuvar rasporeda za PRT/EAET video paket. Dva neovisna okidača za posao.sh:
#   (1) Android posao 4711 (Termux:API job scheduler) - Xiaomi ga briše kad prisilno zaustavi Termux:API,
#       pa ga čuvar vraća čim primijeti da ga nema;
#   (2) petlja unutar Termuxa (svakih 15 min) - ne ovisi o Termux:API.
# Oba dijele bravu i provjeru "već gotovo" u posao.sh, pa dvostruki rad nije moguć.
#
#   cuvar.sh             provjeri i popravi oba (poziva se iz ~/.bashrc, Termux:Boot i petlje)
#   cuvar.sh --samo-posao  vrati samo Android posao ako ga nema
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
petlja_radi() { [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; }
pokreni_petlju() {
  # kopija izvan repozitorija, da je git pull ne mijenja dok radi
  cp "$REPO/telefon/petlja.sh" "$DIR/petlja.sh" && chmod +x "$DIR/petlja.sh" || return 1
  if command -v setsid >/dev/null; then
    setsid nohup bash "$DIR/petlja.sh" >/dev/null 2>&1 < /dev/null &
  else
    nohup bash "$DIR/petlja.sh" >/dev/null 2>&1 < /dev/null &
  fi
  disown 2>/dev/null
  sleep 1
}

case "${1:-}" in
  --samo-posao)
    posao_registriran || registriraj_posao
    exit 0 ;;
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
petlja_radi || pokreni_petlju

if [ "${1:-}" = "--postavi" ]; then
  echo
  bash "$REPO/telefon/cuvar.sh" --stanje
fi
