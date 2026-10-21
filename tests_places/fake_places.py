"""Server palsu yang meniru Google Places API (New) dan Overpass API (OpenStreetMap).

Dipakai tes end-to-end supaya bisa menguji jaringan sungguhan (timeout, 429, key salah, billing mati, ...)
tanpa internet dan tanpa API key. Bisa juga dijalankan manual:

    python tests_places/fake_places.py 9200
    # lalu di .env:  PLACES_PROVIDER=google
    #                GOOGLE_PLACES_API_KEY=test-google-key
    #                GOOGLE_PLACES_BASE_URL=http://127.0.0.1:9200/v1
    #                PLACES_FALLBACK_PROVIDER=osm
    #                PLACES_OSM_URL=http://127.0.0.1:9200/api/interpreter
    # titik uji: lat -6.2, lng 106.8 (CENTER di bawah)

Perilaku diatur lewat  POST /_mode  {"google": "...", "osm": "..."}  (yang tidak disebut tidak berubah):
  Google: ok | invalid_key | service_disabled | billing_disabled | 429 | 500 | slow | html
  OSM:    ok | 429 | 504 | remark_timeout | html | many (selalu mengembalikan 300 elemen)
"""
import asyncio
import re
import sys
from pathlib import Path
from typing import Any, Dict, List
from urllib.parse import parse_qs

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # jalan juga lewat `python tests_places/fake_places.py`
from nearby_places.geo import destination_point, haversine_m  # noqa: E402

API_KEY = "test-google-key"
CENTER = (-6.2, 106.8)


def _at(bearing: float, meters: float):
    return destination_point(CENTER[0], CENTER[1], bearing, meters)


def _poi(pid, name, types, bearing, meters, status="OPERATIONAL", osm=None):
    lat, lng = _at(bearing, meters)
    return {"id": pid, "name": name, "types": types, "lat": lat, "lng": lng, "status": status, "osm": osm or {}}


# Urutan di DATASET sengaja acak (bukan urut jarak, bukan urut popularitas) supaya tes bisa membuktikan
# bahwa modul meminta urutan DISTANCE dan menghitung jarak sendiri.
DATASET: List[Dict[str, Any]] = [
    _poi("rest-far", "Rest Area KM 99 (fake)", ["rest_stop"], 0, 66000, osm={"highway": "services"}),
    _poi("rest-2", "Rest Area KM 20 (fake)", ["rest_stop"], 180, 22000, osm={"highway": "services"}),
    _poi("rest-1", "Rest Area KM 10 (fake)", ["rest_stop"], 0, 5500, osm={"highway": "services"}),
    _poi("mini-4", "Minimarket Empat (fake)", ["convenience_store"], 270, 1500, osm={"shop": "convenience"}),
    _poi("mini-1", "Minimarket Satu (fake)", ["convenience_store", "store"], 90, 200, osm={"shop": "convenience"}),
    _poi("mini-5", "Minimarket Lima (fake)", ["convenience_store"], 45, 2800, osm={"shop": "convenience"}),
    _poi("mini-far", "Minimarket Jauh (fake)", ["convenience_store"], 45, 3500, osm={"shop": "convenience"}),
    _poi("mini-2", "Minimarket Dua (fake)", ["convenience_store"], 180, 450, osm={"shop": "convenience"}),
    _poi("mini-3", "Minimarket Tiga (fake)", ["convenience_store"], 0, 900, osm={"shop": "convenience"}),
    _poi("hotel-closed", "Hotel Tutup (fake)", ["hotel", "lodging"], 10, 300, status="CLOSED_TEMPORARILY",
         osm={"tourism": "hotel"}),
    _poi("guest-1", "Rumah Singgah (fake)", ["guest_house", "lodging"], 300, 8000, osm={"tourism": "guest_house"}),
    _poi("hotel-1", "Hotel Satu (fake)", ["hotel", "lodging"], 20, 1200, osm={"tourism": "hotel"}),
    _poi("motel-1", "Motel Satu (fake)", ["motel", "lodging"], 200, 4000, osm={"tourism": "motel"}),
    _poi("spbu-1", "SPBU Satu (fake)", ["gas_station"], 70, 700, osm={"amenity": "fuel"}),
]

_GOOGLE_MODES = ("ok", "invalid_key", "service_disabled", "billing_disabled", "429", "500", "slow", "html")
_OSM_MODES = ("ok", "429", "504", "remark_timeout", "html", "many")


def _google_error(status: int, message: str, g_status: str, reason: str) -> JSONResponse:
    body = {"error": {"code": status, "message": message, "status": g_status,
                      "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason,
                                   "domain": "googleapis.com"}]}}
    return JSONResponse(body, status_code=status)


def _distance(p) -> float:
    return haversine_m(CENTER[0], CENTER[1], p["lat"], p["lng"])


