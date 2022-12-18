#------------------------------------------------------------------------------
# Publish Logic
#------------------------------------------------------------------------------
publish:run() (
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    publish-gha:run "$@"
    return
  fi

  publish:setup
  publish:setup-gha

  db:index-has-package "$index" "$package_id" ||
    error \
      "Can't publish '$package_id'." \
      "Not yet registered. Please specify --register."

  publish:check

  $option_check && return

  publish:post-log-comment

  publish:trigger
)

publish:setup-gha() {
  index_api_url=$(publish:get-index-api-url)
  local num
  num=$(ini:get --file="$index_file_path" plugin.publish.issue-id) ||
    error "No index entry 'plugin.publish.issue-id'"
  comment_ghapi_url=$index_api_url/issues/$num/comments
  dispatch_ghapi_url=$index_api_url/dispatches

  local user
  user=$(ini:get user.github) ||
    error "No entry for 'user.github' in $root/config"
  token=$(ini:get "publish.github:$user.token") ||
    error "No entry for 'publish.github:$user.token' in $root/config"
  if [[ $token != *????????????????????* ]]; then
    error "Missing or invalid host.github.token in $root/config"
  fi

  publish_html_package_url=https://github.com/$owner/$name/tree/$version
}

publish:post-log-comment() {
  local changes
  changes=$(
    read -r b a <<<"$(
      git config -f Changes --get-regexp '^version.*date' |
        head -n2 |
        cut -d. -f2-4 |
        xargs
    )"
    git log --pretty --format='%s' "$a".."$b"^ |
      xargs -I{} echo '  * {}'
  )

  publish_actions_url=$(publish:get-index-remote-url)/actions

  local body="\
<details><summary>
<h4><a href=\"$publish_actions_url\">Requesting</a>
$APP Package Publish for
<a href=\"$publish_html_package_url\">$package $version</a>
</h4>
</summary>

* **Package**: $package
* **Version**: $version
* **Commit**:  $commit
* **Changes**:
$changes

</details>

