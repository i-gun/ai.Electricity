#!/usr/bin/env python3
"""
Unit tests for validate_build_inputs.py

Validates that the build input validation logic works correctly across all
test cases including valid inputs and various error conditions.
"""

import json
import subprocess
import sys
from pathlib import Path


def run_validator(platforms: str, artifact_formats: str, build_mode: str, 
                 confirmation: str) -> tuple[int, str, str]:
    """
    Run validate_build_inputs.py and capture output.
    
    Args:
        platforms: JSON array string
        artifact_formats: JSON object string
        build_mode: Build mode
        confirmation: Confirmation string
    
    Returns:
        Tuple of (return_code, stdout, stderr)
    """
    script_dir = Path(__file__).parent
    script_path = script_dir / 'validate_build_inputs.py'
    
    cmd = [
        sys.executable, str(script_path),
        '--platforms', platforms,
        '--artifact-formats', artifact_formats,
        '--build-mode', build_mode,
        '--confirmation', confirmation,
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def assert_rejected(case_name: str, platforms: str, artifact_formats: str,
                   build_mode: str, confirmation: str, expected_error: str) -> None:
    """
    Assert that a validation case is rejected with expected error.
    
    Args:
        case_name: Name of test case
        platforms: JSON array string
        artifact_formats: JSON object string
        build_mode: Build mode
        confirmation: Confirmation string
        expected_error: Expected error substring
    
    Raises:
        AssertionError: If validation doesn't fail as expected
    """
    returncode, stdout, stderr = run_validator(
        platforms, artifact_formats, build_mode, confirmation
    )
    
    if returncode == 0:
        raise AssertionError(f'Expected rejection for {case_name}.')
    
    error_output = stderr + stdout
    if expected_error not in error_output:
        raise AssertionError(
            f'Unexpected rejection for {case_name}: {error_output}'
        )


def main():
    """Run all validation tests."""
    print('Testing build input validation...', file=sys.stderr)
    
    # Test valid configuration
    print('  Testing valid configuration...', file=sys.stderr)
    returncode, stdout, stderr = run_validator(
        '["windows","android"]',
        '{"windows":"bundle","android":"apk"}',
        'release',
        'confirmed'
    )
    
    if returncode != 0:
        print(f'Error: Valid case failed: {stderr}', file=sys.stderr)
        return 1
    
    try:
        result = json.loads(stdout)
        if result.get('platforms') != ['windows', 'android']:
            raise AssertionError('Platform count mismatch')
        if result['matrix'][1]['runner'] != 'ubuntu-latest':
            raise AssertionError('Runner OS not normalized correctly')
    except (json.JSONDecodeError, AssertionError) as e:
        print(f'Error: Valid case JSON validation failed: {e}', file=sys.stderr)
        return 1
    
    # Test error cases
    test_cases = [
        ('confirmation', '["windows"]', '{"windows":"bundle"}', 'debug', 'yes',
         'exactly confirmed'),
        ('malformed', '["windows"', '{"windows":"bundle"}', 'debug', 'confirmed',
         'JSON array'),
        ('duplicate', '["windows","windows"]', '{"windows":"bundle"}', 'debug', 'confirmed',
         'duplicates'),
        ('unknown', '["web"]', '{"web":"bundle"}', 'debug', 'confirmed',
         'Unknown platform'),
        ('android-debug', '["android"]', '{"android":"apk"}', 'debug', 'confirmed',
         'release APKs require release build mode'),
    ]
    
    for case_name, platforms, formats, mode, confirm, expected_error in test_cases:
        print(f'  Testing {case_name}...', file=sys.stderr)
        try:
            assert_rejected(case_name, platforms, formats, mode, confirm, expected_error)
        except AssertionError as e:
            print(f'Error: {e}', file=sys.stderr)
            return 1
    
    print('All build input validation tests passed.', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
