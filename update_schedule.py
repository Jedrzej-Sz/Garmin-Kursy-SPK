import hashlib
import json
import logging
import os
import re
import sys
from html.parser import HTMLParser
from logging.handlers import RotatingFileHandler
from pathlib import Path
from urllib.parse import urljoin

import requests
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

# ==============================================================================
# KONFIGURACJA UŻYTKOWNIKA (Linia 412 SPK Swarzędz)
# ==============================================================================
SPK_SCHEDULE_PAGE = "https://swarzedz.pl/fileadmin/Swarzedz/Informator_miejski/komunikacja/rozklad/przystankowy/412lista.htm"
LINE_NUMBER = "412"

# Dokładne (lub unikalne) fragmenty nazw przystanków z tabeli 412lista.htm:
STOP_DIR_A = "Kobylnica Stacja PKP"    # Przystanek z LEWEJ kolumny (Kierunek: Rondo Śródka)
STOP_DIR_B = "Rondo Śródka - Dworzec"  # Przystanek z PRAWEJ kolumny (Kierunek: Swarzędz Węzeł)

GEMINI_MODEL = "gemini-4-hydrogen"

# Ścieżki robocze
BASE_DIR = Path(__file__).resolve().parent
LOG_FILE = BASE_DIR / "updater.log"
PDF_HASH_FILE = BASE_DIR / "pdfs.sha256"
OUT_JSON_FILE = BASE_DIR / "docs" / "schedule.json"
OUT_VER_FILE = BASE_DIR / "docs" / "version.json"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
}

# ==============================================================================
# LOGOWANIE
# ==============================================================================
def setup_logger() -> logging.Logger:
    logger = logging.getLogger("SPKParser")
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")

    fh = RotatingFileHandler(LOG_FILE, maxBytes=1_048_576, backupCount=3, encoding="utf-8")
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger

log = setup_logger()

# ==============================================================================
# SCHEMAT PYDANTIC DLA GEMINI API (Surowe stringi HH:MM)
# ==============================================================================
class RawDirectionSchedule(BaseModel):
    robocze: list[str] = Field(description="Godziny odjazdów w formacie HH:MM w dni robocze")
    soboty: list[str] = Field(description="Godziny odjazdów w formacie HH:MM w soboty")
    niedziele: list[str] = Field(description="Godziny odjazdów w formacie HH:MM w niedziele i święta")

class RawBusSchedule(BaseModel):
    dir_a: RawDirectionSchedule = Field(description=f"Rozkład z pierwszego PDF ({STOP_DIR_A})")
    dir_b: RawDirectionSchedule = Field(description=f"Rozkład z drugiego PDF ({STOP_DIR_B})")

# ==============================================================================
# PARSER TABELI HTML I POBIERANIE PDF
# ==============================================================================
class SPKTableParser(HTMLParser):
    """Wyciąga linki PDF z podziałem na lewą (dir_a) i prawą (dir_b) kolumnę tabeli."""
    def __init__(self):
        super().__init__()
        self.in_tr = False
        self.td_index = -1
        self.current_href = None
        self.current_text = []
        self.dir_a: list[tuple[str, str]] = []  # Lewa kolumna: (nazwa_przystanku, href)
        self.dir_b: list[tuple[str, str]] = []  # Prawa kolumna: (nazwa_przystanku, href)

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "tr":
            self.in_tr = True
            self.td_index = -1
        elif tag == "td" and self.in_tr:
            self.td_index += 1
        elif tag == "a" and self.in_tr:
            href = dict(attrs).get("href", "")
            if href.lower().endswith(".pdf"):
                self.current_href = href
                self.current_text = []

    def handle_data(self, data):
        if self.current_href is not None:
            self.current_text.append(data)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "a" and self.current_href is not None:
            name = " ".join("".join(self.current_text).split())
            # W tabeli 412lista.htm lewy kierunek to pierwsze 3 komórki (indeksy 0-2), prawy to kolejne (3+)
            if self.td_index <= 2:
                self.dir_a.append((name, self.current_href))
            else:
                self.dir_b.append((name, self.current_href))
            self.current_href = None
        elif tag == "tr":
            self.in_tr = False


