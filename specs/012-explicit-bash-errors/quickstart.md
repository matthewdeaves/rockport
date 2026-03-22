# Quickstart: Explicit Bash Error Handling

## Verification Steps

After implementation, verify the changes:

### 1. Check no implicit flags remain

```bash
grep -rn 'set -e\|set -u\|set -o pipefail\|set -euo' scripts/ tests/
# Expected: zero matches
```

### 2. Check die() is defined in all scripts

```bash
grep -l 'die()' scripts/bootstrap.sh scripts/rockport.sh scripts/setup.sh tests/smoke-test.sh
# Expected: all 4 files listed
```

### 3. Run shellcheck

```bash
shellcheck scripts/bootstrap.sh scripts/rockport.sh scripts/setup.sh tests/smoke-test.sh
# Expected: no new warnings
```

### 4. Test rockport.sh error paths

```bash
# Missing dependency
PATH=/nonexistent ./scripts/rockport.sh status
# Expected: "ERROR: aws not found..." message, exit 1

# Bad subcommand
./scripts/rockport.sh nonexistent
# Expected: usage message, exit 1
```

### 5. Test setup.sh (safe — only checks, doesn't install if tools present)

```bash
./scripts/setup.sh
# Expected: same output as before (checkmarks for installed tools)
```
