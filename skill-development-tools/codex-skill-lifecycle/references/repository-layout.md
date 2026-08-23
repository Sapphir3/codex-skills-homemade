# Repository And Source Layout

## Separate The Three Locations

Use three different locations when the environment permits:

1. A synchronized local source tree for authoritative editing and cross-device continuity.
2. A device-local Git checkout outside the synchronized tree for commits, pushes, and CI-facing files.
3. An installed skill directory managed by Codex, CCSwitch, or another installer.

Do not synchronize `.git` through OneDrive. Resolve roots from project instructions or user input rather than assuming a drive letter.

## Multi-Skill Repository

A category directory is an ordinary folder, not a nested Git repository:

```text
codex-skills-homemade/
|-- paper-library-skills/
|   |-- example-skill/
|   `-- example-skill.tests/
|-- skill-development-tools/
|   `-- codex-skill-lifecycle/
|-- tools/
|-- release-records/
|-- .github/workflows/
|-- SKILLS_MANIFEST.md
|-- README.md
`-- LICENSE
```

Every production skill directory directly contains one `SKILL.md`. Its directory name and frontmatter `name` must match. Skill names must be unique across categories. Tests and fixtures must not contain discoverable `SKILL.md` files in the committed repository; generate fixture manifests in temporary directories during tests.

## CCSwitch Compatibility Gate

Do not migrate a working production repository to nested categories until the installed CCSwitch build has demonstrated all of the following against a temporary repository or other isolated target:

- recursive discovery of `<category>/<skill>/SKILL.md`;
- correct installation under the skill name rather than the category name;
- preservation of repository owner, name, branch, and application enablement;
- detection and application of a content change on the configured branch;
- zero pending updates after the update.

By default, prepare the GitHub test and hand the CCSwitch actions to the user. Automate the application only under the explicit full-workflow authorization described in `ccswitch.md`.

If recursive discovery fails, leave production unchanged. Prefer top-level skill directories with logical categories recorded in `SKILLS_MANIFEST.md`. Do not use duplicate skill trees or filesystem links as a compatibility workaround.

## Release ZIP Layout

Each ZIP resolves to exactly one skill. The preferred structure is:

```text
example-skill-v1.2.3.zip
`-- example-skill/
    |-- SKILL.md
    `-- <runtime resources>
```

Do not include tests, repository tools, release records, caches, credentials, or unrelated skills. A flat archive is acceptable only when the target installer requires it and validation still finds exactly one root `SKILL.md`.
