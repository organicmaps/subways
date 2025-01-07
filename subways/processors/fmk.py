from __future__ import annotations

import json
import logging
import os
import typing
from collections import defaultdict
from collections.abc import Callable
from typing import Any, TypeAlias

from subways.consts import DISPLACEMENT_TOLERANCE
from subways.geom_utils import distance
from subways.osm_element import el_center
from subways.structure.station import Station
from subways.types import IdT, LonLat, OsmElementT, TransfersT
from ._common import (
    DEFAULT_AVE_VEHICLE_SPEED,
    DEFAULT_INTERVAL,
    format_colour,
    KMPH_TO_MPS,
    SPEED_ON_TRANSFER,
    TRANSFER_PENALTY,
)

if typing.TYPE_CHECKING:
    from subways.structure.city import City
    from subways.structure.stop_area import StopArea


OSM_TYPES = {"n": (0, "node"), "w": (2, "way"), "r": (3, "relation")}
ENTRANCE_PENALTY = 60  # seconds
SPEED_TO_ENTRANCE = 5 * KMPH_TO_MPS  # m/s

# (stoparea1_uid, stoparea2_uid) -> seconds; stoparea1_uid < stoparea2_uid
TransferTimesT: TypeAlias = dict[tuple[int, int], int]


def uid(elid: IdT, typ: str | None = None) -> int:
    t = elid[0]
    osm_id = int(elid[1:])
    if not typ:
        osm_id = (osm_id << 2) + OSM_TYPES[t][0]
    elif typ != t:
        raise Exception("Got {}, expected {}".format(elid, typ))
    return osm_id << 1


def transit_data_to_fmk(cities: list[City], transfers: TransfersT) -> dict:
    """Generate all output and save to file.
    :param cities: List of City instances
    :param transfers: List of sets of StopArea.id
    :param cache_path: Path to json-file with good cities cache or None.
    """

    def find_exits_for_platform(
        center: LonLat, nodes: list[OsmElementT]
    ) -> list[OsmElementT]:
        exits: list[OsmElementT] = []
        min_distance = None
        for n in nodes:
            d = distance(center, (n["lon"], n["lat"]))
            if not min_distance:
                min_distance = d * 2 / 3
            elif d < min_distance:
                continue
            too_close = False
            for e in exits:
                d = distance((e["lon"], e["lat"]), (n["lon"], n["lat"]))
                if d < min_distance:
                    too_close = True
                    break
            if not too_close:
                exits.append(n)
        return exits

    stop_areas: dict[IdT, StopArea] = {}
    stops: dict[IdT, dict] = {}  # stoparea el_id -> stop jsonified data
    networks = []
    good_cities = [c for c in cities if c.is_good]
    platform_nodes = {}

    for city in good_cities:
        network = {"network": city.name, "routes": [], "agency_id": city.id}
        for route in city:
            routes = {
                "type": route.mode,
                "ref": route.ref,
                "name": route.name,
                "colour": format_colour(route.colour),
                "route_id": uid(route.id, "r"),
                "itineraries": [],
            }
            if route.infill:
                routes["casing"] = routes["colour"]
                routes["colour"] = format_colour(route.infill)
            for i, variant in enumerate(route):
                itin = []
                for stop in variant:
                    stop_areas[stop.stoparea.id] = stop.stoparea
                    itin.append(uid(stop.stoparea.id))
                    # Make exits from platform nodes,
                    # if we don't have proper exits
                    if (
                        len(stop.stoparea.entrances) + len(stop.stoparea.exits)
                        == 0
                    ):
                        for pl in stop.stoparea.platforms:
                            pl_el = city.elements[pl]
                            if pl_el["type"] == "node":
                                pl_nodes = [pl_el]
                            elif pl_el["type"] == "way":
                                pl_nodes = [
                                    city.elements.get("n{}".format(n))
                                    for n in pl_el["nodes"]
                                ]
                            else:
                                pl_nodes = []
                                for m in pl_el["members"]:
                                    if m["type"] == "way":
                                        if (
                                            "{}{}".format(
                                                m["type"][0], m["ref"]
                                            )
                                            in city.elements
                                        ):
                                            pl_nodes.extend(
                                                [
                                                    city.elements.get(
                                                        "n{}".format(n)
                                                    )
                                                    for n in city.elements[
                                                        "{}{}".format(
                                                            m["type"][0],
                                                            m["ref"],
                                                        )
                                                    ]["nodes"]
                                                ]
                                            )
                            pl_nodes = [n for n in pl_nodes if n]
                            platform_nodes[pl] = find_exits_for_platform(
                                stop.stoparea.centers[pl], pl_nodes
                            )

                routes["itineraries"].append(itin)
            network["routes"].append(routes)
        networks.append(network)

    for stop_id, stop in stop_areas.items():
        st = {
            "name": stop.name,
            "int_name": stop.int_name,
            "lat": stop.center[1],
            "lon": stop.center[0],
            "osm_type": OSM_TYPES[stop.station.id[0]][1],
            "osm_id": int(stop.station.id[1:]),
            "id": uid(stop.id),
            "entrances": [],
            "exits": [],
        }
        for e_l, k in ((stop.entrances, "entrances"), (stop.exits, "exits")):
            for e in e_l:
                if e[0] == "n":
                    st[k].append(
                        {
                            "osm_type": "node",
                            "osm_id": int(e[1:]),
                            "lon": stop.centers[e][0],
                            "lat": stop.centers[e][1],
                        }
                    )
        if len(stop.entrances) + len(stop.exits) == 0:
            if stop.platforms:
                for pl in stop.platforms:
                    for n in platform_nodes[pl]:
                        for k in ("entrances", "exits"):
                            st[k].append(
                                {
                                    "osm_type": n["type"],
                                    "osm_id": n["id"],
                                    "lon": n["lon"],
                                    "lat": n["lat"],
                                }
                            )
            else:
                for k in ("entrances", "exits"):
                    st[k].append(
                        {
                            "osm_type": OSM_TYPES[stop.station.id[0]][1],
                            "osm_id": int(stop.station.id[1:]),
                            "lon": stop.centers[stop.id][0],
                            "lat": stop.centers[stop.id][1],
                        }
                    )

        stops[stop_id] = st

    pairwise_transfers: list[list[int]] = []
    for stoparea_id_set in transfers:
        tr = list(sorted([uid(sa_id) for sa_id in stoparea_id_set
                          if sa_id in stops]))
        if len(tr) > 1:
            pairwise_transfers.append(tr)

    result = {
        "stops": list(stops.values()),
        "transfers": pairwise_transfers,
        "networks": networks,
    }
    return result


def process(
    cities: list[City],
    transfers: TransfersT,
    filename: str,
    cache_path: str | None,
) -> None:
    """Generate all output and save to file.
    :param cities: list of City instances
    :param transfers: all collected transfers in the world
    :param filename: Path to file to save the result
    :param cache_path: Path to json-file with good cities cache or None.
    """
    if not filename.lower().endswith("json"):
        filename = f"{filename}.json"

    fmk_transit = transit_data_to_fmk(cities, transfers)

    with open(filename, "w", encoding="utf-8") as f:
        json.dump(
            fmk_transit,
            f,
            indent=1,
            ensure_ascii=False,
        )
