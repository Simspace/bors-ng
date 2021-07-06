defmodule BorsTests do
  use ExUnit.Case, async: false
  @moduletag timeout: 10 * 60 * 1_000

  @staging "staging"
  @into "testing/into"
  @base_into "testing/base-into"
  @base_hook_into "testing/base-hook-into"
  @base_squash_into "testing/base-squash-into"
  @normal_pr_1 "testing/normal-pr-1"
  @normal_pr_2 "testing/normal-pr-2"
  @custom_merge_pr_1 "testing/custom-merge-pr-1"
  @custom_merge_pr_2 "testing/custom-merge-pr-2"
  @merge_conflict_pr_1 "testing/merge-conflict-pr-1"
  @merge_conflict_pr_2 "testing/merge-conflict-pr-2"
  @empty_pr "testing/empty-pr"

  @ci_status "testing/bors-ng"

  @poll_interval 1_000

  setup do
    repo = Confex.fetch_env!(:gh, :test_repo)
    close_all_open_prs!(repo)
    on_exit(fn -> close_all_open_prs!(repo) end)

    # Ngrok has a limit of 20 requests per minute to the external URL.
    # Each webhook counts as a request, so...
    Process.sleep(60 * 1_000)

    %{repo: repo}
  end

  test "can merge two normal PRs", %{repo: repo} do
    %{commit: commit} = reset_repo_state!(repo, @base_into)

    %{issue_number: pr1} = GitHub.create_pull_request!(repo, @into, @normal_pr_1)
    %{issue_number: pr2} = GitHub.create_pull_request!(repo, @into, @normal_pr_2)

    GitHub.comment_on_issue!(repo, pr1, "bors r+")
    GitHub.comment_on_issue!(repo, pr2, "bors r+")

    {:changed, _} = poll_branch(repo, @staging, commit)
    GitHub.Checks.succeed!(repo, @staging, @ci_status)

    {:changed, _} = poll_branch(repo, @into, commit, timeout: 30 * 1_000)
    # To ensure that the PRs merged, it's enough to check that certain files exist.
    {:ok, _} = GitHub.get_file!(repo, "normal-pr-1", @into)
    {:ok, _} = GitHub.get_file!(repo, "normal-pr-2", @into)
  end

  test "can squash merge two normal PRs", %{repo: repo} do
    %{commit: commit} = reset_repo_state!(repo, @base_squash_into)

    %{issue_number: pr1} = GitHub.create_pull_request!(repo, @into, @normal_pr_1)
    %{issue_number: pr2} = GitHub.create_pull_request!(repo, @into, @normal_pr_2)

    GitHub.comment_on_issue!(repo, pr1, "bors r+")
    GitHub.comment_on_issue!(repo, pr2, "bors r+")

    {:changed, _} = poll_branch(repo, @staging, commit)
    GitHub.Checks.succeed!(repo, @staging, @ci_status)

    {:changed, _} = poll_branch(repo, @into, commit)
    # To ensure that the PRs merged, it's enough to check that certain files exist.
    {:ok, _} = GitHub.get_file!(repo, "normal-pr-1", @into)
    {:ok, _} = GitHub.get_file!(repo, "normal-pr-2", @into)
  end

  test "can merge two PRs with a custom merge", %{repo: repo} do
    %{commit: commit} = reset_repo_state!(repo, @base_into)

    %{issue_number: pr1} = GitHub.create_pull_request!(repo, @into, @custom_merge_pr_1)
    %{issue_number: pr2} = GitHub.create_pull_request!(repo, @into, @custom_merge_pr_2)

    GitHub.comment_on_issue!(repo, pr1, "bors r+")
    GitHub.comment_on_issue!(repo, pr2, "bors r+")

    {:changed, _} = poll_branch(repo, @staging, commit)
    GitHub.Checks.succeed!(repo, @staging, @ci_status)

    {:changed, _} = poll_branch(repo, @into, commit, timeout: 30 * 1_000)
    {:ok, contents} = GitHub.get_file!(repo, "file-with-custom-merge", @into)
    assert String.match?(contents, ~r/custom-merge-pr-1/)
    assert String.match?(contents, ~r/custom-merge-pr-2/)
  end

  test "can run hooks successfully on merge and see hook output", %{repo: repo} do
    %{commit: commit} = reset_repo_state!(repo, @base_hook_into)

    %{issue_number: pr} = GitHub.create_pull_request!(repo, @into, @empty_pr)
    GitHub.comment_on_issue!(repo, pr, "bors r+")

    {:changed, _} = poll_branch(repo, @staging, commit)
    GitHub.Checks.succeed!(repo, @staging, @ci_status)

    {:changed, _} = poll_branch(repo, @into, commit)
    # Same here, the hooks just insert empty files with their names
    {:ok, _} = GitHub.get_file!(repo, "before-merge", @into)
    {:ok, _} = GitHub.get_file!(repo, "after-merge", @into)
  end

  test "can still correctly handle merge conflicts by splitting", %{repo: repo} do
    %{commit: commit} = reset_repo_state!(repo, @base_into)

    %{issue_number: pr1} = GitHub.create_pull_request!(repo, @into, @merge_conflict_pr_1)
    %{issue_number: pr2} = GitHub.create_pull_request!(repo, @into, @merge_conflict_pr_2)

    GitHub.comment_on_issue!(repo, pr1, "bors r+")
    GitHub.comment_on_issue!(repo, pr2, "bors r+")

    {:changed, staging_commit} = poll_branch(repo, @staging, commit, timeout: 10 * 60 * 1_000)
    {:ok, contents} = GitHub.get_file!(repo, "merge-conflict-file", @staging)

    # Check that the contents of staging have one of the PRs, but not both
    # i.e. that the first batch containing both failed to merge and Bors
    # automatically split it.
    case {String.match?(contents, ~r/merge-conflict-pr-1/), String.match?(contents, ~r/merge-conflict-pr-2/)} do
      # Sadly, a xor operator doesn't exist.
      {true, false} -> assert true
      {false, true} -> assert true
      {_, _} -> assert false
    end

    Process.sleep(30 * 1_000)  # More sleeps to ensure we don't hit ngrok rate limits
    GitHub.Checks.fail!(repo, @staging, @ci_status)
    {:changed, _} = poll_branch(repo, @staging, staging_commit)
    Process.sleep(30 * 1_000)
    GitHub.Checks.fail!(repo, @staging, @ci_status)

    # Check that `into` hasn't changed
    %{commit: ^commit} = GitHub.get_branch!(repo, @into)
  end

  @doc """
  Block until the specified branch changes from the commit specified.
  Kind of gross, but it's simpler than setting up webhooks for these tests.
  """
  @spec poll_branch(String.t(), String.t(), String.t()) :: :changed | :timeout
  def poll_branch(repo, branch, commit, options \\ []) do
    %{timeout: timeout} = Enum.into(options, %{timeout: 5 * 60 * 1_000})
    start = DateTime.utc_now()

    iterate(:timeout, fn _ ->
      Process.sleep(@poll_interval)
      here = DateTime.utc_now()
      if DateTime.diff(here, start, :millisecond) >= timeout do
        :done
      else
        %{commit: current_head} = GitHub.get_branch!(repo, branch)
        if current_head != commit do
          {:done, {:changed, current_head}}
        else
          {:continue, :timeout}
        end
      end
    end)
  end

  @spec iterate(any(), (any() -> {:continue, any()} | :done)) :: any()
  defp iterate(init, f) do
    case f.(init) do
      {:continue, next} ->
        iterate(next, f)
      {:done, value} ->
        value
      :done ->
        init
    end
  end

  def close_all_open_prs!(repo) do
    %{prs: prs} = GitHub.get_open_pull_requests!(repo)
    prs |> Enum.reduce(:ok, fn %{issue_number: pr}, _ ->
      GitHub.close_pull_request!(repo, pr)
      :ok
    end)
    GitHub.Checks.fail!(repo, @staging, @ci_status)
  end

  @spec reset_repo_state!(String.t(), String.t()) :: %{commit: String.t()}
  defp reset_repo_state!(repo, base_branch) do
    %{commit: commit} = GitHub.get_branch!(repo, base_branch)

    GitHub.force_push!(repo, @into, base_branch)
    GitHub.force_push!(repo, @staging, base_branch)

    %{commit: commit}
  end
end
