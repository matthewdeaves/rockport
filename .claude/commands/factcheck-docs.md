## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty). It may specify which docs to check, specific areas of concern, or files to focus on.

## Purpose

Deep factcheck of project documentation (README.md, CLAUDE.md, and SVG diagrams) against the actual codebase. Finds inaccuracies, stale references, missing information, and bloat. Produces a report and then applies fixes.

**Audience distinction:**
- **README.md** is for humans setting up and using Rockport. It should explain what things do and how to use them.
- **CLAUDE.md** is for Claude Code. It should document non-obvious gotchas, exact technical details, and things that would trip up an AI assistant working on the codebase. Don't duplicate what's readable from code.

## Outline

### Phase 1: Build ground truth from code

Read ALL of the following source-of-truth files. Do not skip any. Use the Agent tool with subagent_type=Explore or parallel Read calls to maximise speed.

**1. LiteLLM config** — `config/litellm-config.yaml`:
   - Extract every model entry: `model_name`, `litellm_params.model` (full Bedrock ID including any `us.` prefix), `aws_region_name`, `model_info.mode`, any extra fields like `disable_background_health_check`
   - Extract `general_settings` (master_key source, database_url, max_budget, budget_duration)
   - Extract `litellm_settings` (drop_params, disable_admin_ui, etc.)
   - Extract `default_key_generate_params` (rpm_limit, tpm_limit)

**2. Terraform infrastructure** — read ALL of these:
   - `terraform/tunnel.tf` — extract the EXACT ingress rules list (path, service, order)
   - `terraform/waf.tf` — extract the EXACT WAF expression (every `not starts_with` line and exact match)
   - `terraform/access.tf` — Cloudflare Access configuration
   - `terraform/variables.tf` — every variable with its default value and description
   - `terraform/main.tf` — instance type, AMI, user_data reference, key resources
   - `terraform/s3.tf` — bucket names, regions, lifecycle rules
   - `terraform/deployer-policies/*.json` — IAM policy structure

**3. Sidecar code** — read these files:
   - `sidecar/image_api.py` — extract every `@router.post` path, every Pydantic model class, every Bedrock model ID and region used, every helper function that still exists
   - `sidecar/video_api.py` — extract every endpoint, model support, validation rules, concurrent job limits
   - `sidecar/prompt_validation.py` — extract exact validation rules (negation words, camera keywords, min length)
   - `sidecar/image_resize.py` — extract resize modes and constraints
   - `sidecar/db.py` — extract what tables are used
   - `sidecar/requirements.txt` — list of dependencies

**4. Admin CLI** — `scripts/rockport.sh`:
   - Extract ALL subcommands by reading the usage/help section at the bottom
   - Extract the `CLAUDE_MODELS` variable (exact model list for --claude-only)
   - Extract any hardcoded values (ports, paths, model names, version strings)
   - Check the health check logic — what patterns are matched, what gets probed vs skipped

**5. Smoke tests** — `tests/smoke-test.sh`:
   - Extract every test number, name, what it tests, and expected HTTP codes
   - Count total tests

**6. Bootstrap** — `scripts/bootstrap.sh`:
   - Extract services installed, system users created, ports bound, systemd units deployed
   - Extract LiteLLM version, Python version

**7. Systemd units** — read ALL of `config/*.service`:
   - Extract service name, user, MemoryMax, security hardening flags
   - Extract ExecStart commands and ports

**8. CI/CD** — read `.github/workflows/*.yml`:
   - Extract workflow names, triggers, steps

**9. IAM policies** — `terraform/deployer-policies/*.json` and `terraform/rockport-admin-policy.json`:
   - Extract key permissions and scoping

**10. Example files and gitignore**:
   - `terraform/terraform.tfvars.example` — every variable in `variables.tf` must be present, defaults must match exactly, required vs optional must be correct
   - `terraform/.env.example` — must exist and document the Cloudflare API token
   - `.gitignore` — must exclude `.env*` and `*.tfvars` but include `!.env.example`, `!*.env.example`, `!*.tfvars.example`

**11. Additional Terraform files**:
   - `terraform/idle.tf` — Lambda, EventBridge, CloudWatch alarm resources
   - `terraform/monitoring.tf` — budget alarms, SNS, auto-recovery
   - `terraform/outputs.tf` — all output names and sensitivity markers
   - `terraform/snapshots.tf` — DLM lifecycle policy

