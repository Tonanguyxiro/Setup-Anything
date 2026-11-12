# Sever-Setup

Guides and scripts for local development, remote workspaces, and shared server administration.

## Architecture

```text
01-Workspace/
├── general/                 # Terminal, development tools, and AI Agents
├── local/                   # VS Code workspace, LaTeX, and Beamer guides
├── homelab/                 # Personal server setup plan
└── remote/                  # SSH forwarding, proxy setup, and remote Codex

02-Remote-Server-Management/
├── disk-usage-tips/         # Data directory login hooks
└── disk-warning/            # Lightweight and detailed disk warnings

setup.sh                     # TUI and direct commands
tui/tui.sh                   # Bash menu primitives
```

## Documentation

- Write repository documentation in English and use `README.md` as the directory entry point.
- Use a brief introduction, an HTML table linking to subtopics, and headings for detailed instructions.
- Treat a subdirectory README as guidance for that directory. Follow the research-specific `AGENTS.md` where present.
- Keep proxy setup steps reproducible. Document which host runs each command and how traffic crosses the SSH tunnel.

## Research Projects

Use `.venv` and `uv`, with dependencies declared in `pyproject.toml`. Run scripts from the project root with `uv run path/to/file.py` or `uv run -m package.module`. Do not modify `sys.path` in `src/`, `test/`, `evaluation/`, or `motivation/`. Leave GPU-dependent commands for the user to run.

- `src/` holds shared library code.
- `evaluation/` holds `baseline/`, `benchmark/`, `eval_*.py` entry points, and `results-*/` directories.
- `motivation/` groups exploratory experiments under `moti_<topic>/`.
- `test/` verifies `src/`.

Paper and presentation projects use `main.tex` and `main.bib`, with styles in `sty/`, figures in `figures/`, plots in `plots/`, and source sections in `src/`. Use `.latexmkrc` and the editor workspace to configure compilation and write build output to `.out/`. See the [research index](./01-Workspace/local/research/README.md) for project-specific instructions.

## Git and Shell Scripts

- The repository is `https://github.com/Tonanguyxiro/Sever-Setup.git`. The main branch is `main`.
- Use concise English commit messages.
- Initialize submodules with `git submodule update --init --recursive`.
- This repository has no project-wide build system or CI. Verify shell changes with syntax and targeted behavior checks.
- Keep shell setup operations idempotent, including any future work on `01-Workspace/remote/00-setup.sh`.
