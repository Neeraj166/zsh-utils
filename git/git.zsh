pr-create() {
  # -----------------------------
  # Parse command-line arguments
  # -----------------------------
  use_dynamic_upstream=false
  while [[ "$1" != "" ]]; do
    case $1 in
      -t ) use_dynamic_upstream=true ;;
      *  ) echo "❌ Unknown option: $1"; return 1 ;;
    esac
    shift
  done

  # -----------------------------
  # Ensure inside a Git repo
  # -----------------------------
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    return 1
  fi

  # -----------------------------
  # Extract origin repo path
  # -----------------------------
  originPath=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
  userName=${originPath%%/*}

  # Determine upstream remote (default to origin if not present)
  if git remote | grep -q '^upstream$'; then
    repo_path=$(git remote get-url upstream | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
    upName="upstream"
  else
    repo_path="$originPath"
    upName="origin"
  fi

  if [[ -z "$repo_path" ]]; then
    echo "❌ Could not determine repository path"
    return 1
  fi

  owner="${repo_path%%/*}"
  repo="${repo_path#*/}"
  upOwner="$owner"

  # -----------------------------
  # Dynamic upstream selection
  # -----------------------------
  if $use_dynamic_upstream; then
    echo "Current repo detected: $owner/$repo"
    echo "Fetching upstream forks..."
    forks=$(gh api repos/"$upOwner"/"$repo"/forks --paginate --jq '.[].full_name')
    forks="$upOwner/$repo"$'\n'"$forks"

    selected_upstream=$(echo "$forks" | fzf \
      --prompt="Select upstream repo for PR (default: $upOwner/$repo): " \
      --height=40% --reverse --border --select-1 --exit-0)

    selected_upstream=${selected_upstream:-"$upOwner/$repo"}
  else
    selected_upstream="$upOwner/$repo"
  fi

  echo "Selected upstream repo: $selected_upstream"

  # -----------------------------
  # Determine remote name / URL
  # -----------------------------
  selected_owner="${selected_upstream%%/*}"
  selected_repo="${selected_upstream#*/}"
  https_url="https://github.com/$selected_upstream.git"

  normalize_url() {
    url="$1"
    url=${url#git@github.com:}
    url=${url#https://github.com/}
    url=${url%.git}
    echo "$url"
  }

  selected_normalized=$(normalize_url "$https_url")
  found_remote_name=""

  while read -r remote_name remote_url _; do
    remote_normalized=$(normalize_url "$remote_url")
    if [[ "$remote_normalized" == "$selected_normalized" ]]; then
      found_remote_name="$remote_name"
      break
    fi
  done < <(git remote -v)

  if [[ -n "$found_remote_name" ]]; then
    echo "Remote already exists as '$found_remote_name'"
    selected_owner="$found_remote_name"
  elif [[ "$selected_owner" != "origin" && "$selected_owner" != "upstream" ]]; then
    echo "Adding remote '$selected_owner' -> $https_url"
    git remote add "$selected_owner" "$https_url"
  else
    echo "Skipping creation of '$selected_owner' (reserved name)"
  fi

  echo "Using remote: $selected_owner"

  # -----------------------------
  # Get current branch
  # -----------------------------
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  head_branch=${current_branch:-main}

  # -----------------------------
  # Fetch branch
  # -----------------------------
  if [[ "$selected_owner" == "upstream" ]]; then
    echo "Fetching all branches from upstream..."
    git fetch upstream &>/dev/null
  elif [[ -n "$head_branch" ]]; then
    echo "Fetching branch '$head_branch' from '$selected_owner'..."
    git fetch "$selected_owner" "$head_branch":"$head_branch" &>/dev/null
  else
    echo "No branch specified. Fetching all from '$selected_owner'..."
    git fetch "$selected_owner" &>/dev/null
  fi

  # -----------------------------
  # List remote branches
  # -----------------------------
  branches=$(git branch -r | grep "$selected_owner/" | sed "s| *$selected_owner/||" | sort -u)

  # -----------------------------
  # Determine default base branch
  # -----------------------------
  if echo "$branches" | grep -qx "$current_branch"; then
    default_selection="$current_branch"
  elif [[ "$current_branch" == stg* ]]; then
    default_selection="staging"
  elif [[ "$current_branch" == dev* ]]; then
    default_selection="development"
  else
    default_selection="main"
  fi

  # -----------------------------
  # Prompt user for base branch
  # -----------------------------
  base_branch=$(echo "$branches" | fzf \
    --prompt="Select $selected_upstream base branch: " \
    --height=40% --reverse --border \
    --preview="git log $selected_owner/{} --oneline -n 5" \
    --query="$default_selection")

  if [[ -z "$base_branch" ]]; then
    echo "❌ No branch selected. Aborting."
    return 1
  fi

  # -----------------------------
  # Push current branch
  # -----------------------------
  echo "Pushing $head_branch to origin..."
  git push origin "$head_branch" || return 1

  # -----------------------------
  # Extract ticket ID for PR body
  # -----------------------------
  if [[ "$head_branch" =~ -([0-9]+)$ ]]; then
    ticket_id="${BASH_REMATCH[1]}"
    pr_body="tid-${ticket_id}"
  else
    pr_body=""
  fi

  # -----------------------------
  # Create PR
  # -----------------------------
  echo "Creating PR: base=$selected_upstream:$base_branch, head=$userName:$head_branch"
  gh pr create \
    --base "${selected_upstream%%/*}:$base_branch" \
    --head "$userName:$head_branch" \
    --body "$pr_body" -w
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

  # Retrieve PR title and base branch
  pr_meta=$(gh pr view "$pr_number" --json title,baseRefName \
    --jq '{title, base: .baseRefName}')

  pr_title=$(echo "$pr_meta" | jq -r .title)
  pr_base=$(echo "$pr_meta" | jq -r .base)

  echo ""
  # Confirm merge
  echo -n "🟢 Merge PR #$pr_number: \"$pr_title\" → base: $pr_base? [y/N]: "
  read should_merge

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
