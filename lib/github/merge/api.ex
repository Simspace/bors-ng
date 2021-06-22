defmodule BorsNG.GitHub.Merge.API do
  @moduledoc """
  Merge together batch patches using GitHub's API. This is
  the default.
  """

  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Repo
  alias BorsNG.Database.Project
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.GitHub
  require Logger

  def merge_batch!(batch) do
    project = batch.project
    repo_conn = Project.installation_connection(project.repo_xref, Repo)

    patch_links =
      Repo.all(LinkPatchBatch.from_batch(batch.id))
      |> Enum.sort_by(& &1.patch.pr_xref)    

    stmp = "#{project.staging_branch}.tmp"    

    base =
      GitHub.get_branch!(
        repo_conn,
        batch.into_branch
      )    

    tbase = %{
      tree: base.tree,
      commit:
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
    }    

    do_merge_patch = fn %{patch: patch}, branch ->
      case branch do
        :conflict ->
          :conflict

        :canceled ->
          :canceled

        _ ->
          GitHub.merge_branch!(
            repo_conn,
            %{
              from: patch.commit,
              to: stmp,
              commit_message:
                "[ci skip][skip ci][skip netlify] -bors-staging-tmp-#{patch.pr_xref}"
            }
          )
      end
    end    

    Enum.reduce(patch_links, tbase, do_merge_patch)    
  end

  def squash_merge_batch!(batch, patch_links, base, toml) do
    repo_conn = Project.installation_connection(batch.project.repo_xref, Repo)

    stmp = "#{batch.project.staging_branch}-squash-merge.tmp"
    GitHub.force_push!(repo_conn, base.commit, stmp)    

    new_head =
      Enum.reduce(patch_links, base.commit, fn patch_link, prev_head ->
        Logger.debug("Patch Link #{inspect(patch_link)}")
        Logger.debug("Patch #{inspect(patch_link.patch)}")

        {:ok, commits} = GitHub.get_pr_commits(repo_conn, patch_link.patch.pr_xref)
        {:ok, pr} = GitHub.get_pr(repo_conn, patch_link.patch.pr_xref)

        {token, _} = repo_conn
        user = GitHub.get_user_by_login!(token, pr.user.login)

        Logger.debug("PR #{inspect(pr)}")
        Logger.debug("User #{inspect(user)}")

        # If a user doesn't have a public email address in their GH profile
        # then get the email from the first commit to the PR
        user_email =
          if user.email != nil do
            user.email
          else
            Enum.at(commits, 0).author_email
          end

        # The head SHA is the final commit in the PR.
        source_sha = pr.head_sha
        Logger.info("Staging branch #{stmp}")
        Logger.info("Commit sha #{source_sha}")

        # Create a merge commit for each PR.
        # Because each PR is merged on top of each other in stmp, we can verify against any merge conflicts
        merge_commit =
          GitHub.merge_branch!(
            repo_conn,
            %{
              from: source_sha,
              to: stmp,
              commit_message:
                "[ci skip][skip ci][skip netlify] -bors-staging-tmp-#{source_sha}"
            }
          )

        Logger.info("Merge Commit #{inspect(merge_commit)}")

        Logger.info("Previous Head #{inspect(prev_head)}")

        # Then compress the merge commit's changes into a single commit,
        # append it to the previous commit
        # Because the merges are iterative they contain *only* the changes from the PR vs the previous PR(or head)

        commit_message =
          Batcher.Message.generate_squash_commit_message(
            pr,
            commits,
            user_email,
            toml.cut_body_after
          )

        cpt =
          GitHub.create_commit!(
            repo_conn,
            %{
              tree: merge_commit.tree,
              parents: [prev_head],
              commit_message: commit_message,
              committer: %{name: user.name || user.login, email: user_email}
            }
          )

        Logger.info("Commit Sha #{inspect(cpt)}")
        cpt
      end)

    GitHub.delete_branch!(repo_conn, stmp)
    new_head
  end
end