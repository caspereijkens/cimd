#!/usr/bin/env python3
"""Generate Zig CIM parent edges from an RDFS/OWL schema file.

Usage:
  scripts/generate-cim-type-table.py path/to/CIM-schema.rdfs

The output is the initializer body for `parent_edges` in
`src/cgmes/cim_types.zig`. Review the diff before committing; cimd currently
checks in a focused subset of CIM classes used by its CLI filters.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RDF_NS = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
RDFS_NS = "{http://www.w3.org/2000/01/rdf-schema#}"


def local_name(value: str) -> str:
    value = value.rsplit("#", 1)[-1].rsplit("/", 1)[-1]
    if "." in value:
        value = value.rsplit(".", 1)[-1]
    return value


def is_class_name(value: str) -> bool:
    return bool(re.match(r"^[A-Z][A-Za-z0-9_]*$", value))


def class_id(element: ET.Element) -> str | None:
    for attr in (RDF_NS + "about", RDF_NS + "ID"):
        if attr in element.attrib:
            name = local_name(element.attrib[attr])
            return name if is_class_name(name) else None
    return None


def parent_id(element: ET.Element) -> str | None:
    for child in element:
        if child.tag != RDFS_NS + "subClassOf":
            continue
        resource = child.attrib.get(RDF_NS + "resource")
        if not resource:
            continue
        name = local_name(resource)
        return name if is_class_name(name) else None
    return None


def generate_edges(path: Path) -> list[tuple[str, str]]:
    root = ET.parse(path).getroot()
    edges: set[tuple[str, str]] = set()
    for element in root.iter():
        child = class_id(element)
        if child is None:
            continue
        parent = parent_id(element)
        if parent is None or parent == child:
            continue
        edges.add((child, parent))
    return sorted(edges)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("rdfs", type=Path)
    args = parser.parse_args()

    for child, parent in generate_edges(args.rdfs):
        print(f'    .{{ .child = "{child}", .parent = "{parent}" }},')
    return 0


if __name__ == "__main__":
    sys.exit(main())