def find_pdf_urls(page_url: str, stop_a: str, stop_b: str, list_only: bool = False) -> tuple[str, str]:
    log.info(f"Pobieranie tabeli przystanków z: {page_url}")
    resp = requests.get(page_url, headers=HEADERS, timeout=20)
    resp.raise_for_status()
    resp.encoding = resp.apparent_encoding

    parser = SPKTableParser()
    parser.feed(resp.text)

    if list_only:
        print("\n--- KIERUNEK A (lewa kolumna: Rondo Śródka) ---")
        for name, href in parser.dir_a:
            print(f"  {name:35s} -> {href}")
        print("\n--- KIERUNEK B (prawa kolumna: Swarzędz Węzeł) ---")
        for name, href in parser.dir_b:
            print(f"  {name:35s} -> {href}")
        sys.exit(0)

    def match_stop(stops: list[tuple[str, str]], query: str, label: str) -> str:
        q = query.lower()
        for name, href in stops:
            if q in name.lower():
                full_url = urljoin(page_url, href)
                log.info(f"Dopasowano {label}: '{name}' -> {full_url}")
                return full_url
        available = [n for n, _ in stops]
        raise ValueError(f"Nie znaleziono przystanku '{query}' w {label}. Dostępne: {available}")

    url_a = match_stop(parser.dir_a, stop_a, "dir_a (lewa kolumna)")
    url_b = match_stop(parser.dir_b, stop_b, "dir_b (prawa kolumna)")
    return url_a, url_b


def download_pdf(url: str) -> bytes:
    log.info(f"Pobieranie pliku: {url}")
    resp = requests.get(url, headers=HEADERS, timeout=25)
    resp.raise_for_status()
    if not resp.content.startswith(b"%PDF"):
        raise ValueError(f"Plik pod {url} nie jest poprawnym PDF-em (brak nagłówka %PDF).")
    log.info(f"Pobrano poprawny PDF ({len(resp.content)} B).")
    return resp.content


def time_str_to_minutes(time_str: str) -> int:
    clean = time_str.strip()
    match = re.match(r'^(\d{1,2}):(\d{2})$', clean)
    if not match:
        raise ValueError(f"Nieprawidłowy format godziny zwrócony przez model: '{time_str}'")
    hour, minute = int(match.group(1)), int(match.group(2))
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ValueError(f"Godzina poza zakresem zegara: '{time_str}'")
    total = hour * 60 + minute
    # Kursy po północy (00:00 - 02:59) traktujemy jako przedłużenie doby (+1440 min)
    return total + 1440 if hour < 3 else total


def convert_and_validate(raw_data: dict) -> dict:
    converted = {}
    for direction in ("dir_a", "dir_b"):
        if direction not in raw_data:
            raise ValueError(f"Brak sekcji '{direction}' w danych z API.")
        converted[direction] = {}
        for day_type in ("robocze", "soboty", "niedziele"):
            raw_list = raw_data[direction].get(day_type)
            if not isinstance(raw_list, list):
                raise ValueError(f"Pole {direction}.{day_type} nie jest listą.")

            minutes_list = sorted(set(time_str_to_minutes(t) for t in raw_list))

            if day_type == "robocze" and len(minutes_list) < 5:
                raise ValueError(
                    f"Zbyt mało kursów w dni robocze dla {direction} ({len(minutes_list)}). "
                    "Możliwy błąd odczytu tabeli."
                )

            converted[direction][day_type] = minutes_list
    return converted


def format_min_preview(minutes_list: list[int]) -> str:
    if not minutes_list:
        return "brak"
    def fmt(m: int) -> str:
        m_norm = m % 1440
        return f"{m_norm // 60:02d}:{m_norm % 60:02d}"
    if len(minutes_list) <= 4:
        return ", ".join(fmt(m) for m in minutes_list)
    return (
        f"{fmt(minutes_list[0])}, {fmt(minutes_list[1])} ... "
        f"{fmt(minutes_list[-2])}, {fmt(minutes_list[-1])} (łącznie: {len(minutes_list)})"
    )