**$APP index updater triggered…**
"
  body=${body//$'"'/\\'"'}
  body=${body//$'\n'/\\n}

  comment_body=$body

  local data="{\"body\": \"$body\"}"

  local json
  json=$(publish:ghapi-post "$comment_ghapi_url" "$data")
  comment_api_url=$(jq -r .url <<<"$json")
  [[ $comment_api_url != null ]] ||
    error "GitHub API call failed: '$comment_ghapi_url'"
  comment_html_url=$(jq -r .html_url <<<"$json")
  comment_reactions_url=$(jq -r .reactions.url <<<"$json")

  say -g "Publish for '$package' version '$version' requested"
  echo
  say -y "  $comment_html_url"
}

publish:trigger() (
  bpan_branch=$(
    cd "$root" || exit
    +git:branch-name
  )

  request=$(cat <<...
{
  "event_type": "bpan-publish",
  "client_payload": {
    "package": "$package",
    "version": "$version",
    "commit": "$commit",
    "app-branch": "$bpan_branch",
    "comment-url": "$comment_api_url",
    "comment-body": "$comment_body",
    "reactions-url": "$comment_reactions_url",
    "debug": true
  }
}
...
  )

  publish:ghapi-post "$dispatch_ghapi_url" "$request"
)

publish:ghapi-post() (
  url=$1
  data=$2

  publish:api-status-ok

  $option_verbose && set -x
  curl \
    --silent \
    --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $token" \
    --data "$data" \
    "$url" || true
)

publish:api-status-ok() (
  if +sys:is-cmd jq; then
    api_status=$(
      curl -s https://www.githubstatus.com/api/v2/summary.json |
        jq -r '.components | .[] | select(.name == "Actions") | .status'
    )

    if [[ $api_status != operational ]]; then
      error "\
  Can't publish. GitHub Actions is not operational.
  status='$api_status'.
  See: https://www.githubstatus.com/"
    fi
  fi
)

publish:get-index-remote-url() (
  url=$(git -C "$index_file_dir" config remote.origin.url) ||
    error "Can't determine index url"
  echo "${url%.git}"
)

publish:get-index-api-url() (
  url=$(publish:get-index-remote-url)
  echo "${url/github.com/api.github.com/repos}"
)


#------------------------------------------------------------------------------
# GHA-side publish logic
#------------------------------------------------------------------------------

publish-gha:run() (
  ok=false

  +trap publish-gha:post-status

  publish-gha:setup

  publish-gha:check

  publish:update-index Publish

  git -C "$index_file_dir" push

  ok=true
)

publish-gha:setup() {
  config_file=.$app/config

  index_file_dir=/github/workspace
  index_file_path=/github/workspace/$index_file_name

  package_id=$gha_request_package
  package_version=$gha_request_version
  package_commit=$gha_request_commit
  comment_body=$(
    grep -v '^\*\*'"$APP"' index updater.*\*\*' \
      <<<"$gha_event_comment_body"
  )
  package_title=$(
    git config --file="$config_file" \
      package.title
  )
  package_license=$(
    git config --file="$config_file" \
      package.license
  )
  package_summary=$(
    git config --file="$config_file" \
      package.summary || true
  )
  package_type=$(
    git config --file="$config_file" \
      package.type
  )
  package_tag=$(
    git config --file="$config_file" \
      package.tag || true
  )

  job_url=$(
    curl \
      --silent \
      --request GET \
      --header "Authorization: token $gha_token" \
      --header "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$gha_repository/actions/runs/$gha_run_id/jobs" |
    jq -r '.jobs[0].html_url'
  )
}

publish-gha:check() {
  [[ -f $config_file ]] ||
    die "Package '$package_id' has no '$config_file' file"

  : "Check new version is greater than indexed one"
  publish:check-version-bump "$package_version"

  package_author=$(publish:get-package-author)
  # [[ $author_user == "$gha_triggering_actor" ]] ||
  #   die "Request from '$gha_triggering_actor' should be from '$author_user'"

  : "Check that request commit matches actual version commit"
  actual_commit=$(git rev-parse "$package_version") || true
  [[ $actual_commit == "$package_commit" ]] ||
    die "'$package_commit' is not the actual commit "\
''''''''"for '$package_id' tag '$package_version'"

  : "Run the package's test suite"
  (
    unset BPAN_DEBUG BPAN_DEBUG_BASH BPAN_DEBUG_BASH_X
    prove -v test
  ) || die "$package_id v$package_version failed tests"
}

# Add the GHA job url to the request comment:
publish-gha:update-comment-body() (
  $option_debug &&
    echo "+ publish-gha:update-comment-body ..."

  content=$1
  content=${content//\"/\\\"}
  content=${content//$'\n'/\\n}

  # Get index auth header made by action checkout@v3
  auth_header=$(
    git -C .. config http.https://github.com/.extraheader
  )

  curl \
    --silent \
    --show-error \
    --request PATCH \
    --header "Accept: application/vnd.github+json" \
    --header "$auth_header" \
    "$gha_event_comment_url" \
    --data "{\"body\":\"$content\"}"
)

# React thumbs-up or thumbs-down on request comment:
publish-gha:post-status() (
  [[ ${gha_event_comment_reactions_url} ]] || return

  comment_body=${comment_body/actions/actions${job_url#*/actions}}

  set "${BPAN_DEBUG_BASH_X:-+x}"
  if $ok; then
    l1=$(
      git -C .. diff HEAD^ |
        grep '^@@' |
        tail -n1 |
        cut -d+ -f2 |
        cut -d, -f1
    )
    l1=$(( ${l1:-0} + 1 ))
    l2=$(( l1 + 8 ))

    url=$(git -C .. config remote.origin.url)
    url+=/blob/$GITHUB_REF_NAME/index.ini#L$l1-L$l2

    comment_body+=$'\n\n'":+1: &nbsp; **[Publish Successful - Index Updated]($url)**"
  else
    comment_body+=$'\n\n'":-1: &nbsp; **[Publish Failed - See Logs]($job_url)**"
  fi

  publish-gha:update-comment-body "$comment_body"
  $option_debug && set -x

  # Get index auth header made by action checkout@v3
  auth_header=$(
    git -C .. config http.https://github.com/.extraheader
  )

  if $ok; then
    echo 'Publish Successful'
  else
    echo 'Publish Failed'
  fi
)


#------------------------------------------------------------------------------
# Register logic
#------------------------------------------------------------------------------
publish:register() (
  source-once db

  github_id=$(ini:get user.github) ||
    error "Can't publish to GitHub." \
          "No 'user.github' id in $app config file"

  force_update=true db:sync
  db:get-index-info "$index"

  index_api_url=$(publish:get-index-api-url)

  say -y "Check Package is Ready to Register"
  publish:register-check
  say -g "Package is Ready to Register"

  index_dir=.bpan/bpan-index
  rm -fr "$index_dir"

  say -y "\nPrepare BPAN Index Pull Request"
  publish:register-update-index
  say -g "Pull Request is Prepared"

  say -y "\nSubmit BPAN Index Pull Request"
  pull_request_url=$(publish:register-post-pull-request)
  say -g "Pull Request Submitted"

  say "\n${G}See:$Z $pull_request_url"

  rm -fr "$index_dir"
)

publish:register-check() {
  local user
  user=$(ini:get user.github) ||
    error "No entry for 'user.github' in $root/config"
  token=$(ini:get "publish.github:$user.token") ||
    error "No entry for 'publish.github:$user.token' in $root/config"
  [[ $token =~ [a-zA-Z0-9]{36} ]] ||
    error "Your configured 'host.github.token' does not seem valid"
  o "GitHub token looks ok"

  +git:in-repo ||
    error "Not in a git repo directory"
  o "Inside a git repo directory"

  +git:is-clean ||
    error "Git repo has uncommitted changes"
  o "Git repo is in a clean state"

  [[ -f .bpan/config ]] ||
    error "Not in a bpan project directory"
  o "Inside a BPAN project directory"

  remote_url=$(git config remote.origin.url) ||
    error "No remote.origin.url found in .git/config"
  remote_url=${remote_url%.git}
  o "Remote url for project is '$remote_url'"

  if [[ $remote_url == git@github.com:*/* ]]; then
    remote_owner_repo=${remote_url#git@github.com:}
  elif [[ $remote_url == https://github.com/*/* ]]; then
    remote_owner_repo=${remote_url#https://github.com/}
  else
    error "'$remote_url' is not in a recognized format"
  fi
  package_id=github:$remote_owner_repo
  o "BPAN package full name is '$package_id'"
  package_owner=${remote_owner_repo%%/*}
  o "BPAN package owner is '$package_owner'"
  package_repo=${remote_owner_repo#*/}
  o "BPAN package repo is '$package_repo'"

  if grep -q '^\[package "'"$package_id"'"\]' "$index_file_path"; then
    error "Package '$package_id' is already registered"
  fi
  o "Package '$package_id' is not already registered"

  package_author=$(publish:get-package-author)
  o "User to update BPAN index is '$package_author'"

  bpan:get-pkg-vars
  package_name=$pkg_name
  o "Config package.name = '$package_name'"

  package_title=$(git config -f .bpan/config package.title) ||
    error "Config has no package.title"
  [[ $package_title != *CHANGEME* ]] ||
    error "Please change the 'package.title' entry in '.bpan/config'"
  o "Config package.title = '$package_title'"

  package_version=$(git config -f .bpan/config package.version) ||
    error "Config has no package.version"
  o "Config package.version = '$package_version'"

  package_license=$(git config -f .bpan/config package.license) ||
    error "Config has no package.license"
  o "Config package.license = '$package_license'"

  package_summary=$(git config -f .bpan/config package.summary) ||
    true
  o "Config package.summary = '$package_summary'"

  package_type=$(git config -f .bpan/config package.type) ||
    error "Config has no package.type"
  o "Config package.type = '$package_type'"

  package_tag=$(git config -f .bpan/config package.tag) ||
    true
  o "Config package.tag = '$package_tag'"

  [[ $package_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    error "Config package.version '$package_version' does not match '#.#.#'"
  [[ $package_version != 0.0.0 ]] ||
    error "Can't register package with version '0.0.0'." \
          "Try 'bpan publish --bump'."
  o "Package version '$package_version' looks ok"

  +git:tag-exists "$package_version" ||
    error "No tag '$package_version' found"
  o "Git tag '$package_version' exists"

  package_commit=$(+git:commit-sha "$package_version")
  [[ $package_commit == "$(+git:commit-sha HEAD)" ]] ||
    error "Git tag '$package_version' commit is not HEAD commit"
  o "Git commit for tag '$package_version' is HEAD commit"

  +git:tag-pushed "$package_version" ||
    error "Git tag '$package_version' not pushed"
  o "Git commit for tag '$package_version' is pushed to origin"

  # VERSION is correct
  # Changes is correct
  # License file looks right
  # Tests pass

  o "Running the test suite:"
  BASHPLUS_DEBUG_STACK='' bpan-run test ||
    error "Test suite failed"
}

publish:register-update-index() (
  local entry head line

  fork_repo_url=git@github.com:$github_id/${index_api_url##*/}

  forked=false
  o "Cloning fork: '$fork_repo_url'"
  i=0
  while
    (( i++ < 10 )) &&
    ! git clone \
        --quiet \
        "$fork_repo_url" \
        "$index_dir" \
        2>/dev/null
  do
    mkdir -p "$index_dir"
    if ! $forked; then
      +post "$index_api_url/forks" >/dev/null
      o "Forked $index_from"
      forked=true
    fi
    say -y "  * Waiting for fork to be ready to clone..."
    sleep 1
    rm -fr "$index_dir"
  done
  if (( i >= 10 )); then
    error "Failed to clone '$fork_repo_url'"
  fi
  o "Cloned '$fork_repo_url'"

  fork_branch=$package_owner/$package_name

  git -C "$index_dir" checkout --quiet -b "$fork_branch"
  o "Created branch '$fork_branch'"
  git -C "$index_dir" fetch --quiet \
    "$index_from" \
    "$index_branch"
  o "Fetched '$index_branch' branch of '$index_from'"
  git -C "$index_dir" reset --quiet --hard FETCH_HEAD
  o "Hard reset HEAD to '$index_from' HEAD"

  (
    index_file_dir=$index_dir
    index_file_path=$index_file_dir/$index_file_name
    publish:add-new-index-entry
    publish:update-index Register
  )

  o "Committed the new index entry to the bpan-index fork"

  git -C "$index_dir" push --quiet --force origin "$fork_branch" &>/dev/null
  o "Pushed the new fork commit"
)

publish:register-post-pull-request() (
  fork_branch=$package_owner/$package_name
  head=$github_id:$fork_branch
  base=$index_branch
  title="Register $package_id=$package_version"
  http=https://github.com/$remote_owner_repo/tree/$package_version
  body=$(+json-escape "\
Please add this new package to the \
[BPAN Index]($index_from/blob/$index_branch/$index_file_name):

> $http

    package: $package_id
    title:   $package_title
    version: $package_version
    license: $package_license
    author:  $package_author"
  )

  json=$(cat <<...
{
  "head":  "$head",
  "base":  "$base",
  "title": "$title",
  "body":  "$body",
  "maintainer_can_modify": true
}
...
  )

  json=${json//$'\n'/\ }

  response=$(
    +post \
      "$index_api_url/pulls" \
      "$json"
  )

  pull_request_url=$(
    echo "$response" |
      grep '^  "html_url":' ||
      error "Unrecognized PR response:\n$(head <<<"$response")..."
  )

  echo "$pull_request_url" |
    head -n1 |
    cut -d'"' -f4
)


#------------------------------------------------------------------------------
# Miscellaneous functions
#------------------------------------------------------------------------------
+json-escape() (
  string=$1
  string=${string//$'\n'/\\n}
  string=${string//\"/\\\"}
  echo "$string"
)

+post() (
  url=$1
  data=${2-}
  cache=.bpan/bpan-index
  options=()
  if [[ $data ]]; then
    options+=(--data "$data")
  fi

  response=$(
    curl \
      --silent \
      --show-error \
      --request POST \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer $token" \
      --stderr "$cache/stderr" \
      --dump-header "$cache/header" \
      "${options[@]}" \
      "$url"
  )

  if grep -q '^ \+"errors":' <<<"$response"; then
    msg=$(grep '^ \+"message":' <<<"$response" || true)
    if [[ $msg ]]; then
      msg=$(
        echo "$msg" |
          head -n1 |
          cut -d'"' -f4
      )
    fi
    error "${msg:-"Unknown error for 'curl $url'"}" "$response"
  fi

  echo "$response"
)

o() (
  say -y "* $1"
)
