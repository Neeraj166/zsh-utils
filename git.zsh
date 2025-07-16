pr-create() {
  # Parse args
  use_dynamic_upstream=false
  while [[ "$1" != "" ]]; do
    case $1 in
      -t ) use_dynamic_upstream=true ;;
      * ) echo "❌ Unknown option: $1"; return 1 ;;
    esac
    shift
  done

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    return 1
  fi

  if $use_dynamic_upstream; then
    # Current repo (owner/repo)
    repo_path=$(git remote get-url origin | sed -E 's|.*github\.com[:/](.+)\.git|\1|')
    if [[ -z "$repo_path" ]]; then
      echo "❌ Could not determine repository path from origin remote"
      return 1
    fi

    owner="${repo_path%%/*}"
    repo="${repo_path#*/}"

    echo "Current repo detected: $owner/$repo"

    echo "Fetching list of upstream forks (this may take a moment)..."
    forks=$(gh api repos/shikhartech/$repo/forks --paginate --jq '.[].full_name')

    # Add main upstream repo at the top as default choice
    forks="shikhartech/$repo"$'\n'"$forks"

    selected_upstream=$(echo "$forks" | fzf --prompt="Select upstream repo for PR (default: shikhartech/$repo): " --height=40% --reverse --border --select-1 --exit-0)

    if [[ -z "$selected_upstream" ]]; then
      selected_upstream="shikhartech/$repo"
    fi

  else
    selected_upstream="shikhartech/$repo"
  fi

  echo "Selected upstream repo: $selected_upstream"

  # Set or update upstream remote
  if ! git remote | grep -q '^upstream$'; then
    git remote add upstream "https://github.com/$selected_upstream.git"
  else
    current_upstream_url=$(git remote get-url upstream)
    expected_url="https://github.com/$selected_upstream.git"
    if [[ "$current_upstream_url" != "$expected_url" ]]; then
      git remote set-url upstream "$expected_url"
    fi
  fi

  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  head_branch=${current_branch:-main}

  echo "Fetching branches from $selected_upstream..."
  git fetch upstream &>/dev/null

  branches=$(git branch -r | grep 'upstream/' | sed 's| *upstream/||' | sort -u)

  if echo "$branches" | grep -qx "$current_branch"; then
    default_selection="$current_branch"
  else
    default_selection="main"
  fi

  base_branch=$(echo "$branches" | fzf \
    --prompt="Select upstream base branch: " \
    --height=40% \
    --reverse \
    --border \
    --preview="git log upstream/{} --oneline -n 5" \
    --query="$default_selection")

  if [[ -z "$base_branch" ]]; then
    echo "❌ No branch selected. Aborting."
    return 1
  fi

  echo "Pushing to origin/$head_branch..."
  git push origin "$head_branch" &&

  echo "Creating PR from origin/$head_branch → $selected_upstream:$base_branch"
  gh pr create --base "$selected_upstream:$base_branch" --head "$owner:$head_branch" -w
}


pr-review() {
  # Check required commands
  for cmd in git gh fzf jq; do
    if ! command -v $cmd &>/dev/null; then
      echo "❌ Required command '$cmd' not found. Please install it."
      return 1
    fi
  done

  # Check inside a Git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    return 1
  fi

  echo "Fetching open pull requests..."

  pr_list=$(gh pr list --state open --limit 100 --json number,title,author \
    --template '{{range .}}{{.number}}\t{{.title}} [{{.author.login}}]{{"\n"}}{{end}}')

  if [[ -z "$pr_list" ]]; then
    echo "✅ No open pull requests found."
    return 0
  fi


  selected=$(echo "$pr_list" | \
    fzf --prompt="Select PR to approve: " \
        --header="Enter to approve, Esc to cancel" \
        --height=40% \
        --reverse \
        --border \
        --preview='gh pr view {1} --json commits --jq ".commits[] | \"\(.oid[0:7]) - \(.messageHeadline)\""')

  if [[ -z "$selected" ]]; then
    echo "❌ No PR selected. Aborting."
    return 1
  fi

  pr_number=$(echo "$selected" | cut -f1)

  echo "🔍 Checking if PR #$pr_number is already approved..."

  is_approved=$(gh pr view "$pr_number" --json reviews \
    --jq '.reviews | map(select(.state == "APPROVED")) | length')

  if [[ "$is_approved" -gt 0 ]]; then
    echo "✅ PR #$pr_number is already approved."
  else

      read "? Do you want to approve PR #$pr_number? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
          echo "❌ Aborting."
          echo "✅ PR #$pr_number not approved."
          return 1  # or exit 1 in scripts
        fi

    echo "🔏 Approving PR #$pr_number..."
    if ! gh pr review --approve "$pr_number"; then
      echo "❌ Failed to approve PR."
      return 1
    fi
    echo "✅ PR #$pr_number approved."
  fi

  echo ""
  pr_meta=$(gh pr view "$pr_number" --json title,baseRefName \
    --jq '{title, base: .baseRefName}')

  pr_title=$(echo "$pr_meta" | jq -r .title)
  pr_base=$(echo "$pr_meta" | jq -r .base)

  echo ""
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