# ==============================================================================
# GŁÓWNY PRZEPŁYW
# ==============================================================================
def main() -> int:
    force_update = "--force" in sys.argv
    list_stops = "--list-stops" in sys.argv

    try:
        url_a, url_b = find_pdf_urls(SPK_SCHEDULE_PAGE, STOP_DIR_A, STOP_DIR_B, list_only=list_stops)

        if not os.environ.get("GEMINI_API_KEY"):
            log.critical("Brak zmiennej środowiskowej GEMINI_API_KEY! Załaduj plik .env przed uruchomieniem.")
            return 1

        OUT_JSON_FILE.parent.mkdir(parents=True, exist_ok=True)

        pdf_a = download_pdf(url_a)
        pdf_b = download_pdf(url_b)

        combined_hash = hashlib.sha256(pdf_a + pdf_b).hexdigest()
        old_hash = PDF_HASH_FILE.read_text(encoding="utf-8").strip() if PDF_HASH_FILE.exists() else ""

        if not force_update and combined_hash == old_hash and OUT_JSON_FILE.exists():
            log.info(f"Pliki PDF nie uległy zmianie (SHA-256: {combined_hash[:12]}). Pomijam wywołanie API.")
            return 0

        log.info(f"Uruchamiam parsowanie przez {GEMINI_MODEL} (hash PDF: {combined_hash[:12]})...")
        client = genai.Client()

        prompt = (
            f"Odczytaj wszystkie godziny odjazdów z dwóch załączonych tabliczek przystankowych linii {LINE_NUMBER} SPK Swarzędz.\n"
            f"- Pierwszy plik PDF to kierunek A (dir_a) dla przystanku '{STOP_DIR_A}'.\n"
            f"- Drugi plik PDF to kierunek B (dir_b) dla przystanku '{STOP_DIR_B}'.\n\n"
            "Zasady odczytu:\n"
            "1. Każdy plik zawiera tabelę odjazdów podzieloną na kolumny dni: 'robocze' (Dni robocze / poniedziałek-piątek), "
            "'soboty' (Soboty) oraz 'niedziele' (Niedziele i święta). Jeśli któraś kolumna jest pusta lub nie istnieje, zwróć pustą listę [].\n"
            "2. Wiersze oznaczają pełną godzinę, a liczby w kolumnach to minuty odjazdu. Połącz je w format 'HH:MM' "
            "(np. godzina 6 i minuty '05', '35' -> '06:05', '06:35').\n"
            "3. Usuń z minut wszelkie dopiski literowe lub symbole (np. '15s', '40*', '22k' -> 'HH:15', 'HH:40', 'HH:22').\n"
            "4. Uwzględnij kursy szkolne (oznaczone np. 'S' w legendzie). Pomiń jedynie kursy wyraźnie oznaczone w legendzie jako "
            "skrócone i niedojeżdżające do pętli końcowej (jeśli takie występują).\n"
            "5. Zignoruj całkowicie listę przystanków na trasie oraz czasy przejazdu między nimi.\n"
            "6. Zwróć wyłącznie czyste napisy 'HH:MM' zgodnie ze schematem JSON. Nie przeliczaj godzin na minuty."
        )

        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[
                types.Part.from_bytes(data=pdf_a, mime_type="application/pdf"),
                types.Part.from_bytes(data=pdf_b, mime_type="application/pdf"),
                prompt,
            ],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=RawBusSchedule,
                temperature=0.0,
            ),
        )

        if not response.text:
            raise RuntimeError("API zwróciło pustą odpowiedź tekstową.")

        raw_parsed = json.loads(response.text)
        final_schedule = convert_and_validate(raw_parsed)

        # Obliczenie hasha wersji danych dla zegarka
        canonical_str = json.dumps(final_schedule, separators=(",", ":"), sort_keys=True)
        version_hash = hashlib.sha256(canonical_str.encode("utf-8")).hexdigest()[:12]

        payload = {
            "hash": version_hash,
            "line": LINE_NUMBER,
            "data": final_schedule,
        }

        # Atomowy zapis na dysk
        tmp_json = OUT_JSON_FILE.with_suffix(".tmp")
        tmp_ver = OUT_VER_FILE.with_suffix(".tmp")

        tmp_json.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        tmp_ver.write_text(json.dumps({"hash": version_hash}), encoding="utf-8")

        tmp_json.replace(OUT_JSON_FILE)
        tmp_ver.replace(OUT_VER_FILE)
        PDF_HASH_FILE.write_text(combined_hash, encoding="utf-8")

        log.info(f"Zapisano nowy rozkład! Wersja (hash): {version_hash}")
        log.info(f"  [dir_a] Robocze:   {format_min_preview(final_schedule['dir_a']['robocze'])}")
        log.info(f"  [dir_a] Soboty:    {format_min_preview(final_schedule['dir_a']['soboty'])}")
        log.info(f"  [dir_a] Niedziele: {format_min_preview(final_schedule['dir_a']['niedziele'])}")
        log.info(f"  [dir_b] Robocze:   {format_min_preview(final_schedule['dir_b']['robocze'])}")
        log.info(f"  [dir_b] Soboty:    {format_min_preview(final_schedule['dir_b']['soboty'])}")
        log.info(f"  [dir_b] Niedziele: {format_min_preview(final_schedule['dir_b']['niedziele'])}")
        return 0

    except requests.RequestException as e:
        log.error(f"Błąd połączenia HTTP: {e}")
        return 2
    except Exception as e:
        log.exception(f"Błąd przetwarzania rozkładu: {e}")
        return 3

if __name__ == "__main__":
    sys.exit(main())
