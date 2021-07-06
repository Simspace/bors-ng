defmodule GitHub.Checks do
  def succeed!(repo, branch, name, description \\ nil) do
    set_status!(repo, branch, name, "success", description)
  end

  def fail!(repo, branch, name, description \\ nil) do
    set_status!(repo, branch, name, "failure", description)
  end

  defp set_status!(repo, branch, name, status, description) do
    %{commit: commit} = GitHub.get_branch!(repo, branch)
    GitHub.post!(
      "token #{GitHub.access_token}",
      "/repos/#{repo}/statuses/#{commit}",
      %{
        context: name,
        state: status,
        description: description
      }
    )
  end
end
