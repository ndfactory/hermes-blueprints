---
name: {{skill_id}}
description: Plan, implement, and verify focused software changes for {{idea_name}}.
version: 1.0.0
metadata:
  hermes:
    tags: [software-development, implementation, verification]
    category: development
---

# Software development for {{idea_name}}

## When to Use

Use this skill when planning or implementing software for: {{idea_description}}

## Procedure

1. Read `AGENTS.md`, `README.md`, `project-plan.md`, and `idea-brief.md`; inspect relevant code before choosing an approach.
2. Clarify expected behavior and acceptance criteria. Check current official documentation when using framework or library APIs.
3. Make the smallest coherent change that meets the criteria and follows established project conventions.
4. Verify changed behavior with relevant checks, including important error paths and edge cases.
5. Review the diff, update relevant documentation, and summarize changes and verification.
6. For Kanban work, keep durable context in the project folder and report changed files, verification evidence, risks, blockers, and the next handoff to the planner.

## Pitfalls

- Do not invent repository structure, commands, or API behavior; inspect the project or consult official documentation.
- Avoid unrelated refactors and unnecessary dependencies.
- Do not claim checks passed unless they were run successfully.

## Verification

- Acceptance criteria are addressed by the implementation.
- Relevant checks pass, or remaining failures and limitations are stated clearly.
- The final diff contains only intended changes and required documentation updates.
