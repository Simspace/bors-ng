defmodule BorsNG.GitHub.Merge.Hooks do
  @moduledoc """
  Runs shell scripts during Bors's merge process.

  Only invoked when local merges are enabled.
  """

  defp config do
    Confex.fetch_env!(:bors, __MODULE__)
  end

  defp hooks_dir do
    config[:hooks_dir]
  end

  @spec invoke_before_merge_hook!(binary) :: nil
  def invoke_before_merge_hook!(project_dir) do
    hook_file = File.cwd!()
    |> Path.join(project_dir)
    |> Path.join(hooks_dir())
    |> Path.join("before-merge")

    case File.exists?(hook_file) do
      false ->
        nil

      true ->
        {_, 0} = System.cmd(hook_file, [], cd: project_dir)
        nil
    end
  end

  @spec invoke_after_merge_hook!(binary) :: nil
  def invoke_after_merge_hook!(project_dir) do
    hook_file = File.cwd!()
    |> Path.join(project_dir)
    |> Path.join(hooks_dir())
    |> Path.join("after-merge")

    case File.exists?(hook_file) do
      false ->
        nil

      true ->
        {_, 0} = System.cmd(hook_file, [], cd: project_dir)
        nil
    end
  end
end