def create_fake_places() -> FastAPI:
    app = FastAPI()
    state: Dict[str, Any] = {}

    def reset():
        state.clear()
        state.update(google_mode="ok", osm_mode="ok", google_calls=0, osm_calls=0,
                     google_requests=[], osm_requests=[])

    reset()

    @app.post("/_mode")
    async def set_mode(body: Dict[str, Any]):
        reset()
        if "google" in body:
            assert body["google"] in _GOOGLE_MODES, body
            state["google_mode"] = body["google"]
        if "osm" in body:
            assert body["osm"] in _OSM_MODES, body
            state["osm_mode"] = body["osm"]
        return {"ok": True}

    @app.get("/_state")
    async def get_state():
        return state

    # ------------------------------------------------------------------ Google
    @app.post("/v1/places:searchNearby")
    async def search_nearby(request: Request):
        body = await request.json()
        state["google_calls"] += 1
        headers = {k: request.headers.get(k) for k in ("x-goog-api-key", "x-goog-fieldmask", "content-type")}
        state["google_requests"].append({"headers": headers, "body": body, "query": str(request.url.query)})
        mode = state["google_mode"]

        if headers["x-goog-api-key"] != API_KEY or mode == "invalid_key":
            return _google_error(400, "API key not valid. Please pass a valid API key.", "INVALID_ARGUMENT",
                                 "API_KEY_INVALID")
        if mode == "service_disabled":
            return _google_error(403, "Places API (New) has not been used in project 123 before or it is disabled.",
                                 "PERMISSION_DENIED", "SERVICE_DISABLED")
        if mode == "billing_disabled":
            return _google_error(403, "This API method requires billing to be enabled.", "PERMISSION_DENIED",
                                 "BILLING_DISABLED")
        if mode == "429":
            return _google_error(429, "Quota exceeded for quota metric 'Nearby Search requests'.",
                                 "RESOURCE_EXHAUSTED", "RATE_LIMIT_EXCEEDED")
        if mode == "500":
            return _google_error(500, "Internal error encountered.", "INTERNAL", "INTERNAL")
        if mode == "html":
            return PlainTextResponse("<html>502 bad gateway</html>", media_type="text/html")
        if mode == "slow":
            await asyncio.sleep(1.5)

        mask = headers["x-goog-fieldmask"]
        if not mask:
            return _google_error(400, "FieldMask is a required parameter.", "INVALID_ARGUMENT", "")
        circle = ((body.get("locationRestriction") or {}).get("circle")) or {}
        radius = circle.get("radius", 0)
        count = body.get("maxResultCount", 20)
        types = body.get("includedTypes") or []
        if not (0 < radius <= 50000) or not (1 <= count <= 20) or len(types) > 50:
            return _google_error(400, "Invalid request.", "INVALID_ARGUMENT", "")

        center = circle["center"]
        found = []
        for p in DATASET:
            if types and not set(types) & set(p["types"]):
                continue
            dist = haversine_m(center["latitude"], center["longitude"], p["lat"], p["lng"])
            if dist <= radius:
                found.append((dist, p))
        if body.get("rankPreference") == "DISTANCE":
            found.sort(key=lambda t: t[0])
        else:  # bawaan Google = POPULARITY; di sini disimulasikan sebagai urutan terjauh dulu
            found.sort(key=lambda t: -t[0])

        wanted = {m.split(".", 1)[1] for m in mask.split(",") if m.startswith("places.")}
        places = []
        for _, p in found[:count]:
            full = {
                "id": p["id"],
                "displayName": {"text": p["name"], "languageCode": "id"},
                "formattedAddress": f"Jl. Contoh {p['id']}, Indonesia",
                "location": {"latitude": p["lat"], "longitude": p["lng"]},
                "googleMapsUri": f"https://maps.google.com/?cid={p['id']}",
                "businessStatus": p["status"],
                "primaryType": p["types"][0],
                "rating": 4.3,
                "currentOpeningHours": {"openNow": True},
            }
            places.append({k: v for k, v in full.items() if k in wanted})
        return {"places": places} if places else {}

    # ---------------------------------------------------------------- Overpass
    @app.post("/api/interpreter")
    async def overpass(request: Request):
        raw = (await request.body()).decode()
        query = parse_qs(raw).get("data", [""])[0]
        state["osm_calls"] += 1
        state["osm_requests"].append({"query": query, "user_agent": request.headers.get("user-agent"),
                                      "content_type": request.headers.get("content-type"),
                                      "url_query": str(request.url.query)})
        mode = state["osm_mode"]
        if mode == "429":
            return PlainTextResponse("Too Many Requests", status_code=429)
        if mode == "504":
            return PlainTextResponse("Gateway Timeout", status_code=504)
        if mode == "html":
            return PlainTextResponse("<html>oops</html>", media_type="text/html")
        if mode == "remark_timeout":
            return {"version": 0.6, "elements": [],
                    "remark": 'runtime error: Query timed out in "query" at line 4 after 7 seconds.'}

        around = re.search(r"\(around:(\d+),(-?[\d.]+),(-?[\d.]+)\)", query)
        radius, lat, lng = int(around.group(1)), float(around.group(2)), float(around.group(3))
        if mode == "many":
            far = [{"type": "node", "id": 1000 + i, "lat": lat + 0.0001 * (i + 1), "lon": lng, "tags": {"name": f"n{i}"}}
                   for i in range(300)]
            return {"version": 0.6, "elements": far}

        filters = []
        for key, value in re.findall(r'\["(\w+)"="([^"]+)"\]', query):
            filters.append((key, {value}))
        for key, values in re.findall(r'\["(\w+)"~"\^\(([^)]+)\)\$"\]', query):
            filters.append((key, set(values.split("|"))))
        elements = []
        for index, p in enumerate(DATASET):
            if not any(p["osm"].get(k) in vals for k, vals in filters):
                continue
            if haversine_m(lat, lng, p["lat"], p["lng"]) > radius:
                continue
            tags = dict(p["osm"], name=p["name"])
            if index % 2:  # sebagian dijadikan 'way' supaya jalur titik-tengah (center) ikut teruji
                elements.append({"type": "way", "id": 5000 + index, "center": {"lat": p["lat"], "lon": p["lng"]},
                                 "tags": tags})
            else:
                elements.append({"type": "node", "id": 7000 + index, "lat": p["lat"], "lon": p["lng"], "tags": tags})
        return {"version": 0.6, "elements": elements}

    return app


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(create_fake_places(), host="127.0.0.1", port=int(sys.argv[1]) if len(sys.argv) > 1 else 9200)
