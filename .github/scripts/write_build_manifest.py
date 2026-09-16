#!/usr/bin/env python3
"""
Generate build manifest and checksums from staged artifacts.

This script reads staged build artifacts, computes SHA256 checksums,
and generates a manifest file with artifact metadata.

Usage:
    python write_build_manifest.py --staging-directory /path/to/staging \
        --output-directory /path/to/output --source-ref main \
        --commit-sha abc123... --run-id 12345 --runner-os Linux \
        --flutter-version "3.10.0" --dart-version "3.10.0"
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Any


def compute_file_sha256(file_path: Path) -> str:
    """
    Compute SHA256 hash of a file.
    
    Args:
        file_path: Path to file
    
    Returns:
        Lowercase hex digest
    """
    sha256 = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            sha256.update(chunk)
    return sha256.hexdigest().lower()


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


def generate_manifest(staging_dir: str, output_dir: str, source_ref: str,
                     commit_sha: str, run_id: str, runner_os: str,
                     flutter_version: str, dart_version: str) -> Dict[str, Any]:
    """
    Generate build manifest and checksums.
    
    Args:
        staging_dir: Staging directory with build artifacts
        output_dir: Output directory for manifest and checksums
        source_ref: Source reference (branch/tag)
        commit_sha: Commit SHA
        run_id: GitHub Actions run ID
        runner_os: Runner OS name
        flutter_version: Flutter version
        dart_version: Dart version
    
    Returns:
        Generated manifest dictionary
    
    Raises:
        ValueError: If artifact paths escape staging directory
        FileNotFoundError: If entries.json not found
    """
    staging_path = Path(staging_dir).resolve()
    output_path = Path(output_dir).resolve()
    
    # Create output directory
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Read entries
    entries_file = staging_path / 'entries.json'
    if not entries_file.exists():
        raise FileNotFoundError('No entries.json found in staging directory.')
    
    with open(entries_file, 'r', encoding='utf-8') as f:
        entries = json.load(f)
    
    manifest_entries: List[Dict[str, Any]] = []
    checksum_lines: List[str] = []
    
    for entry in entries:
        artifact_path = (staging_path / entry['path']).resolve()
        
        # Ensure path is within staging directory
        try:
            artifact_path.relative_to(staging_path)
        except ValueError:
            raise ValueError('Artifact path escaped staging.')
        
        # Get all files recursively
        files = sorted(artifact_path.rglob('*'))
        files = [f for f in files if f.is_file()]
        
        if not files:
            raise FileNotFoundError(f'Artifact has no files: {entry["path"]}')
        
        # Compute checksums
        parts = []
        total_bytes = 0
        for file in files:
            file_hash = compute_file_sha256(file)
            relative_file = get_safe_relative_path(staging_path, file)
            parts.append(f'{relative_file}={file_hash}')
            total_bytes += file.stat().st_size
            checksum_lines.append(f'{file_hash}  {relative_file}')
        
        # Compute aggregate hash
        aggregate_data = '\n'.join(parts).encode('utf-8')
        aggregate_hash = hashlib.sha256(aggregate_data).hexdigest().lower()
        
        manifest_entries.append({
            'platform': entry['platform'],
            'build_mode': entry['build_mode'],
            'format': entry['format'],
            'relative_artifact_path': entry['path'],
            'byte_size': total_bytes,
            'sha256': aggregate_hash,
            'build_status': 'completed',
            'warnings': [],
        })
    
    # Create manifest
    manifest = {
        'schema': 'code-build-artifact-manifest/v1',
        'workflow_run_id': run_id,
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'source_ref': source_ref,
        'commit_sha': commit_sha,
        'runner_os': runner_os,
        'flutter_version': flutter_version.strip(),
        'dart_version': dart_version.strip(),
        'artifacts': manifest_entries,
        'warnings': [],
    }
    
    # Write manifest
    manifest_file = output_path / 'manifest.json'
    with open(manifest_file, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2)
    
    # Write checksums
    checksums_file = output_path / 'SHA256SUMS'
    with open(checksums_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(checksum_lines))
        if checksum_lines:
            f.write('\n')
    
    return manifest


def main():
    """Parse arguments and generate manifest."""
    parser = argparse.ArgumentParser(
        description='Generate build manifest and checksums from staged artifacts.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--staging-directory', required=True,
                       help='Directory containing staged artifacts')
    parser.add_argument('--output-directory', required=True,
                       help='Directory to write manifest and checksums')
    parser.add_argument('--source-ref', required=True,
                       help='Source reference (branch/tag)')
    parser.add_argument('--commit-sha', required=True,
                       help='Commit SHA')
    parser.add_argument('--run-id', required=True,
                       help='GitHub Actions run ID')
    parser.add_argument('--runner-os', required=True,
                       help='Runner OS name')
    parser.add_argument('--flutter-version', required=True,
                       help='Flutter version')
    parser.add_argument('--dart-version', required=True,
                       help='Dart version')
    
    args = parser.parse_args()
    
    try:
        manifest = generate_manifest(
            args.staging_directory, args.output_directory,
            args.source_ref, args.commit_sha, args.run_id,
            args.runner_os, args.flutter_version, args.dart_version
        )
        print(json.dumps(manifest, indent=2))
        return 0
    except (ValueError, FileNotFoundError) as e:
        print(f'Error: {e}', file=sys.stderr)
        return 1
    except Exception as e:
        print(f'Unexpected error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
