# Repository instructions

This repository contains reusable project blueprints for Hermes Agent v0.22.5.

## Working with the catalog

- Keep each blueprint self-contained under `blueprints/<id>/`.
- Update `blueprint.json` when changing metadata, specialist profiles, orchestration, or workflow guidance.
- Keep generated project files in the blueprint's `templates/` directory.
- Use `{{placeholder_name}}` for values supplied by the wizard. Supported placeholders are `idea_name`, `idea_slug`, `idea_description`, `blueprint_name`, and `skill_id`.
- Keep project-local Hermes skills under `.agents/skills/<skill-id>/SKILL.md` and follow Hermes frontmatter conventions.
- Run `ruby test/blueprints_test.rb` after changing generator behavior or templates.

## Generator behavior

- Do not overwrite an existing destination folder.
- Provision the board with Hermes CLI v0.22.5 and target it explicitly for all task commands.
- Seed one requirements-driven triage goal assigned to the blueprint orchestrator; let Hermes decompose it into linked specialist tasks.
- Preserve existing Hermes profile configuration; explain that model setup and gateway dispatch are prerequisites for autonomous execution.
- Do not switch the user's active Hermes board.
- Never remove a board or generated project automatically after a provisioning failure; report the partial result for manual recovery.
