#!/usr/bin/env python3
"""Select a real iPhone from `xcodebuild -showdestinations` output."""

from __future__ import annotations

import argparse
import re
import sys
from typing import NamedTuple


class SimulatorDestination(NamedTuple):
    """An Xcode-compatible iPhone simulator destination."""

    identifier: str
    name: str
    os_version: str


def parse_destinations(output: str) -> list[SimulatorDestination]:
    """Parse real iPhone simulator destinations from Xcode text output."""
    destinations: list[SimulatorDestination] = []
    ineligible_section = False

    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Available destinations"):
            ineligible_section = False
            continue
        if stripped.startswith("Ineligible destinations"):
            ineligible_section = True
            continue
        if ineligible_section:
            continue
        if not stripped.startswith("{") or not stripped.endswith("}"):
            continue

        fields: dict[str, str] = {}
        for component in stripped.removeprefix("{").removesuffix("}").split(","):
            key, separator, value = component.partition(":")
            if separator:
                fields[key.strip()] = value.strip()

        identifier = fields.get("id", "")
        name = fields.get("name", "")
        if fields.get("platform") != "iOS Simulator":
            continue
        if "error" in fields:
            continue
        if "placeholder" in identifier.casefold():
            continue
        if not name.startswith("iPhone"):
            continue

        destinations.append(
            SimulatorDestination(
                identifier=identifier,
                name=name,
                os_version=fields.get("OS", ""),
            )
        )

    return destinations


def version_key(version: str) -> tuple[int, ...]:
    """Return a numeric key for an Xcode destination OS version."""
    return tuple(int(component) for component in re.findall(r"\d+", version))


def choose_simulator(
    output: str,
    preferred_name: str = "iPhone 16 Pro",
) -> SimulatorDestination | None:
    """Choose the preferred iPhone, then the first real iPhone available."""
    destinations = parse_destinations(output)
    preferred = [
        destination
        for destination in destinations
        if destination.name == preferred_name
    ]
    if preferred:
        return max(
            preferred,
            key=lambda destination: (
                version_key(destination.os_version),
                destination.identifier,
            ),
        )
    return destinations[0] if destinations else None


def main() -> int:
    """Read Xcode destinations from stdin and print the selected opaque UDID."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--preferred-name", default="iPhone 16 Pro")
    arguments = parser.parse_args()

    destination = choose_simulator(
        sys.stdin.read(),
        preferred_name=arguments.preferred_name,
    )
    if destination is None:
        print(
            "No real iPhone simulator appears in Xcode's available destinations.",
            file=sys.stderr,
        )
        return 2

    print(destination.identifier)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
