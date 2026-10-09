#!/usr/bin/env python3
"""Create a temporary Release/UI-test workspace without changing project schemes."""

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path, help="New .xcworkspace path under /private/tmp")
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if workspace.suffix != ".xcworkspace":
        parser.error("workspace must end in .xcworkspace")
    if workspace.exists():
        parser.error(f"{workspace} already exists; remove it or pick another path")

    repository = Path(__file__).resolve().parent.parent
    project = repository / "opencast.xcodeproj"
    scheme = ET.parse(project / "xcshareddata/xcschemes/OpenCast.xcscheme")
    test_action = scheme.getroot().find("TestAction")
    testables = test_action.find("Testables") if test_action is not None else None
    if test_action is None or testables is None:
        parser.error("OpenCast.xcscheme has no TestAction/Testables to derive the profile scheme from")
    test_action.set("buildConfiguration", "Release")
    test_action.set("codeCoverageEnabled", "NO")
    for testable in list(testables):
        if testable.find("BuildableReference").get("BlueprintName") != "OpenCastUITests":
            testables.remove(testable)
    for reference in scheme.iter("BuildableReference"):
        reference.set("ReferencedContainer", f"container:{project}")

    workspace.mkdir(parents=True)
    schemes = workspace / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    ET.indent(scheme, space="   ")
    scheme.write(schemes / "OpenCastInteractionProfile.xcscheme", encoding="UTF-8", xml_declaration=True)
    contents = ET.Element("Workspace", version="1.0")
    ET.SubElement(contents, "FileRef", location=f"absolute:{project}")
    ET.ElementTree(contents).write(workspace / "contents.xcworkspacedata", encoding="UTF-8", xml_declaration=True)
    print(workspace)


if __name__ == "__main__":
    main()
