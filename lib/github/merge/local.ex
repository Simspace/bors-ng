defmodule BorsNG.GitHub.Merge.Local do
  @moduledoc """
  Uses local Git to construct staging/trying branches instead of GitHub's
  API.

  Only used when local merges are enabled.
  """

  use GenServer

  alias BorsNG.Database.Repo
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Project
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.GitHub
  alias BorsNG.GitHub.Merge.Hooks
  alias BorsNG.Worker.Batcher

  @bors_author ["-c", "user.name='bors-ng'", "-c", "user.email='bors@app.bors.tech'"]

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(_) do
    {:ok, nil}
  end

  @doc """
  GitHub allows GH Apps to authenticate over HTTPS using a username of
  'x-access-token' and a password of the installation access token, which
  happily gives us a way to authenticate CLI git commands.
  """
  def cli_creds(repo_conn) do
    {:raw, token} = GitHub.get_raw_token!(repo_conn)
    "x-access-token:#{token}"
  end

  @spec merge_batch!(Batch.t(), list(LinkPatchBatch.t()), %{commit: String.t(), tree: String.t()}) ::
          %{commit: String.t(), tree: String.t()} | :conflict
  def merge_batch!(batch, patch_links, base) do
    GenServer.call(__MODULE__, {:merge_batch, batch, patch_links, base}, :infinity)
  end

  @spec squash_merge_batch!(Batch.t(), list(LinkPatchBatch.t()), map) ::
          %{commit: String.t(), tree: String.t()}
  def squash_merge_batch!(batch, patch_links, toml) do
    GenServer.call(__MODULE__, {:squash_merge_batch, batch, patch_links, toml}, :infinity)
  end

  def handle_call(msg, _from, state) do
    reply = do_handle_call(msg)
    {:reply, reply, state}
  end

  defp do_handle_call({:merge_batch, batch, patch_links, base}) do
    batch = batch |> Repo.preload([:project])
    workdir = batch.project.name

    repo_conn = Project.installation_connection(batch.project.repo_xref, Repo)

    stmp = "#{batch.project.staging_branch}.tmp"

    # Create the staging.tmp branch before we push to it
    GitHub.synthesize_commit!(
      repo_conn,
      %{
        branch: stmp,
        tree: base.tree,
        parents: [base.commit],
        commit_message: "[ci skip][skip ci][skip netlify]",
        committer: nil
      }
    )

    # We make sure to clone the repository for each batch, rather than
    # trying to reuse it, because hooks may change behavior in ways that could
    # persist between batches in ways that Git can't detect, like modifying
    # the .git/config.
    File.rm_rf!(workdir)
    init_project_repo!(batch.project, cli_creds(repo_conn))

    git = fn args -> System.cmd("git", @bors_author ++ args, cd: workdir) end

    git.(["fetch", "origin", batch.into_branch])
    git.(["checkout", "origin/#{batch.into_branch}"])

    Hooks.invoke_before_merge_hook!(workdir)

    merge_status =
      patch_links
      |> Enum.reduce(:merged, fn link_patch_batch, status ->
        case status do
          :conflict ->
            :conflict

          _ ->
            link_patch_batch = link_patch_batch |> Repo.preload([:patch])
            patch = link_patch_batch.patch

            git.(["fetch", "origin", patch.commit])

            {_, exit_code} =
              git.([
                "merge",
                patch.commit,
                "-m",
                "[ci skip][skip ci][skip netlify] -bors-staging-tmp-#{patch.pr_xref}"
              ])

            case exit_code do
              0 -> status
              _ -> :conflict
            end
        end
      end)

    case merge_status do
      :conflict ->
        :conflict

      :merged ->
        Hooks.invoke_after_merge_hook!(workdir)
        commit_hook_changes!(workdir)
        persist_local_to_github!(stmp, workdir)

        local_commit_info(batch.project.name)
    end
  end

  defp do_handle_call({:squash_merge_batch, batch, patch_links, toml}) do
    batch = batch |> Repo.preload([:project])
    workdir = batch.project.name

    repo_conn = Project.installation_connection(batch.project.repo_xref, Repo)

    stmp = "#{batch.project.staging_branch}-squash-merge.tmp"

    # We make sure to clone the repository for each batch, rather than
    # trying to reuse it, because hooks may change behavior in ways that could
    # persist between batches in ways that Git can't detect, like modifying
    # the .git/config.
    File.rm_rf!(workdir)
    init_project_repo!(batch.project, cli_creds(repo_conn))

    git = fn args -> System.cmd("git", @bors_author ++ args, cd: workdir) end

    git.(["fetch", "origin", batch.into_branch])
    git.(["checkout", "origin/#{batch.into_branch}"])

    Hooks.invoke_before_merge_hook!(workdir)

    head =
      patch_links
      |> Enum.reduce("origin/#{batch.into_branch}", fn patch_link, prev_head ->
        patch_link = patch_link |> Repo.preload([:patch])
        patch = patch_link.patch

        {:ok, commits} = GitHub.get_pr_commits(repo_conn, patch.pr_xref)
        {:ok, pr} = GitHub.get_pr(repo_conn, patch.pr_xref)

        {token, _} = repo_conn
        user = GitHub.get_user_by_login!(token, pr.user.login)

        git.(["fetch", "origin", patch.commit])
        {_, 0} = git.(["merge", patch.commit])
        %{tree: tree} = local_commit_info(workdir)

        # If a user doesn't have a public email address in their GH profile
        # then get the email from the first commit to the PR
        user_email =
          if user.email != nil do
            user.email
          else
            Enum.at(commits, 0).author_email
          end

        # Manually create a squash commit with the directory contents after the merge
        commit_message =
          Batcher.Message.generate_squash_commit_message(
            pr,
            commits,
            user_email,
            toml.cut_body_after
          )

        {new_head, 0} = git.(["commit-tree", tree, "-p", prev_head, "-m", commit_message])
        String.trim(new_head)
      end)

    git.(["checkout", head])
    Hooks.invoke_after_merge_hook!(workdir)
    commit_hook_changes!(workdir)

    persist_local_to_github!(stmp, workdir)
    GitHub.delete_branch!(repo_conn, stmp)
    local_commit_info(workdir)
  end

  @spec local_commit_info(String.t()) :: %{commit: String.t(), tree: String.t()}
  defp local_commit_info(workdir) do
    {commit, 0} = System.cmd("git", ["log", "-n1", "--pretty=%H"], cd: workdir)
    {tree, 0} = System.cmd("git", ["log", "-n1", "--pretty=%T"], cd: workdir)

    %{commit: String.trim(commit), tree: String.trim(tree)}
  end

  @spec init_project_repo!(Project.t(), String.t()) :: :ok
  defp init_project_repo!(project, creds) do
    System.cmd("git", [
      "clone",
      "https://#{creds}@github.com/#{project.name}.git",
      "--recursive",
      project.name
    ])

    :ok
  end

  @spec persist_local_to_github!(String.t(), String.t()) :: :ok
  defp persist_local_to_github!(branch_name, workdir) do
    # Credentials already exist in the URL for 'origin' here, from the clone.
    # Each access token is valid for an hour, so there shouldn't be a need to
    # refresh it before pushing.
    {_, 0} =
      System.cmd(
        "git",
        ["push", "origin", "--force", "HEAD:refs/heads/#{branch_name}"],
        cd: workdir
      )

    :ok
  end

  @doc """
  The intended semantics are that hooks can change the repo filesystem, and
  we'll combine those changes with our merge commit. This function is careful
  to not add a new commit to the commit history.
  """
  @spec commit_hook_changes!(String.t()) :: :ok
  def commit_hook_changes!(workdir) do
    git = fn args -> System.cmd("git", @bors_author ++ args, cd: workdir) end
    {last_msg, 0} = git.(["log", "-n1", "--pretty=%B"])
    git.(["add", "-A"])
    git.(["commit", "--amend", "-m", last_msg])
    :ok
  end
end
