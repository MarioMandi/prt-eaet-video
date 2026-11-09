# prt-eaet-video

Tjedni YouTube paket za zadatak **NOVI IZVORI ZA PRT I EAET** (Korak 5).
Agent u oblaku ne može pristupiti YouTubeu, a zadaci po rasporedu ne mogu čitati privatne
GitHub repozitorije. Zato mobitel (Termux + yt-dlp) svake nedjelje navečer prikupi nove videe i
**samo titlove** (video se ne preuzima), zapakira ih, **šifrira (AES-256)** i objavi ovdje.
Repozitorij je javan; javno su vidljivi samo kod i šifrirani paketi. Ključ postoji samo na
mobitelu i u uputi tjednog zadatka.

## Tok
1. **Dva neovisna okidača** pokreću `telefon/posao.sh`: Android posao 4711 (Termux:API, svakih sat
   vremena) i petlja unutar Termuxa (`telefon/petlja.sh`, svakih 15 min, bez wake-locka dok spava).
   Xiaomi briše Android posao kad prisilno zaustavi Termux:API, pa ga `telefon/cuvar.sh` vraća pri
   svakom otvaranju Termuxa (~/.bashrc), nakon paljenja (Termux:Boot) i jednom na sat iz petlje.
   Rad se izvodi samo u prozoru **nedjelja 18:00 – ponedjeljak 07:40**, jednom po ciklusu.
2. `posao.sh`: poravna kopiju koda s GitHubom (`git reset --hard origin/main` - na mobitelu u
   repozitoriju nema podataka), ažurira yt-dlp (najviše jednom dnevno), pokreće
   `telefon/prt_video.py`, zatim **šifrira** paket i objavi samo `paket/<ciklus>.tar.gz.enc` i
   `paket/ZADNJI.txt`.
3. `prt_video.py` (podaci u `~/.prt-video/radni`, samo na mobitelu):
   - kanali iz `izvori.json` (kartice *videos* i *streams*), ID kanala razriješi sam;
   - YouTube pretrage po pojmovima i autorima (filtar „objavljeno ovaj mjesec");
   - za svaki neviđeni video: podaci i titlovi (autorski > automatski na jeziku videa), čisti tekst
     s oznakama vremena svake ~2 min;
   - relevantni videi bez titlova: zvuk → Soniox (EU) → tekst; zvuk se odmah briše
     (samo kustosirani kanali ili jak pojam u naslovu; limit 180 min tjedno ≈ 0,30 $);
   - rezultati pretraga bez ijednog pojma iz `jaki_pojmovi` idu u popis „odbačeno".
4. Tjedni zadatak (Korak 5) preuzme `paket/ZADNJI.txt` i paket preko
   `raw.githubusercontent.com` (bez prijave), dešifrira ga ključem iz svoje upute i obradi.

## Struktura repozitorija (javno)
| Put | Sadržaj |
|---|---|
| `izvori.json` | kanali, pretrage, limiti, pojmovi relevantnosti |
| `telefon/` | skripte za mobitel |
| `paket/ZADNJI.txt` | 1 ciklus, 2 vrijeme, 3 stanje, 4 datoteka paketa, 5 istek GitHub ključa |
| `paket/<GGGG-MM-DD>.tar.gz.enc` | šifrirani paket (zadnjih 12 tjedana) |

Sadržaj šifriranog paketa: `tjedni/<ciklus>/INDEX.md`, `index.json`, `t/<id>.txt`,
`stanje/zadnji_rad.json` (dijagnostika), `stanje/pokretanja.txt` (okidanja rasporeda).

Dešifriranje (Linux, macOS, Termux):
```
openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -pass pass:<KLJUČ> -in paket/<ciklus>.tar.gz.enc | tar xz
```

Tajne nisu u repozitoriju: GitHub ključ je samo u `.git/config` na mobitelu, Soniox ključ u
`~/.config/prt-video/soniox.json`, ključ paketa u `~/.config/prt-video/paket.key` (sve chmod 600).

## Instalacija / novi mobitel
Preduvjeti: Termux i **Termux:API** iz F-Droida, `termux-setup-storage` jednom izveden.
1. Fine-grained GitHub ključ: samo repozitorij `prt-eaet-video`, *Contents: Read and write*.
2. `telefon/instaliraj.sh` preuzmi na mobitel i pokreni: `bash ~/storage/downloads/instaliraj.sh`
   (traži GitHub ključ, ključ za šifriranje iz upute tjednog zadatka i Soniox ključ).
3. Xiaomi/HyperOS: Termux i Termux:API → *Automatsko pokretanje u pozadini* uključeno,
   *Napajanje: Nema ograničenja*; Termux zaključan u nedavnim aplikacijama.

## Ručno pokretanje i dijagnostika
- Odmah: `~/prt-eaet-video/telefon/posao.sh --sada`
- Okidači: `bash ~/prt-eaet-video/telefon/cuvar.sh --stanje`
- Log: `~/.prt-video/posao.log`
- Prijelaz starije instalacije (prije v2.0): `telefon/prijelaz.sh <ključ>`
