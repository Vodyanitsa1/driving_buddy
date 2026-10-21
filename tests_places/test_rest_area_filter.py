"""Bengkel yang salah ditandai highway=services di OSM tidak boleh muncul sebagai rest area."""
import json

from nearby_places.categories import CATEGORIES
from nearby_places.config import load_settings
from nearby_places.providers import SnapshotProvider
from nearby_places.providers.osm import _excluded, _to_place
from test_osm_v2 import ByHost, make, node, ok, search

REST = CATEGORIES["rest_area"]

# Tag asli 27 rest area OSM di area Semarang-Solo (data 20 Okt 2026, © kontributor OpenStreetMap, ODbL).
SEMARANG_SOLO = [
    {"highway": "services", "name": "bengkel motor"},
    {"highway": "rest_area"},
    {"highway": "services", "name": "Rest Area KM 429"},
    {"highway": "services", "name": "Rest Area KM 439 A", "toilets": "yes"},
    {"highway": "services", "name": "Rest Area KM 445B", "toilets": "yes"},
    {"area": "yes", "highway": "services", "name": "Rest Area KM 392",
     "operator": "PT Jasa Marga Batang-Semarang (Persero)"},
    {"area": "yes", "highway": "services", "name": "Rest Area KM 389B",
     "operator": "PT Jasa Marga Batang-Semarang (Persero)"},
    {"highway": "services", "name": "Honda Ahass 7386 Dipo Jaya Sakti", "opening_hours": "Mo-Sa 08:00-16:00",
     "operator": "AHASS"},
    {"highway": "rest_area", "name": "Sitalang"},
    {"highway": "services", "name": "Rest Area KM 456B", "operator": "Trans Marga Jateng", "toilets": "yes"},
    {"highway": "services", "name": "Rest Area KM 456A", "operator": "Trans Marga Jateng", "toilets": "yes"},
    {"area": "yes", "highway": "services", "name": "Rest Area Krengseng",
     "operator": "PT Jasa Marga Batang-Semarang (Persero)"},
    {"highway": "rest_area"},
    {"highway": "rest_area"},
    {"addr:city": "Magelang", "highway": "rest_area", "name": "Rest Area Bandongan"},
    {"highway": "services", "name": "Rest Area KM 360"},
    {"amenity": "parking", "highway": "rest_area", "name": "Parkir Siswodipuran"},
    {"area": "yes", "highway": "rest_area", "name": "Laju Prima", "opening_hours": "24/7"},
    {"highway": "services", "name": "Rest Area KM 487 A", "toilets": "yes"},
    {"highway": "services", "name": "Rest Area KM 487 B", "toilets": "yes"},
    {"highway": "services", "name": "Rest Area Sijonggol"},
    {"highway": "rest_area", "name": "Sekar Pajang", "opening_hours": "24/7", "toilets": "yes"},
    {"highway": "services", "name": "Bengkel Body Repair Citam Bengkel Cat", "opening_hours": "8 ours",
     "operator": "Bengkel Body Repair Citam Bengkel Cat"},
    {"area": "yes", "highway": "services", "name": "Rest Area KM 519A", "toilets": "yes"},
    {"area": "yes", "highway": "services", "name": "Rest Area KM 519B", "toilets": "yes"},
    {"area": "yes", "highway": "services", "name": "Rest Area KM 344B"},
    {"highway": "services", "name": "Rest Area KM 344A"},
]


def test_only_repair_shops_are_dropped_from_real_data():
    dropped = [tags.get("name") for tags in SEMARANG_SOLO if _excluded(REST, tags)]
    assert dropped == ["bengkel motor", "Honda Ahass 7386 Dipo Jaya Sakti", "Bengkel Body Repair Citam Bengkel Cat"]


def test_repair_tags_are_dropped_even_with_a_neutral_name():
    assert _excluded(REST, {"highway": "services", "shop": "motorcycle_repair", "name": "Jaya Motor"})
    assert _excluded(REST, {"highway": "services", "amenity": "car_wash"})
    assert _excluded(REST, {"highway": "services", "name": "Tambal Ban 24 Jam"})
    assert not _excluded(REST, {"highway": "services", "name": "Rest Area KM 57", "amenity": "fuel"})


def test_other_categories_are_not_filtered():
    shop = {"type": "node", "id": 1, "lat": -6.99, "lon": 110.42, "tags": {"shop": "convenience", "name": "Bengkel Kopi"}}
    assert _to_place(shop, CATEGORIES["minimarket"]).name == "Bengkel Kopi"
    bengkel = {"type": "way", "id": 2, "center": {"lat": -7.03, "lon": 110.38},
               "tags": {"highway": "services", "name": "bengkel motor"}}
    assert _to_place(bengkel, REST) is None


def test_live_osm_results_skip_repair_shops():
    calls = ByHost(a=[ok(node(1, highway="services", name="bengkel motor"),
                         node(2, -6.21, 106.8, highway="services", name="Rest Area KM 429"))])
    places = search(make(calls, PLACES_OSM_URL="https://a.example/api/interpreter"), category="rest_area")
    assert [p.name for p in places] == ["Rest Area KM 429"]


def test_snapshot_skips_repair_shops(tmp_path):
    elements = [{"type": "way", "id": i, "center": {"lat": -7.0 - i / 100, "lon": 110.4}, "tags": tags}
                for i, tags in enumerate(SEMARANG_SOLO)]
    path = tmp_path / "places_snapshot.json"
    path.write_text(json.dumps({"elements": elements}), encoding="utf-8")
    settings = load_settings({"PLACES_PROVIDER": "snapshot", "PLACES_USAGE_FILE": "off",
                              "PLACES_SNAPSHOT_FILE": str(path)})
    provider = SnapshotProvider(settings)
    names = [p.name for p in provider.places["rest_area"]]
    assert len(names) == 24 and "bengkel motor" not in names and "Parkir Siswodipuran" in names
