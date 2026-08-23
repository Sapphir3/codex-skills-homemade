# CCSwitch Installation And Update

## Authorization Rule

Default to manual CCSwitch operation. Automated application control is allowed only when the user explicitly states at the start of the task that the entire workflow, including CCSwitch installation and update verification, should be completed autonomously.

Ordinary requests such as “create,” “update,” “publish,” or “release this skill” do not provide that authorization. A later GitHub success does not expand it.

## Manual Handoff

After a successful GitHub release, stop and report:

- skill name and semantic version;
- full GitHub repository URL and branch;
- category path and repository-relative skill path;
- commit, tag, and Release URL;
- ZIP name and SHA-256;
- local and CI validation result;
- action: add repository and install, or check updates;
- expected observable content for an update test.

Use the full repository URL because tested CCSwitch builds may reject `owner/name` shorthand.

Explain that a ZIP installation has a `local:` source and cannot receive repository updates. For first repository adoption, the user may need to remove the local-source installation once and reinstall from the repository listing. Ask the user to report success or the exact error; update records only after that report.

## Autonomous Verification

When explicitly authorized, record the pre-update repository fields, content hash, timestamp, and application enablement. Perform only the scoped installation or update, then require:

- the expected skill and only that skill is offered for update;
- repository owner, name, branch, and application enablement are preserved;
- content hash changes and timestamp advances;
- installed files match the authoritative source;
- the observable patch content is present;
- the interface returns to zero pending updates.

Never edit the CCSwitch database to simulate repository installation or success. Pause for unavailable UI, human verification, login, ambiguous destructive removal, or inconsistent application state.
