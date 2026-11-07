# Hermes Agent Blueprints

A small, dependency-free Ruby catalog for starting ideas with reusable project files, Hermes project instructions, project-local skills, and a dedicated Kanban board that can autonomously route work to specialist profiles.

The initial catalog includes:

- **Research** — planner, researcher, writer, and reviewer profiles.
- **Software Development** — planner, developer, tester, and reviewer profiles.

## Requirements

- Ruby 3.1 or newer
- Hermes Agent **v0.22.5** available as `hermes`

The generator does not require third-party Ruby gems. It uses Hermes's Kanban CLI to create a board and a requirements-driven triage goal. It does not switch the active board. Hermes decomposes the goal and routes child tasks based on specialist profile descriptions when its gateway dispatcher is running.

## Create a project

Run the wizard and answer its prompts:

```sh
./bin/hermes-blueprint new
```

Before first use, create the starter profiles for the selected blueprint and configure each profile's model and credentials:

```sh
./bin/hermes-blueprint setup-profiles --blueprint software-development
hermes -p hbplanner setup
hermes -p hbdeveloper setup
hermes -p hbtester setup
hermes -p hbcodereviewer setup
```

For the research blueprint, configure `hbplanner`, `hbresearcher`, `hbwriter`, and `hbresearchreviewer` instead. `setup-profiles` prints the setup command for every profile it creates.

Profile names live in your Hermes configuration and are shared globally. The starter blueprints use distinct specialist names to keep their role descriptions separate; the general `hbplanner` profile can be shared. Existing profiles are preserved. Run setup once for each new profile, then start the gateway dispatcher in a persistent process:

```sh
hermes gateway start
```

Or supply all values directly:

```sh
./bin/hermes-blueprint new \
  --blueprint research \
  --name "Battery materials review" \
  --description "Compare recent evidence on sodium-ion battery materials." \
  --requirements-file ./battery-review-plan.md \
  --output "$HOME/projects/battery-materials-review"
```

The output path must not already exist. Enter the full project plan and requirements through `--requirements-file`, or paste them at the interactive prompt and finish with a line containing only `.`. The wizard creates `README.md`, `AGENTS.md`, `idea-brief.md`, `project-plan.md`, and a project-local Hermes skill under `.agents/skills/`. It creates a non-active board with a single triage goal assigned to the planner profile. The goal contains your full requirements, workspace path, role roster, workflow guidance, and review expectations. Hermes decomposes that goal into linked tasks routed to specialists when the gateway dispatcher is running.

All profiles in the selected blueprint must already exist. If they are missing, the wizard stops before creating the board and tells you how to create and configure them. `setup-profiles` creates missing role profiles, preserves existing ones, and enables Kanban tools for the planner; model credentials are configured separately with `hermes -p PROFILE setup`. Hermes also needs a usable auxiliary model for `auxiliary.kanban_decomposer`; check this setting if the triage goal remains in triage.

If task provisioning fails after the board is created, the wizard leaves the generated files and board in place and prints recovery details. It never deletes user data automatically.

## Manage blueprints

```sh
./bin/hermes-blueprint list
./bin/hermes-blueprint validate
./bin/hermes-blueprint --help
```

Each blueprint lives under `blueprints/<id>/` and contains:

```text
blueprints/<id>/
├── blueprint.json       # ID, display name, skill ID, roles, planner, and workflow guidance
└── templates/           # Files copied into each generated project
```

Use `{{idea_name}}`, `{{idea_slug}}`, `{{idea_description}}`, `{{blueprint_name}}`, and `{{skill_id}}` in template files. Add a new blueprint by creating a directory, adding a valid `blueprint.json`, and placing its starter files in `templates/`. Each blueprint must provide `README.md`, `AGENTS.md`, and `.agents/skills/<skill_id>/SKILL.md`. The validator checks the catalog before generation.

## Blueprint authoring guide

This section explains how to change the catalog itself. There are two different things you might edit:

- A **blueprint** is the reusable source under `blueprints/`. Changing it affects projects generated in the future.
- A **generated project** is a copy made by `hermes-blueprint new`. It is independent of the source blueprint. Editing a source blueprint does not update projects or Kanban boards that were already created.

If you meant to customize one idea that has already been generated, edit that idea's own `README.md`, `AGENTS.md`, brief, skill, files, and Hermes Kanban board. Do not edit the catalog just to make a one-off project change.

### Blueprint files and what they control

Each blueprint follows this layout:

```text
blueprints/<blueprint-id>/
├── blueprint.json
└── templates/
    ├── README.md
    ├── AGENTS.md
    ├── idea-brief.md
    └── .agents/
        └── skills/
            └── {{skill_id}}/
                └── SKILL.md
```

