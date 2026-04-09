# AAP Execution Environment Configuration Repository

This repository contains the build definitions and dependency requirements for all Ansible Automation Platform (AAP) Execution Environments (EEs) and Decision Environments (DEs). It is the single source of truth for EE/DE image configuration and uses a GitOps workflow to build and promote images through lab and production environments via Gitea Actions.

Ansible collection dependencies are **not** managed here. Collections are declared in each Ansible project's own `requirements.yml` and installed at runtime by AAP. This repository is concerned only with the EE/DE image itself — the Python environment, system packages, and base image configuration.

---

## Naming Standard

All images follow this naming convention:

```
<org>_<type>_<n>:<major>.<minor>
```

| Segment | Format | Description |
|---|---|---|
| `org` | 3 letters | Owning organization identifier |
| `type` | `EE` or `DE` | Execution Environment or Decision Environment |
| `name` | 6 letters or fewer | Short descriptive name for the EE/DE |
| `version` | `1.0`, `1.1`, etc. | Semantic version — see versioning rules below |

**Example:** `ops_EE_netops:1.2`

The folder name for each EE/DE must match the image name exactly, without the version tag:

```
ops_EE_netops/
```

### Versioning Rules

The version is stored in a `VERSION` file at the root of each EE/DE directory (e.g. `1.2`). It must be bumped in every PR — the CI pipeline will fail if the `VERSION` file is unchanged. The pipeline reads this file at build time to tag the image.

**Increment the minor version** (`1.0` → `1.1`) when:
- Adding or updating a Python package in `requirements.txt`

**Increment the major version** (`1.0` → `2.0`) when:
- Changing the base image
- Changing the Python binary version
- Adding or updating a system package in `bindep.txt`

---

## Dependency Pinning

All packages in `requirements.txt` and `bindep.txt` must be version pinned. Unpinned packages are flagged as a warning during CI — the build will still proceed, but the PR will be marked with a warning and the unpinned packages will be listed in the CI output.

Any of the following pinning formats are acceptable:

| Format | Example | Meaning |
|---|---|---|
| Exact | `requests==2.31.0` | Only this version |
| Compatible release | `requests~=2.31.0` | `>=2.31.0, <2.32.0` |
| Bounded range | `requests>=2.31.0,<=2.32.0` | Within explicit bounds |

Bare package names with no version specifier (e.g. `requests`) are not acceptable and will trigger a warning.

> **Why this matters:** Unpinned packages can silently pull in a newer version at build time, causing unexpected behavior and making builds non-reproducible. A version change that would otherwise require a version bump in `VERSION` could slip through unnoticed.

---

## Repository Structure

Each EE or DE has its own top-level directory named after the image (without the version tag). Every directory must contain the four standard files:

```
.
├── <org>_<EE|DE>_<n>/
│   ├── execution-environment.yml   # ansible-builder EE/DE definition
│   ├── requirements.txt            # Python (pip) dependencies (must be pinned)
│   ├── bindep.txt                  # System package dependencies (must be pinned)
│   └── VERSION                     # Current image version (e.g. 1.2)
├── <org>_<EE|DE>_<n>/
│   └── ...
└── README.md
```

> Do not place EE/DE build files outside of their respective directory.

---

## Branch Strategy

```
feature/<your-branch>
        │
        │  Pull Request
        ▼
       dev             ← Lab build & test CI runs here
        │
        │  Pull Request (requires passing dev CI run)
        ▼
      main             ← Production build CI runs here
```

| Branch | Purpose | Who can push? |
|---|---|---|
| `main` | Production-promoted EE/DE definitions | PRs from `dev` only |
| `dev` | Integration branch; triggers lab builds | PRs from feature branches only |
| `feature/*` | Day-to-day development and changes | Any contributor |

**Direct pushes to `dev` and `main` are not permitted.** All changes must come in through a pull request.

---

## PR Requirements

Before a PR to either `dev` or `main` can be merged, the following automated checks must pass:

**Single EE/DE per PR** — A PR may only contain changes to files within a single EE/DE directory. If changes span more than one folder, the check will fail and the PR cannot be merged. Each EE/DE change must go through its own separate PR and CI cycle.

**VERSION file bumped** — The `VERSION` file in the changed EE/DE directory must be updated in every PR. A PR that modifies any other file in the directory without also bumping `VERSION` will fail this check.

**Passing CI run** — All pipeline steps (build, push, and tests) must complete successfully.

**Passing dev CI reference (main PRs only)** — A PR targeting `main` must include a reference to the passing Gitea Actions run from `dev` in the PR description. See the workflow section below for the required format.

The following is a non-blocking warning that will be surfaced in the CI output but will not prevent a merge:

**Unpinned packages** — If any package in `requirements.txt` or `bindep.txt` lacks a version specifier, the CI run will post a warning listing each unpinned package. The build will still proceed, but the warning should be resolved before the next PR.

