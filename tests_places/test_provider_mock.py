"""Tes provider mock (tempat palsu untuk pengembangan tanpa internet/API key)."""
import pytest

from conftest import run
from nearby_places.categories import CATEGORIES, Category
from nearby_places.geo import bearing_deg, angle_diff_deg, haversine_m
from nearby_places.providers.base import NO_BUDGET
from nearby_places.providers.mock import MockProvider

JAKARTA = (-6.2, 106.8)
DENPASAR = (-8.65, 115.2167)


def search(category, position=JAKARTA, radius=None):
    cat = CATEGORIES[category]
    return run(MockProvider().search(cat, position[0], position[1], radius or cat.default_radius_m, NO_BUDGET))


@pytest.mark.parametrize("category", list(CATEGORIES))
def test_every_category_has_places(category):
    assert search(category)


@pytest.mark.parametrize("position", [JAKARTA, DENPASAR, (47.6, -122.3), (-33.9, 151.2)])
def test_places_are_placed_relative_to_any_position(position):
    for place in search("minimarket", position):
        assert 300 <= haversine_m(position[0], position[1], place.lat, place.lng) <= 2000


def test_distance_and_bearing_match_the_seed():
    near = search("minimarket")[0]  # Alfamart: 350 m ke arah 40 derajat
    assert abs(haversine_m(*JAKARTA, near.lat, near.lng) - 350) < 1
    assert angle_diff_deg(bearing_deg(*JAKARTA, near.lat, near.lng), 40) < 0.5


def test_radius_filters_places():
    assert [p.name for p in search("minimarket", radius=1000)] == ["Alfamart (contoh)", "Indomaret (contoh)"]
    assert search("minimarket", radius=200) == []


def test_places_are_clearly_marked_as_fake():
    for category in CATEGORIES:
        for place in search(category):
            assert "(contoh)" in place.name
            assert place.id.startswith("mock:")
            assert place.provider_type == "mock"
            assert place.maps_url.startswith("https://www.google.com/maps/")


def test_ids_are_unique_and_stable():
    first = [p.id for category in CATEGORIES for p in search(category)]
    second = [p.id for category in CATEGORIES for p in search(category)]
    assert first == second
    assert len(first) == len(set(first))


def test_unknown_category_returns_nothing():
    other = Category(key="aneh", label="Aneh", speech="aneh", google_types=("x",), osm_filters=(),
                     default_radius_m=1000)
    assert run(MockProvider().search(other, *JAKARTA, 1000, NO_BUDGET)) == []


def test_probe_counts_results():
    assert run(MockProvider().probe(NO_BUDGET)) >= 1