| File | What it controls | Typical edits |
| --- | --- | --- |
| `blueprint.json` | Wizard listing and autonomous Kanban handoff | Name, description, skill ID, roles, planner, workflow guidance |
| `templates/README.md` | Generated project's landing page | Getting started steps, output locations, project-specific conventions |
| `templates/AGENTS.md` | Instructions supplied to coding agents in the generated project | Guardrails, evidence standards, review steps, documentation expectations |
| `templates/idea-brief.md` | The initial project planning document | Questions and sections that help scope this kind of idea |
| `templates/.agents/skills/{{skill_id}}/SKILL.md` | Hermes's project-local skill for this idea | Activation conditions, procedure, pitfalls, and completion checks |
| Other files under `templates/` | Any additional generated files or folders | Checklists, examples, source logs, design notes, starter code, etc. |

Files inside `templates/` are copied into the new project. Their relative paths are preserved, after supported placeholders in the path are substituted. Keep the `{{skill_id}}` directory spelling in the catalog; the wizard replaces it using the `skill_id` value in the manifest.

### Edit an existing blueprint

1. Choose its folder, for example `blueprints/research/` or `blueprints/software-development/`.
2. Edit `blueprint.json` if you want to change the wizard label, description, skill name, profile roster, planner, or workflow guidance.
3. Edit or add files under that blueprint's `templates/` if you want to change what a newly generated project contains.
4. Run the validator and test suite before committing:

   ```sh
   ./bin/hermes-blueprint validate
   ruby test/blueprints_test.rb
   ```

5. Review the diff and, if Hermes v0.22.5 is installed, optionally generate a disposable project to inspect the rendered result and seeded board.

The generator reads the blueprint from disk each time it runs; no build or installation step is needed. Existing generated projects and boards are snapshots, so changes take effect on the next generation only.

### Add or remove generated project files

To add a generated file, create it under the relevant `templates/` directory. For example, add `templates/research-plan.md` to generate `research-plan.md` at the root of each project created from that blueprint. To place it in a subfolder, add the file there, such as `templates/research/sources.md`.

To remove a file from future projects, delete the corresponding template file. This does not remove it from previously generated projects. Avoid creating files named with path separators in placeholder values; the built-in `skill_id` is the only placeholder normally needed in a path.

Required files for every blueprint:

- `templates/README.md`
- `templates/AGENTS.md`
- `templates/.agents/skills/{{skill_id}}/SKILL.md`

You can add any number of other files. Empty folders are not generated unless they contain a file, so include a small `.gitkeep` or README if an empty directory is important.

### Edit roles and autonomous handoffs

Open `blueprint.json`. Its `profiles` array lists Hermes profiles that can receive routed work. Each profile has a lowercase alphanumeric `id` and a detailed `description` used by Hermes to choose an agent. `orchestrator_profile` identifies the profile assigned the root triage goal and must match one of those IDs. Example:

```json
{
  "id": "research",
  "name": "Research",
  "description": "Turn an open question into a sourced, reviewed research brief.",
  "skill_id": "research-project",
  "orchestrator_profile": "hbplanner",
  "profiles": [
    { "id": "hbplanner", "description": "Decomposes project goals, delegates to specialists, integrates results, and reports completion." },
    { "id": "hbresearcher", "description": "Finds authoritative sources, evaluates evidence, records citations, and identifies gaps." }
  ],
  "workflow_guidance": [
    "Clarify scope and acceptance criteria before broad research.",
    "Gather and evaluate primary sources; preserve citations and dates.",
    "Synthesize findings and obtain an independent quality review."
  ]
}
```

Use distinct, concrete descriptions that state each role's capabilities, evidence expectations, and deliverables. Profile names are global to your Hermes installation, not namespaced by blueprint. If you add a new role, make sure it is configured in Hermes; existing profiles keep their settings and are never overwritten by this tool.

`workflow_guidance` is a JSON array of workflow phases and quality gates included in the planner's root goal. It is guidance for decomposition, not a static list of tasks. The planner should create concrete tasks based on the actual requirements, establish dependencies, assign specialists, include independent review, and report blockers rather than guessing.

To change the workflow:

- **Add a phase or gate:** add a string to `workflow_guidance`, such as threat modeling before implementation or an independent review before release.
- **Change who handles work:** update or add a profile description that makes its role distinct.
- **Change the goal owner:** set `orchestrator_profile` to one of the listed roles.
- **Improve handoffs:** state where outputs belong, what counts as verifiable completion, and what blockers must be escalated.

Hermes v0.22.5's dispatcher automatically decomposes triage tasks and routes child tasks using available profile descriptions. Keep `kanban.auto_decompose` enabled (true by default), configure a usable `auxiliary.kanban_decomposer` model, and run `hermes gateway start` for dispatch. The root task uses the generated project folder as its workspace; decomposed children inherit its workspace kind and path. Workers should read the generated `AGENTS.md` and skill before acting. The resulting board task graph is not synchronized back to this blueprint catalog.

### Edit the Hermes skill

