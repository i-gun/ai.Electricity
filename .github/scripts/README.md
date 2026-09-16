# Build Scripts - Python Implementation

This directory contains Python scripts for the ai.Electricity CI/CD build pipeline. These scripts have been migrated from PowerShell to Python to ensure **cross-platform compatibility** across Windows, macOS, and Linux environments.

## Scripts

### validate_build_inputs.py
Validates and normalizes build matrix inputs for GitHub Actions.

**Purpose:**
- Validates platform selections (windows, macos, linux, android, ios)
- Validates build modes (debug, profile, release)
- Validates artifact formats for each platform
- Verifies confirmation status
- Outputs normalized JSON matrix suitable for GitHub Actions

**Usage:**
```bash
python3 validate_build_inputs.py \
  --platforms '["windows","android"]' \
  --artifact-formats '{"windows":"bundle","android":"apk"}' \
  --build-mode release \
  --confirmation confirmed
```

**Output:**
Prints JSON containing `platforms`, `build_mode`, `formats`, and `matrix` array with runner assignments.

### collect_build_artifacts.py
Collects and stages build artifacts from Flutter build output.

**Purpose:**
- Locates platform-specific build artifacts from Flutter builds
- Stages artifacts for manifest generation
- Computes artifact metadata (path, platform, build_mode, format)
- Writes entries to `entries.json` for subsequent processing

**Usage:**
```bash
python3 collect_build_artifacts.py \
  --platform windows \
  --build-mode release \
  --format bundle \
  --workspace /path/to/workspace \
  --staging-directory /path/to/staging
```

**Output:**
Prints JSON entry with artifact metadata and updates `entries.json` in staging directory.

### write_build_manifest.py
Generates build manifest and checksums from staged artifacts.

**Purpose:**
- Reads staged artifacts from `entries.json`
- Computes SHA256 checksums for all files
- Generates comprehensive manifest with artifact metadata
- Creates `SHA256SUMS` file for integrity verification
- Produces structured build report

**Usage:**
```bash
python3 write_build_manifest.py \
  --staging-directory /path/to/staging \
  --output-directory /path/to/output \
  --source-ref main \
  --commit-sha abc123... \
  --run-id 12345 \
  --runner-os Linux \
  --flutter-version "3.10.0" \
  --dart-version "3.10.0"
```

**Output:**
- `manifest.json` - Comprehensive build manifest with schema version and artifact details
- `SHA256SUMS` - Checksums in standard `sha256sum` format
- Prints manifest JSON to stdout

### test_validate_build_inputs.py
Unit tests for the build input validation logic.

**Purpose:**
- Tests valid input configurations
- Tests rejection of various malformed/invalid inputs
- Validates normalization of platform names and matrix generation
- Ensures error messages match expected patterns

**Usage:**
```bash
python3 test_validate_build_inputs.py
```

**Output:**
Prints test progress to stderr and exits with 0 on success, 1 on failure.

## Migration from PowerShell

### Why Python?
- **Cross-Platform:** Python 3 is available on Windows, macOS, and Linux without additional setup
- **Dependency-Free:** Uses only Python standard library (no third-party packages)
- **Consistency:** Easier to maintain a single codebase across all CI/CD runners
- **Performance:** Slightly faster execution than PowerShell on Linux/macOS

### Updated Workflows
The following GitHub Actions workflows have been updated to use Python scripts:
- `.github/workflows/code-build-artifacts.yml` - Primary build artifact workflow
- `.github/workflows/release.yml` - Release binary packaging workflow

### Shell Changes
Where previously workflows used `shell: pwsh`, they now use `shell: bash` for better cross-platform support. Bash is available on all major CI runners (Windows includes Git Bash, macOS and Linux have bash built-in).

### Platform-Specific Build Logic
Build commands for different platforms are now handled using bash `case` statements instead of PowerShell `switch` statements, maintaining the same logic with better portability.

## Requirements

- **Python 3.8+** (available on all GitHub Actions runners)
- **Bash** (for workflow shell execution)
- No additional Python packages required

## Development

### Adding New Validations
To add new platform validation rules, update the `ALLOWED_FORMATS` and `PLATFORM_RUNNERS` dictionaries in `validate_build_inputs.py` and add corresponding test cases to `test_validate_build_inputs.py`.

### Adding New Platforms
1. Add platform to `ALLOWED_FORMATS` dict with supported format
2. Add platform runner mapping to `PLATFORM_RUNNERS` dict
3. Update `collect_build_artifacts.py` with artifact search paths
4. Add test cases to `test_validate_build_inputs.py`

### Error Handling
All scripts follow consistent error handling patterns:
- Print errors to stderr
- Exit with code 1 on validation/processing errors
- Exit with code 0 on success
- Include helpful error messages for troubleshooting

## Future Enhancements

- Parallelization of artifact collection for faster builds
- Integration with artifact signing/verification tools
- Support for additional artifact formats (IPA for iOS distribution)
- Enhanced checksum verification with cryptographic signatures
