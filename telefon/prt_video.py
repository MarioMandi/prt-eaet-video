#!/usr/bin/env python3
"""
PRT/EAET tjedni video paket - sakupljač (mobitel/Termux ili bilo koje računalo).

Što radi:
  1. Izlista nove videe s kanala iz izvori.json i rezultate YouTube pretraga.
  2. Za svaki novi video dohvati podatke (naslov, kanal, datum, trajanje, opis)
     i SAMO titlove (autorske, inače automatske). Video se NE preuzima.
  3. Za relevantne videe bez titlova (ako je postavljen Soniox ključ) preuzme
     samo zvuk, transkribira ga preko Sonioxa i odmah briše zvuk lokalno i kod Sonioxa.
  4. Sve zapiše u radni direktorij na uređaju (~/.prt-video/radni): tjedni/<datum ponedjeljka>/
     (INDEX.md, index.json, t/<id>.txt) te stanje/ (vidjeno.json, zadnji_rad.json, kanali.json).

Šifriranje paketa i objavu u (javni) repozitorij radi posao.sh, ne ova skripta.

Pokretanje:  python3 prt_video.py [--sada] [--repo PUT] [--ytdlp PUT]
  --sada   ne preskači ako je ciklus nedavno dovršen
"""
import argparse
import datetime as dt
import html
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

VERZIJA = "2.0 (2026-11-09)"
KONFIG_DIR = Path.home() / ".config" / "prt-video"


# ----------------------------------------------------------------- pomoćno
def sada():
    return dt.datetime.now().astimezone()


def log(*a):
    print(sada().strftime("%H:%M:%S"), *a, flush=True)


def ucitaj_json(p, zadano):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return zadano
    except Exception as e:  # oštećena datoteka - ne ruši rad
        log(f"UPOZORENJE: ne mogu pročitati {p}: {e}")
        return zadano


def spremi_json(p, obj):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(p)


def fmt_trajanje(s):
    if not s:
        return "?"
    s = int(s)
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def fmt_marker(s):
    s = int(s)
    return f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def ymd(d):
    """YYYYMMDD -> YYYY-MM-DD"""
    if not d or len(d) != 8:
        return None
    return f"{d[:4]}-{d[4:6]}-{d[6:]}"


def ciklus_za(danas):
    """Datum ponedjeljka (izvješća) kojem pripada ovaj rad."""
    wd = danas.isoweekday()
    return danas if wd == 1 else danas + dt.timedelta(days=8 - wd)


# ----------------------------------------------------------------- yt-dlp
class YtGreska(Exception):
    pass