Edit `templates/.agents/skills/{{skill_id}}/SKILL.md` to change the instructions Hermes uses when it is started from a generated project checkout. Follow the Hermes skill format: YAML frontmatter followed by a Markdown body. A useful structure is:

```markdown
---
name: {{skill_id}}
description: A short explanation of when this skill helps.
version: 1.0.0
metadata:
  hermes:
    tags: [topic, workflow]
    category: research
---

# Skill title

## When to Use
Describe the tasks that should activate this skill.

## Procedure
Give clear, ordered steps for the agent to follow.

## Pitfalls
Describe common mistakes and how to avoid them.

## Verification
Explain what evidence shows the work is complete and sound.
```

Use `{{skill_id}}` in the frontmatter name so the generated skill name matches the manifest. Keep `{{idea_name}}`, `{{idea_description}}`, and other supported placeholders where project-specific context belongs. Hermes recognizes skills in the generated project's `.agents/skills/` directory when launched inside that Git checkout. The catalog validator checks that the file starts with frontmatter and includes a `## Procedure` section; it does not fully parse or validate the skill's YAML, so keep the frontmatter valid yourself.

### Supported placeholders

Placeholders work in template file contents and file paths. Their values are:

| Placeholder | Value |
| --- | --- |
| `{{idea_name}}` | Name entered in the wizard |
| `{{idea_slug}}` | Name converted to lowercase ASCII letters/numbers separated by hyphens; punctuation and spaces become hyphens and leading/trailing hyphens are removed |
| `{{idea_description}}` | Description entered in the wizard; if blank, the idea name is used |
| `{{blueprint_name}}` | `name` from `blueprint.json` |
| `{{skill_id}}` | `skill_id` from `blueprint.json` |

Use the placeholder spelling exactly. Unknown placeholders and unresolved `{{...}}` expressions in file contents cause validation to fail; placeholders in file paths are checked when a project is generated. The idea name is converted to a slug for the Kanban board. If the slug is already in use, board creation stops with an error; rerun the wizard with an idea name that produces a different slug.

### Add a new blueprint

The easiest way to create a related blueprint is to copy an existing one and then customize it. For example:

```sh
cp -R blueprints/research blueprints/product-planning
```

Then make these edits:

1. In `blueprints/product-planning/blueprint.json`, set:
   - `id` to a unique lowercase slug such as `product-planning`.
   - `name` to the label shown in the wizard, such as `Product Planning`.
   - `description` to a short explanation of the blueprint's intended outcome.
   - `skill_id` to a unique lowercase slug such as `product-planning-project`.
   - `orchestrator_profile` to one of the profile IDs.
   - `profiles` to detailed specialist roles that Hermes should route work to.
   - `workflow_guidance` to the phases, quality gates, and completion evidence for this workflow.
2. Edit every copied template so its README, AGENTS instructions, idea brief, and skill match the new blueprint rather than Research.
3. Keep the skill template path as `templates/.agents/skills/{{skill_id}}/SKILL.md`. The wizard renders the directory name from the new manifest's `skill_id`.
4. Add or remove template files to match what a user starting this kind of idea needs.
5. Validate and test:

   ```sh
   ./bin/hermes-blueprint validate
   ./bin/hermes-blueprint list
   ruby test/blueprints_test.rb
   ```

6. Review the copied files with `git diff` and commit the new blueprint when it is ready.

The validator requires a unique blueprint `id`, non-empty `name`, `description`, and `skill_id`, unique valid role IDs, an orchestrator included in the role list, non-empty workflow guidance, and the three required generated files. It also renders all template placeholders during validation to catch typos.

### Editing a project that was already generated

Once a project has been generated, it is a standalone copy. To customize just that idea:

1. Edit the generated project's `README.md`, `AGENTS.md`, `project-plan.md`, `idea-brief.md`, and `.agents/skills/<skill-id>/SKILL.md` as needed.
2. Add or edit files in that project directly.
3. Edit its Hermes Kanban board directly with the Hermes CLI. The catalog does not sync task changes back from a board.
4. Keep its Git history in that project's repository or your chosen workspace; the wizard itself does not initialize Git.

To make the same changes apply to future projects, make the corresponding change in the source blueprint under `blueprints/` as well. Changes to a generated project do not flow back into the catalog automatically.

## Hermes conventions

Generated skills use Hermes's project skill discovery location and `SKILL.md` format. Blueprint workflow guidance stays in this repository; Hermes Agent v0.22.5 performs runtime task decomposition and profile routing from the triage goal and role descriptions.

- [Hermes skills](https://github.com/nousresearch/hermes-agent/blob/v0.22.5/website/docs/user-guide/features/skills.md)
- [Hermes Kanban](https://github.com/nousresearch/hermes-agent/blob/v0.22.5/website/docs/user-guide/features/kanban.md)

## Development

Run the test suite:

```sh
ruby test/blueprints_test.rb
```

The integration-style tests use a fake Hermes executable, so they do not create real boards.