**12. Init/deploy flow** — `scripts/rockport.sh`:
   - Extract the admin vs deployer credential flow (auto-profile selection, init override)
   - Extract what `cmd_init` creates (IAM policies, deployer user, access keys, CLI profile, master key, state bucket)
   - Extract what `cmd_destroy` cleans up (and what it doesn't — IAM users/policies, CLI profile, orphaned log groups)

### Phase 2: Cross-reference and audit

For each documentation file, check EVERY factual claim against the ground truth gathered in Phase 1. Be methodical — go line by line through each doc file.

#### README.md audit checklist
- [ ] Opening description matches actual capabilities
- [ ] "What you get" bullet list — every bullet is true, nothing important is missing
- [ ] Model list matches litellm-config.yaml EXACTLY (model names, no extras, no omissions)
- [ ] Prerequisites section — Marketplace subscription list is accurate
- [ ] CLI commands table — every subcommand exists, descriptions match, no missing commands
- [ ] Configuration variables table — every variable exists in variables.tf, defaults match EXACTLY
- [ ] Image generation model table — dimensions, constraints, defaults all correct per model
- [ ] Image editing section — model names match config, endpoint path is correct, cost table accurate
- [ ] Sidecar endpoint table — only lists endpoints that actually exist in image_api.py
- [ ] Video generation — durations, costs, modes, model comparison table all accurate
- [ ] Security section — every claim matches actual systemd/terraform/WAF config
- [ ] CI/CD section — matches actual workflow files
- [ ] Smoke test description — cost estimate accurate, test count correct
- [ ] Setup section — IAM policy names match actual policies created by init (3 deployer policies, not 1)
- [ ] Setup section — admin vs deployer credential flow accurately described
- [ ] Setup section — profile auto-selection behavior documented
- [ ] No dead links or references to removed features/endpoints

#### CLAUDE.md audit checklist
- [ ] Project Structure tree — run `find` to verify every listed file/directory exists, no missing entries
- [ ] Key Commands table — matches rockport.sh subcommands exactly
- [ ] Important Notes — check EVERY bullet against code:
  - [ ] Ports mentioned match tunnel.tf and systemd units
  - [ ] Region assignments match litellm-config.yaml aws_region_name fields
  - [ ] Model names/IDs match litellm-config.yaml exactly
  - [ ] Endpoint paths match sidecar @router.post decorators
  - [ ] Tunnel routing description matches tunnel.tf ingress rules EXACTLY
  - [ ] WAF description matches waf.tf expression EXACTLY
  - [ ] Memory limits match systemd MemoryMax values
  - [ ] Cost figures match actual Bedrock pricing
  - [ ] Prompt validation rules match prompt_validation.py EXACTLY
  - [ ] Resize modes match image_resize.py EXACTLY
- [ ] Project Structure tree — includes example files (terraform.tfvars.example, .env.example)
- [ ] Active Technologies — no stale feature-branch references (e.g. "(009-complete-image-services)")
- [ ] Recent Changes — is current and accurate
- [ ] No duplicate bullets saying the same thing in different words
- [ ] No bullets that just restate what's obvious from reading the code

#### SVG diagram audit (rockport_architecture_overview.svg)
- [ ] Every model box has a model name that exists in litellm-config.yaml
- [ ] No model boxes for models that don't exist in config
- [ ] Region labels match config: check eu-west-2, us-east-1, us-west-2 assignments
- [ ] Service ports (:4000, :4001) match tunnel.tf and systemd
- [ ] cloudflared routing text matches tunnel.tf ingress rules
- [ ] Sidecar box description matches actual sidecar capabilities (video + what image ops?)
- [ ] Memory limits in boxes match systemd MemoryMax
- [ ] AWS services panel matches actual terraform resources (SSM, CloudWatch, DLM, S3, Budgets, Lambda)

#### SVG diagram audit (rockport_request_dataflow.svg)
- [ ] cloudflared routing description matches tunnel.tf ingress (path patterns and port assignments)
- [ ] LiteLLM processing steps match actual auth flow (key format, DB lookup, model restriction, rate limit, budget, routing)
- [ ] Error codes match actual responses (401, 403, 429, 400)
- [ ] Rate limit values match litellm-config.yaml (rpm_limit, tpm_limit)
- [ ] Budget values match litellm-config.yaml (max_budget, default budget)
- [ ] Video sidecar flow matches video_api.py (auth, validation, budget, Bedrock call, concurrent limit)

### Phase 3: Report findings

Present ALL findings in a table. Be exhaustive — every discrepancy matters.

```
| # | File | Location | Type | Description | Fix |
|---|------|----------|------|-------------|-----|
| 1 | README.md | L42 | STALE | References /v1/images/structure (removed) | Remove row |
| 2 | CLAUDE.md | L108 | INACCURATE | Says MemoryMax 512MB, systemd has 256MB | Change to 256MB |
| 3 | arch.svg | sidecar box | MISSING | No stability-* models shown | Add model box |
| 4 | CLAUDE.md | L95,L107 | DUPLICATE | Tunnel routing described twice | Remove one |
```

Issue types:
- **STALE** — references something that no longer exists in code
- **INACCURATE** — states something that contradicts the code
- **MISSING** — omits something important that exists in code
- **BLOAT** — unnecessary verbosity or over-documentation of obvious things
- **DUPLICATE** — same fact stated multiple times
- **INCONSISTENT** — two doc files contradict each other about the same fact

After presenting the table, ask: "Shall I apply all fixes?" and wait for confirmation before proceeding.

### Phase 4: Apply fixes

After user confirms, apply all fixes:
- **STALE**: remove or update the reference
- **INACCURATE**: correct to match code exactly
- **MISSING**: add in the appropriate location (README for users, CLAUDE.md for Claude)
- **BLOAT**: remove the unnecessary content
- **DUPLICATE**: keep the better version, remove the other
- **INCONSISTENT**: use the version that matches code, fix the other

### Phase 5: Verify

After applying fixes:
1. Run `shellcheck` on any modified `.sh` files
2. Run `terraform -chdir=terraform fmt -check` if terraform files were touched
3. Run `python3 -c "import ast; ast.parse(open('file').read())"` on any modified `.py` files
4. Validate modified SVGs are well-formed XML: `python3 -c "import xml.etree.ElementTree as ET; ET.parse('file.svg')"`
5. Run `python3 -c "import yaml; yaml.safe_load(open('config/litellm-config.yaml'))"` if config was touched
6. Show a git diff summary of all changes made

## Rules

### No bloat (CRITICAL)

- **Only document what is needed and accurate. Be succinct.** Don't add prose, context, or background that doesn't help the reader do something or avoid a mistake.
- **State facts, not explanations.** "Stability AI image edit models use the `us.` cross-region inference prefix" is good. "Because Stability AI models on Bedrock are only available through cross-region inference profiles, which route requests across multiple US regions for improved availability, the model IDs must include the `us.` prefix" is bloat.
- **If the current wording is accurate, leave it alone.** Don't rephrase working descriptions.
- **CLAUDE.md litmus test:** "Would Claude make a mistake without this bullet?" If no, delete it.
- **README.md should be scannable.** Tables over paragraphs. Bullet points over prose. Code examples over descriptions.

### Source of truth

- **Code is the single source of truth** — if docs and code disagree, docs are wrong
- **Every claim must be verifiable** — if you can't find it in the code, it shouldn't be in the docs
- **Precision over prose** — use exact model names, exact paths, exact ports, exact error codes

### Audience

- **README.md is for humans** — explain what things do and how to use them
- **CLAUDE.md is for Claude** — document non-obvious gotchas and constraints that would cause mistakes. Don't document things readable from code
- **No duplication across files** — don't repeat the same fact in both unless the audiences genuinely need different framing

### SVG diagrams

- **SVGs must render correctly** — every edit must produce valid XML. After any SVG edit, validate with `python3 -c "import xml.etree.ElementTree as ET; ET.parse('file.svg'); print('valid')"` before moving on
- **Do not rewrite SVGs** — make targeted text edits only. Changing a `<text>` element's content is fine. Restructuring layout, moving boxes, or adding new elements risks breaking coordinates and alignment. Only add/move SVG elements if you can verify the coordinates are correct by examining adjacent elements
- **SVG text must match code exactly** — routing descriptions, port numbers, model names, memory limits must all come from the source-of-truth files read in Phase 1
- **Test SVG rendering** — if any SVG was modified, after all fixes are applied open it in a browser or viewer to check it renders without overlapping text or broken layout. If you can't open a viewer, at minimum validate XML and check that no coordinates were accidentally changed

### Cleanup

- **Remove stale feature-branch annotations** — bullets ending in "(009-complete-image-services)" or similar should be cleaned up once merged
- **Active Technologies should list only current tech** — no feature-branch-specific entries
- **Remove dead references** — any mention of endpoints, files, or features that no longer exist must be removed, not just updated
