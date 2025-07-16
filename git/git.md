
# **GitHub PR Tools**

This repository provides two helpful Git shell functions to simplify pull request workflows using the GitHub CLI:

* `pr-create` — Create a pull request to an upstream repository with optional dynamic fork selection.

* `pr-review` — Review, approve, and optionally merge a pull request interactively.
sdf


## **📦 Prerequisites**

Ensure the following tools are installed:

* [`git`](https://git-scm.com/)

* [`gh`](https://cli.github.com/) (GitHub CLI)

* [`fzf`](https://github.com/junegunn/fzf) (fuzzy finder)

* `jq` (JSON parser)

---

## **⚠️ Remote Naming Convention**

These tools expect your Git remotes to follow standard naming:

| Remote Name | Purpose |
| ----- | ----- |
| `origin` | Your personal fork of the repository |
| `upstream` | The main repository (where the PR will be sent) |

If `upstream` is not set, the script will fall back to `origin` as the upstream target.

To check or set your remotes:

bash  
CopyEdit  
`git remote -v`

`# To add upstream (if missing)`  
`git remote add upstream https://github.com/OWNER/REPO.git`

---

## **🔧 Setup**

To use these functions in your terminal, source the script in your `.bashrc`, `.zshrc`, or custom shell config:

bash  
CopyEdit  
`source /path/to/pr-tools.sh`

Then reload your shell:

bash  
CopyEdit  
`source ~/.zshrc  # or ~/.bashrc`

---

## **✨ Function: `pr-create`**

Creates a GitHub pull request from your fork (`origin`) to the upstream repository (`upstream`).

### **🔹 Usage**

bash  
CopyEdit  
`pr-create [-t]`

### **🔸 Options**

| Flag | Description |
| ----- | ----- |
| `-t` | Enables dynamic upstream selection using GitHub's fork list (via `gh api`) |

### **🧠 How It Works**

1. Verifies that you are in a Git repository.

2. Determines the upstream repository (`upstream` remote or falls back to `origin`).

3. If `-t` is passed, fetches the list of forks and lets you select the upstream repo via `fzf`.

4. Prompts you to select the base branch of the upstream to target.

5. Pushes the current branch to your `origin`.

6. Creates a draft pull request using the GitHub CLI (`gh pr create`).

### **📌 Example**

bash  
CopyEdit  
`pr-create -t`

This will allow dynamic upstream selection before creating the PR.

---

## **✨ Function: `pr-review`**

Interactively reviews, approves, and optionally merges an open pull request.

### **🔹 Usage**

bash  
CopyEdit  
`pr-review`

### **🧠 How It Works**

1. Verifies you're in a Git repository and required tools are installed.

2. Fetches a list of open pull requests.

3. Presents the list via `fzf`, with previews of recent commits.

4. Approves the selected PR if not already approved.

5. Prompts for confirmation before merging.

### **📌 Example**

bash  
CopyEdit  
`pr-review`

Select a PR, review its commits, approve it (if needed), and optionally merge it.

---

## **🧪 Tested Environments**

* macOS 13+

* Ubuntu 22.04

* GitHub CLI version `2.x`

* Shells: `zsh`, `bash`

---

## **🛠 Troubleshooting**

* **`❌ Required command '...' not found`** — Make sure all dependencies are installed and available in your `$PATH`.

* **`❌ No branch selected`** — You exited `fzf` without picking a branch. Try again.

* **`gh: command not found`** — Install the GitHub CLI and authenticate with `gh auth login`.

---

## **🧑‍💻 Contributions**

Feel free to submit improvements or enhancements via PR. These tools are meant to streamline common PR workflows, especially in collaborative fork-based repositories.

