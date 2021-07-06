defmodule GitHub do
  @api_root "https://api.github.com"
  @content_type "application/vnd.github.v3+json"

  @type pr :: %{issue_number: integer}

  def installation do
    Confex.fetch_env!(:gh, :installation_id)
  end

  @spec access_token() :: binary
  def access_token do
    %{status: 201, body: body} = post!(
      "Bearer #{Tokens.default_token}",
      "/app/installations/#{installation()}/access_tokens",
      ""
    )

    Poison.decode!(body)["token"]
  end

  @spec get_branch!(binary, binary) :: %{commit: binary, tree: binary}
  def get_branch!(repo, branch) do
    %{status: 200, body: body} = get!(
      "token #{access_token()}",
      "/repos/#{repo}/branches/#{branch}"
    )

    head = Poison.decode!(body)["commit"]
    %{commit: head["sha"], tree: head["commit"]["tree"]["sha"]}
  end

  @spec get_open_pull_requests!(String.t()) :: %{prs: list(pr)}
  def get_open_pull_requests!(repo) do
    %{status: 200, body: body} = get!(
      "token #{access_token()}",
      "/repos/#{repo}/pulls?state=open&per_page=100"
    )

    prs =
      body
      |> Poison.decode!()
      |> Enum.map(fn pr -> %{issue_number: pr["number"]} end)

    %{prs: prs}
  end

  @spec create_pull_request!(String.t(), String.t(), String.t()) :: pr
  def create_pull_request!(repo, into_branch, from_branch) do
    %{status: 201, body: body} = post!(
      "token #{access_token()}",
      "/repos/#{repo}/pulls",
      %{
        title: from_branch,
        head: from_branch,
        base: into_branch
      }
    )

    result = Poison.decode!(body)
    %{issue_number: result["number"]}
  end

  @spec close_pull_request!(String.t(), integer) :: map
  def close_pull_request!(repo, issue_number) do
    %{status: 200, body: body} = patch!(
      "token #{access_token()}",
      "/repos/#{repo}/pulls/#{issue_number}",
      %{
        state: "closed"
      }
    )

    Poison.decode!(body)
  end

  @spec get_file!(String.t(), String.t(), String.t()) ::
    {:ok, String.t()} | :not_found
  def get_file!(repo, path, ref) do
    %{status: status, body: body} = get!(
      "token #{access_token()}",
      "/repos/#{repo}/contents/#{path}?ref=#{ref}"
    )

    case status do
      200 ->
        contents =
          Poison.decode!(body)["content"]
          |> Base.decode64!(ignore: :whitespace)

        {:ok, contents}
      _ ->
        :not_found
    end
  end

  @spec comment_on_issue!(String.t(), integer, String.t()) :: map
  def comment_on_issue!(repo, issue_number, comment) do
    %{status: 201, body: body} = post!(
      "token #{access_token()}",
      "/repos/#{repo}/issues/#{issue_number}/comments",
      %{
        body: comment
      }
    )

    Poison.decode!(body)
  end

  @spec force_push!(String.t(), String.t(), String.t()) :: map
  def force_push!(repo, into_branch, from_branch) do
    %{commit: head} = get_branch!(repo, from_branch)

    patch!(
      "token #{access_token()}",
      "/repos/#{repo}/git/refs/heads/#{into_branch}",
      %{
        sha: head,
        force: true
      }
    )
  end

  @spec get!(binary, binary, binary, list) :: map
  def get!(
         authorization,
         path,
         content_type \\ @content_type,
         params \\ []
       ) do
    authorization
    |> tesla_client(content_type)
    |> Tesla.get!(URI.encode(path), params)
  end

  @spec post!(binary, binary, binary, binary) :: map
  def post!(
         authorization,
         path,
         body,
         content_type \\ @content_type
       ) do
    authorization
    |> tesla_client(content_type)
    |> Tesla.post!(URI.encode(path), Poison.encode!(body))
  end

  @spec patch!(binary, binary, binary, binary) :: map
  def patch!(
    authorization,
    path,
    body,
    content_type \\ @content_type
  ) do
    authorization
    |> tesla_client(content_type)
    |> Tesla.patch!(URI.encode(path), Poison.encode!(body))
  end

  defp tesla_client(authorization, content_type) do
    middleware = [
      {Tesla.Middleware.BaseUrl, @api_root},
      {Tesla.Middleware.Headers,
       [
         {"authorization", authorization},
         {"accept", content_type},
         {"user-agent", "bors-ng https://bors.tech"}
       ]},
      {Tesla.Middleware.Retry, delay: 100, max_retries: 5}
    ]

    Tesla.client(middleware)
  end
end
