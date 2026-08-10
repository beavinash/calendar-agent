"""Tests for deterministic GitHub Actions simulator selection."""

import importlib.util
from pathlib import Path
from types import ModuleType

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def load_selector() -> ModuleType:
  """Load the workflow helper without making `.github` an app package."""
  helper_path = REPOSITORY_ROOT / ".github" / "select_ios_simulator.py"
  spec = importlib.util.spec_from_file_location(
    "select_ios_simulator",
    helper_path,
  )
  assert spec is not None
  assert spec.loader is not None
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


def test_prefers_iphone_16_pro_and_ignores_placeholder() -> None:
  output = """
Available destinations for the "CalendarAgent" scheme:
  { platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
  { platform:iOS Simulator, arch:arm64, id:PHONE-16, OS:18.5, name:iPhone 16 }
  { platform:iOS Simulator, arch:arm64, id:PHONE-16-PRO, OS:18.5, name:iPhone 16 Pro }
"""

  destination = load_selector().choose_simulator(output)

  assert destination is not None
  assert destination.identifier == "PHONE-16-PRO"
  assert destination.name == "iPhone 16 Pro"


def test_uses_highest_os_for_preferred_model() -> None:
  output = """
  { platform:iOS Simulator, arch:arm64, id:OLDER, OS:18.4, name:iPhone 16 Pro }
  { platform:iOS Simulator, arch:arm64, id:NEWER, OS:18.5, name:iPhone 16 Pro }
"""

  destination = load_selector().choose_simulator(output)

  assert destination is not None
  assert destination.identifier == "NEWER"


def test_falls_back_to_first_real_iphone() -> None:
  output = """
  { platform:iOS Simulator, arch:arm64, id:PHONE-15, OS:18.5, name:iPhone 15 }
  { platform:iOS Simulator, arch:arm64, id:PHONE-SE, OS:18.5, name:iPhone SE (3rd generation) }
  { platform:iOS Simulator, arch:arm64, id:IPAD, OS:18.5, name:iPad Pro 13-inch (M4) }
"""

  destination = load_selector().choose_simulator(output)

  assert destination is not None
  assert destination.identifier == "PHONE-15"


def test_ignores_preferred_model_in_ineligible_destinations() -> None:
  output = """
Available destinations for the "CalendarAgent" scheme:
  { platform:iOS Simulator, arch:arm64, id:PHONE-15, OS:18.5, name:iPhone 15 }
Ineligible destinations for the "CalendarAgent" scheme:
  { platform:iOS Simulator, arch:arm64, id:BAD-PRO, OS:18.5, name:iPhone 16 Pro, error:iOS 18.5 is not installed }
"""

  destination = load_selector().choose_simulator(output)

  assert destination is not None
  assert destination.identifier == "PHONE-15"


def test_returns_none_when_only_placeholders_or_non_iphones_exist() -> None:
  output = """
  { platform:macOS, arch:arm64, id:MAC, name:My Mac }
  { platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
  { platform:iOS Simulator, arch:arm64, id:IPAD, OS:18.5, name:iPad Air 11-inch (M3) }
"""

  assert load_selector().choose_simulator(output) is None


def test_ios_workflow_resolves_a_real_simulator_udid() -> None:
  workflow = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text()

  assert "xcrun simctl list devices available" in workflow
  assert "xcodebuild -downloadPlatform iOS" in workflow
  assert "steps.simulator.outputs.id" in workflow
  assert "OS=latest,name=iPhone 16 Pro" not in workflow
