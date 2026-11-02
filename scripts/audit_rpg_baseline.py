"""Read-only P0 source inventory; does not compile or run the iOS application."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SWIFT = sorted(ROOT.glob('*.swift'))
PROJECT = ROOT / 'Moonlight-iOS.xcodeproj/project.pbxproj'
project = PROJECT.read_text()
references = re.findall(r'path = ([^;]+\.swift);', project)
references = [name.strip('"') for name in references]
ui_source = ROOT / 'MoonlightUITests/ScrollGestureTests.swift'
tests = re.findall(r'\bfunc (test\w+)\(', ui_source.read_text())
missing = [name for name in references if not (ROOT / name).is_file()]
imports = {}
for path in SWIFT:
    for module in re.findall(r'^import (\w+)', path.read_text(), re.MULTILINE):
        imports.setdefault(module, []).append(path.name)
expected_types = ('WorldState', 'Chunk', 'BlockDefinition', 'BlockInstance',
                  'MediaBinding', 'PhysicsProfile', 'BehaviorGraph',
                  'TopDownProjection', 'SideViewScene', 'StoryGraph', 'StoryState')
found = {}
for path in SWIFT:
    declarations = re.findall(r'\b(?:struct|class|enum|protocol|actor)\s+(\w+)', path.read_text())
    for name in expected_types:
        if name in declarations:
            found.setdefault(name, []).append(path.name)
fingerprint = hashlib.sha256()
for path in SWIFT:
    fingerprint.update(path.name.encode() + b'\0' + path.read_bytes() + b'\0')
result = {
    'audit_kind': 'static_source_inventory_not_ios_build_or_runtime_validation',
    'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'root_swift_sources': [path.name for path in SWIFT],
    'root_swift_source_count': len(SWIFT),
    'app_swift_source_fingerprint_sha256': fingerprint.hexdigest(),
    'project_swift_reference_count_including_ui_tests': len(references),
    'missing_project_references': missing,
    'ui_test_methods': tests,
    'ui_test_count': len(tests),
    'unique_ui_test_count': len(set(tests)),
    'swift_versions': sorted(set(re.findall(r'SWIFT_VERSION = ([^;]+);', project))),
    'deployment_targets': sorted(set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);', project))),
    'device_families': sorted(set(re.findall(r'TARGETED_DEVICE_FAMILY = "([^"]+)";', project))),
    'swift_package_references': len(re.findall(r'isa = XCRemoteSwiftPackageReference', project)),
    'root_dependency_manifests': [name for name in ('Package.swift', 'Package.resolved', 'Podfile', 'Cartfile') if (ROOT / name).exists()],
    'framework_imports_by_file': dict(sorted(imports.items())),
    'proposed_rpg_type_declarations_found': found,
    'spec_dimension_arithmetic_only_not_a_generated_world': {
        'surface_cells': 256 * 256, 'chunk_cells': 32 * 32,
        'chunks_per_axis': 256 // 32, 'chunks_total': (256 // 32) ** 2,
    },
}
print(json.dumps(result, ensure_ascii=False, indent=2))
if missing or len(tests) != len(set(tests)):
    sys.exit(1)
