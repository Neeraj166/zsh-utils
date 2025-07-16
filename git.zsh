pr-create() {
  # Parse command-line arguments
  use_dynamic_upstream=false
  while [[ "$1" != "" ]]; do
    case $1 in
      -t ) use_dynamic_upstream=true ;;  # Enable dynamic upstream selection via -t
      * ) echo "❌ Unknown option: $1"; return 1 ;;  # Handle unknown flags
    esac
    shift
  done

  # Ensure inside a Git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    return 1
  fi

  # Extract GitHub repo path (user/repo) from origin remote
  originPath=$(git remote get-url origin | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
  userName=${originPath%%/*}

  # Determine upstream remote or fall back to origin
  if git remote | grep -q '^upstream$'; then
    repo_path=$(git remote get-url upstream | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
    upName="upstream"
  else
    repo_path="$originPath"
    upName="origin"
  fi

  # Check that repo path was successfully determined
  if [[ -z "$repo_path" ]]; then
    echo "❌ Could not determine repository path"
    return 1
  fi

  # Parse owner and repo from path
  owner="${repo_path%%/*}"
  repo="${repo_path#*/}"
  upOwner="$owner"

  # If -t is passed, dynamically fetch and choose upstream fork
  if $use_dynamic_upstream; then
    echo "Current repo detected: $owner/$repo"
    echo "Fetching list of upstream forks (this may take a moment)..."

    forks=$(gh api repos/"$upOwner"/"$repo"/forks --paginate --jq '.[].full_name')
    forks="$upOwner/$repo"$'\n'"$forks"  # Add upstream as default option

    # Prompt user to choose an upstream repo
    selected_upstream=$(echo "$forks" | fzf --prompt="Select upstream repo for PR (default: $upOwner/$repo): " --height=40% --reverse --border --select-1 --exit-0)

    # Default to original upstream if none selected
    if [[ -z "$selected_upstream" ]]; then
      selected_upstream="$upOwner/$repo"
    fi
  else
    selected_upstream="$upOwner/$repo"
  fi

  echo "Selected upstream repo: $selected_upstream"

  # Add upstream remote if it doesn't already exist
  if ! git remote | grep -q "^$upName$"; then
    git remote add "$upName" "https://github.com/$selected_upstream.git"
  fi

  # Get the current branch name, default to 'main' if not found
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  head_branch=${current_branch:-main}

  echo "Fetching branches from $selected_upstream..."

  # Fetch branches from upstream or selected remote
  if [[ "$upName" == "upstream" ]]; then
    git fetch upstream &>/dev/null
  else
    git fetch "$upName" "$head_branch" &>/dev/null
  fi

  # List available remote branches from upstream
  branches=$(git branch -r | grep "$upName/" | sed "s| *$upName/||" | sort -u)

  # Suggest current branch or fallback to 'main' as default
  if echo "$branches" | grep -qx "$current_branch"; then
    default_selection="$current_branch"
  else
    default_selection="main"
  fi

  # Prompt user to choose a base branch from upstream
  base_branch=$(echo "$branches" | fzf \
    --prompt="Select $upName base branch: " \
    --height=40% \
    --reverse \
    --border \
    --preview="git log $upName/{} --oneline -n 5" \
    --query="$default_selection")

  # Abort if no base branch selected
  if [[ -z "$base_branch" ]]; then
    echo "❌ No branch selected. Aborting."
    return 1
  fi

  # Push current branch to origin before PR
  echo "Pushing to origin/$head_branch..."
  git push origin "$head_branch" || return 1

  # Create PR targeting base branch of selected upstream repo
  echo "Creating PR from ${selected_upstream%%/*}:$base_branch --head $userName:$head_branch"
  gh pr create --base "${selected_upstream%%/*}:$base_branch" --head "$userName:$head_branch" -w
}

pr-review() {
  # Check required CLI tools
  for cmd in git gh fzf jq; do
    if ! command -v $cmd &>/dev/null; then
      echo "❌ Required command '$cmd' not found. Please install it."
      return 1
    fi
  done

  # Confirm inside a Git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    return 1
  fi

  echo "Fetching open pull requests..."

  # List open PRs with number, title, and author
  pr_list=$(gh pr list --state open --limit 100 --json number,title,author \
    --template '{{range .}}{{.number}}\t{{.title}} [{{.author.login}}]{{"\n"}}{{end}}')

  # Exit early if no PRs found
  if [[ -z "$pr_list" ]]; then
    echo "✅ No open pull requests found."
    return 0
  fi

  # Prompt user to select a PR to review
  selected=$(echo "$pr_list" | \
    fzf --prompt="Select PR to approve: " \
        --header="Enter to approve, Esc to cancel" \
        --height=40% \
        --reverse \
        --border \
        --preview='gh pr view {1} --json commits --jq ".commits[] | \"\(.oid[0:7]) - \(.messageHeadline)\""')

  # Exit if no PR selected
  if [[ -z "$selected" ]]; then
    echo "❌ No PR selected. Aborting."
    return 1
  fi

  # Extract PR number from selection
  pr_number=$(echo "$selected" | cut -f1)

  echo "🔍 Checking if PR #$pr_number is already approved..."

  # Check if the PR already has an approval
  is_approved=$(gh pr view "$pr_number" --json reviews \
    --jq '.reviews | map(select(.state == "APPROVED")) | length')

  if [[ "$is_approved" -gt 0 ]]; then
    echo "✅ PR #$pr_number is already approved."
  else
    # Ask user for approval confirmation
    read "? Do you want to approve PR #$pr_number? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
      echo "❌ Aborting."
      echo "✅ PR #$pr_number not approved."
      return 1
    fi

    # Approve the PR
    echo "🔏 Approving PR #$pr_number..."
    if ! gh pr review --approve "$pr_number"; then
      echo "❌ Failed to approve PR."
      return 1
    fi
    echo "✅ PR #$pr_number approved."
  fi

  echo ""
  # Retrieve PR title and base branch
  pr_meta=$(gh pr view "$pr_number" --json title,baseRefName \
    --jq '{title, base: .baseRefName}')

  pr_title=$(echo "$pr_meta" | jq -r .title)
  pr_base=$(echo "$pr_meta" | jq -r .base)

  echo ""
  # Confirm merge
  read -r -p "🟢 Merge PR #$pr_number: \"$pr_title\" → base: $pr_base? [y/N]: " should_merge

  if [[ "$should_merge" =~ ^[Yy]$ ]]; then
    echo "🔃 Merging PR #$pr_number..."
    if gh pr merge "$pr_number" --merge; then
      echo "✅ PR #$pr_number merged successfully."
    else
      echo "❌ Merge failed."
    fi
  else
    echo "ℹ️ Skipping merge."
  fi
}