---

## Workflow

### 1. Making Changes

Create a feature branch off of `dev`:

```bash
git checkout dev
git pull
git checkout -b feature/<image-name>-<short-description>
```

Make your changes within a single EE/DE directory. Before opening the PR:

- Ensure all packages in `requirements.txt` and `bindep.txt` are version pinned.
- Bump the `VERSION` file according to the versioning rules above.

Then open a PR targeting the `dev` branch.

### 2. Lab Build (dev CI)

When a PR is merged into `dev`, Gitea Actions triggers the lab runner pipeline automatically. The pipeline:

1. Identifies which EE/DE directory was changed in the PR.
2. Reads the `VERSION` file from that directory to determine the image tag.
3. Checks `requirements.txt` and `bindep.txt` for unpinned packages and posts a warning to the PR if any are found.
4. Builds that image using `ansible-builder` inside a Podman container on the runner host.
5. Pushes the resulting image to the **lab registry**, tagged with the version from the `VERSION` file.
6. Runs the EE/DE test suite against the image (see [Testing](#testing) below).
7. Reports pass/fail status back to the PR.

A successful lab CI run produces a test result artifact linked in the Gitea Actions run summary. This link is required when opening a PR to `main`.

### 3. Promoting to Production (main CI)

To promote a validated image to production:

1. Open a PR from `dev` → `main`.
2. In the PR description, **you must reference the Gitea Actions run from dev that produced passing tests**. PRs without this reference will not be reviewed or merged.
3. When the PR is merged into `main`, the same pipeline runs again using the production runner, rebuilding the image and pushing it to the **production registry**.

> **Example PR description format for a `main` PR:**
> ```
> Promotes ops_EE_netops:1.2 to production.
>
> Validated by: <link to passing dev Actions run>
> ```

---

## CI Pipeline Details

Builds are executed directly on the Gitea runner host using Podman. `ansible-builder` is invoked inside a Podman container to produce the final image, tagged with the version read from the `VERSION` file, and pushed to the appropriate registry for that environment. Only the EE/DE directory that changed in the PR is built — unrelated images are not rebuilt.

| Environment | Runner | Registry | Trigger |
|---|---|---|---|
| Lab | Gitea runner (lab) | Lab registry | Merge to `dev` |
| Production | Gitea runner (prod) | Production registry | Merge to `main` |

> *(Update this table with the actual registry hostnames once confirmed.)*

---

## Testing

Images are validated using `podman run` based checks executed against the built image. These tests verify that the final container actually contains what was declared — they do not test Ansible playbook logic or collection behavior, only the image itself.

Tests are run as a series of `podman run --rm` commands and check for:

- **Python packages** — confirms each package in `requirements.txt` is installed and importable (e.g. `podman run --rm <image> pip show <package>`)
- **System binaries** — confirms any tools installed via `bindep.txt` are present and executable (e.g. `podman run --rm <image> which <tool>`)
- **Basic execution** — confirms the image can run Ansible at all (e.g. `podman run --rm <image> ansible --version`)

If any check fails, the CI run fails and the PR cannot be promoted to `main`.

> Each EE/DE directory may include a `tests/` subdirectory containing additional test scripts. If no `tests/` directory is present, only the baseline checks above are run.

---

## Adding a New EE or DE

1. Create a new directory following the naming standard: `<org>_<EE|DE>_<n>/`
2. Add the four standard files:
   - `execution-environment.yml` — image definition consumable by `ansible-builder`
   - `requirements.txt` — Python dependencies required inside the image (all packages must be pinned)
   - `bindep.txt` — system-level package dependencies (all packages must be pinned)
   - `VERSION` — initial version set to `1.0`
3. Open a feature branch and PR to `dev` as described above.
4. Confirm the lab build, registry push, and tests all pass before opening a PR to `main`.

---

## Prerequisites & Local Development

To build an image locally for development and troubleshooting:

```bash
# Build from the EE/DE directory
cd <org>_<EE|DE>_<n>/
VERSION=$(cat VERSION)
ansible-builder build -t <org>_<EE|DE>_<n>:${VERSION} -f execution-environment.yml
```

You can then run the same validation checks locally:

```bash
IMAGE=<org>_<EE|DE>_<n>:${VERSION}

# Confirm Ansible runs
podman run --rm ${IMAGE} ansible --version

# Check a Python package
podman run --rm ${IMAGE} pip show <package>

# Check a system binary
podman run --rm ${IMAGE} which <tool>
```

Podman or Docker must be available on your local machine. The pipeline uses Podman; local builds with Docker may surface minor behavioral differences.

---

## Questions & Ownership

> *(Update this section with team contact info, Gitea project link, and any related AAP documentation.)*
