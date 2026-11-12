# AI Agents

Install AI Agent tools and configure user and project rules.

<table>
  <thead>
    <tr>
      <th>Topic</th>
      <th>Link</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Karpathy Skills</td>
      <td><a href="./andrej-karpathy-skills/README.md">Submodule guide</a></td>
    </tr>
  </tbody>
</table>

## Install Agents

<table>
  <thead>
    <tr>
      <th>Agent / Tools</th>
      <th>Install Command</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>CC-Switch-CLI</strong></td>
      <td><code>curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash</code></td>
    </tr>
    <tr>
      <td><strong>Codex</strong></td>
      <td><code>npm i -g @openai/codex</code></td>
    </tr>
    <tr>
      <td><strong>Opencode</strong></td>
      <td><code>curl -fsSL https://opencode.ai/install | bash</code></td>
    </tr>
    <tr>
      <td><strong>Claude Code &amp; CC-Switch</strong></td>
      <td><code>curl -fsSL https://claude.ai/install.sh | bash</code></td>
    </tr>
  </tbody>
</table>

## Configure Agents

### Skills

- [Andrej Karpathy Skills](./andrej-karpathy-skills/README.md)

### `AGENTS.md`

- **User Level** Rules
    - [Andrej Karpathy Skills](https://github.com/forrestchang/andrej-karpathy-skills/tree/main)
        - Use these rules as user-level instructions.
        - Check that the agent loaded the rules by asking `Summarise all rules and instructions level by level`
        - Store the rules in `AGENTS.md`.
- **Project Level** Rules
    - [Agent Style](https://github.com/yzhao062/agent-style)
        - Install with `uv tool install agent-style`.
        - Run `agent-style enable agents-md` in the project or paper directory.