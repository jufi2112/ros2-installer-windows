# AGENTS.md

## Project Overview

This repository contains code to create an installer application that installs ROS 2 Humble on the executing PC.

## General Guidelines

- Read relevant existing code before making changes.
- Prefer minimal, targeted modifications.
- Follow existing code conventions and architecture.
- Avoid introducing unnecessary dependencies.
- Do not modify unrelated files.
- Explain significant architectural changes before implementing them.

## File Access and Safety

- Restrict file modifications to this repository.
- Ask for explicit permission before modifying files outside the repository.
- Do not modify system configuration or global development settings.
- Do not access or modify credentials unless explicitly authorized.
- Never commit secrets, passwords, or API keys.
- Do not delete files or overwrite user data without authorization.

## Testing

- Run relevant tests after modifying code.
- Use the project's documented test commands.
- Report test failures and their likely causes.
- Do not claim that tests passed unless they were executed successfully.

## Completion

Before finishing a task:

1. Review the changes for unintended modifications.
2. Run the relevant tests when possible.
3. Summarize what changed.
4. Report any tests that could not be executed.
5. Mention any remaining problems or risks.