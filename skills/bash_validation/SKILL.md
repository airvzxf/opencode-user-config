---
name: bash-validation
description: Validate and correct Bash scripts using shellcheck
---

# Bash Validation Skill

This skill is designed to help you validate, debug, and correct Bash scripts using the `shellcheck` static analysis tool.

## Key Goals
- Detect syntax errors and common pitfalls in Bash scripts.
- Interpret `shellcheck` warnings (SC codes).
- Apply best practices for shell scripting, including strict mode and robust error handling.

## Tool Usage

Use `run_command` to execute `shellcheck`.

**IMPORTANT**: When validating scripts that use `source` or `.` to include external files, you MUST execute `shellcheck` from the script's directory. Otherwise, `shellcheck` won't find the sourced files and will report false errors.

### 1. Validation (Recommended)
Use this command to validate scripts with strict style enforcement and external source checking:
```bash
cd /path/to/script/directory
shellcheck --enable=require-variable-braces --external-sources ./script.sh
```

### 2. Machine-Readable Output
For detailed analysis, use JSON output with strict checks enabled:
```bash
cd /path/to/script/directory
shellcheck --enable=require-variable-braces --external-sources --format json ./script.sh
```

### 3. Generate Diff (Reference Only)
To see how `shellcheck` would auto-fix the code (use this as a guide):
```bash
cd /path/to/script/directory
shellcheck --enable=require-variable-braces --external-sources --format diff ./script.sh
```

## Interpreting Output

`shellcheck` output includes:
- **File**: The file being checked.
- **Line/Column**: Location of the issue.
- **Level**: Severity (error, warning, info, style).
- **Code**: The SC code (e.g., SC2086).
- **Message**: Description of the issue.

### Common Codes
- **SC2086**: Double quote to prevent globbing and word splitting.
  - *Fix*: Quote variables (e.g., `"$var"` instead of `$var`).
- **SC2006**: Use `$(...)` notation instead of legacy backticks `` `...` ``.
- **SC2155**: Declare and assign separately to avoid masking return values.
- **SC2250**: Prefer braces for variable expansion (optional).
  - *Fix*: Use `${var}` instead of `$var`.

## Best Practices

When writing or correcting Bash scripts, adhere to these standards:

### 1. Shebang
Use `#!/usr/bin/env bash` for better portability across different systems.

### 2. File Extension
- **New Files**: Always use the `.bash` extension (e.g., `script.bash`) instead of `.sh`.
- **Existing Files**: If you encounter a Bash script with a `.sh` extension, recommend changing it to `.bash`, but do not force the rename unless explicitly asked.

### 3. Strict Mode
Always start scripts with:
```bash
set -euo pipefail
```
- `-e`: Exit immediately if a command exits with a non-zero status.
- `-u`: Treat unset variables as an error.
- `-o pipefail`: Return value of a pipeline is the status of the last command to exit with a non-zero status.

### 3. Cleanup and Traps
Use `trap` to ensure cleanup code runs even if the script fails or is interrupted:
```bash
cleanup() {
  # Remove temporary files, kill background processes, etc.
  rm -f /tmp/tempfile
}
trap cleanup EXIT
```

## Remediation Strategy

1.  **Analyze**: Navigate to the script's directory and run `shellcheck` with strict checks:
    ```bash
    cd /path/to/script/directory
    shellcheck --enable=require-variable-braces --external-sources --format json ./script.sh
    ```
2.  **Plan**: For each issue, determine the correct fix.
    - If `shellcheck` offers a fix (visible via `--format diff`), evaluate it.
    - **CRITICAL**: Do not blindly apply `shellcheck --format diff` or patches if you are unsure. Context matters.
3.  **Apply**: Use `replace_file_content` or `multi_replace_file_content` to apply the fixes to the script.
4.  **Verify**: Run `shellcheck` again to ensure no new errors were introduced and the targeted errors are resolved.

## Examples

See the `examples/` directory for `bad_script.sh` and `good_script.sh` to understand common errors and their fixes.
