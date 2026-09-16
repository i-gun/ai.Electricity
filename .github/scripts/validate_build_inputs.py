#!/usr/bin/env python3
"""
Validate and normalize build matrix inputs for ai.Electricity CI/CD.

This script validates platform selections, build modes, artifact formats, and
confirmation status. It outputs a normalized JSON matrix suitable for GitHub Actions.

Usage:
    python validate_build_inputs.py --platforms '["windows","android"]' \
        --artifact-formats '{"windows":"bundle","android":"apk"}' \
        --build-mode release --confirmation confirmed
"""

import argparse
import json
import sys
from typing import List, Dict, Any


ALLOWED_FORMATS = {
    'windows': 'bundle',
    'macos': 'bundle',
    'linux': 'bundle',
    'android': 'apk',
    'ios': 'simulator-app',
}
ALLOWED_PLATFORMS = sorted(ALLOWED_FORMATS.keys())
PLATFORM_RUNNERS = {
    'windows': 'windows-latest',
    'macos': 'macos-latest',
    'ios': 'macos-latest',
    'linux': 'ubuntu-latest',
    'android': 'ubuntu-latest',
}


def validate_inputs(platforms: str, artifact_formats: str, build_mode: str, confirmation: str) -> Dict[str, Any]:
    """
    Validate all build inputs and return normalized matrix.
    
    Args:
        platforms: JSON array string of platform names
        artifact_formats: JSON object string mapping platforms to formats
        build_mode: Build mode (debug, profile, release)
        confirmation: Confirmation string (must be exactly 'confirmed')
    
    Returns:
        Dictionary containing normalized platforms, build_mode, formats, and matrix
    
    Raises:
        ValueError: If any validation fails
    """
    
    # Validate confirmation
    if confirmation != 'confirmed':
        raise ValueError('Confirmation must be exactly confirmed.')
    
    # Parse and validate platforms
    try:
        selected_platforms = json.loads(platforms)
        if not isinstance(selected_platforms, list):
            raise ValueError()
    except (json.JSONDecodeError, ValueError):
        raise ValueError('Platforms must be a JSON array.')
    
    # Check for empty or invalid platform values
    if not selected_platforms or not all(isinstance(p, str) and p.strip() for p in selected_platforms):
        raise ValueError('Platforms must be a non-empty JSON array of strings.')
    
    # Normalize to lowercase
    normalized_platforms = [p.lower() for p in selected_platforms]
    
    # Check for duplicates
    if len(set(normalized_platforms)) != len(normalized_platforms):
        raise ValueError('Platforms must not contain duplicates.')
    
    # Validate each platform
    for platform in normalized_platforms:
        if platform not in ALLOWED_PLATFORMS:
            raise ValueError(f'Unknown platform: {platform}')
        if platform == 'android' and build_mode != 'release':
            raise ValueError('Android release APKs require release build mode.')
    
    # Parse and validate artifact formats
    try:
        format_map = json.loads(artifact_formats)
        if not isinstance(format_map, dict):
            raise ValueError()
    except (json.JSONDecodeError, ValueError):
        raise ValueError('ArtifactFormats must be a JSON object.')
    
    # Validate formats for selected platforms
    for platform in normalized_platforms:
        if platform not in format_map:
            raise ValueError(f'Missing format for platform: {platform}')
        format_value = str(format_map[platform]).strip()
        if format_value != ALLOWED_FORMATS[platform]:
            raise ValueError(f'Unsupported or missing format for {platform}. '
                           f'Expected {ALLOWED_FORMATS[platform]}.')
    
    # Check for extra formats
    extra_formats = [p for p in format_map.keys() if p not in normalized_platforms]
    if extra_formats:
        raise ValueError(f'Artifact formats contain unselected platforms: {", ".join(extra_formats)}.')
    
    # Build matrix
    matrix = []
    for platform in normalized_platforms:
        runner = PLATFORM_RUNNERS[platform]
        matrix.append({
            'platform': platform,
            'format': ALLOWED_FORMATS[platform],
            'runner': runner,
        })
    
    result = {
        'platforms': normalized_platforms,
        'build_mode': build_mode,
        'formats': format_map,
        'matrix': matrix,
    }
    
    return result


def main():
    """Parse arguments and validate build inputs."""
    parser = argparse.ArgumentParser(
        description='Validate and normalize build matrix inputs for ai.Electricity CI/CD.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--platforms', required=True, help='JSON array of platform names')
    parser.add_argument('--artifact-formats', required=True, help='JSON object of platform to format mappings')
    parser.add_argument('--build-mode', required=True, choices=['debug', 'profile', 'release'],
                       help='Flutter build mode')
    parser.add_argument('--confirmation', required=True, help='Confirmation string (must be "confirmed")')
    parser.add_argument('--output-path', help='Optional: write output to file instead of stdout')
    
    args = parser.parse_args()
    
    try:
        result = validate_inputs(args.platforms, args.artifact_formats, args.build_mode, args.confirmation)
        json_output = json.dumps(result, separators=(',', ':'))
        
        if args.output_path:
            with open(args.output_path, 'w', encoding='utf-8') as f:
                f.write(json_output)
        
        print(json_output)
        return 0
    except ValueError as e:
        print(f'Error: {e}', file=sys.stderr)
        return 1
    except Exception as e:
        print(f'Unexpected error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