class YtDlp:
    def __init__(self, put=None):
        kandidati = [put, os.environ.get("YTDLP"), str(Path.home() / "bin" / "yt-dlp"), shutil.which("yt-dlp")]
        self.put = next((c for c in kandidati if c and Path(c).is_file()), None)
        if not self.put:
            raise SystemExit("GREŠKA: yt-dlp nije pronađen (očekivano ~/bin/yt-dlp ili u PATH-u)")
        try:
            glava = Path(self.put).read_bytes()[:200]
        except Exception:
            glava = b""
        # zipapp s python shebangom pokrećemo izravno pythonom (sigurno i izvan interaktivnog Termuxa)
        self.cmd = [sys.executable, self.put] if glava.startswith(b"#!") and b"python" in glava.split(b"\n")[0] else [self.put]
        self.zajednicko = ["--ignore-config", "--no-warnings", "--socket-timeout", "30", "--retries", "3",
                           "--extractor-retries", "2", "--sleep-requests", "1"]
        self.verzija = self._run(["--version"], 60).stdout.strip()

    def _run(self, args, timeout):
        try:
            r = subprocess.run(self.cmd + args, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise YtGreska(f"isteklo vrijeme ({timeout} s)")
        return r

    def run(self, args, timeout=180):
        r = self._run(self.zajednicko + args, timeout)
        if r.returncode != 0:
            linije = [l for l in (r.stderr or "").strip().splitlines() if l.strip()]
            raise YtGreska(linije[-1][:300] if linije else f"izlazni kod {r.returncode}")
        return r

    def json(self, args, timeout=180):
        r = self.run(args + ["-J"], timeout)
        try:
            return json.loads(r.stdout)
        except Exception:
            raise YtGreska("neispravan JSON od yt-dlp")

    def flat(self, url, n):
        return self.json(["--flat-playlist", "--playlist-end", str(n),
                          "--extractor-args", "youtubetab:approximate_date", url], timeout=240)

    def info(self, vid):
        return self.json(["--skip-download", f"https://www.youtube.com/watch?v={vid}"], timeout=240)

    def titlovi(self, vid, kljuc, auto, odrediste):
        self.run(["--skip-download", "--write-auto-subs" if auto else "--write-subs",
                  "--sub-langs", kljuc, "--sub-format", "vtt/json3/best",
                  "-o", str(Path(odrediste) / "%(id)s.%(ext)s"),
                  f"https://www.youtube.com/watch?v={vid}"], timeout=240)
        return sorted(Path(odrediste).glob(f"{vid}*"))

    def zvuk(self, vid, odrediste):
        self.run(["-f", "wa/ba/b", "--no-playlist", "-o", str(Path(odrediste) / "%(id)s.%(ext)s"),
                  f"https://www.youtube.com/watch?v={vid}"], timeout=1800)
        f = [p for p in Path(odrediste).glob(f"{vid}.*") if not p.name.endswith((".part", ".ytdl"))]
        if not f:
            raise YtGreska("zvuk nije preuzet")
        return f[0]


# ----------------------------------------------------------------- titlovi -> tekst
TS = re.compile(r"(?:(\d+):)?(\d{2}):(\d{2})[.,]\d{3}\s+-->")


def vtt_u_tekst(s):
    dijelovi, zadnje, sljedeci = [], [], 0
    for blok in re.split(r"\r?\n\s*\r?\n", s):
        t0, tekst = None, []
        for l in blok.splitlines():
            m = TS.search(l)
            if m:
                t0 = int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
                continue
            if t0 is None:
                continue
            l = html.unescape(re.sub(r"<[^>]+>", "", l)).replace("​", "").strip()
            if l:
                tekst.append(l)
        if t0 is None:
            continue
        for l in tekst:
            if l in zadnje:  # automatski titlovi ponavljaju prethodni redak
                continue
            if t0 >= sljedeci:
                dijelovi.append(f"\n[{fmt_marker(t0)}] ")
                sljedeci = t0 - t0 % 120 + 120
            dijelovi.append(l + " ")
            zadnje = (zadnje + [l])[-4:]
    return re.sub(r"[ \t]+", " ", "".join(dijelovi)).strip()


def json3_u_tekst(s):
    d = json.loads(s)
    dijelovi, sljedeci = [], 0
    for ev in d.get("events", []):
        segs = ev.get("segs")
        if not segs:
            continue
        t0 = int(ev.get("tStartMs", 0)) // 1000
        txt = "".join(x.get("utf8", "") for x in segs).replace("\n", " ").strip()
        if not txt:
            continue
        if t0 >= sljedeci:
            dijelovi.append(f"\n[{fmt_marker(t0)}] ")
            sljedeci = t0 - t0 % 120 + 120
        dijelovi.append(txt + " ")
    return re.sub(r"[ \t]+", " ", "".join(dijelovi)).strip()


def izaberi_titlove(info):
    """Vrati (kljuc, auto?, vrsta) ili (None, None, None).
    Prednost ima jezik videa. YouTube kod videa s automatskom sinkronizacijom nudi više
    "<jezik>-orig" zapisa (npr. ar-orig, de-orig za engleski video) - njih ne smijemo uzeti nasumce."""
    puni = (info.get("language") or "").lower()
    jezik = puni.split("-")[0] or None
    man = {k: v for k, v in (info.get("subtitles") or {}).items() if k != "live_chat"}
    auto = info.get("automatic_captions") or {}
    baza = lambda k: k.lower().replace("-orig", "").split("-")[0]

    def prvi(kljucevi, pref):
        for p in pref:
            for k in sorted(kljucevi):
                if baza(k) == p:
                    return k
        return None

    pref = ([jezik] if jezik else []) + (["en"] if jezik != "en" else [])
    k = prvi(man, pref) or (sorted(man)[0] if man else None)
    if k:
        return k, False, "autorski titlovi"
    orig = [k for k in auto if k.lower().endswith("-orig")]
    # 1) izvorni zapis na jeziku videa (točan, pa osnovni jezik), 2) neprevedeni ključ jezika videa
    for uvjet in ((lambda k: k.lower()[:-5] == puni), (lambda k: baza(k) == jezik)):
        pogodak = sorted(k for k in orig if jezik and uvjet(k))
        if pogodak:
            return pogodak[0], True, "automatski titlovi"
    for k in (info.get("language"), jezik):
        if k and k in auto:
            return k, True, "automatski titlovi"
    if not jezik and len(orig) == 1:  # jezik videa nepoznat, ali postoji samo jedan izvorni zapis
        return orig[0], True, "automatski titlovi"
    k = prvi([x for x in orig], ["en"]) or ("en" if "en" in auto else None)
    if k:
        return k, True, ("automatski titlovi (vjerojatno strojni prijevod)" if jezik and jezik != "en" else "automatski titlovi")
    return None, None, None


def krivi_jezik(z):
    """Je li transkript automatskih titlova na drugom jeziku od jezika videa (greška verzije 1.0/1.1)."""
    t = z.get("transkript") or {}
    if not str(t.get("vrsta", "")).startswith("automatski") or not z.get("jezik") or not t.get("jezik"):
        return False
    return t["jezik"].lower().replace("-orig", "").split("-")[0] != z["jezik"].lower().split("-")[0]


# ----------------------------------------------------------------- Soniox
class Soniox:
    def __init__(self, kljuc, baza, model):
        self.kljuc, self.baza, self.model = kljuc, baza.rstrip("/"), model

    def _req(self, metoda, put, tijelo=None, timeout=120):
        data = json.dumps(tijelo).encode() if tijelo is not None else None
        req = urllib.request.Request(self.baza + put, data=data, method=metoda)
        req.add_header("Authorization", f"Bearer {self.kljuc}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            b = r.read()
            return json.loads(b) if b else {}

    def izaberi_model(self):
        try:
            modeli = self._req("GET", "/models").get("models", [])
            asinkroni = [m["id"] for m in modeli if str(m.get("transcription_mode", "")).startswith("async")]
            if self.model not in asinkroni and asinkroni:
                self.model = sorted(asinkroni)[-1]
        except Exception as e:
            log(f"Soniox: popis modela nedostupan ({e}); koristim {self.model}")

    def _upload(self, put):
        u = urllib.parse.urlparse(self.baza + "/files")
        granica = uuid.uuid4().hex
        pre = (f'--{granica}\r\nContent-Disposition: form-data; name="file"; filename="{put.name}"\r\n'
               f"Content-Type: application/octet-stream\r\n\r\n").encode()
        post = f"\r\n--{granica}--\r\n".encode()
        vel = put.stat().st_size
        c = (http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=600) if u.scheme == "https"
             else http.client.HTTPConnection(u.hostname, u.port or 80, timeout=600))
        c.putrequest("POST", u.path)
        c.putheader("Authorization", f"Bearer {self.kljuc}")
        c.putheader("Content-Type", f"multipart/form-data; boundary={granica}")
        c.putheader("Content-Length", str(len(pre) + vel + len(post)))
        c.endheaders()
        c.send(pre)
        with open(put, "rb") as f:
            while True:
                b = f.read(1 << 16)
                if not b:
                    break
                c.send(b)
        c.send(post)
        r = c.getresponse()
        tijelo = r.read()
        if r.status >= 300:
            raise RuntimeError(f"upload HTTP {r.status}: {tijelo[:200]!r}")
        return json.loads(tijelo)["id"]

    def transkribiraj(self, put, jezik):
        file_id = tr_id = None
        try:
            file_id = self._upload(put)
            tr = self._req("POST", "/transcriptions", {"model": self.model, "file_id": file_id,
                                                        "language_hints": [jezik or "en"]})
            tr_id = tr["id"]
            kraj = time.time() + 1800
            while True:
                st = self._req("GET", f"/transcriptions/{tr_id}")
                if st.get("status") == "completed":
                    break
                if st.get("status") == "error":
                    raise RuntimeError(f"Soniox greška: {st.get('error_message') or st}")
                if time.time() > kraj:
                    raise RuntimeError("Soniox: isteklo vrijeme čekanja (30 min)")
                time.sleep(5)
            t = self._req("GET", f"/transcriptions/{tr_id}/transcript", timeout=300)
            dijelovi, sljedeci = [], 0
            for tok in t.get("tokens", []):
                s = int(tok.get("start_ms", 0)) // 1000
                if s >= sljedeci:
                    dijelovi.append(f"\n[{fmt_marker(s)}] ")
                    sljedeci = s - s % 120 + 120
                dijelovi.append(tok.get("text", ""))
            tekst = re.sub(r"[ \t]+", " ", "".join(dijelovi)).strip()
            return tekst or (t.get("text") or "").strip()
        finally:
            for put_brisanja in ([f"/transcriptions/{tr_id}"] if tr_id else []) + ([f"/files/{file_id}"] if file_id else []):
                try:
                    self._req("DELETE", put_brisanja)
                except Exception as e:
                    log(f"Soniox: brisanje {put_brisanja} nije uspjelo: {e}")


def ucitaj_soniox(postavke):
    if not postavke.get("soniox_ukljucen", True):
        return None
    cfg = ucitaj_json(KONFIG_DIR / "soniox.json", {})
    kljuc = os.environ.get("SONIOX_API_KEY") or cfg.get("kljuc")
    if not kljuc:
        return None
    baza = cfg.get("baza") or os.environ.get("SONIOX_API_BASE_URL") or "https://api.eu.soniox.com/v1"
    return Soniox(kljuc, baza, postavke.get("soniox_model", "stt-async-v5"))


# ----------------------------------------------------------------- glavni rad
class Sakupljac:
    def __init__(self, repo, yt, sada_flag, radni=None):
        self.repo = Path(repo)  # kod i izvori.json (javni repozitorij)
        # podaci (paketi, stanje) žive samo na uređaju; u repozitorij ide samo šifrirani paket (posao.sh)
        self.radni = Path(radni) if radni else Path.home() / ".prt-video" / "radni"
        self.yt = yt
        self.sada_flag = sada_flag
        self.cfg = ucitaj_json(self.repo / "izvori.json", None)
        if not self.cfg:
            raise SystemExit("GREŠKA: nema izvori.json u repozitoriju")
        self.p = self.cfg.get("postavke", {})
        self.danas = dt.date.fromisoformat(os.environ["PRT_DANAS"]) if os.environ.get("PRT_DANAS") else sada().date()  # PRT_DANAS samo za testiranje
        self.ciklus = ciklus_za(self.danas).isoformat()
        self.dir = self.radni / "tjedni" / self.ciklus
        self.tdir = self.dir / "t"
        self.st_put = self.radni / "stanje" / "zadnji_rad.json"
        self.vid_put = self.radni / "stanje" / "vidjeno.json"
        self.kan_put = self.radni / "stanje" / "kanali.json"
        self.stanje = ucitaj_json(self.st_put, {})
        self.prvi_put = (not self.vid_put.exists()) or self.stanje.get("prvi_ciklus") == ciklus_za(self.danas).isoformat()
        if not self.vid_put.exists():
            self.stanje["prvi_ciklus"] = ciklus_za(self.danas).isoformat()
        self.vidjeno = ucitaj_json(self.vid_put, {})
        self.kanali_id = ucitaj_json(self.kan_put, {})
        self.idx = ucitaj_json(self.dir / "index.json", {"videi": [], "retroaktivno": [], "odbaceno": []})
        self.u_paketu = {v["id"] for v in self.idx["videi"] + self.idx["retroaktivno"]}
        pojmovi = self.cfg.get("jaki_pojmovi") or self.cfg.get("relevantni_pojmovi", [])
        self.rel = re.compile(r"\b(" + "|".join(re.escape(x) for x in pojmovi) + r")", re.I) if pojmovi else None
        od = self.stanje.get("sljedeci_od")
        self.od = dt.date.fromisoformat(od) if od else self.danas - dt.timedelta(days=self.p.get("prozor_dana_prvi_put", 8))
        if self.stanje.get("ciklus") == self.ciklus and self.stanje.get("prozor_od"):
            self.od = min(self.od, dt.date.fromisoformat(self.stanje["prozor_od"]))
        self.retro_od = self.danas - dt.timedelta(days=self.p.get("retroaktivno_dana_prvi_put", 90))
        self.izvori_status = {}
        self.greske = []
        self.soniox_min = float(self.stanje.get("soniox_minuta", 0)) if self.stanje.get("ciklus") == self.ciklus else 0.0

    # --- spremanje međustanja (rad se može prekinuti i nastaviti)
    def spremi(self, faza):
        spremi_json(self.dir / "index.json", self.idx)
        spremi_json(self.vid_put, self.vidjeno)
        spremi_json(self.kan_put, self.kanali_id)
        st = dict(self.stanje)
        st.update({
            "ciklus": self.ciklus, "faza": faza, "zadnja_promjena": sada().isoformat(timespec="seconds"),
            "prozor_od": self.od.isoformat(), "prozor_do": self.danas.isoformat(),
            "verzija_skripte": VERZIJA, "yt_dlp": self.yt.verzija, "uredaj": uredaj(),
            "izvori": self.izvori_status, "greske": self.greske[-40:], "soniox_minuta": round(self.soniox_min, 1),
            "broj_novih": len(self.idx["videi"]), "broj_retro": len(self.idx["retroaktivno"]),
            "github_kljuc_istjece": ucitaj_json(KONFIG_DIR / "github.json", {}).get("istjece"),
            "soniox_postavljen": bool(ucitaj_soniox(self.p)),
            "pokretanja_rasporeda": zadnja_pokretanja(),
        })
        self.stanje = st
        spremi_json(self.st_put, st)

    def treba_preskociti(self):
        if self.sada_flag:
            return False
        if self.stanje.get("ciklus") == self.ciklus and self.stanje.get("faza") == "gotovo":
            try:
                zadnje = dt.datetime.fromisoformat(self.stanje["zadnja_promjena"])
                if sada() - zadnje < dt.timedelta(hours=20):
                    return True
            except Exception:
                pass
        return False

    def relevantno(self, *tekstovi):
        if not self.rel:
            return True
        return bool(self.rel.search(" ".join(t or "" for t in tekstovi)))

    # --- kanali
    def razrijesi_kanal(self, k):
        naziv = k["naziv"]
        if naziv in self.kanali_id:
            return f"https://www.youtube.com/channel/{self.kanali_id[naziv]['id']}"
        for url in k.get("kandidati", []):
            try:
                d = self.yt.flat(url.rstrip("/") + "/videos", 1)
                cid = d.get("channel_id") or d.get("uploader_id")
                if cid and cid.startswith("UC"):
                    self.kanali_id[naziv] = {"id": cid, "ime": d.get("channel") or d.get("uploader"), "izvor": url}
                    return f"https://www.youtube.com/channel/{cid}"
            except YtGreska as e:
                log(f"  kandidat {url}: {e}")
        # poznati video s tog kanala -> ID kanala
        for vid in k.get("video_primjer", []):
            try:
                i = self.yt.info(vid)
                if i.get("channel_id"):
                    self.kanali_id[naziv] = {"id": i["channel_id"], "ime": i.get("channel"), "izvor": f"video {vid}"}
                    return f"https://www.youtube.com/channel/{i['channel_id']}"
            except YtGreska as e:
                log(f"  video {vid}: {e}")
        # zadnja mogućnost: pretraga i podudaranje naziva kanala
        q = k.get("trazi_po_nazivu") or naziv
        imena = [naziv.lower()] + [x.lower() for x in k.get("zamjenski_nazivi", [])]
        try:
            d = self.yt.flat(f"ytsearch20:{q}", 20)
            for e in d.get("entries") or []:
                ch = (e.get("channel") or e.get("uploader") or "").lower()
                cid = e.get("channel_id")
                if cid and any(ch == i or (len(i) > 6 and i in ch) for i in imena):
                    self.kanali_id[naziv] = {"id": cid, "ime": e.get("channel"), "izvor": f"pretraga: {q}"}
                    return f"https://www.youtube.com/channel/{cid}"
        except YtGreska as e:
            log(f"  pretraga kanala {naziv}: {e}")
        return None

    def kandidati_kanala(self, k):
        naziv = k["naziv"]
        baza = self.razrijesi_kanal(k)
        if not baza:
            self.izvori_status[f"kanal: {naziv}"] = "GREŠKA: kanal nije pronađen"
            self.greske.append(f"kanal {naziv}: nije razriješen")
            return []
        out, poruke = [], []
        for kartica in ("videos", "streams"):
            try:
                d = self.yt.flat(f"{baza}/{kartica}", self.p.get("kanal_zadnjih_po_kartici", 15))
                for poz, e in enumerate(d.get("entries") or []):
                    if e.get("id"):
                        out.append({"id": e["id"], "poz": poz, "naslov": e.get("title"), "kanal": d.get("channel") or naziv,
                                    "approx": e.get("upload_date") or (dt.datetime.fromtimestamp(e["timestamp"]).strftime("%Y%m%d") if e.get("timestamp") else None),
                                    "trajanje_s": e.get("duration"), "izvor": f"kanal: {naziv}", "kustosiran": True})
                poruke.append(f"{kartica} ok ({len(d.get('entries') or [])})")
            except YtGreska as e:
                msg = str(e)
                if "does not have a" in msg or "This channel has no" in msg:
                    poruke.append(f"{kartica}: nema kartice")
                else:
                    poruke.append(f"{kartica} GREŠKA: {msg[:120]}")
                    self.greske.append(f"kanal {naziv}/{kartica}: {msg[:200]}")
        ime = (self.kanali_id.get(naziv) or {}).get("ime") or "?"
        self.izvori_status[f"kanal: {naziv}"] = "; ".join(poruke) + f" [{ime} | {baza}]"
        return out

    def kandidati_pretrage(self, q):
        n = self.p.get("pretraga_rezultata_prvi_put", 5) if self.prvi_put else self.p.get("pretraga_rezultata", 10)
        # YouTube je ukinuo sortiranje po datumu (yt-dlp "ytsearchdate" više ne postoji).
        # 1. izbor: filtar "objavljeno ovaj mjesec, samo videi" (sp=EgQIBBAB); rezerva: obična pretraga.
        varijante = [("filtar: ovaj mjesec", f"https://www.youtube.com/results?search_query={urllib.parse.quote_plus(q)}&sp=EgQIBBAB"),
                     ("bez filtra", f"ytsearch{n}:{q}")]
        zadnja = None
        for oznaka, url in varijante:
            try:
                d = self.yt.flat(url, n)
                ents = [e for e in d.get("entries") or [] if e.get("id") and len(e["id"]) == 11][:n]
                self.izvori_status[f"pretraga: {q}"] = f"ok ({len(ents)}; {oznaka})"
                return [{"id": e["id"], "naslov": e.get("title"), "kanal": e.get("channel") or e.get("uploader"),
                         "approx": None, "trajanje_s": e.get("duration"), "izvor": f"pretraga: {q}", "kustosiran": False}
                        for e in ents]
            except YtGreska as e:
                zadnja = e
        self.izvori_status[f"pretraga: {q}"] = f"GREŠKA: {str(zadnja)[:120]}"
        self.greske.append(f"pretraga '{q}': {str(zadnja)[:200]}")
        return []

    # --- obrada jednog videa
    def obradi(self, c, izvori):
        vid = c["id"]
        approx = c.get("approx")
        if approx and c["kustosiran"]:
            d = dt.date(int(approx[:4]), int(approx[4:6]), int(approx[6:]))
            if d < self.od - dt.timedelta(days=3):  # približni datum, uz rezervu od 3 dana
                if self.prvi_put and d >= self.retro_od:
                    self.idx["retroaktivno"].append({"id": vid, "url": f"https://www.youtube.com/watch?v={vid}",
                                                     "naslov": c.get("naslov"), "kanal": c.get("kanal"),
                                                     "objavljeno_priblizno": ymd(approx), "trajanje": fmt_trajanje(c.get("trajanje_s")),
                                                     "izvori": izvori})
                self.vidjeno[vid] = self.danas.isoformat()
                return
        if self.prvi_put and c["kustosiran"] and not approx and c.get("poz", 0) >= 5:
            self.vidjeno[vid] = self.danas.isoformat()  # bazna linija: starije stavke bez datuma ne obrađujemo
            return
        try:
            info = self.yt.info(vid)
        except YtGreska as e:
            pokusaji = self.stanje.setdefault("neuspjeli_pokusaji", {})
            pokusaji[vid] = pokusaji.get(vid, 0) + 1
            self.greske.append(f"video {vid} ({c.get('naslov')}): {str(e)[:200]}")
            trajno = any(x in str(e) for x in ("confirm your age", "Private video", "members-only", "Video unavailable", "This video has been removed"))
            if trajno or pokusaji[vid] >= 3:  # trajna greška ili 3 pokušaja: odustani
                self.vidjeno[vid] = self.danas.isoformat()
            return
        objavljeno = info.get("upload_date")
        d = dt.date(int(objavljeno[:4]), int(objavljeno[4:6]), int(objavljeno[6:])) if objavljeno else self.danas
        naslov, opis, kanal = info.get("title"), info.get("description") or "", info.get("channel") or info.get("uploader")
        rel = c["kustosiran"] or self.relevantno(naslov, opis, kanal, " ".join(info.get("tags") or []))
        self.vidjeno[vid] = self.danas.isoformat()
        if info.get("live_status") in ("is_upcoming", "is_live"):
            self.vidjeno.pop(vid, None)  # obradit ćemo ga kad snimka bude dostupna
            return
        if d < self.od:
            if self.prvi_put and d >= self.retro_od and rel:
                self.idx["retroaktivno"].append({"id": vid, "url": info.get("webpage_url"), "naslov": naslov, "kanal": kanal,
                                                 "objavljeno": ymd(objavljeno), "trajanje": fmt_trajanje(info.get("duration")),
                                                 "izvori": izvori})
            return
        if not rel:
            self.idx["odbaceno"].append({"id": vid, "naslov": naslov, "kanal": kanal, "objavljeno": ymd(objavljeno),
                                         "url": info.get("webpage_url"), "izvori": izvori})
            return
        zapis = {
            "id": vid, "url": info.get("webpage_url") or f"https://www.youtube.com/watch?v={vid}",
            "naslov": naslov, "kanal": kanal, "kanal_id": info.get("channel_id"),
            "kanal_url": info.get("channel_url"), "objavljeno": ymd(objavljeno),
            "trajanje_s": info.get("duration"), "trajanje": fmt_trajanje(info.get("duration")),
            "jezik": info.get("language"), "uzivo_snimka": bool(info.get("was_live")),
            "pregleda": info.get("view_count"), "oznake": (info.get("tags") or [])[:15],
            "opis": opis[:2000], "izvori": izvori, "kustosiran_kanal": c["kustosiran"],
            "transkript": {"vrsta": "nema", "datoteka": None, "rijeci": 0},
        }
        self.titlovi_u_zapis(zapis, info)
        self.idx["videi"].append(zapis)

    def titlovi_u_zapis(self, zapis, info):
        vid = zapis["id"]
        kljuc, auto, vrsta = izaberi_titlove(info)
        if kljuc:
            with tempfile.TemporaryDirectory() as tmp:
                try:
                    datoteke = self.yt.titlovi(vid, kljuc, auto, tmp)
                    tekst = ""
                    for f in datoteke:
                        s = f.read_text(encoding="utf-8", errors="replace")
                        if f.suffix == ".vtt":
                            tekst = vtt_u_tekst(s)
                        elif f.suffix == ".json3":
                            tekst = json3_u_tekst(s)
                        if tekst:
                            break
                    if tekst:
                        self.zapisi_transkript(zapis, tekst, vrsta, kljuc)
                    else:
                        zapis["transkript"]["napomena"] = f"titlovi ({kljuc}) preuzeti, ali prazni"
                except YtGreska as e:
                    zapis["transkript"]["napomena"] = f"titlovi ({kljuc}) nisu preuzeti: {str(e)[:150]}"
                    self.greske.append(f"titlovi {vid}: {str(e)[:200]}")
        else:
            zapis["transkript"]["napomena"] = "video nema titlova"

    def popravi_jezik(self):
        losi = [z for z in self.idx["videi"] if krivi_jezik(z)]
        for z in losi:
            log(f"  popravak jezika transkripta: {z['naslov']} ({z['transkript'].get('jezik')} -> {z['jezik']})")
            try:
                info = self.yt.info(z["id"])
            except YtGreska as e:
                self.greske.append(f"popravak {z['id']}: {str(e)[:200]}")
                continue
            stari = self.tdir / f"{z['id']}.txt"
            stari.unlink(missing_ok=True)
            z["transkript"] = {"vrsta": "nema", "datoteka": None, "rijeci": 0}
            self.titlovi_u_zapis(z, info)
        if losi:
            log(f"Popravljeno transkripata: {len(losi)}")
            self.spremi("u_tijeku")

    def zapisi_transkript(self, zapis, tekst, vrsta, jezik):
        maks = self.p.get("max_znakova_transkripta", 200000)
        skraceno = len(tekst) > maks
        tekst = tekst[:maks]
        self.tdir.mkdir(parents=True, exist_ok=True)
        glava = (f"# {zapis['naslov']}\n# Kanal: {zapis['kanal']} | Objavljeno: {zapis['objavljeno']} | "
                 f"Trajanje: {zapis['trajanje']}\n# URL: {zapis['url']}\n# Transkript: {vrsta} [{jezik}]"
                 f"{' | SKRAĆENO na ' + str(maks) + ' znakova' if skraceno else ''}\n"
                 f"# Oznake [mm:ss] su približne (svake ~2 min).\n\n")
        (self.tdir / f"{zapis['id']}.txt").write_text(glava + tekst + "\n", encoding="utf-8")
        zapis["transkript"] = {"vrsta": vrsta, "jezik": jezik, "datoteka": f"t/{zapis['id']}.txt",
                               "rijeci": len(tekst.split()), "skraceno": skraceno}

    def soniox_faza(self):
        sx = ucitaj_soniox(self.p)
        cekaju = [z for z in self.idx["videi"] if z["transkript"]["vrsta"] == "nema" and not z["transkript"].get("soniox_pokusan")]
        if not cekaju:
            return
        if not sx:
            for z in cekaju:
                napomena(z, "Soniox nije postavljen")
            return
        sx.izaberi_model()
        max_v = self.p.get("soniox_max_minuta_po_videu", 120)
        max_t = self.p.get("soniox_max_minuta_tjedno", 180)
        for z in cekaju:
            if not (z.get("kustosiran_kanal") or self.relevantno(z.get("naslov"))):
                napomena(z, "Soniox preskočen (nije kustosirani kanal ni jak pojam u naslovu)")
                continue
            minute = (z.get("trajanje_s") or 0) / 60
            if minute <= 0 or minute > max_v:
                napomena(z, f"Soniox preskočen (trajanje {z['trajanje']} > {max_v} min ili nepoznato)")
                continue
            if self.soniox_min + minute > max_t:
                napomena(z, f"Soniox preskočen (tjedni limit {max_t} min)")
                continue
            log(f"  Soniox: {z['naslov']} ({z['trajanje']})")
            z["transkript"]["soniox_pokusan"] = True
            with tempfile.TemporaryDirectory() as tmp:
                try:
                    audio = self.yt.zvuk(z["id"], tmp)
                    tekst = sx.transkribiraj(audio, (z.get("jezik") or "en").split("-")[0])
                    audio.unlink(missing_ok=True)
                    self.soniox_min += minute
                    if tekst:
                        self.zapisi_transkript(z, tekst, f"Soniox ({sx.model})", (z.get("jezik") or "en"))
                except Exception as e:
                    napomena(z, f"Soniox greška: {str(e)[:150]}")
                    self.greske.append(f"Soniox {z['id']}: {str(e)[:200]}")
            self.spremi("u_tijeku")

    def napisi_index(self, faza):
        v = sorted(self.idx["videi"], key=lambda z: z.get("objavljeno") or "", reverse=True)
        ok = sum(1 for s in self.izvori_status.values() if "GREŠKA" not in s)
        L = [f"# YouTube paket za izvješće od {self.ciklus} (ponedjeljak)",
             "",
             f"- Generirano: {sada().strftime('%Y-%m-%d %H:%M %Z')} | stanje: **{faza}** | uređaj: {uredaj()}",
             f"- Prozor objave: {self.od.isoformat()} – {self.danas.isoformat()}" + (" | PRVO POKRETANJE (bazna linija)" if self.prvi_put else ""),
             f"- Izvori: {len(self.izvori_status)} provjereno, {ok} bez greške, {len(self.izvori_status) - ok} s greškom",
             f"- Novih relevantnih videa: {len(v)} | retroaktivno (samo metapodaci): {len(self.idx['retroaktivno'])} | "
             f"odbačeno kao nerelevantno: {len(self.idx['odbaceno'])}",
             f"- Soniox potrošeno ovaj ciklus: {self.soniox_min:.0f} min | yt-dlp {self.yt.verzija} | skripta {VERZIJA}",
             "",
             "Napomena za agenta: transkripti su u t/<id>.txt. Automatski titlovi su strojno generirani i mogu",
             "sadržavati pogreške u imenima, brojkama i stručnim pojmovima; ne citiraj ih kao doslovne bez provjere.",
             "", f"## A. Novi videi ({len(v)})", ""]
        for i, z in enumerate(v, 1):
            t = z["transkript"]
            tr = (f"{t['vrsta']} [{t.get('jezik')}] -> `{t['datoteka']}` ({t['rijeci']} riječi"
                  f"{', SKRAĆENO' if t.get('skraceno') else ''})") if t.get("datoteka") else f"NEMA ({t.get('napomena', '')})"
            opis = re.sub(r"\s+", " ", z.get("opis") or "")[:700]
            L += [f"### {i}. {z['naslov']}",
                  f"- Kanal: {z['kanal']} | Objavljeno: {z['objavljeno']} | Trajanje: {z['trajanje']} | Jezik: {z.get('jezik') or '?'}"
                  f"{' | snimka prijenosa uživo' if z.get('uzivo_snimka') else ''}",
                  f"- URL: {z['url']}",
                  f"- Pronađeno preko: {'; '.join(z['izvori'])}",
                  f"- Transkript: {tr}",
                  f"- Opis: {opis}", ""]
        if self.idx["retroaktivno"]:
            L += [f"## B. Retroaktivno – objavljeno prije prozora, prvi put uočeno ({len(self.idx['retroaktivno'])}, bez transkripta)", ""]
            for z in self.idx["retroaktivno"]:
                L.append(f"- {z.get('objavljeno') or z.get('objavljeno_priblizno', '?') + ' (približno)'} | {z['naslov']} | "
                         f"{z['kanal']} | {z.get('trajanje')} | {z['url']} | {'; '.join(z['izvori'])}")
            L.append("")
        if self.idx["odbaceno"]:
            L += [f"## C. Odbačeno iz pretraga kao nerelevantno ({len(self.idx['odbaceno'])}) – provjeri samo naslove", ""]
            for z in self.idx["odbaceno"]:
                L.append(f"- {z.get('objavljeno')} | {z['naslov']} | {z['kanal']} | {z['url']}")
            L.append("")
        L += ["## D. Status izvora", ""] + [f"- {k}: {s}" for k, s in self.izvori_status.items()] + [""]
        L += [f"## E. Greške ({len(self.greske)})", ""] + [f"- {g}" for g in self.greske] + ([""] if self.greske else ["- nema", ""])
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "INDEX.md").write_text("\n".join(L), encoding="utf-8")
        (self.radni / "tjedni" / "ZADNJI.txt").write_text(f"{self.ciklus}\n{sada().isoformat(timespec='seconds')}\n{faza}\n", encoding="utf-8")

    def pokreni(self):
        if self.treba_preskociti():
            log(f"Ciklus {self.ciklus} je već dovršen ({self.stanje.get('zadnja_promjena')}); ništa za raditi.")
            return 0
        log(f"Ciklus {self.ciklus}, prozor od {self.od}, prvi put: {self.prvi_put}, yt-dlp {self.yt.verzija}")
        self.spremi("u_tijeku")
        self.popravi_jezik()
        kandidati = {}
        for k in self.cfg.get("kanali", []):
            log(f"Kanal: {k['naziv']}")
            for c in self.kandidati_kanala(k):
                kandidati.setdefault(c["id"], {"c": c, "izvori": []})["izvori"].append(c["izvor"])
        for q in self.cfg.get("pretrage", []):
            log(f"Pretraga: {q}")
            for c in self.kandidati_pretrage(q):
                if c["id"] in kandidati:
                    kandidati[c["id"]]["izvori"].append(c["izvor"])
                else:
                    kandidati[c["id"]] = {"c": c, "izvori": [c["izvor"]]}
        novi = [x for vid, x in kandidati.items() if vid not in self.vidjeno and vid not in self.u_paketu]
        log(f"Kandidata: {len(kandidati)}, neviđenih: {len(novi)}")
        for i, x in enumerate(novi, 1):
            log(f"  [{i}/{len(novi)}] {x['c'].get('naslov')}")
            self.obradi(x["c"], x["izvori"])
            if i % 5 == 0:
                self.spremi("u_tijeku")
        self.spremi("u_tijeku")
        self.napisi_index("titlovi gotovi, Soniox u tijeku")
        self.soniox_faza()
        gresaka = sum(1 for s in self.izvori_status.values() if "GREŠKA" in s)
        faza = "gotovo" if gresaka <= len(self.izvori_status) / 2 else "djelomicno"
        # rezanje starih zapisa (držimo 400 dana)
        granica = (self.danas - dt.timedelta(days=400)).isoformat()
        self.vidjeno = {k: v for k, v in self.vidjeno.items() if v >= granica}
        self.stanje["neuspjeli_pokusaji"] = {k: v for k, v in self.stanje.get("neuspjeli_pokusaji", {}).items()
                                             if k not in self.vidjeno}
        if faza == "gotovo":
            self.stanje["sljedeci_od"] = (self.danas - dt.timedelta(days=1)).isoformat()
        self.spremi(faza)
        self.napisi_index(faza)
        log(f"Gotovo: {len(self.idx['videi'])} novih, {len(self.idx['retroaktivno'])} retro, "
            f"{len(self.idx['odbaceno'])} odbačeno, grešaka izvora {gresaka}/{len(self.izvori_status)} -> {faza}")
        return 0 if faza == "gotovo" else 2


def zadnja_pokretanja(n=30):
    """Zadnjih n pokretanja posao.sh (svako okidanje Android rasporeda, i izvan prozora) - dijagnostika."""
    try:
        return (Path.home() / ".prt-video" / "tik.log").read_text(encoding="utf-8").splitlines()[-n:]
    except Exception:
        return []


def napomena(z, txt):
    stara = z["transkript"].get("napomena")
    if txt not in (stara or ""):
        z["transkript"]["napomena"] = f"{stara}; {txt}" if stara else txt


def uredaj():
    if "com.termux" in os.environ.get("PREFIX", ""):
        return "Android/Termux"
    return sys.platform


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sada", action="store_true", help="pokreni i ako je ciklus nedavno dovršen")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--ytdlp", default=None)
    ap.add_argument("--radni", default=None, help="radni direktorij s podacima (zadano ~/.prt-video/radni)")
    a = ap.parse_args()
    yt = YtDlp(a.ytdlp)
    return Sakupljac(a.repo, yt, a.sada, a.radni).pokreni()


if __name__ == "__main__":
    sys.exit(main())
