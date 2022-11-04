"""
To perform tests manually, run this command from the top directory
of the repository:

> python -m unittest discover tests

or simply

> python -m unittest
"""

import io
import unittest

from subway_structure import City
from subway_io import load_xml
from tests.sample_data import sample_networks


class TestOneRouteTracks(unittest.TestCase):
    """Test tracks extending and truncating on one-route networks"""

    CITY_TEMPLATE = {
        "id": 1,
        "name": "Null Island",
        "country": "World",
        "continent": "Africa",
        "num_stations": None,  # Would be taken from the sample network data under testing
        "num_lines": 1,
        "num_light_lines": 0,
        "num_interchanges": 0,
        "bbox": "-179, -89, 179, 89",
        "networks": "",
    }

    def assertListAlmostEqual(self, list1, list2, places=10) -> None:
        if not (isinstance(list1, list) and isinstance(list2, list)):
            raise RuntimeError(
                f"Not lists passed to the '{self.__class__.__name__}."
                "assertListAlmostEqual' method"
            )
        self.assertEqual(len(list1), len(list2))
        for a, b in zip(list1, list2):
            if isinstance(a, list) and isinstance(b, list):
                self.assertListAlmostEqual(a, b, places)
            else:
                self.assertAlmostEqual(a, b, places)

    def prepare_city_routes(self, network) -> tuple:
        city_data = self.CITY_TEMPLATE.copy()
        city_data["num_stations"] = network["station_count"]
        city = City(city_data)
        elements = load_xml(io.BytesIO(network["xml"].encode("utf-8")))
        for el in elements:
            city.add(el)
        city.extract_routes()
        city.validate()

        self.assertTrue(city.is_good)

        route_master = list(city.routes.values())[0]
        variants = route_master.routes

        fwd_route = [v for v in variants if v.name == "Forward"][0]
        bwd_route = [v for v in variants if v.name == "Backward"][0]

        return fwd_route, bwd_route

    def _test_tracks_extending_for_network(self, network_data):
        fwd_route, bwd_route = self.prepare_city_routes(network_data)

        self.assertEqual(
            fwd_route.tracks,
            network_data["tracks"],
            "Wrong tracks",
        )
        extended_tracks = fwd_route.get_extended_tracks()
        self.assertEqual(
            extended_tracks,
            network_data["extended_tracks"],
            "Wrong tracks after extending",
        )

        self.assertEqual(
            bwd_route.tracks,
            network_data["tracks"][::-1],
            "Wrong backward tracks",
        )
        extended_tracks = bwd_route.get_extended_tracks()
        self.assertEqual(
            extended_tracks,
            network_data["extended_tracks"][::-1],
            "Wrong backward tracks after extending",
        )

    def _test_tracks_truncating_for_network(self, network_data):
        fwd_route, bwd_route = self.prepare_city_routes(network_data)

        truncated_tracks = fwd_route.get_truncated_tracks(fwd_route.tracks)
        self.assertEqual(
            truncated_tracks,
            network_data["truncated_tracks"],
            "Wrong tracks after truncating",
        )
        truncated_tracks = bwd_route.get_truncated_tracks(bwd_route.tracks)
        self.assertEqual(
            truncated_tracks,
            network_data["truncated_tracks"][::-1],
            "Wrong backward tracks after truncating",
        )

    def _test_stop_positions_on_rails_for_network(self, network_data):
        fwd_route, bwd_route = self.prepare_city_routes(network_data)

        for route, route_label in zip(
            (fwd_route, bwd_route), ("forward", "backward")
        ):
            route_data = network_data[route_label]

            for attr in (
                "first_stop_on_rails_index",
                "last_stop_on_rails_index",
            ):
                self.assertEqual(
                    getattr(route, attr),
                    route_data[attr],
                    f"Wrong {attr} for {route_label} route",
                )

            first_index = route_data["first_stop_on_rails_index"]
            last_index = route_data["last_stop_on_rails_index"]
            positions_on_rails = [
                rs.positions_on_rails
                for rs in route.stops[first_index : last_index + 1]
            ]
            self.assertListAlmostEqual(
                positions_on_rails, route_data["positions_on_rails"]
            )

    def test_tracks_extending(self) -> None:
        for network_name, network_data in sample_networks.items():
            with self.subTest(msg=network_name):
                self._test_tracks_extending_for_network(network_data)

    def test_tracks_truncating(self) -> None:
        for network_name, network_data in sample_networks.items():
            with self.subTest(msg=network_name):
                self._test_tracks_truncating_for_network(network_data)

    def test_stop_position_on_rails(self) -> None:
        for network_name, network_data in sample_networks.items():
            with self.subTest(msg=network_name):
                self._test_stop_positions_on_rails_for_network(network_data)