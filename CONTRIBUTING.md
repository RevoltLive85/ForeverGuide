# Contributing to ForeverGuide

ForeverGuide targets the **WoW Forever beta**, not stock Classic or Retail. Check
[README.md](README.md) for installation, commands, and known beta limitations.

## Report a bug

Open a GitHub issue with:

- Client build (`/dump GetBuildInfo()`) and addon version (`ForeverGuide.toc`).
- What you did, what happened, and what you expected. For guide errors, include faction,
  race, level, guide name, step number, quest ID, and map/coordinates (`/fg pos`).
- The Lua error text (enable errors with `/console scriptErrors 1`, then `/reload`), if any.
- Whether it reproduces after `/reload`, on a fresh login, or only during combat.

Please remove character/account names and other private details from logs before posting.
A `/fg wrong <description>` report is saved locally; it does not open a GitHub issue.

## Propose a change

1. Branch from `main` and keep each pull request focused on one fix or guide correction.
2. Edit `guides-src/*.json`, **not** generated `Guides/*.lua` or `Guides/Guides.xml`.
   The step format is in [guides-src/SCHEMA.md](guides-src/SCHEMA.md).
3. From the addon root, run the relevant checks:

   ```sh
   python3 tools/compile_guides.py           # after guide edits; commit generated outputs
   python3 tools/compile_guides.py --check   # validate without writing
   lua5.1 tools/test/run_tests.lua           # headless engine checks
   ```

4. Test the change in the Forever beta: log in, try the affected step or UI action,
   `/reload`, and test combat if the change touches UI or protected actions. Include
   the client build, test steps, and results in the PR.

For database changes, read [Data/README.md](Data/README.md) before adding third-party
material; attribution alone does not establish permission to redistribute it. Do not
commit raw `WTF/` SavedVariables or player logs. The repo's
[README.md](README.md#writing-a-guide) explains how to write a guide, and its
[layout section](README.md#layout) maps the engine and generation tools.
