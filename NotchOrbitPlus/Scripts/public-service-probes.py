#!/usr/bin/env python3
"""Read public weather/FX endpoints and retain real responses, including failures."""
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
import json
import math
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/public-probes"
LIMIT = 4 * 1024 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_geocoding(payload):
    places = payload.get("results")
    if not isinstance(places, list) or not places:
        raise ValueError("No geocoding result returned for the public Berlin test location.")
    for place in places:
        if not isinstance(place.get("id"), int) or not isinstance(place.get("name"), str):
            raise ValueError("Geocoding result lacks its identifier/name.")
        lat, lon = place.get("latitude"), place.get("longitude")
        if not finite(lat) or not finite(lon) or not -90 <= lat <= 90 or not -180 <= lon <= 180:
            raise ValueError("Geocoding result has invalid coordinates.")


def validate_forecast(payload):
    current, daily = payload.get("current"), payload.get("daily")
    if not isinstance(current, dict) or not isinstance(daily, dict):
        raise ValueError("Current/daily weather objects are missing.")
    datetime.fromisoformat(current["time"])
    for key in ("temperature_2m", "wind_speed_10m"):
        if not finite(current.get(key)):
            raise ValueError(f"Current weather has invalid {key}.")
    if not isinstance(current.get("weather_code"), int):
        raise ValueError("Current weather code is missing.")
    keys = ("time", "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max")
    if any(not isinstance(daily.get(key), list) or len(daily[key]) != 7 for key in keys):
        raise ValueError("The provider did not return seven aligned forecast days.")
    dates = [date.fromisoformat(value) for value in daily["time"]]
    if len(set(dates)) != 7 or dates != sorted(dates):
        raise ValueError("Forecast dates are duplicated or unordered.")
    for index in range(7):
        high, low, rain = (daily[key][index] for key in ("temperature_2m_max", "temperature_2m_min", "precipitation_probability_max"))
        if not all(finite(value) for value in (high, low, rain)) or high < low or not 0 <= rain <= 100:
            raise ValueError("Forecast temperatures/precipitation are invalid.")
        if not isinstance(daily["weather_code"][index], int):
            raise ValueError("Daily weather code is missing.")


def validate_provider_timestamp(value):
    # Both supplemental requests explicitly ask for Unix timestamps. These are
    # the same finite/range bounds used by OnlineServiceDecoding.date.
    if not finite(value) or not -62_135_596_800 <= value <= 253_402_300_799:
        raise ValueError("Supplemental weather timestamp is invalid.")


def validate_air_quality(payload):
    current = payload.get("current")
    if not isinstance(current, dict):
        raise ValueError("Current air-quality fields are unavailable.")
    validate_provider_timestamp(current.get("time"))
    for key, maximum in (("us_aqi", 1_000), ("uv_index", 30), ("pm2_5", 10_000)):
        value = current.get(key)
        if not finite(value) or not 0 <= value <= maximum:
            raise ValueError(f"Current air quality has invalid {key}.")


def validate_minutely_rain(payload):
    forecast = payload.get("minutely_15")
    if not isinstance(forecast, dict):
        raise ValueError("15-minute precipitation fields are unavailable.")
    times, amounts = forecast.get("time"), forecast.get("precipitation")
    if (not isinstance(times, list) or not isinstance(amounts, list)
            or not 1 <= len(times) <= 16 or len(times) != len(amounts)):
        raise ValueError("The provider did not return bounded, aligned 15-minute precipitation values.")
    for timestamp, amount in zip(times, amounts):
        validate_provider_timestamp(timestamp)
        if not finite(amount) or not 0 <= amount <= 1_000:
            raise ValueError("15-minute precipitation amount is invalid.")
    if any(later - earlier != 900 for earlier, later in zip(times, times[1:])):
        raise ValueError("Precipitation timestamps are not consecutive 15-minute intervals.")


def validate_fx(payload):
    if payload.get("base") != "USD":
        raise ValueError("FX provider did not use the requested USD base.")
    date.fromisoformat(payload["date"])
    rates = payload.get("rates")
    if not isinstance(rates, dict) or not rates:
        raise ValueError("FX rates are missing.")
    for currency, rate in rates.items():
        if not re.fullmatch(r"[A-Z]{3}", currency) or not finite(rate) or rate <= 0:
            raise ValueError("FX provider returned an invalid currency/rate.")


PROBES = (
    ("weather-geocoding", "https://geocoding-api.open-meteo.com/v1/search?name=Berlin&count=1&language=en&format=json", validate_geocoding),
    ("weather-forecast", "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.405&current=temperature_2m,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=7", validate_forecast),
    ("weather-air-quality", "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=52.52&longitude=13.405&current=us_aqi,uv_index,pm2_5&timezone=GMT&timeformat=unixtime", validate_air_quality),
    ("weather-minutely-rain", "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.405&minutely_15=precipitation&forecast_minutely_15=8&timezone=GMT&timeformat=unixtime", validate_minutely_rain),
    ("fx-usd", "https://api.frankfurter.dev/v1/latest?base=USD", validate_fx),
)


def fetch(probe):
    name, url, validate = probe
    started = time.monotonic()
    result = {"id": name, "url": url, "http_status": None, "validated": False, "response_file": None}
    body = b""
    try:
        request = Request(url, headers={"Accept": "application/json", "User-Agent": "NotchOrbitPlus-public-validation/0.1"})
        with build_opener(NoRedirect()).open(request, timeout=30) as response:
            result["http_status"] = response.status
            body = response.read(LIMIT + 1)
        if len(body) > LIMIT:
            raise ValueError("Public provider response exceeded the 4 MB bound.")
        payload = json.loads(body)
        if not isinstance(payload, dict):
            raise ValueError("Public provider response is not a JSON object.")
        validate(payload)
        output = name + ".json"
        (OUTPUT / output).write_bytes(body)
        result.update(validated=True, response_file=output)
        if "date" in payload:
            result["provider_date"] = payload["date"]
    except HTTPError as error:
        result["http_status"] = error.code
        body = error.read(LIMIT + 1)
        result["error"] = f"HTTP {error.code}; no redirect or authentication was attempted."
    except (URLError, OSError, ValueError, KeyError, TypeError) as error:
        result["error"] = str(error)
    if not result["validated"] and body:
        output = name + ".error-response.txt"
        (OUTPUT / output).write_bytes(body[:LIMIT])
        result["response_file"] = output
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # These are generated probe files; remove previous evidence before a fresh request.
    (OUTPUT / "status.json").unlink(missing_ok=True)
    for name, _, _ in PROBES:
        for suffix in (".json", ".error-response.txt"):
            (OUTPUT / (name + suffix)).unlink(missing_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(fetch, PROBES))
    passed = all(result["validated"] for result in results)
    status = {"fetched_at": datetime.now(timezone.utc).isoformat(), "purpose": "Live public endpoint evidence, separate from test fixtures",
              "test_location": "Berlin, public city coordinates", "api_credentials_used": False, "all_validated": passed, "results": results}
    (OUTPUT / "status.json").write_text(json.dumps(status, indent=2) + "\n")
    for result in results:
        print(f"{result['id']}: {'validated real response' if result['validated'] else 'failed'} (HTTP {result['http_status']})")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
