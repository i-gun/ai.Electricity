#!/usr/bin/env python3
"""
Collect build artifacts from Flutter build output.

This script locates platform-specific build artifacts and stages them for
manifest generation and checksum computation.

Usage:
    python collect_build_artifacts.py --platform windows --build-mode release \
        --format bundle --workspace /path/to/workspace --staging-directory /path/to/staging
"""

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Dict, Any


def get_safe_relative_path(base: Path, path: Path) -> str:
    """
    Get a safe relative path from base to path, ensuring path doesn't escape base.

    Args:
        base: Base directory
        path: Target path

    Returns:
        Relative path with forward slashes

    Raises:
        ValueError: If path escapes base directory
    """
    try:
        relative = path.relative_to(base)
        return str(relative).replace('\\', '/')
    except ValueError:
        raise ValueError('Path is outside the expected root.')


def find_artifact(workspace: Path, platform: str, build_mode: str, fmt: str) -> Path:
    """
    Find the build artifact for a given platform and build mode.

    Args:
        workspace: Workspace root directory
        platform: Platform name (windows, macos, linux, android, ios)
        build_mode: Build mode (debug, profile, release)
        fmt: Artifact format (bundle, apk, simulator-app)

    Returns:
        Path to the artifact

    Raises:
        FileNotFoundError: If artifact cannot be found
    """
    mode_title = build_mode.capitalize()

    candidates = []
    if platform == 'windows':
        candidates = [workspace / f'apps/desktop/build/windows/x64/runner/{mode_title}']
    elif platform == 'macos':
        candidates = [workspace / f'apps/desktop/build/macos/Build/Products/{mode_title}']
    elif platform == 'linux':
        candidates = [workspace / f'apps/desktop/build/linux/x64/{build_mode}/bundle']
    elif platform == 'android':
        candidates = [workspace / f'apps/mobile/build/app/outputs/flutter-apk/app-{build_mode}.apk']
    elif platform == 'ios':
        candidates = [workspace / f'apps/mobile/build/ios/iphonesimulator']

    # Try to find the artifact
    for candidate in candidates:
        if candidate.is_file():
            return candidate
        if candidate.is_dir():
            return candidate

        # Try glob patterns
        if '*' in str(candidate):
            parent = candidate.parent
            pattern = candidate.name
            if parent.exists():
                matches = list(parent.glob(pattern))
                if matches:
                    return matches[0]

    raise FileNotFoundError(
        f'No real output found for {platform}/{build_mode} ({fmt}).'
    )


def collect_artifacts(platform: str, build_mode: str, fmt: str,
                     workspace: str, staging_directory: str) -> Dict[str, Any]:
    """
    Collect and stage build artifacts.

    Args:
        platform: Platform name
        build_mode: Build mode
        fmt: Artifact format
        workspace: Workspace root directory
        staging_directory: Directory to stage artifacts

    Returns:
        Dictionary with artifact metadata

    Raises:
        ValueError: If artifact paths escape workspace
        FileNotFoundError: If artifacts not found
    """
    workspace_path = Path(workspace).resolve()
    staging_path = Path(staging_directory).resolve()

    # Create staging directory
    staging_path.mkdir(parents=True, exist_ok=True)

    # Find artifact
    source = find_artifact(workspace_path, platform, build_mode, fmt)
    source_full = source.resolve()

    # Ensure source is within workspace
    try:
        source_full.relative_to(workspace_path)
    except ValueError:
        raise ValueError('Artifact source escaped the workspace.')

    # Stage artifact
    destination = staging_path / f'{platform}-{build_mode}-{fmt}'
    if destination.exists():
        shutil.rmtree(destination)

    if source_full.is_dir():
        shutil.copytree(source_full, destination)
    else:
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_full, destination / source_full.name)

    # Generate entry
    relative = get_safe_relative_path(staging_path, destination)
    entry = {
        'platform': platform,
        'build_mode': build_mode,
        'format': fmt,
        'path': relative,
    }

    # Write entry to entries.json
    entries_file = staging_path / 'entries.json'
    entries_content = []
    if entries_file.exists():
        with open(entries_file, 'r', encoding='utf-8') as f:
            entries_content = json.load(f)

    entries_content.append(entry)

    with open(entries_file, 'w', encoding='utf-8') as f:
        json.dump(entries_content, f, separators=(',', ':'))

    return entry


def main():
    """Parse arguments and collect build artifacts."""
    parser = argparse.ArgumentParser(
        description='Collect build artifacts from Flutter build output.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--platform', required=True,
                       choices=['windows', 'macos', 'linux', 'android', 'ios'],
                       help='Target platform')
    parser.add_argument('--build-mode', required=True,
                       choices=['debug', 'profile', 'release'],
                       help='Flutter build mode')
    parser.add_argument('--format', required=True,
                       choices=['bundle', 'apk', 'simulator-app'],
                       help='Artifact format')
    parser.add_argument('--workspace', required=True, help='Workspace root directory')
    parser.add_argument('--staging-directory', required=True,
                       help='Directory to stage artifacts')

    args = parser.parse_args()

    try:
        entry = collect_artifacts(args.platform, args.build_mode, args.format,
                                 args.workspace, args.staging_directory)
        print(json.dumps(entry, separators=(',', ':')))
        return 0
    except (ValueError, FileNotFoundError) as e:
        print(f'Error: {e}', file=sys.stderr)
        return 1
    except Exception as e:
        print(f'Unexpected error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
